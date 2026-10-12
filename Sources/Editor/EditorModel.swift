import AppKit
import SwiftUI

struct ProjectDraft: Identifiable, Equatable {
    let id = UUID()
    var project: Project
    /// A newly chosen logo (already normalized PNG data), written to icons/<id>.png on save.
    var pendingIcon: Data?
}

struct EditorIssue: Hashable {
    let message: String
    let isError: Bool
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var drafts: [ProjectDraft] = []
    @Published var selection: ProjectDraft.ID?
    @Published var saveError: String?
    /// Launcher path → what its script revealed.
    @Published private(set) var detections: [String: LauncherDetection] = [:]

    /// Sync state of the config repo, shown in the editor's footer.
    @Published private(set) var syncStatus: String?
    /// True while first-run setup is cloning or creating a config.
    @Published private(set) var isSettingUp = false

    private(set) var fileURL: URL
    private var savedProjects: [Project] = []
    private var comment: String?
    private var iconCache: [String: NSImage] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var baseURL: URL { fileURL.deletingLastPathComponent() }

    /// No projects.json yet: the editor offers to clone or create one.
    var needsSetup: Bool { !FileManager.default.fileExists(atPath: fileURL.path) }

    var configRepoName: String? { GitHub.repoName(of: baseURL) }

    var isDirty: Bool {
        drafts.map(\.project) != savedProjects || drafts.contains { $0.pendingIcon != nil }
    }

    var hasErrors: Bool {
        drafts.contains { issues(for: $0).contains(where: \.isError) }
    }

    // MARK: - Loading and saving

    func load() {
        let selectedIndex = selection.flatMap { id in drafts.firstIndex { $0.id == id } } ?? 0
        guard !needsSetup else {
            savedProjects = []
            drafts = []
            selection = nil
            return
        }
        do {
            let file = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: fileURL))
            comment = file.comment
            savedProjects = file.projects
            saveError = nil
        } catch {
            savedProjects = []
            saveError = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
        drafts = savedProjects.map { ProjectDraft(project: $0) }
        iconCache = [:]
        selection = drafts.indices.contains(selectedIndex) ? drafts[selectedIndex].id : drafts.first?.id
    }

    func save() {
        guard !hasErrors else {
            saveError = "Fix the problems marked in red before saving."
            return
        }
        do {
            for index in drafts.indices {
                if drafts[index].project.id.isEmpty {
                    drafts[index].project.id = Self.slug(drafts[index].project.name)
                }
                guard let png = drafts[index].pendingIcon else { continue }
                let relative = "icons/\(drafts[index].project.id).png"
                let destination = baseURL.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: destination, options: .atomic)
                drafts[index].project.icon = relative
                drafts[index].pendingIcon = nil
            }
            try ConfigFile(comment: comment, projects: drafts.map(\.project)).write(to: fileURL)
            savedProjects = drafts.map(\.project)
            iconCache = [:]
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
            return
        }
        push()
    }

    // MARK: - Config repo sync

    /// Saves are committed and pushed automatically when the config folder is a git repo.
    private func push() {
        guard GitHub.isRepository(baseURL) else {
            syncStatus = "Saved locally. The config folder isn't a git repo, so it isn't synced."
            return
        }
        syncStatus = "Pushing…"
        let folder = baseURL
        Task {
            let result = await Task.detached { GitHub.commitAndPush(folder, message: "Update projects") }.value
            switch result {
            case .success: syncStatus = "Saved and pushed to \(configRepoName ?? "the config repo")."
            case .failure(let failure): syncStatus = "Saved, but couldn't push: \(failure.message)"
            }
        }
    }

    /// Shows what's on disk right away, then pulls edits made on other Macs and reloads if anything changed.
    /// The reload is skipped once there's unsaved work here.
    func pullAndLoad() {
        guard !isDirty else { return }
        load()
        guard !needsSetup, GitHub.isRepository(baseURL) else { return }
        let folder = baseURL
        let before = try? Data(contentsOf: fileURL)
        Task {
            let result = await Task.detached { GitHub.pull(folder) }.value
            if case .failure(let failure) = result {
                syncStatus = "Couldn't pull the latest config: \(failure.message)"
            }
            if !isDirty, (try? Data(contentsOf: fileURL)) != before { load() }
        }
    }

    // MARK: - Config folder and first-run setup

    func switchFolder(to folder: URL) {
        ConfigStore.folder = folder
        fileURL = folder.appendingPathComponent("projects.json")
        syncStatus = nil
        load()
        NotificationCenter.default.post(name: .configFolderDidChange, object: nil)
    }

    /// Clones an existing config repo (e.g. from another Mac) into the config folder.
    func cloneConfig(repo: String) {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        let folder = baseURL
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !contents.isEmpty {
            saveError = "\(EditorModel.abbreviate(folder)) already has files in it. Choose an empty config folder first."
            return
        }
        isSettingUp = true
        Task {
            let result = await Task.detached { GitHub.clone(repo, to: folder) }.value
            isSettingUp = false
            switch result {
            case .success: switchFolder(to: folder)
            case .failure(let failure): saveError = "Couldn't clone \(repo): \(failure.message)"
            }
        }
    }

    /// Starts a new config from the example bundled with the app.
    func createConfig() {
        let folder = baseURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let example = Bundle.main.url(forResource: "examples", withExtension: nil) {
                try FileManager.default.copyItem(
                    at: example.appendingPathComponent("projects.example.json"), to: fileURL
                )
                let icons = example.appendingPathComponent("icons")
                if FileManager.default.fileExists(atPath: icons.path) {
                    try FileManager.default.copyItem(at: icons, to: folder.appendingPathComponent("icons"))
                }
            } else {
                try ConfigFile(comment: nil, projects: []).write(to: fileURL)
            }
            switchFolder(to: folder)
        } catch {
            saveError = "Couldn't create a config in \(EditorModel.abbreviate(folder)): \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    func binding(for id: ProjectDraft.ID) -> Binding<ProjectDraft>? {
        guard let current = drafts.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.drafts.first { $0.id == id } ?? current },
            set: { newValue in
                if let index = self.drafts.firstIndex(where: { $0.id == id }) { self.drafts[index] = newValue }
            }
        )
    }

    func addBlank() {
        let draft = ProjectDraft(project: Project(
            id: "", name: "New Project", path: "", launcher: "", match: .init(variable: "")
        ))
        drafts.append(draft)
        selection = draft.id
    }

    /// Adds a project from its launcher app, filling in everything the launcher's script reveals.
    func add(launcher app: URL) {
        let detection = LauncherInspector.inspect(app)
        detections[app.path] = detection
        let name = detection.suggestedName ?? app.deletingPathExtension().lastPathComponent
        var project = Project(
            id: uniqueID(Self.slug(name)), name: name,
            path: Self.abbreviate(app.deletingLastPathComponent()), launcher: Self.abbreviate(app),
            match: .init(variable: "")
        )
        project.repo = GitHub.repoName(of: app.deletingLastPathComponent())
        apply(detection, to: &project)
        var draft = ProjectDraft(project: project)
        // Start with the best logo the project folder has, if any.
        if let logo = IconFinder.candidates(in: project.pathURL, limit: 1).first {
            draft.pendingIcon = NSImage(contentsOf: logo).flatMap(IconImage.normalizedPNG)
        }
        drafts.append(draft)
        selection = draft.id
    }

    /// Fills in the GitHub repo from the project folder's `origin` remote.
    func detectRepo(for id: ProjectDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        if let repo = GitHub.repoName(of: drafts[index].project.pathURL) {
            drafts[index].project.repo = repo
        } else {
            saveError = "\(drafts[index].project.path) has no GitHub origin remote."
        }
    }

    func remove(_ id: ProjectDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        selection = drafts.indices.contains(index) ? drafts[index].id : drafts.last?.id
    }

    func move(from source: IndexSet, to destination: Int) {
        drafts.move(fromOffsets: source, toOffset: destination)
    }

    func setIcon(from url: URL, for id: ProjectDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              let image = NSImage(contentsOf: url),
              let png = IconImage.normalizedPNG(from: image) else {
            saveError = "Couldn't read \(url.lastPathComponent) as an image."
            return
        }
        drafts[index].pendingIcon = png
        saveError = nil
    }

    // MARK: - Launcher detection

    func detection(for draft: ProjectDraft) -> LauncherDetection? {
        detections[draft.project.launcherURL.path]
    }

    func loadDetection(for launcher: String) async {
        let url = URL(fileURLWithPath: (launcher as NSString).expandingTildeInPath)
        guard !launcher.isEmpty, detections[url.path] == nil,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let detection = await Task.detached { LauncherInspector.inspect(url) }.value
        detections[url.path] = detection
    }

    /// Overwrites the status-detection fields with what the launcher reveals.
    func applyDetection(to id: ProjectDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let url = drafts[index].project.launcherURL
        let detection = LauncherInspector.inspect(url)
        detections[url.path] = detection
        apply(detection, to: &drafts[index].project)
    }

    private func apply(_ detection: LauncherDetection, to project: inout Project) {
        if let variable = detection.variable {
            // Every pane is monitored until it's unchecked; existing choices are kept.
            project.match = .init(variable: variable, equals: detection.equals)
        }
        if let url = detection.url { project.url = url }
    }

    // MARK: - Presentation

    func image(for draft: ProjectDraft) -> NSImage? {
        if let png = draft.pendingIcon { return NSImage(data: png) }
        guard let icon = draft.project.icon else { return nil }
        let url = ConfigStore.resolve(icon, against: baseURL)
        if let cached = iconCache[url.path] { return cached }
        let image = NSImage(contentsOf: url)
        iconCache[url.path] = image
        return image
    }

    func issues(for draft: ProjectDraft) -> [EditorIssue] {
        let project = draft.project
        let fm = FileManager.default
        var issues: [EditorIssue] = []
        if project.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(message: "Give the project a name.", isError: true))
        }
        let id = project.id.isEmpty ? Self.slug(project.name) : project.id
        if drafts.filter({ ($0.project.id.isEmpty ? Self.slug($0.project.name) : $0.project.id) == id }).count > 1 {
            issues.append(.init(message: "Another project already uses the ID “\(id)”.", isError: true))
        }
        let installed = project.path.isEmpty || fm.fileExists(atPath: project.pathURL.path)
        if project.launcher.isEmpty {
            issues.append(.init(message: "Choose the launcher app that starts this project.", isError: true))
        } else if installed, !fm.fileExists(atPath: project.launcherURL.path) {
            issues.append(.init(message: "No launcher at \(project.launcher).", isError: false))
        }
        if project.match.variable.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(message: "Set the iTerm variable its launcher tags panes with, or use Detect.", isError: true))
        }
        if !installed {
            let fix = project.repo == nil ? "Add its GitHub repo so it can be installed." : "Install it from the picker."
            issues.append(.init(message: "Not on this Mac (no folder at \(project.path)). \(fix)", isError: false))
        }
        if draft.pendingIcon == nil {
            if let icon = project.icon {
                if !fm.fileExists(atPath: ConfigStore.resolve(icon, against: baseURL).path) {
                    issues.append(.init(message: "The logo file \(icon) is missing.", isError: false))
                }
            } else {
                issues.append(.init(message: "No logo yet; the picker will show a letter tile.", isError: false))
            }
        }
        return issues
    }

    static func slug(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func uniqueID(_ base: String) -> String {
        let taken = Set(drafts.map(\.project.id))
        var candidate = base.isEmpty ? "project" : base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

extension Binding where Value == String? {
    /// Edits an optional string as plain text; clearing the field stores nil.
    var orEmpty: Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: { wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
