import SwiftUI
import UIKit

// MARK: - Tabs

/// The Snipe segmented control: three sort modes over the live feed, plus a Saved
/// view of bookmarked listings. ("Cheapest" was dropped — "Best deal" already ranks
/// by price + round-trip fuel, so it was effectively a condensed version of it.)
enum SnipeTab: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case closest = "Closest"
    case bestDeal = "Best deal"
    case bookmarks = "Saved"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .newest: return "clock.badge"
        case .closest: return "location.fill"
        case .bestDeal: return "star.fill"
        case .bookmarks: return "bookmark.fill"
        }
    }
}

// MARK: - Snipe tab

struct SnipeView: View {
    @EnvironmentObject private var listingsService: ListingsService
    @EnvironmentObject private var driveTimeService: DriveTimeService

    @State private var tab: SnipeTab = .newest
    @State private var searchText = ""
    @Binding var showingSettings: Bool

    private var visibleListings: [RankedListing] {
        // The Saved tab reads bookmarks (already newest-saved first); the rest sort the feed.
        var items = tab == .bookmarks ? listingsService.bookmarked : listingsService.ranked

        if !searchText.isEmpty {
            items = items.filter { $0.listing.title.localizedCaseInsensitiveContains(searchText) }
        }

        switch tab {
        case .newest:
            items.sort { ($0.listing.displayDate ?? .distantPast) > ($1.listing.displayDate ?? .distantPast) }
        case .closest:
            items.sort { sortAscending($0.straightLineMiles, $1.straightLineMiles) }
        case .bestDeal:
            items.sort { sortAscending($0.totalAcquisitionCost, $1.totalAcquisitionCost) }
        case .bookmarks:
            break  // keep most-recently-saved order
        }
        return items
    }

    /// Ascending sort that always pushes `nil` (unknown) values to the bottom.
    private func sortAscending(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sortBar

            if tab == .bookmarks {
                if listingsService.bookmarkedListings.isEmpty {
                    bookmarksEmptyState
                } else {
                    listingsList
                }
            } else if listingsService.ranked.isEmpty {
                emptyState
            } else {
                listingsList
            }
        }
        .task {
            // Initial load + auto-refresh loop while this tab is on screen.
            await refreshNow()
            await autoRefreshLoop()
        }
    }

    // MARK: Sort bar

    private var sortBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by title", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Picker("View", selection: $tab) {
                ForEach(SnipeTab.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                if let updated = listingsService.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                }
                if listingsService.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer()
                Text("\(visibleListings.count) \(tab == .bookmarks ? "saved" : "listings")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: List

    private var listingsList: some View {
        List {
            ForEach(visibleListings) { item in
                Button {
                    openInFacebook(item.listing)
                } label: {
                    ListingRowView(item: item, isSaved: listingsService.isBookmarked(item.listing.id))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    let saved = listingsService.isBookmarked(item.listing.id)
                    Button {
                        withAnimation { listingsService.toggleBookmark(item.listing) }
                    } label: {
                        Label(saved ? "Remove" : "Save",
                              systemImage: saved ? "bookmark.slash.fill" : "bookmark.fill")
                    }
                    .tint(saved ? .red : .blue)
                }
            }

            // Footer spacer so the last row clears the floating tab bar.
            Color.clear.frame(height: 72).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .refreshable { await refreshNow() }
    }

    // MARK: Empty / error state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 60)
                Image(systemName: "scope")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(listingsService.isConfigured ? "No listings yet" : "Snipe not set up")
                    .font(.title3.bold())
                Text(listingsService.errorMessage
                     ?? (listingsService.isConfigured
                         ? "Pull to refresh once the scraper has run on your PC."
                         : "Add your Gist ID in settings to start seeing scraped listings."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    showingSettings = true
                } label: {
                    Label("Open Snipe Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh") { Task { await refreshNow() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refreshNow() }
    }

    private var bookmarksEmptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            Image(systemName: "bookmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No saved listings")
                .font(.title3.bold())
            Text("Swipe left on any listing and tap **Save** to keep it here — saved posts stay even after they leave the feed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func refreshNow() async {
        await listingsService.refresh(homeAddress: driveTimeService.homeAddress)
    }

    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            let interval = max(30, listingsService.refreshInterval)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            await listingsService.refresh(homeAddress: driveTimeService.homeAddress)
        }
    }

    /// Open the listing. The canonical marketplace URL is a Universal Link, so
    /// iOS routes it into the Facebook app when installed, otherwise Safari.
    private func openInFacebook(_ listing: Listing) {
        guard let web = listing.marketplaceURL else { return }
        UIApplication.shared.open(web)
    }
}

// MARK: - Listing row

struct ListingRowView: View {
    let item: RankedListing
    var isSaved: Bool = false
    private var listing: Listing { item.listing }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(listing.price)
                        .font(.headline)
                        .foregroundStyle(.green)
                    if listing.isFresh {
                        Text("NEW")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                    if isSaved {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(listing.timeAgo)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(listing.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    if !listing.location.isEmpty {
                        Label(listing.location, systemImage: "mappin.and.ellipse")
                            .lineLimit(1)
                    }
                    if let dist = item.distanceLabel {
                        Label(dist, systemImage: "car.fill")
                    }
                    if let cost = item.costLabel {
                        Text(cost).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Image(systemName: "arrow.up.forward.app.fill")
                .font(.title3)
                .foregroundStyle(.blue)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        AsyncImage(url: listing.imageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                Image(systemName: "photo").foregroundStyle(.secondary)
            case .empty:
                ProgressView()
            @unknown default:
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Settings sheet

struct SnipeSettingsView: View {
    @EnvironmentObject private var listingsService: ListingsService
    @EnvironmentObject private var driveTimeService: DriveTimeService
    @Environment(\.dismiss) private var dismiss

    @State private var gistID = ""
    @State private var token = ""
    @State private var home = ""
    @State private var interval: Double = 120

    // Banger alert rules
    @State private var alertsEnabled = false
    @State private var keywords = ""
    @State private var maxPrice = ""
    @State private var maxMiles = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Gist ID", text: $gistID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Feed")
                } footer: {
                    Text("The scraper prints this Gist ID on its first run. Paste it here to connect the feed.")
                }

                Section {
                    SecureField("GitHub token (optional)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Token (optional)")
                } footer: {
                    Text("Only needed if you refresh very frequently. A token raises GitHub's rate limit.")
                }

                Section {
                    TextField("Home address", text: $home)
                    Stepper("Auto-refresh: \(Int(interval))s", value: $interval, in: 30...600, step: 30)
                } header: {
                    Text("Distance & refresh")
                } footer: {
                    Text("Distance and the $0.69/mi round-trip cost are measured from your home address.")
                }

                Section {
                    Toggle("Banger alerts 🔥", isOn: $alertsEnabled)
                    TextField("Keywords (comma-separated)", text: $keywords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!alertsEnabled)
                    HStack {
                        Text("Max price")
                        Spacer()
                        TextField("any", text: $maxPrice)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .disabled(!alertsEnabled)
                    }
                    HStack {
                        Text("Max distance (mi)")
                        Spacer()
                        TextField("any", text: $maxMiles)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .disabled(!alertsEnabled)
                    }
                } header: {
                    Text("Banger alerts")
                } footer: {
                    Text("Get a push the moment a fresh listing matches a keyword and is within your price/distance limits. Leave a field blank for no limit. Works even when the app is closed (best-effort background refresh).")
                }
            }
            .navigationTitle("Snipe Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                gistID = listingsService.gistID
                token = listingsService.githubToken
                interval = listingsService.refreshInterval
                home = driveTimeService.homeAddress
                alertsEnabled = listingsService.alertsEnabled
                keywords = listingsService.alertKeywords
                maxPrice = listingsService.alertMaxPrice > 0 ? String(listingsService.alertMaxPrice) : ""
                maxMiles = listingsService.alertMaxMiles > 0 ? String(listingsService.alertMaxMiles) : ""
            }
        }
    }

    private func save() {
        let wasEnabled = listingsService.alertsEnabled

        listingsService.gistID = gistID.trimmingCharacters(in: .whitespacesAndNewlines)
        listingsService.githubToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        listingsService.refreshInterval = interval
        listingsService.alertsEnabled = alertsEnabled
        listingsService.alertKeywords = keywords
        listingsService.alertMaxPrice = Int(maxPrice.trimmingCharacters(in: .whitespaces)) ?? 0
        listingsService.alertMaxMiles = Int(maxMiles.trimmingCharacters(in: .whitespaces)) ?? 0
        driveTimeService.homeAddress = home
        driveTimeService.saveHomeAddress()

        // Turning alerts on means "alert me going forward" — don't replay the backlog.
        if alertsEnabled && !wasEnabled {
            listingsService.rebaselineAlerts()
        }
        dismiss()
    }
}
