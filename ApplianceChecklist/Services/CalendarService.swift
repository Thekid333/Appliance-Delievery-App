import EventKit
import SwiftUI

/// Manages Apple Calendar integration via EventKit.
@MainActor
class CalendarService: ObservableObject {

    private let store = EKEventStore()

    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var lastError: String?

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    /// Request full calendar access. Returns true if granted.
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            lastError = nil
            return granted
        } catch {
            lastError = error.localizedDescription
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    // MARK: - Event Management

    /// Creates or updates a calendar event for the given job.
    /// Returns the event identifier on success, nil on failure.
    func addOrUpdateEvent(for job: Job) async -> String? {
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return nil }
        }

        let event: EKEvent

        // Try to update existing event
        if let existingId = job.calendarEventIdentifier,
           let existing = store.event(withIdentifier: existingId) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = store.defaultCalendarForNewEvents
        }

        // Populate event fields
        event.title = "\(job.type.rawValue): \(job.title)"
        let addr = job.address.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = addr.isEmpty ? "Address TBD" : job.address
        event.startDate = job.departureTime
        event.endDate = job.estimatedReturnTime

        // Build notes with timing summary
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        event.notes = """
        Prep starts: \(formatter.string(from: job.prepStartTime))
        Depart: \(formatter.string(from: job.departureTime))
        Arrive: \(formatter.string(from: job.scheduledDate))
        Est. return: \(formatter.string(from: job.estimatedReturnTime))
        Duration: \(job.estimatedDurationMinutes) min
        """

        // Add prep reminder alarm (fires prepTimeMinutes before departure)
        event.alarms = [
            EKAlarm(relativeOffset: Double(-job.prepTimeMinutes) * 60.0)
        ]

        do {
            try store.save(event, span: .thisEvent)
            lastError = nil
            return event.eventIdentifier
        } catch {
            lastError = "Failed to save event: \(error.localizedDescription)"
            return nil
        }
    }

    /// Removes the calendar event with the given identifier.
    func removeEvent(identifier: String?) {
        guard let identifier,
              let event = store.event(withIdentifier: identifier) else { return }
        do {
            try store.remove(event, span: .thisEvent)
            lastError = nil
        } catch {
            lastError = "Failed to remove event: \(error.localizedDescription)"
        }
    }
}
