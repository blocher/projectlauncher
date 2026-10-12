import AppKit
import SwiftUI

struct ProjectDraft: Identifiable, Equatable {
    let id: UUID
    var project: Project
    /// A newly chosen logo (already normalized PNG data), written to icons/<id>.png on save.
    var pendingIcon: Data?

    init(id: UUID = UUID(), project: Project, pendingIcon: Data? = nil) {
        self.id = id
        self.project = project
        self.pendingIcon = pendingIcon
    }
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
    /// The config repo's GitHub `owner/name`, looked up off the main thread whenever the folder changes.
    @Published private(set) var configRepoName: String?
    /// Set when projects.json exists but can't be read. Saving is blocked so an empty list can't overwrite it.
    @Published private(set) var loadFailure: String?
    /// True while first-run setup is cloning or creating a config.
    @Published private(set) var isSettingUp = false
    /// True while "Add from Launcher App…" inspects the launcher and project.
    @Published private(set) var isAdding = false

    private(set) var fileURL: URL
    private var savedProjects: [Project] = []
    private var comment: String?
    /// The bytes of projects.json as last loaded or saved, to notice changes made underneath the editor.
    private var loadedData: Data?
    private var iconCache: [String: NSImage] = [:]
    private var missingIcons: Set<String> = []
    private var pendingIconCache: [UUID: (data: Data, image: NSImage)] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var baseURL: URL { fileURL.deletingLastPathComponent() }

    /// No projects.json yet: the editor offers to clone or create one.
    var needsSetup: Bool { !FileManager.default.fileExists(atPath: fileURL.path) }

    var isDirty: Bool {
        drafts.map(\.project) != savedProjects || drafts.contains { $0.pendingIcon != nil }
    }

    var hasErrors: Bool {
        drafts.contains { issues(for: $0).contains(where: \.isError) }
    }

    var canSave: Bool { isDirty && loadFailure == nil }

    // MARK: - Loading and saving

    /// Reads projects.json. Drafts keep their identity (and the selection stays put) for projects that are still
    /// there, so a reload doesn't reset the form being edited.
    func load() {
        let selectedProjectID = selection.flatMap { id in drafts.first { $0.id == id }?.project.id }
        let existingIDs = Dictionary(drafts.map { ($0.project.id, $0.id) }, uniquingKeysWith: { first, _ in first })
        iconCache = [:]
        missingIcons = []
        pendingIconCache = [:]
        guard !needsSetup else {
            savedProjects = []
            drafts = []
            selection = nil
            loadedData = nil
            loadFailure = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var file = try JSONDecoder().decode(ConfigFile.self, from: data)
            // `"enabled": true` means the same as leaving it out; normalize so toggling off and on isn't a change.
            for index in file.projects.indices where file.projects[index].enabled == true {
                file.projects[index].enabled = nil
            }
            comment = file.comment
            savedProjects = file.projects
            loadedData = data
            loadFailure = nil
            saveError = nil
        } catch {
            comment = nil
            savedProjects = []
            loadedData = nil
            loadFailure = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription) Fix the file (Open projects.json), then reopen this window. Saving is disabled so the list isn't overwritten."
        }
        drafts = savedProjects.map { ProjectDraft(id: existingIDs[$0.id] ?? UUID(), project: $0) }
        selection = drafts.first { $0.project.id == selectedProjectID }?.id ?? drafts.first?.id
        refreshRepoName()
    }

    /// Reloads when projects.json changed on disk (e.g. a pull brought in another Mac's edits) and nothing here
    /// is unsaved. With unsaved edits, `save()` refuses instead of overwriting the newer file.
    func reloadIfChangedOnDisk() {
        guard !isDirty, (try? Data(contentsOf: fileURL)) != loadedData else { return }
        load()
    }

    private var changedOnDiskSinceLoad: Bool {
        guard let loadedData else { return false }
        return (try? Data(contentsOf: fileURL)) != loadedData
    }

    func save() {
        guard loadFailure == nil else { return }
        guard !hasErrors else {
            saveError = "Fix the problems marked in red before saving."
            return
        }
        guard !changedOnDiskSinceLoad else {
            saveError = "projects.json changed since this window loaded it (probably pulled from another Mac). Click Revert to load the latest, then make your change again."
            return
        }
        do {
            for index in drafts.indices {
                if drafts[index].project.id.isEmpty {
                    drafts[index].project.id = uniqueID(Self.slug(drafts[index].project.name), excluding: index)
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
            loadedData = try? Data(contentsOf: fileURL)
            removeOrphanedIcons(previouslySaved: savedProjects)
            savedProjects = drafts.map(\.project)
            iconCache = [:]
            missingIcons = []
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
            return
        }
        push()
    }

    /// Deletes logos in the config's icons/ folder that only deleted projects used.
    private func removeOrphanedIcons(previouslySaved: [Project]) {
        let stillUsed = Set(drafts.compactMap(\.project.icon))
        for icon in Set(previouslySaved.compactMap(\.icon)).subtracting(stillUsed) where icon.hasPrefix("icons/") {
            try? FileManager.default.removeItem(at: baseURL.appendingPathComponent(icon))
        }
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
        let repoName = configRepoName ?? "the config repo"
        Task {
            let result = await Task.detached { GitHub.commitAndPush(folder, message: "Update projects") }.value
            guard folder == baseURL else { return }  // The config folder changed meanwhile.
            switch result {
            case .success: syncStatus = "Saved and pushed to \(repoName)."
            case .failure(let failure): syncStatus = "Saved here, but couldn't push: \(failure.message)"
            }
            loadedData = try? Data(contentsOf: fileURL)  // A pull during the push may have rebased the file.
        }
    }

    /// Shows what's on disk right away, then pulls edits made on other Macs and reloads if anything changed.
    func pullAndLoad() {
        guard !isDirty else { return }
        load()
        guard !needsSetup, loadFailure == nil, GitHub.isRepository(baseURL) else { return }
        let folder = baseURL
        Task {
            let result = await Task.detached { GitHub.pull(folder) }.value
            guard folder == baseURL else { return }
            if case .failure(let failure) = result {
                syncStatus = "Couldn't pull the latest config: \(failure.message)"
            }
            reloadIfChangedOnDisk()
        }
    }

    private func refreshRepoName() {
        let folder = baseURL
        Task {
            let name = await Task.detached { GitHub.repoName(of: folder) }.value
            if folder == baseURL { configRepoName = name }
        }
    }

    // MARK: - Config folder and first-run setup

    /// The caller confirms discarding unsaved changes first.
    func switchFolder(to folder: URL) {
        ConfigStore.folder = folder
        fileURL = folder.appendingPathComponent("projects.json")
        syncStatus = nil
        saveError = nil
        configRepoName = nil
        drafts = []
        savedProjects = []
        load()
        NotificationCenter.default.post(name: .configFolderDidChange, object: nil)
    }

    /// Clones an existing config repo (e.g. from another Mac) into the config folder.
    func cloneConfig(repo: String) {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        let folder = baseURL
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if contents.contains(where: { !$0.hasPrefix(".") }) {
            saveError = "\(Self.abbreviate(folder)) already has files in it. Choose an empty config folder first."
            return
        }
        // git won't clone into a non-empty folder, so clear out stray dotfiles such as .DS_Store.
        for name in contents { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        isSettingUp = true
        saveError = nil
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
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let example = Bundle.main.url(forResource: "examples", withExtension: nil) {
                let icons = example.appendingPathComponent("icons")
                let destinationIcons = folder.appendingPathComponent("icons")
                if fm.fileExists(atPath: icons.path), !fm.fileExists(atPath: destinationIcons.path) {
                    try fm.copyItem(at: icons, to: destinationIcons)
                }
                // Written last: its presence is what marks the setup as done.
                try fm.copyItem(at: example.appendingPathComponent("projects.example.json"), to: fileURL)
            } else {
                try ConfigFile(comment: nil, projects: []).write(to: fileURL)
            }
            switchFolder(to: folder)
        } catch {
            saveError = "Couldn't create a config in \(Self.abbreviate(folder)): \(error.localizedDescription)"
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
    /// Inspecting the launcher and searching the project for a logo can take a while, so it runs off the main thread.
    func add(launcher app: URL) {
        isAdding = true
        Task {
            let (detection, repo, logo) = await Task.detached {
                let folder = app.deletingLastPathComponent()
                let logo = IconFinder.candidates(in: folder, limit: 1).first
                    .flatMap(NSImage.init(contentsOf:))
                    .flatMap(IconImage.normalizedPNG)
                return (LauncherInspector.inspect(app), GitHub.repoName(of: folder), logo)
            }.value
            isAdding = false
            detections[app.path] = detection
            let name = detection.suggestedName ?? app.deletingPathExtension().lastPathComponent
            var project = Project(
                id: uniqueID(Self.slug(name)), name: name,
                path: Self.abbreviate(app.deletingLastPathComponent()), launcher: Self.abbreviate(app),
                match: .init(variable: "")
            )
            project.repo = repo
            apply(detection, to: &project)
            let draft = ProjectDraft(project: project, pendingIcon: logo)
            drafts.append(draft)
            selection = draft.id
        }
    }

    /// Fills in the GitHub repo from the project folder's `origin` remote.
    func detectRepo(for id: ProjectDraft.ID) {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        let folder = draft.project.pathURL
        Task {
            let repo = await Task.detached { GitHub.repoName(of: folder) }.value
            guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
            if let repo {
                drafts[index].project.repo = repo
            } else {
                saveError = "\(drafts[index].project.path) isn't a git repo with a GitHub origin remote."
            }
        }
    }

    func remove(_ id: ProjectDraft.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        pendingIconCache[id] = nil
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
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        let url = draft.project.launcherURL
        Task {
            let detection = await Task.detached { LauncherInspector.inspect(url) }.value
            detections[url.path] = detection
            guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
            apply(detection, to: &drafts[index].project)
        }
    }

    private func apply(_ detection: LauncherDetection, to project: inout Project) {
        if let variable = detection.variable {
            // Every pane is monitored until it's unchecked; existing choices are kept.
            project.match = .init(variable: variable, equals: detection.equals)
        }
        if let url = detection.url { project.url = url }
    }

    // MARK: - Presentation

    /// Called while rendering, so it must stay cheap: decoded logos and missing files are both cached.
    func image(for draft: ProjectDraft) -> NSImage? {
        if let png = draft.pendingIcon {
            if let cached = pendingIconCache[draft.id], cached.data == png { return cached.image }
            guard let image = NSImage(data: png) else { return nil }
            pendingIconCache[draft.id] = (png, image)
            return image
        }
        guard let icon = draft.project.icon else { return nil }
        let path = ConfigStore.resolve(icon, against: baseURL).path
        if let cached = iconCache[path] { return cached }
        if missingIcons.contains(path) { return nil }
        guard let image = NSImage(contentsOfFile: path) else {
            missingIcons.insert(path)
            return nil
        }
        iconCache[path] = image
        return image
    }

    func issues(for draft: ProjectDraft) -> [EditorIssue] {
        let project = draft.project
        let fm = FileManager.default
        var issues: [EditorIssue] = []
        if project.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(message: "Give the project a name.", isError: true))
        }
        if !project.id.isEmpty, project.id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            issues.append(.init(message: "The ID can only contain letters, numbers, - and _.", isError: true))
        }
        let id = effectiveID(of: project)
        if drafts.filter({ effectiveID(of: $0.project) == id }).count > 1 {
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
            if project.icon == nil {
                issues.append(.init(message: "No logo yet; the picker will show a letter tile.", isError: false))
            } else if image(for: draft) == nil {
                issues.append(.init(message: "The logo file \(project.icon ?? "") is missing.", isError: false))
            }
        }
        return issues
    }

    /// The ID a project is saved under: its own, or one derived from its name. Compared case-insensitively,
    /// since icon files are named after it on a case-insensitive file system.
    private func effectiveID(of project: Project) -> String {
        (project.id.isEmpty ? Self.slug(project.name) : project.id).lowercased()
    }

    static func slug(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func uniqueID(_ base: String, excluding excludedIndex: Int? = nil) -> String {
        let taken = Set(drafts.indices.filter { $0 != excludedIndex }.map { drafts[$0].project.id.lowercased() })
        let base = base.isEmpty ? "project" : base
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
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
