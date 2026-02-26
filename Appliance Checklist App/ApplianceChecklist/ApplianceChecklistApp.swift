import SwiftUI
import SwiftData

@main
struct ApplianceChecklistApp: App {
    @StateObject private var calendarService = CalendarService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var driveTimeService = DriveTimeService()

    var body: some Scene {
        WindowGroup {
            JobListView()
                .environmentObject(calendarService)
                .environmentObject(notificationService)
                .environmentObject(driveTimeService)
                .task {
                    // Request permissions on launch
                    await notificationService.requestAuthorization()
                    _ = await calendarService.requestAccess()
                }
        }
        .modelContainer(for: Job.self)
    }
}
