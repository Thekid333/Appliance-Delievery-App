import Foundation
import SwiftData

// MARK: - Job Type

enum JobType: String, Codable, CaseIterable, Identifiable {
    case delivery = "Delivery"
    case installation = "Installation"
    case pickup = "Pickup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .delivery: return "box.truck.fill"
        case .installation: return "wrench.and.screwdriver.fill"
        case .pickup: return "shippingbox.fill"
        }
    }
}

// MARK: - Job Status

enum JobStatus: String {
    case upcoming = "Upcoming"
    case inProgress = "In Progress"
    case completed = "Completed"

    var icon: String {
        switch self {
        case .upcoming: return "clock"
        case .inProgress: return "figure.walk"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

// MARK: - Job Model

@Model
final class Job {
    var id: UUID
    var typeRawValue: String
    var title: String
    var address: String
    var scheduledDate: Date
    var driveTimeMinutes: Int
    var numberOfPeople: Int
    var includesInstallation: Bool
    var isPostTinkering: Bool
    var calendarEventIdentifier: String?
    var checkedItems: [String]
    /// Optional so jobs saved before this field was added still load (nil = not completed).
    var isCompleted: Bool?
    var completedDate: Date?

    // MARK: - Computed Job Type

    var type: JobType {
        get { JobType(rawValue: typeRawValue) ?? .delivery }
        set { typeRawValue = newValue.rawValue }
    }

    // MARK: - Init

    init(
        type: JobType,
        title: String,
        address: String,
        scheduledDate: Date,
        driveTimeMinutes: Int,
        numberOfPeople: Int,
        includesInstallation: Bool = false,
        isPostTinkering: Bool = false
    ) {
        self.id = UUID()
        self.typeRawValue = type.rawValue
        self.title = title
        self.address = address
        self.scheduledDate = scheduledDate
        self.driveTimeMinutes = driveTimeMinutes
        self.numberOfPeople = max(1, numberOfPeople)
        self.includesInstallation = includesInstallation
        self.isPostTinkering = isPostTinkering
        self.checkedItems = []
        self.isCompleted = false
        self.completedDate = nil
    }

    // MARK: - Status

    /// Current lifecycle status of the job.
    var status: JobStatus {
        if isCompleted == true {
            return .completed
        }
        let now = Date()
        if now >= departureTime && now < estimatedReturnTime {
            return .inProgress
        }
        if now >= estimatedReturnTime {
            // Past return time but never marked complete — auto-complete
            return .completed
        }
        return .upcoming
    }

    /// Whether the job is in the past (completed or past return time).
    var isPast: Bool {
        status == .completed
    }

    /// Mark this job as finished (manually).
    func markCompleted() {
        isCompleted = true
        completedDate = Date()
    }

    // MARK: - Timing Calculations

    /// Total job duration in minutes (from leaving home to returning).
    var estimatedDurationMinutes: Int {
        switch type {
        case .delivery:
            let base = (2 * driveTimeMinutes) + (30 / max(1, numberOfPeople))
            return includesInstallation ? base + 30 : base
        case .installation:
            return (2 * driveTimeMinutes) + 30
        case .pickup:
            return (2 * driveTimeMinutes) + (30 / max(1, numberOfPeople))
        }
    }

    /// Human-readable duration (e.g. "1h 30m" instead of "90 min").
    var formattedDuration: String {
        let hours = estimatedDurationMinutes / 60
        let mins = estimatedDurationMinutes % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    /// Format drive time as "1h 30m" or "45m".
    static func formatDriveTime(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Minutes of prep time before departure.
    var prepTimeMinutes: Int {
        switch type {
        case .delivery: return 60
        case .installation: return 30
        case .pickup: return 45
        }
    }

    /// When to start prepping (prep window before departure).
    var prepStartTime: Date {
        departureTime.addingTimeInterval(Double(-prepTimeMinutes) * 60.0)
    }

    /// When to leave home (scheduledDate is arrival time, subtract drive time).
    var departureTime: Date {
        scheduledDate.addingTimeInterval(Double(-driveTimeMinutes) * 60.0)
    }

    /// Estimated time of return home.
    var estimatedReturnTime: Date {
        departureTime.addingTimeInterval(Double(estimatedDurationMinutes) * 60.0)
    }

    // MARK: - Warranty (Delivery jobs only, 30 days from completion)

    var warrantyExpirationDate: Date? {
        guard type == .delivery else { return nil }
        // Use completedDate if manually completed, otherwise use estimatedReturnTime if past
        let completed: Date
        if let cd = completedDate {
            completed = cd
        } else if Date() >= estimatedReturnTime {
            completed = estimatedReturnTime
        } else {
            return nil
        }
        return Calendar.current.date(byAdding: .day, value: 30, to: completed)
    }

    var warrantyDaysRemaining: Int? {
        guard let expiry = warrantyExpirationDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return max(0, days)
    }

    var isWarrantyExpired: Bool {
        guard let remaining = warrantyDaysRemaining else { return false }
        return remaining <= 0
    }

    // MARK: - Checklist Helpers

    func isItemChecked(_ item: String) -> Bool {
        checkedItems.contains(item)
    }

    func toggleItem(_ item: String) {
        if checkedItems.contains(item) {
            checkedItems.removeAll { $0 == item }
        } else {
            checkedItems.append(item)
        }
    }

    /// Fraction of checklist items completed (0.0 to 1.0).
    func checklistProgress(allItems: [String]) -> Double {
        guard !allItems.isEmpty else { return 1.0 }
        let checked = allItems.filter { checkedItems.contains($0) }.count
        return Double(checked) / Double(allItems.count)
    }
}
