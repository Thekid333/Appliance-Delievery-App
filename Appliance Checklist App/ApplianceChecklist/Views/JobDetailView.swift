import SwiftUI

struct JobDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var calendarService: CalendarService
    @EnvironmentObject var notificationService: NotificationService

    @Bindable var job: Job

    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var showingCompleteAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                
                // Mark Complete button for in-progress jobs
                if job.status == .inProgress {
                    markCompleteButton
                }

                // Warranty card for completed delivery jobs
                if job.status == .completed, job.warrantyExpirationDate != nil {
                    warrantyCard
                }

                timelineCard
                checklistSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(job.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    if job.status != .completed {
                        Button {
                            showingCompleteAlert = true
                        } label: {
                            Label("Mark Complete", systemImage: "checkmark.circle")
                        }
                    }

                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditJobView(job: job)
        }
        .alert("Delete Job?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteJob()
            }
        } message: {
            Text("This will also remove the calendar event and notifications.")
        }
        .alert("Finish Job Early?", isPresented: $showingCompleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Mark Complete") {
                completeJob()
            }
        } message: {
            Text("This will mark the job as completed now and start the warranty timer for delivery jobs.")
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: job.type.icon)
                    .font(.largeTitle)
                    .foregroundStyle(colorForType(job.type))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(job.type.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(colorForType(job.type))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(colorForType(job.type).opacity(0.12))
                            .clipShape(Capsule())

                        // Status badge
                        Text(job.status.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(job.title)
                        .font(.title2.bold())

                    if job.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Address TBD", systemImage: "mappin.slash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            openAddressInMaps()
                        } label: {
                            Label(job.address, systemImage: "mappin")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Spacer()
            }

            Divider()

            // Quick stats
            HStack {
                statBadge(
                    icon: "clock",
                    value: job.formattedDuration,
                    label: "Duration"
                )
                Spacer()
                statBadge(
                    icon: "car",
                    value: Job.formatDriveTime(job.driveTimeMinutes),
                    label: "Drive"
                )
                Spacer()
                statBadge(
                    icon: "person.2",
                    value: "\(job.numberOfPeople)",
                    label: "People"
                )
            }

            if job.includesInstallation {
                Label("Includes Installation", systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.12))
                    .clipShape(Capsule())
            }

            if job.isPostTinkering {
                Label("Post-Tinkering Job", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Mark Complete Button

    private var markCompleteButton: some View {
        Button {
            showingCompleteAlert = true
        } label: {
            Label("Finish Job Early", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
    }

    // MARK: - Warranty Card

    private var warrantyCard: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .foregroundStyle(job.isWarrantyExpired ? .red : .blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("30-Day Warranty")
                        .font(.headline)

                    if let expiry = job.warrantyExpirationDate {
                        Text("Expires: \(expiry.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let days = job.warrantyDaysRemaining {
                    if days > 0 {
                        VStack {
                            Text("\(days)")
                                .font(.title.bold())
                                .foregroundStyle(.blue)
                            Text("days left")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Expired")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)
                    }
                }
            }

            // Progress bar for warranty
            if let days = job.warrantyDaysRemaining, !job.isWarrantyExpired {
                ProgressView(value: Double(30 - days), total: 30.0)
                    .tint(days <= 7 ? .orange : .blue)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Timeline Card

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .padding(.bottom, 12)

            timelineRow(
                icon: "alarm",
                color: .orange,
                title: "Prep Starts",
                time: job.prepStartTime,
                subtitle: "\(job.prepTimeMinutes) min before departure"
            )

            timelineConnector()

            timelineRow(
                icon: "car.fill",
                color: .red,
                title: "Depart",
                time: job.departureTime,
                subtitle: "\(Job.formatDriveTime(job.driveTimeMinutes)) drive"
            )

            timelineConnector()

            timelineRow(
                icon: "mappin.circle.fill",
                color: .blue,
                title: "Arrive",
                time: job.scheduledDate,
                subtitle: "Appointment time"
            )

            timelineConnector()

            timelineRow(
                icon: "house.fill",
                color: .green,
                title: "Est. Return",
                time: job.estimatedReturnTime,
                subtitle: "Back home"
            )

            if job.status == .completed, let cd = job.completedDate {
                timelineConnector()

                timelineRow(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "Completed",
                    time: cd,
                    subtitle: "Job finished"
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Checklist Section

    private var checklistSection: some View {
        ChecklistView(job: job)
    }

    // MARK: - Actions

    private func deleteJob() {
        calendarService.removeEvent(identifier: job.calendarEventIdentifier)
        notificationService.removeNotifications(for: job)
        modelContext.delete(job)
        dismiss()
    }

    private func completeJob() {
        job.markCompleted()
        notificationService.removeNotifications(for: job)
    }

    private func openAddressInMaps() {
        let addr = job.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, let encoded = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }

        // Try Google Maps first
        if let googleURL = URL(string: "comgooglemaps://?q=\(encoded)"),
           UIApplication.shared.canOpenURL(googleURL) {
            UIApplication.shared.open(googleURL)
        } else if let appleURL = URL(string: "https://maps.apple.com/?q=\(encoded)") {
            // Fall back to Apple Maps
            UIApplication.shared.open(appleURL)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch job.status {
        case .upcoming: return .secondary
        case .inProgress: return .green
        case .completed: return .blue
        }
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timelineRow(icon: String, color: Color, title: String, time: Date, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(time, style: .time)
                .font(.subheadline.monospacedDigit().bold())

            Text(time, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timelineConnector() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2, height: 20)
            .padding(.leading, 13)
    }

    private func colorForType(_ type: JobType) -> Color {
        switch type {
        case .delivery: return .blue
        case .installation: return .orange
        case .pickup: return .green
        }
    }
}

#Preview {
    NavigationStack {
        JobDetailView(
            job: Job(
                type: .delivery,
                title: "Washer Delivery",
                address: "123 Main St, Springfield",
                scheduledDate: Date().addingTimeInterval(7200),
                driveTimeMinutes: 30,
                numberOfPeople: 1,
                includesInstallation: true,
                isPostTinkering: true
            )
        )
    }
    .modelContainer(for: Job.self, inMemory: true)
    .environmentObject(CalendarService())
    .environmentObject(NotificationService())
}
