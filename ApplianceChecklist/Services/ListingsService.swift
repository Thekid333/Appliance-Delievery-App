import Foundation
import CoreLocation
import SwiftUI
import UserNotifications
import BackgroundTasks
import os

/// Fetches scraped Marketplace listings from the GitHub Gist the PC scraper publishes,
/// then geocodes each listing's city to rank it by distance/cost from the user's home.
/// Also fires "banger" local notifications when a great, relevant listing lands.
@MainActor
final class ListingsService: ObservableObject {

    /// Background App Refresh task id (must match Info.plist BGTaskSchedulerPermittedIdentifiers).
    /// Short, frequent, best-effort wake-ups.
    nonisolated static let bgRefreshID = "com.appliancechecklist.snipe.refresh"
    /// Background *processing* task id — longer time budget, scheduled by the system in
    /// more favorable windows. Gives distance-based bangers room to geocode. Also in Info.plist.
    /// (nonisolated: referenced from the nonisolated task-registration path at launch.)
    nonisolated static let bgProcessingID = "com.appliancechecklist.snipe.processing"

    /// Unified log — watch with: `log stream --predicate 'subsystem == "com.appliancechecklist"'`
    /// or filter for "snipe" in Console.app to confirm background runs actually fire.
    private static let log = Logger(subsystem: "com.appliancechecklist", category: "snipe")

    // MARK: Stored config (UserDefaults)

    static let gistIDKey = "snipe.gistID"
    static let tokenKey = "snipe.githubToken"
    static let refreshIntervalKey = "snipe.refreshInterval"
    static let alertsEnabledKey = "snipe.alertsEnabled"
    static let alertKeywordsKey = "snipe.alertKeywords"
    static let alertMaxPriceKey = "snipe.alertMaxPrice"
    static let alertMaxMilesKey = "snipe.alertMaxMiles"
    static let alertedIDsKey = "snipe.alertedIDs"
    static let alertsSeededKey = "snipe.alertsSeeded"
    /// Persisted location -> [lat, lon] successes, so cold background launches don't
    /// start with an empty geocode cache (the in-memory one is wiped each process).
    static let geoCacheKey = "snipe.geoCache"
    /// Full snapshots of the user's saved listings (JSON), so bookmarks survive even
    /// after a listing drops out of the live feed (sold/removed).
    static let bookmarksKey = "snipe.bookmarks"

    @Published var gistID: String {
        didSet {
            UserDefaults.standard.set(gistID, forKey: Self.gistIDKey)
            // A different gist is a different resource — drop the ETag cache.
            lastETag = nil
            lastFeedListings = nil
        }
    }
    /// Optional personal access token — raises the GitHub API rate limit. Not required.
    @Published var githubToken: String {
        didSet { UserDefaults.standard.set(githubToken, forKey: Self.tokenKey) }
    }
    /// Auto-refresh interval in seconds (default 120 to stay under the unauthenticated rate limit).
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Self.refreshIntervalKey) }
    }

    // MARK: Banger alert rules

    @Published var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsEnabledKey) }
    }
    /// Comma-separated keywords; a listing must match at least one (empty = match any).
    @Published var alertKeywords: String {
        didSet { UserDefaults.standard.set(alertKeywords, forKey: Self.alertKeywordsKey) }
    }
    /// Only alert at/under this price (0 = no limit).
    @Published var alertMaxPrice: Int {
        didSet { UserDefaults.standard.set(alertMaxPrice, forKey: Self.alertMaxPriceKey) }
    }
    /// Only alert at/under this many miles away (0 = no limit).
    @Published var alertMaxMiles: Int {
        didSet { UserDefaults.standard.set(alertMaxMiles, forKey: Self.alertMaxMilesKey) }
    }

    // MARK: Published state

    @Published private(set) var ranked: [RankedListing] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    /// Listings the user has saved, most-recently-saved first. Snapshots, not just ids,
    /// so they remain viewable after they leave the live feed.
    @Published private(set) var bookmarkedListings: [Listing] = []

    // MARK: Internals

    private var homeAddress: String = ""
    private var homeCoordinate: CLLocationCoordinate2D?
    private var geocodedHomeFor: String?
    /// Cache: location string -> coordinate (or nil if it failed, to avoid re-querying).
    private var locationCache: [String: CLLocationCoordinate2D?] = [:]
    /// Disk-backed mirror of *successful* geocodes (location/home address -> [lat, lon]),
    /// so a fresh background process can compute distances without re-geocoding everything.
    private var persistedGeo: [String: [Double]] = [:]
    private let geocoder = CLGeocoder()

    /// Listing ids we've already alerted on (de-dup) and whether we've established a baseline.
    private var alertedIDs: Set<String>
    private var hasSeededAlerts: Bool

    /// Last successful fetch's ETag + decoded listings, kept in memory only.
    /// The auto-refresh loop polls every ~2 min but the scraper publishes less
    /// often, so most polls can be conditional GETs — GitHub answers 304 with
    /// no body, and 304s don't count against the rate limit. Process-local on
    /// purpose: a cold background launch has no cached feed, sends no ETag,
    /// and gets a full 200 — so alerts never depend on this cache.
    private var lastETag: String?
    private var lastFeedListings: [Listing]?

    var isConfigured: Bool { !gistID.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {
        let d = UserDefaults.standard
        self.gistID = d.string(forKey: Self.gistIDKey) ?? ""
        self.githubToken = d.string(forKey: Self.tokenKey) ?? ""
        let stored = d.double(forKey: Self.refreshIntervalKey)
        self.refreshInterval = stored > 0 ? stored : 120

        self.alertsEnabled = d.bool(forKey: Self.alertsEnabledKey)
        self.alertKeywords = d.string(forKey: Self.alertKeywordsKey) ?? ""
        self.alertMaxPrice = d.integer(forKey: Self.alertMaxPriceKey)
        self.alertMaxMiles = d.integer(forKey: Self.alertMaxMilesKey)
        self.alertedIDs = Set(d.stringArray(forKey: Self.alertedIDsKey) ?? [])
        self.hasSeededAlerts = d.bool(forKey: Self.alertsSeededKey)
        self.persistedGeo = (d.dictionary(forKey: Self.geoCacheKey) as? [String: [Double]]) ?? [:]

        if let data = d.data(forKey: Self.bookmarksKey),
           let saved = try? JSONDecoder().decode([Listing].self, from: data) {
            self.bookmarkedListings = saved
        }

        // Warm the in-memory cache from disk so the very first (possibly background)
        // refresh of this process can already rank by distance.
        for (location, pair) in persistedGeo where pair.count == 2 {
            locationCache[location] = .some(CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]))
        }
    }

    // MARK: - Public API

    /// Refresh using a specific home address (geocoded once and cached).
    func refresh(homeAddress: String) async {
        self.homeAddress = homeAddress
        await refresh()
    }

    /// Foreground refresh: fetch, geocode, rank, and evaluate banger alerts.
    func refresh() async {
        await performRefresh(background: false)
    }

    /// Background App Refresh entry point: reschedule, then do a light fetch + alert pass.
    func performBackgroundRefresh() async {
        Self.log.info("Snipe background task started")
        scheduleBackgroundRefresh()
        await performRefresh(background: true)
        Self.log.info("Snipe background task finished")
    }

    // MARK: - Bookmarks

    /// Saved listings decorated with current distance/cost (recomputed from the live
    /// geocode cache + home), preserving most-recently-saved order.
    var bookmarked: [RankedListing] { rank(bookmarkedListings) }

    func isBookmarked(_ id: String) -> Bool {
        bookmarkedListings.contains { $0.id == id }
    }

    /// Save the listing if it isn't saved, otherwise remove it.
    func toggleBookmark(_ listing: Listing) {
        if let idx = bookmarkedListings.firstIndex(where: { $0.id == listing.id }) {
            bookmarkedListings.remove(at: idx)
        } else {
            bookmarkedListings.insert(listing, at: 0)  // most-recent first
        }
        saveBookmarks()
    }

    func removeBookmark(_ id: String) {
        bookmarkedListings.removeAll { $0.id == id }
        saveBookmarks()
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarkedListings) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
    }

    private func performRefresh(background: Bool) async {
        // In the background we may be a fresh process — pull the saved home address.
        if homeAddress.trimmingCharacters(in: .whitespaces).isEmpty {
            homeAddress = UserDefaults.standard.string(forKey: DriveTimeService.homeAddressKey) ?? ""
        }

        guard isConfigured else {
            errorMessage = "Add your Gist ID in Snipe settings to load listings."
            return
        }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let feed = try await fetchFeed()
            Self.log.info("Snipe refresh fetched \(feed.listings.count) listings (background=\(background))")
            await ensureHomeGeocoded()
            // Show results immediately with whatever distances are already cached…
            ranked = rank(feed.listings)
            lastUpdated = Date()
            // Fast alert pass (price/keyword bangers don't need geocoding).
            evaluateAlerts(ranked)

            if !background {
                // Foreground: fill in every missing geocode (throttled), then re-evaluate.
                await geocodeMissing(in: feed.listings)
                evaluateAlerts(ranked)
            } else {
                // Background: geocoding everything would blow the time budget, but a
                // distance-limited banger can NEVER fire without a distance. So resolve
                // just the handful of listings that already pass the cheap rules, then
                // re-rank and re-evaluate. This is what previously forced the user to
                // reopen the app before distance-based alerts would show up.
                await geocodeCandidates(in: ranked)
                ranked = rank(feed.listings)
                evaluateAlerts(ranked)
            }
        } catch {
            errorMessage = friendlyError(error)
            Self.log.error("Snipe refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Background scheduling

    /// Queue both a short app-refresh and a longer processing task. iOS picks whichever
    /// fits the moment; queuing both maximizes the chance of *some* background run.
    func scheduleBackgroundRefresh() {
        submitAppRefresh()
        submitProcessing()
    }

    private func submitAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)  // ~15 min floor
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.info("Scheduled app-refresh task")
        } catch {
            Self.log.error("app-refresh submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func submitProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.bgProcessingID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = true   // we always need to hit GitHub
        request.requiresExternalPower = false        // don't wait for the charger
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.log.info("Scheduled processing task")
        } catch {
            Self.log.error("processing submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Register the processing-task handler. Must run at launch (App.init) so iOS can
    /// hand us the task even after a cold background relaunch. The app-refresh handler is
    /// registered separately by SwiftUI's `.backgroundTask(.appRefresh:)` modifier.
    ///
    /// We spin up a fresh `ListingsService` here: all config and de-dup/geo state lives in
    /// UserDefaults, so a cold instance behaves correctly. An explicit expiration handler
    /// cancels in-flight work (geocode loops below check `Task.isCancelled`) and reports
    /// completion so iOS doesn't penalize our future background budget.
    nonisolated static func registerProcessingTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgProcessingID, using: nil) { task in
            let processingTask = task as? BGProcessingTask
            let work = Task { @MainActor in
                let service = ListingsService()
                await service.performBackgroundRefresh()
                processingTask?.setTaskCompleted(success: true)
            }
            processingTask?.expirationHandler = { work.cancel() }
        }
    }

    // MARK: - Networking

    private func fetchFeed() async throws -> ListingFeed {
        let id = gistID.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "https://api.github.com/gists/\(id)") else {
            throw ListingsError.badConfig
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let token = githubToken.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag = lastETag, lastFeedListings != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        var etag: String?
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                etag = http.value(forHTTPHeaderField: "ETag")
            case 304:
                // Feed unchanged since last fetch — reuse it (rate-limit-free).
                if let cached = lastFeedListings {
                    return ListingFeed(generatedAt: nil, count: cached.count, listings: cached)
                }
                throw ListingsError.emptyFeed  // unreachable: ETag only sent alongside a cached feed
            case 404: throw ListingsError.notFound
            case 403: throw ListingsError.rateLimited
            default: throw ListingsError.http(http.statusCode)
            }
        }

        // The gist response wraps the file; the actual feed JSON is a string inside it.
        let gist = try JSONDecoder().decode(GistResponse.self, from: data)
        guard let file = gist.files["listings.json"] else {
            throw ListingsError.emptyFeed
        }

        // GitHub truncates inline content over 1 MB; fall back to the raw URL if so.
        let feedData: Data
        if file.truncated == true, let raw = file.rawURL, let rawURL = URL(string: raw) {
            (feedData, _) = try await URLSession.shared.data(from: rawURL)
        } else if let content = file.content, let d = content.data(using: .utf8) {
            feedData = d
        } else {
            throw ListingsError.emptyFeed
        }
        let feed = try JSONDecoder().decode(ListingFeed.self, from: feedData)
        lastETag = etag
        lastFeedListings = feed.listings
        return feed
    }

    // MARK: - Ranking & geocoding

    private func rank(_ listings: [Listing]) -> [RankedListing] {
        listings.map { listing in
            var r = RankedListing(listing: listing, straightLineMiles: nil)
            if let coord = locationCache[listing.location] ?? nil, let home = homeCoordinate {
                let from = CLLocation(latitude: home.latitude, longitude: home.longitude)
                let to = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                r.straightLineMiles = from.distance(from: to) / 1609.34
            } else if let scraped = listing.scrapedDistanceMiles {
                r.straightLineMiles = scraped
            }
            return r
        }
    }

    private func ensureHomeGeocoded() async {
        let trimmed = homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { homeCoordinate = nil; return }
        guard geocodedHomeFor != trimmed else { return }
        // Reuse a persisted geocode if we have one — saves a lookup (and a failure point)
        // in the background, where the home address rarely changes between runs.
        if let pair = persistedGeo[trimmed], pair.count == 2 {
            homeCoordinate = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            geocodedHomeFor = trimmed
            return
        }
        if let coord = await geocode(trimmed) {
            homeCoordinate = coord
            geocodedHomeFor = trimmed
            persistGeo(coord, for: trimmed)
        }
    }

    /// Geocode the unique, not-yet-cached locations, throttled to respect CLGeocoder limits.
    private func geocodeMissing(in listings: [Listing]) async {
        guard homeCoordinate != nil else { return }
        let unique = Set(listings.map(\.location))
            .filter { !$0.isEmpty && locationCache[$0] == nil }
        guard !unique.isEmpty else { return }

        for location in unique.prefix(40) {  // cap per refresh; cached ones are free next time
            if Task.isCancelled { break }
            let coord = await geocode(location)
            cacheCoordinate(coord, for: location)
            // Re-rank incrementally so distances appear as they resolve.
            ranked = rank(listings)
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // ~1.2s between geocodes
        }
        ranked = rank(listings)
    }

    /// Background-only: geocode just the few listings that already pass the cheap rules
    /// (keyword/price/freshness) but still lack a distance, so a max-miles banger can fire
    /// without waiting for the next foreground open. Honors the task's time budget via
    /// cancellation, and is a no-op when no distance limit is configured.
    private func geocodeCandidates(in items: [RankedListing]) async {
        guard alertsEnabled, alertMaxMiles > 0, homeCoordinate != nil else { return }
        let candidates = items.filter { item in
            !alertedIDs.contains(item.id)
                && item.straightLineMiles == nil
                && passesCheapRules(item.listing)
                && !item.listing.location.isEmpty
                && locationCache[item.listing.location] == nil
        }
        guard !candidates.isEmpty else { return }
        Self.log.info("Snipe background geocoding \(candidates.count) candidate location(s)")

        for item in candidates.prefix(15) {
            if Task.isCancelled { break }
            let location = item.listing.location
            let coord = await geocode(location)
            cacheCoordinate(coord, for: location)
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // ~1s between geocodes
        }
    }

    /// Record a geocode result in memory (including failures, to skip re-querying this
    /// session) and persist successes so future cold/background launches reuse them.
    private func cacheCoordinate(_ coord: CLLocationCoordinate2D?, for location: String) {
        locationCache[location] = .some(coord)
        if let coord { persistGeo(coord, for: location) }
    }

    private func persistGeo(_ coord: CLLocationCoordinate2D, for key: String) {
        persistedGeo[key] = [coord.latitude, coord.longitude]
        UserDefaults.standard.set(persistedGeo, forKey: Self.geoCacheKey)
    }

    private func geocode(_ address: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(address) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let e = error as? ListingsError { return e.message }
        return error.localizedDescription
    }

    // MARK: - Banger alerts

    var alertKeywordList: [String] {
        alertKeywords
            .lowercased()
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Evaluate the feed and fire a notification for each new, qualifying listing (once).
    private func evaluateAlerts(_ items: [RankedListing]) {
        let ids = items.map(\.id)

        // First time we ever see a feed: take everything as the baseline so we don't
        // spam an alert for every pre-existing listing. Only items added *after* this fire.
        if !hasSeededAlerts {
            alertedIDs.formUnion(ids)
            hasSeededAlerts = true
            saveAlertState()
            return
        }

        guard alertsEnabled else { return }

        var fired = false
        for item in items where !alertedIDs.contains(item.id) {
            if isBanger(item) {
                fireBangerNotification(for: item)
                alertedIDs.insert(item.id)
                fired = true
            }
            // Items that fail are intentionally NOT marked seen — a later refresh may
            // resolve their distance and qualify them.
        }

        // Keep the de-dup set from growing in UserDefaults forever. Ids absent
        // from the feed were pruned by the scraper's 7-day retention and can't
        // return unless genuinely relisted — in which case re-alerting is right.
        if alertedIDs.count > 1000 {
            alertedIDs.formIntersection(ids)
            fired = true  // force a save of the shrunken set
        }

        if fired { saveAlertState() }
    }

    /// The rules that need no geocoding: freshness, keyword relevance, and price.
    /// Shared by `isBanger` and the background candidate picker so they agree on what's
    /// worth resolving a distance for.
    private func passesCheapRules(_ listing: Listing) -> Bool {
        // Freshness backstop: never alert on something listed more than a day ago.
        if let seen = listing.displayDate, Date().timeIntervalSince(seen) > 24 * 3600 {
            return false
        }

        // Relevance: title or category must contain a keyword (when keywords are set).
        let keywords = alertKeywordList
        if !keywords.isEmpty {
            let haystack = (listing.title + " " + (listing.category ?? "")).lowercased()
            guard keywords.contains(where: { haystack.contains($0) }) else { return false }
        }

        // Price ceiling.
        if alertMaxPrice > 0 {
            guard let price = listing.priceValue, price <= alertMaxPrice else { return false }
        }

        return true
    }

    /// A listing is a "banger" if it passes the cheap rules *and* the distance ceiling.
    private func isBanger(_ item: RankedListing) -> Bool {
        guard passesCheapRules(item.listing) else { return false }

        // Distance ceiling (unknown distance fails when a limit is set; resolves later).
        if alertMaxMiles > 0 {
            guard let miles = item.straightLineMiles, miles <= Double(alertMaxMiles) else { return false }
        }

        return true
    }

    private func fireBangerNotification(for item: RankedListing) {
        let listing = item.listing

        var headline = [listing.price]
        if let dist = item.distanceLabel { headline.append(dist) }
        if let cost = item.costLabel { headline.append(cost) }

        let content = UNMutableNotificationContent()
        content.title = "🔥 Banger — " + headline.joined(separator: " · ")
        content.body = listing.location.isEmpty ? listing.title : "\(listing.title) — \(listing.location)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        if let url = listing.marketplaceURL?.absoluteString {
            content.userInfo = ["url": url, "listingID": listing.id]
        }

        // trigger: nil delivers immediately.
        let request = UNNotificationRequest(identifier: "banger-\(listing.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Self.log.info("Fired banger notification for listing \(listing.id, privacy: .public)")
    }

    /// Treat everything currently in the feed as "already seen" so only listings that
    /// appear *after this moment* can fire. Call when the user turns alerts on.
    func rebaselineAlerts() {
        alertedIDs.formUnion(ranked.map(\.id))
        hasSeededAlerts = true
        saveAlertState()
    }

    private func saveAlertState() {
        let d = UserDefaults.standard
        d.set(Array(alertedIDs), forKey: Self.alertedIDsKey)
        d.set(hasSeededAlerts, forKey: Self.alertsSeededKey)
    }
}

// MARK: - Errors

enum ListingsError: Error {
    case badConfig, notFound, rateLimited, emptyFeed, http(Int)

    var message: String {
        switch self {
        case .badConfig: return "Invalid Gist ID."
        case .notFound: return "Gist not found. Check the Gist ID in settings."
        case .rateLimited: return "GitHub rate limit hit. Add a token in settings or slow the refresh."
        case .emptyFeed: return "No listings.json in that gist yet — run the scraper at least once."
        case .http(let code): return "Server error (HTTP \(code))."
        }
    }
}

// MARK: - GitHub Gist API shapes

private struct GistResponse: Decodable {
    let files: [String: GistFile]
}

private struct GistFile: Decodable {
    let content: String?
    let truncated: Bool?
    let rawURL: String?

    enum CodingKeys: String, CodingKey {
        case content, truncated
        case rawURL = "raw_url"
    }
}
