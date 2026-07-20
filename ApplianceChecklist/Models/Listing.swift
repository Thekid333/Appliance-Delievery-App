import Foundation
import CoreLocation

// MARK: - Feed wrapper (matches the JSON the scraper publishes to the Gist)

struct ListingFeed: Decodable {
    let generatedAt: String?
    let count: Int?
    let listings: [Listing]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case count
        case listings
    }

    var generatedDate: Date? { Listing.parseDate(generatedAt) }
}

// MARK: - A single scraped Marketplace listing

struct Listing: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let price: String
    let priceValue: Int?
    let location: String
    /// Distance Facebook itself reported (only present if the search had a location set). Usually nil.
    let scrapedDistanceMiles: Double?
    let image: String?
    let link: String?
    let url: String?
    let category: String?
    /// ISO-8601 string stamped by the scraper when the item was first seen.
    let firstSeen: String?
    /// ISO-8601 string for when the item was actually posted on Facebook, read
    /// from the item's own page by the scraper. May be nil for older records.
    let listedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, price, location, image, link, url, category
        case priceValue = "price_value"
        case scrapedDistanceMiles = "distance_miles"
        case firstSeen = "first_seen"
        case listedAt = "listed_at"
    }

    // MARK: Derived

    var firstSeenDate: Date? { Listing.parseDate(firstSeen) }
    var listedDate: Date? { Listing.parseDate(listedAt) }

    /// When the listing was posted if we know it, otherwise when we first saw it.
    /// Drives the time label, NEW badge, and "Newest" sort.
    var displayDate: Date? { listedDate ?? firstSeenDate }

    /// Canonical URL for the item. Built from the id so it's free of the search
    /// tracking params, and routes straight into the Facebook app via Universal
    /// Links when it's installed (else Safari).
    var marketplaceURL: URL? {
        URL(string: "https://www.facebook.com/marketplace/item/\(id)")
    }

    var imageURL: URL? {
        guard let image, !image.isEmpty else { return nil }
        return URL(string: image)
    }

    /// "2h ago", "just now", etc. — based on when it was listed when known.
    var timeAgo: String {
        guard let date = displayDate else { return "" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Considered "fresh" (worth a NEW badge) if listed within the last hour.
    var isFresh: Bool {
        guard let date = displayDate else { return false }
        return Date().timeIntervalSince(date) < 3600
    }

    // MARK: Tolerant ISO-8601 parsing

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let d = isoWithFraction.date(from: string) { return d }
        if let d = isoPlain.date(from: string) { return d }
        return nil
    }
}

// MARK: - Listing decorated with distance/cost relative to home

struct RankedListing: Identifiable, Hashable {
    let listing: Listing
    /// Straight-line one-way miles from home (nil if not geocoded yet).
    var straightLineMiles: Double?

    var id: String { listing.id }

    /// Driving distance is roughly 1.3x straight-line. Used for the fuel estimate.
    static let roadFactor = 1.3
    /// Cost per mile for the 4WD vehicle.
    static let costPerMile = 0.69

    /// Estimated one-way driving miles.
    var drivingMiles: Double? {
        guard let m = straightLineMiles else { return nil }
        return m * Self.roadFactor
    }

    /// Round-trip fuel/operating cost at $0.69/mi.
    var roundTripCost: Double? {
        guard let m = drivingMiles else { return nil }
        return m * 2.0 * Self.costPerMile
    }

    /// All-in cost = asking price + round-trip fuel. Used for the "Best deal" sort.
    /// Unknown price returns nil (sorts to the bottom) — a "See Listing" price is
    /// not a deal, even if the fuel cost alone looks tiny.
    var totalAcquisitionCost: Double? {
        guard let price = listing.priceValue.map(Double.init) else { return nil }
        return price + (roundTripCost ?? 0)
    }

    var distanceLabel: String? {
        guard let m = straightLineMiles else { return nil }
        return String(format: "%.0f mi", m)
    }

    var costLabel: String? {
        guard let c = roundTripCost else { return nil }
        return String(format: "~$%.0f rt", c)
    }
}
