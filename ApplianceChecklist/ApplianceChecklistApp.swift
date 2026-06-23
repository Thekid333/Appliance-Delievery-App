import SwiftUI
import SwiftData

@main
struct ApplianceChecklistApp: App {
    @StateObject private var calendarService = CalendarService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var driveTimeService = DriveTimeService()
    @StateObject private var listingsService = ListingsService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            JobListView()
                .environmentObject(calendarService)
                .environmentObject(notificationService)
                .environmentObject(driveTimeService)
                .environmentObject(listingsService)
                .task {
                    // Request permissions on launch
                    await notificationService.requestAuthorization()
                    _ = await calendarService.requestAccess()
                    // Make sure a background banger-check is queued.
                    listingsService.scheduleBackgroundRefresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Re-queue a background refresh whenever we leave the foreground.
                    if phase == .background {
                        listingsService.scheduleBackgroundRefresh()
                    }
                }
        }
        .modelContainer(for: Job.self)
        // Wakes opportunistically (even when the app is closed) to fetch the feed and
        // fire banger alerts. iOS decides exact timing; this is best-effort and free.
        .backgroundTask(.appRefresh(ListingsService.bgRefreshID)) {
            await listingsService.performBackgroundRefresh()
        }
    }
}
