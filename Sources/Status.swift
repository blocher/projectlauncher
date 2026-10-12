import AppKit

enum Health {
    case stopped, starting, running, degraded
    /// The project folder doesn't exist on this Mac.
    case missing, installing

    /// For the Dock menu, which can't show images.
    var emoji: String {
        switch self {
        case .stopped: "⚪️"
        case .missing: "⬇️"
        case .starting, .installing: "🔵"
        case .running: "🟢"
        case .degraded: "🟠"
        }
    }

    var dotColor: NSColor? {
        switch self {
        case .stopped, .missing: nil
        case .starting, .installing: .systemBlue
        case .running: .systemGreen
        case .degraded: .systemOrange
        }
    }
}

struct ProjectStatus {
    var health: Health = .stopped
    var windowID: String?
    var services = 0
    /// Roles (or pane names) of service panes that have dropped back to an idle shell.
    var down: [String] = []

    var up: Int { services - down.count }

    var summary: String {
        switch health {
        case .stopped: "Not running"
        case .missing: "Not on this Mac"
        case .installing: "Installing…"
        case .starting: "Starting…"
        case .running: services > 0 ? "Running · \(up)/\(services) services up" : "Running"
        case .degraded: "\(down.joined(separator: ", ")) stopped · \(up)/\(services) up"
        }
    }

    static func evaluate(_ project: Project, panes: [Pane], busyTTYs: Set<String>) -> ProjectStatus {
        let variable = project.match.variable
        let matching = panes.filter { pane in
            guard let value = pane.values[variable], !value.isEmpty else { return false }
            return project.match.equals.map { $0 == value } ?? true
        }
        guard let windowID = matching.first?.windowID else { return ProjectStatus() }

        let idle = project.idlePanes ?? []
        var status = ProjectStatus(health: .running, windowID: windowID)
        for pane in matching where pane.windowID == windowID {
            // Generated launchers tag each pane's role. Older ones either put the role in the match variable or,
            // when they tag the whole window alike, leave only the pane's name to go on.
            let role = !pane.role.isEmpty ? pane.role
                : project.match.equals == nil ? pane.values[variable] ?? pane.name : pane.name
            if idle.contains(where: { role == $0 || pane.name.hasPrefix($0) }) { continue }
            status.services += 1
            if !busyTTYs.contains(pane.tty) { status.down.append(role) }
        }
        if !status.down.isEmpty { status.health = .degraded }
        return status
    }
}

/// Turns iTerm scans into project statuses, remembering which windows belong to which project between polls.
/// Not thread-safe: use from one queue.
final class StatusScanner {
    /// Window id → the variable that identified it.
    private var known: [String: String] = [:]
    /// Window id → when it was found to belong to no project.
    private var unclaimedAt: [String: Date] = [:]
    private static let recheckUnclaimedAfter: TimeInterval = 15

    /// `fresh` re-examines every window instead of trusting recent "no project here" results.
    func scan(_ projects: [Project], fresh: Bool) -> Result<[String: ProjectStatus], ScriptError> {
        var statuses: [String: ProjectStatus] = [:]
        for project in projects { statuses[project.id] = ProjectStatus() }
        // Never query a closed iTerm: the AppleScript would launch it.
        guard ITerm.isRunning, !projects.isEmpty else {
            known = [:]
            unclaimedAt = [:]
            return .success(statuses)
        }

        let now = Date()
        let skip = fresh ? [] : Set(unclaimedAt.filter { now.timeIntervalSince($0.value) < Self.recheckUnclaimedAfter }.keys)
        let variables = Array(Set(projects.map(\.match.variable))).sorted()
        return ITerm.scan(variables: variables, known: known, skip: skip).map { result in
            known = [:]
            for pane in result.panes {
                known[pane.windowID] = pane.values.keys.first
            }
            unclaimedAt = unclaimedAt.filter { result.skipped.contains($0.key) }
            for id in result.unclaimed { unclaimedAt[id] = now }

            let busy = Processes.busyTTYs()
            for project in projects {
                statuses[project.id] = ProjectStatus.evaluate(project, panes: result.panes, busyTTYs: busy)
            }
            return statuses
        }
    }
}
