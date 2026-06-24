import SwiftUI
import SwiftData

@main
struct ApplianceChecklistApp: App {
    @StateObject private var calendarService = CalendarService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var driveTimeService = DriveTimeService()
    @StateObject private var listingsService = ListingsService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must register before launch completes so iOS can dispatch the background
        // *processing* task even when it cold-launches us in the background.
        // (The app-refresh handler is registered by `.backgroundTask(.appRefresh:)` below.)
        ListingsService.registerProcessingTask()
    }

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
                .onChange(of: scenePhase) {
                    // Re-queue a background refresh whenever we leave the foreground.
                    if scenePhase == .background {
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
