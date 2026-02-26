import SwiftUI
import SwiftData

/// Job types that can be created (Installation is add-on only to Delivery).
private let creatableJobTypes: [JobType] = [.delivery, .pickup]

struct AddEditJobView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var calendarService: CalendarService
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var driveTimeService: DriveTimeService

    var existingJob: Job?

    @State private var jobType: JobType = .delivery
    @State private var title: String = ""
    @State private var address: String = ""
    @State private var addressNotGivenYet: Bool = false
    @State private var scheduledDate: Date = Self.defaultScheduledDate()
    @State private var driveTimeMinutes: Int = 30
    @State private var numberOfPeople: Int = 1
    @State private var includesInstallation: Bool = false
    @State private var isPostTinkering: Bool = false
    @State private var isSaving = false
    @State private var driveTimeFetchTask: Task<Void, Never>?

    private var isEditing: Bool { existingJob != nil }

    /// True when the user may edit drive time (address not provided yet).
    private var isDriveTimeEditable: Bool {
        addressNotGivenYet || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(job: Job? = nil) {
        self.existingJob = job
        if let job {
            // Installation is add-on only: treat as Delivery + includesInstallation
            let type: JobType = job.type == .installation ? .delivery : job.type
            _jobType = State(initialValue: type)
            _title = State(initialValue: job.title)
            _address = State(initialValue: job.address)
            _addressNotGivenYet = State(initialValue: job.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            _scheduledDate = State(initialValue: job.scheduledDate)
            _driveTimeMinutes = State(initialValue: job.driveTimeMinutes)
            _numberOfPeople = State(initialValue: job.numberOfPeople)
            _includesInstallation = State(initialValue: job.type == .installation || job.includesInstallation)
            _isPostTinkering = State(initialValue: job.isPostTinkering)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                jobTypeSection
                detailsSection
                scheduleSection
                optionsSection
                calculatedTimesSection
            }
            .navigationTitle(isEditing ? "Edit Job" : "New Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        Task { await saveJob() }
                    }
                    .disabled(title.isEmpty || (!addressNotGivenYet && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isSaving)
                    .bold()
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView("Saving...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onChange(of: jobType) { _, newType in
                if newType != .delivery {
                    includesInstallation = false
                }
            }
            .onChange(of: driveTimeService.homeAddress) { _, _ in
                driveTimeService.saveHomeAddress()
            }
            .onChange(of: address) { _, newAddress in
                guard !addressNotGivenYet else { return }
                let trimmed = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !driveTimeService.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                driveTimeFetchTask?.cancel()
                driveTimeFetchTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000) // 0.6 s debounce
                    guard !Task.isCancelled else { return }
                    await fetchDriveTime()
                }
            }
        }
    }

    // MARK: - Sections

    private var jobTypeSection: some View {
        Section {
            Picker("Job Type", selection: $jobType) {
                ForEach(creatableJobTypes, id: \.self) { type in
                    Label(type.rawValue, systemImage: type.icon)
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            TextField("Job Title", text: $title)
                .textContentType(.name)

            Toggle("Address not given yet", isOn: $addressNotGivenYet)

            if !addressNotGivenYet {
                AddressFieldWithSuggestions(text: $address, placeholder: "Address")
            }
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
            AddressFieldWithSuggestions(
                text: Binding(
                    get: { driveTimeService.homeAddress },
                    set: { driveTimeService.homeAddress = $0 }
                ),
                placeholder: "Your home address (for drive time)"
            )

            DatePicker(
                "Appointment Time",
                selection: $scheduledDate,
                displayedComponents: [.date, .hourAndMinute]
            )

            HStack {
                if isDriveTimeEditable {
                    Stepper(
                        "Drive Time: \(Job.formatDriveTime(driveTimeMinutes))",
                        value: $driveTimeMinutes,
                        in: 5...180,
                        step: 5
                    )
                } else {
                    LabeledContent("Drive Time") {
                        HStack(spacing: 6) {
                            if driveTimeService.isFetching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(Job.formatDriveTime(driveTimeMinutes))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !driveTimeService.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { await fetchDriveTime() }
                        } label: {
                            Text("Refresh")
                                .font(.caption.bold())
                        }
                        .disabled(driveTimeService.isFetching)
                    }
                }
            }

            if let error = driveTimeService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Stepper(
                "People: \(numberOfPeople)",
                value: $numberOfPeople,
                in: 1...10
            )
        }
    }

    private func fetchDriveTime() async {
        let dest = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        if let minutes = await driveTimeService.fetchDriveTimeTo(destinationAddress: dest) {
            driveTimeMinutes = min(180, max(5, minutes))
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            if jobType == .delivery {
                Toggle(isOn: $includesInstallation) {
                    Label("Includes Installation", systemImage: "wrench.and.screwdriver")
                }
            }

            Toggle(isOn: $isPostTinkering) {
                Label("Post-Tinkering Job", systemImage: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - Calculated Times Helpers

    private var calculatedDepartureTime: Date {
        scheduledDate.addingTimeInterval(Double(-driveTimeMinutes * 60))
    }

    private var calculatedPrepMinutes: Int {
        jobType == .delivery ? 60 : (jobType == .pickup ? 45 : 30)
    }

    private var calculatedPrepTime: Date {
        calculatedDepartureTime.addingTimeInterval(Double(-calculatedPrepMinutes * 60))
    }

    private var calculatedTotalDuration: Int {
        switch jobType {
        case .delivery:
            let base = (2 * driveTimeMinutes) + (30 / max(1, numberOfPeople))
            return includesInstallation ? base + 30 : base
        case .installation:
            return (2 * driveTimeMinutes) + 30
        case .pickup:
            return (2 * driveTimeMinutes) + (30 / max(1, numberOfPeople))
        }
    }

    private var calculatedReturnTime: Date {
        calculatedDepartureTime.addingTimeInterval(Double(calculatedTotalDuration * 60))
    }

    private var formattedCalculatedDuration: String {
        let hours = calculatedTotalDuration / 60
        let mins = calculatedTotalDuration % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    private var calculatedTimesSection: some View {
        Section("Calculated Times") {
            LabeledContent("Prep Starts") {
                Text(calculatedPrepTime, style: .time)
                    .foregroundStyle(.orange)
                    .bold()
            }

            LabeledContent("Depart") {
                Text(calculatedDepartureTime, style: .time)
                    .foregroundStyle(.red)
                    .bold()
            }

            LabeledContent("Arrive") {
                Text(scheduledDate, style: .time)
                    .bold()
            }

            LabeledContent("Est. Return") {
                Text(calculatedReturnTime, style: .time)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Total Duration") {
                Text(formattedCalculatedDuration)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Save

    private var effectiveAddress: String {
        if addressNotGivenYet { return "" }
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveJob() async {
        isSaving = true
        defer { isSaving = false }

        let savedAddress = effectiveAddress

        if let job = existingJob {
            job.type = jobType
            job.title = title
            job.address = savedAddress
            job.scheduledDate = scheduledDate
            job.driveTimeMinutes = driveTimeMinutes
            job.numberOfPeople = max(1, numberOfPeople)
            job.includesInstallation = includesInstallation
            job.isPostTinkering = isPostTinkering

            // Update calendar event
            if let eventId = await calendarService.addOrUpdateEvent(for: job) {
                job.calendarEventIdentifier = eventId
            }

            // Reschedule notifications
            notificationService.scheduleNotifications(for: job)
        } else {
            let job = Job(
                type: jobType,
                title: title,
                address: savedAddress,
                scheduledDate: scheduledDate,
                driveTimeMinutes: driveTimeMinutes,
                numberOfPeople: numberOfPeople,
                includesInstallation: includesInstallation,
                isPostTinkering: isPostTinkering
            )
            modelContext.insert(job)

            // Add to calendar
            if let eventId = await calendarService.addOrUpdateEvent(for: job) {
                job.calendarEventIdentifier = eventId
            }

            // Schedule notifications
            notificationService.scheduleNotifications(for: job)
        }

        dismiss()
    }

    // MARK: - Helpers

    private static func defaultScheduledDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        guard let nextHour = calendar.date(byAdding: .hour, value: 2, to: now) else { return now }
        return calendar.date(bySetting: .minute, value: 0, of: nextHour) ?? nextHour
    }
}

#Preview {
    AddEditJobView()
        .modelContainer(for: Job.self, inMemory: true)
        .environmentObject(CalendarService())
        .environmentObject(NotificationService())
        .environmentObject(DriveTimeService())
}
