import Foundation
import CoreLocation
import SwiftUI
import UserNotifications
import BackgroundTasks

/// Fetches scraped Marketplace listings from the GitHub Gist the PC scraper publishes,
/// then geocodes each listing's city to rank it by distance/cost from the user's home.
/// Also fires "banger" local notifications when a great, relevant listing lands.
@MainActor
final class ListingsService: ObservableObject {

    /// Background App Refresh task id (must match Info.plist BGTaskSchedulerPermittedIdentifiers).
    static let bgRefreshID = "com.appliancechecklist.snipe.refresh"

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

    @Published var gistID: String {
        didSet { UserDefaults.standard.set(gistID, forKey: Self.gistIDKey) }
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

    // MARK: Internals

    private var homeAddress: String = ""
    private var homeCoordinate: CLLocationCoordinate2D?
    private var geocodedHomeFor: String?
    /// Cache: location string -> coordinate (or nil if it failed, to avoid re-querying).
    private var locationCache: [String: CLLocationCoordinate2D?] = [:]
    private let geocoder = CLGeocoder()

    /// Listing ids we've already alerted on (de-dup) and whether we've established a baseline.
    private var alertedIDs: Set<String>
    private var hasSeededAlerts: Bool

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
        scheduleBackgroundRefresh()
        await performRefresh(background: true)
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
            await ensureHomeGeocoded()
            // Show results immediately with whatever distances are already cached…
            ranked = rank(feed.listings)
            lastUpdated = Date()
            // Fast alert pass (price/keyword bangers don't need geocoding).
            evaluateAlerts(ranked)

            // Foreground only: fill in missing geocodes (throttled) and re-evaluate for
            // distance-based bangers. Skipped in the background to respect the time budget.
            if !background {
                await geocodeMissing(in: feed.listings)
                evaluateAlerts(ranked)
            }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Background scheduling

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)  // ~15 min floor
        try? BGTaskScheduler.shared.submit(request)
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

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
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
        return try JSONDecoder().decode(ListingFeed.self, from: feedData)
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
        if let coord = await geocode(trimmed) {
            homeCoordinate = coord
            geocodedHomeFor = trimmed
        }
    }

    /// Geocode the unique, not-yet-cached locations, throttled to respect CLGeocoder limits.
    private func geocodeMissing(in listings: [Listing]) async {
        guard homeCoordinate != nil else { return }
        let unique = Set(listings.map(\.location))
            .filter { !$0.isEmpty && locationCache[$0] == nil }
        guard !unique.isEmpty else { return }

        for location in unique.prefix(40) {  // cap per refresh; cached ones are free next time
            let coord = await geocode(location)
            locationCache[location] = .some(coord)  // store nil-failures too, so we don't retry endlessly
            // Re-rank incrementally so distances appear as they resolve.
            ranked = rank(listings)
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // ~1.2s between geocodes
        }
        ranked = rank(listings)
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
        if fired { saveAlertState() }
    }

    /// A listing is a "banger" if it's fresh and passes every configured rule.
    private func isBanger(_ item: RankedListing) -> Bool {
        let listing = item.listing

        // Freshness backstop: never alert on something first seen more than a day ago.
        if let seen = listing.firstSeenDate, Date().timeIntervalSince(seen) > 24 * 3600 {
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
