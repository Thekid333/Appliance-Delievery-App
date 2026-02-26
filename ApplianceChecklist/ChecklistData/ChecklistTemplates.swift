import Foundation

// MARK: - Checklist Template

struct ChecklistTemplate: Identifiable {
    let id = UUID()
    let name: String
    let items: [String]
}

// MARK: - Templates

struct ChecklistTemplates {

    static let delivery = ChecklistTemplate(
        name: "Delivery Checklist",
        items: [
            "Ramp",
            "Dolly",
            "Two Heavy Duty Straps",
            "Couple of Rags",
            "Runners",
            "Washer Hot and Cold Connections",
            "Washer Drain Pipe",
            "Dryer plug INSTALLED",
            "The opposite dryer cord",
            "Check Gas"
        ]
    )

    static let installation = ChecklistTemplate(
        name: "Installation Checklist",
        items: [
            "Screwdriver",
            "Impact with drills bit",
            "Channel Lock Pliers"
        ]
    )

    static let pickup = ChecklistTemplate(
        name: "Pickup Checklist",
        items: [
            "Dolly",
            "Two Heavy Duty Straps",
            "Dolly Strap",
            "Ramp",
            "Runner / Rags",
            "Cash",
            "Check Gas"
        ]
    )

    static let postTinkering = ChecklistTemplate(
        name: "Post-Tinkering",
        items: [
            "ALWAYS Test after you fix/change something"
        ]
    )

    // MARK: - Template Resolution

    /// Returns the applicable checklist templates for a given job configuration.
    static func templates(
        for jobType: JobType,
        includesInstallation: Bool,
        isPostTinkering: Bool
    ) -> [ChecklistTemplate] {
        var result: [ChecklistTemplate] = []

        switch jobType {
        case .delivery:
            result.append(delivery)
            if includesInstallation {
                result.append(installation)
            }
        case .installation:
            result.append(installation)
        case .pickup:
            result.append(pickup)
        }

        if isPostTinkering {
            result.append(postTinkering)
        }

        return result
    }

    /// Returns a flat list of all checklist item names for a given job configuration.
    static func allItems(
        for jobType: JobType,
        includesInstallation: Bool,
        isPostTinkering: Bool
    ) -> [String] {
        templates(
            for: jobType,
            includesInstallation: includesInstallation,
            isPostTinkering: isPostTinkering
        ).flatMap { $0.items }
    }
}
