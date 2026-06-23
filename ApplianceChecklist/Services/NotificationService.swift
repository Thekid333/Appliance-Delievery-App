import UserNotifications
import SwiftUI
import UIKit

/// Manages local notifications for job reminders and Snipe "banger" alerts.
/// Also acts as the notification-center delegate so banners appear in the foreground
/// and tapping a banger alert opens the listing.
@MainActor
class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    @Published var isAuthorized = false
    @Published var lastError: String?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Delegate (foreground presentation + tap handling)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let urlString = info["url"] as? String, let url = URL(string: urlString) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        completionHandler()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isAuthorized = false
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Schedule Notifications

    /// Schedules all notifications for the given job.
    func scheduleNotifications(for job: Job) {
        // Remove any existing notifications for this job first
        removeNotifications(for: job)

        // Only schedule for future events
        guard job.prepStartTime > Date() else { return }

        schedulePrepReminder(for: job)
        scheduleDepartureReminder(for: job)

        if job.isPostTinkering {
            schedulePostTinkeringReminder(for: job)
        }
    }

    /// Removes all pending notifications for the given job.
    func removeNotifications(for job: Job) {
        let identifiers = [
            "prep-\(job.id.uuidString)",
            "depart-\(job.id.uuidString)",
            "posttinker-\(job.id.uuidString)"
        ]
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Private Scheduling

    private func locationDescription(for job: Job) -> String {
        let addr = job.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return addr.isEmpty ? "Address TBD" : addr
    }

    private func schedulePrepReminder(for job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "Time to Prep! \(job.type.rawValue)"
        content.body = "\(job.title) — \(locationDescription(for: job)). Start getting ready. You have \(job.prepTimeMinutes) min before departure."
        content.sound = .default
        content.categoryIdentifier = "JOB_PREP"

        guard let trigger = calendarTrigger(for: job.prepStartTime) else { return }

        let request = UNNotificationRequest(
            identifier: "prep-\(job.id.uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleDepartureReminder(for job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "Time to leave — head out now!"
        content.body = "\(job.title) — \(locationDescription(for: job)). Drive time: \(Job.formatDriveTime(job.driveTimeMinutes))."
        content.sound = .default
        content.categoryIdentifier = "JOB_DEPART"

        guard let trigger = calendarTrigger(for: job.departureTime) else { return }

        let request = UNNotificationRequest(
            identifier: "depart-\(job.id.uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func schedulePostTinkeringReminder(for job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "Post-Tinkering Reminder"
        content.body = "ALWAYS Test after you fix/change something!"
        content.sound = .default
        content.categoryIdentifier = "JOB_POSTTINKER"

        guard let trigger = calendarTrigger(for: job.estimatedReturnTime) else { return }

        let request = UNNotificationRequest(
            identifier: "posttinker-\(job.id.uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private func calendarTrigger(for date: Date) -> UNCalendarNotificationTrigger? {
        guard date > Date() else { return nil }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
}
