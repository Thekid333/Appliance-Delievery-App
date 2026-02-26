import SwiftUI
import SwiftData

struct JobListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Job.scheduledDate, order: .forward) private var jobs: [Job]
    @State private var showingAddJob = false
    @State private var selectedTab = 0

    private var upcomingAndInProgressJobs: [Job] {
        jobs.filter { $0.status == .upcoming || $0.status == .inProgress }
    }

    private var completedJobs: [Job] {
        jobs.filter { $0.status == .completed }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                // Tab 1: Upcoming / In Progress
                upcomingTab
                    .tag(0)

                // Tab 2: Completed
                completedTab
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .bottom) {
                tabBar
            }
            .navigationTitle(selectedTab == 0 ? "Upcoming" : "Completed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddJob = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showingAddJob) {
                AddEditJobView()
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Upcoming", icon: "clock", tag: 0)
            tabButton(title: "Completed", icon: "checkmark.circle", tag: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
    }

    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        let isSelected = selectedTab == tag
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tag
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.bold())
                Text(title)
                    .font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? .white : .secondary)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upcoming tab

    private var upcomingTab: some View {
        Group {
            if upcomingAndInProgressJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Upcoming Jobs", systemImage: "clock")
                } description: {
                    Text("Jobs you add will show here until they're completed.")
                } actions: {
                    Button("Add Job") {
                        showingAddJob = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    // In Progress first
                    if !inProgressJobs.isEmpty {
                        Section {
                            ForEach(inProgressJobs, id: \.id) { job in
                                NavigationLink(destination: JobDetailView(job: job)) {
                                    JobRowView(job: job)
                                }
                            }
                            .onDelete { indexSet in
                                deleteJobs(from: inProgressJobs, at: indexSet)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "figure.walk")
                                Text("In Progress")
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                            }
                            .font(.headline)
                            .foregroundStyle(.green)
                        }
                    }

                    // Upcoming
                    if !upcomingJobs.isEmpty {
                        Section {
                            ForEach(upcomingJobs, id: \.id) { job in
                                NavigationLink(destination: JobDetailView(job: job)) {
                                    JobRowView(job: job)
                                }
                            }
                            .onDelete { indexSet in
                                deleteJobs(from: upcomingJobs, at: indexSet)
                            }
                        } header: {
                            Label("Upcoming", systemImage: "clock")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    // MARK: - Completed tab

    private var completedTab: some View {
        Group {
            if completedJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Completed Jobs", systemImage: "checkmark.circle")
                } description: {
                    Text("Finished jobs and warranty info will appear here.")
                }
            } else {
                List {
                    Section {
                        ForEach(completedJobs, id: \.id) { job in
                            NavigationLink(destination: JobDetailView(job: job)) {
                                JobRowView(job: job)
                            }
                        }
                        .onDelete { indexSet in
                            deleteJobs(from: completedJobs, at: indexSet)
                        }
                    } header: {
                        Label("Completed", systemImage: "checkmark.circle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var upcomingJobs: [Job] {
        jobs.filter { $0.status == .upcoming }
    }

    private var inProgressJobs: [Job] {
        jobs.filter { $0.status == .inProgress }
    }

    // MARK: - Actions

    private func deleteJobs(from source: [Job], at offsets: IndexSet) {
        for index in offsets {
            let job = source[index]
            modelContext.delete(job)
        }
    }
}

// MARK: - Job Row

struct JobRowView: View {
    let job: Job

    private var allItems: [String] {
        ChecklistTemplates.allItems(
            for: job.type,
            includesInstallation: job.includesInstallation,
            isPostTinkering: job.isPostTinkering
        )
    }

    private var displayAddress: String {
        let a = job.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return "Address TBD" }
        return a
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.type.icon)
                .font(.title2)
                .foregroundStyle(colorForType(job.type))
                .frame(width: 40, height: 40)
                .background(colorForType(job.type).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.title)
                        .font(.headline)

                    if job.status == .inProgress {
                        Text("LIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                    }
                }

                Text(displayAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(job.scheduledDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if job.status != .completed, !allItems.isEmpty {
                        let progress = job.checklistProgress(allItems: allItems)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.bold())
                            .foregroundStyle(progress >= 1.0 ? .green : .orange)
                    }

                    if job.status == .completed, let daysLeft = job.warrantyDaysRemaining {
                        if daysLeft > 0 {
                            Label("\(daysLeft)d warranty", systemImage: "shield.checkered")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        } else {
                            Label("Warranty expired", systemImage: "shield.slash")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Spacer()

            VStack {
                Text(job.formattedDuration)
                    .font(.subheadline.bold())
            }
            .frame(width: 54)
        }
        .padding(.vertical, 4)
        .opacity(job.status == .completed ? 0.7 : 1.0)
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
    JobListView()
        .modelContainer(for: Job.self, inMemory: true)
        .environmentObject(CalendarService())
        .environmentObject(NotificationService())
        .environmentObject(DriveTimeService())
}
