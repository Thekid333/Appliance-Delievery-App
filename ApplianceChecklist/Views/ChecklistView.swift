import SwiftUI

struct ChecklistView: View {
    @Bindable var job: Job

    private var templates: [ChecklistTemplate] {
        ChecklistTemplates.templates(
            for: job.type,
            includesInstallation: job.includesInstallation,
            isPostTinkering: job.isPostTinkering
        )
    }

    private var allItems: [String] {
        templates.flatMap { $0.items }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Progress header
            progressHeader

            // Checklist sections
            ForEach(templates) { template in
                VStack(alignment: .leading, spacing: 0) {
                    // Section header
                    Text(template.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    // Items
                    ForEach(template.items, id: \.self) { item in
                        ChecklistRow(
                            item: item,
                            isChecked: job.isItemChecked(item),
                            onToggle: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    job.toggleItem(item)
                                }
                            }
                        )

                        if item != template.items.last {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Progress Header

    private var progressHeader: some View {
        let progress = job.checklistProgress(allItems: allItems)
        let checkedCount = allItems.filter { job.isItemChecked($0) }.count

        return VStack(spacing: 8) {
            HStack {
                Text("Checklist")
                    .font(.headline)
                Spacer()
                Text("\(checkedCount)/\(allItems.count)")
                    .font(.subheadline.bold())
                    .foregroundStyle(progress >= 1.0 ? .green : .primary)
            }

            ProgressView(value: progress)
                .tint(progress >= 1.0 ? .green : .accentColor)
                .animation(.easeInOut, value: progress)

            if progress >= 1.0 {
                Label("All items checked!", systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Checklist Row

struct ChecklistRow: View {
    let item: String
    let isChecked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? .green : .secondary)

                Text(item)
                    .font(.body)
                    .foregroundStyle(isChecked ? .secondary : .primary)
                    .strikethrough(isChecked, color: .secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let job = Job(
        type: .delivery,
        title: "Washer Delivery",
        address: "123 Main St",
        scheduledDate: Date().addingTimeInterval(7200),
        driveTimeMinutes: 30,
        numberOfPeople: 1,
        includesInstallation: true,
        isPostTinkering: true
    )

    ScrollView {
        ChecklistView(job: job)
    }
    .modelContainer(for: Job.self, inMemory: true)
}
