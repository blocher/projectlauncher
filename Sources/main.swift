import AppKit

// `ProjectLauncher --status` prints what the picker would show, without any UI.
if CommandLine.arguments.contains("--status") {
    let config = ConfigStore.current()
    guard config.exists else {
        print("No config at \(config.fileURL.path). Open Project Launcher to set one up.")
        exit(1)
    }
    config.reloadIfChanged()
    if let error = config.error { print(error) }
    let projects = config.projects.filter(\.isEnabled)
    switch StatusScanner().scan(projects.filter { FileManager.default.fileExists(atPath: $0.pathURL.path) }, fresh: true) {
    case .failure(let error):
        print("iTerm query failed: \(error.message)")
    case .success(let statuses):
        for project in projects {
            let installed = FileManager.default.fileExists(atPath: project.pathURL.path)
            let status = installed ? statuses[project.id] ?? ProjectStatus() : ProjectStatus(health: .missing)
            let window = status.windowID.map { " [window \($0)]" } ?? ""
            print("\(project.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(status.summary)\(window)")
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
