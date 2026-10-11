import SwiftUI
import UniformTypeIdentifiers

struct ProjectsEditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if model.needsSetup {
            SetupView(model: model)
        } else {
            editor
        }
    }

    private var editor: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 340)
            VStack(spacing: 0) {
                if let id = model.selection, let draft = model.binding(for: id) {
                    ProjectForm(draft: draft, model: model)
                        .id(id)
                } else {
                    ContentUnavailableView("No Project Selected", systemImage: "square.grid.3x3",
                                           description: Text("Pick a project, or add one with +."))
                }
                Divider()
                footer
            }
            .frame(minWidth: 480)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.drafts) { draft in
                    if let binding = model.binding(for: draft.id) {
                        SidebarRow(draft: binding, model: model)
                            .tag(draft.id)
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("Add from Launcher App…") { chooseLauncherToAdd() }
                    Button("Add Blank Project") { model.addBlank() }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a project")

                Button {
                    if let id = model.selection { model.remove(id) }
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(model.selection == nil)
                .help("Remove the selected project")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Open projects.json") { NSWorkspace.shared.open(model.fileURL) }
                Button("Show Config Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.fileURL]) }
                Divider()
                Button("Change Config Folder…") { chooseConfigFolder(model: model) }
            } label: {
                Label(EditorModel.abbreviate(model.baseURL), systemImage: "folder")
            }
            .fixedSize()
            .help(model.configRepoName.map { "Synced with github.com/\($0)" } ?? "Not a git repo, so not synced")
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let status = model.syncStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { model.load() }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
        }
        .padding(12)
    }

    private func chooseLauncherToAdd() {
        let panel = NSOpenPanel()
        panel.message = "Choose the app that starts the project's iTerm window."
        panel.prompt = "Add Project"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("projects")
        if panel.runModal() == .OK, let url = panel.url { model.add(launcher: url) }
    }
}

private struct SidebarRow: View {
    @Binding var draft: ProjectDraft
    @ObservedObject var model: EditorModel

    var body: some View {
        let issues = model.issues(for: draft)
        HStack(spacing: 8) {
            Toggle("Show in picker", isOn: $draft.project.isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(draft.project.isEnabled ? "Shown in the picker; uncheck to hide it" : "Hidden from the picker; check to show it")
            ProjectIcon(image: model.image(for: draft), size: 24)
                .opacity(draft.project.isEnabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.project.name.isEmpty ? "Untitled" : draft.project.name)
                    .lineLimit(1)
                Text(draft.project.isEnabled ? draft.project.launcherURL.deletingPathExtension().lastPathComponent : "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(draft.project.isEnabled ? 1 : 0.55)
            Spacer(minLength: 0)
            if issues.contains(where: \.isError) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProjectIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

private struct ProjectForm: View {
    @Binding var draft: ProjectDraft
    @ObservedObject var model: EditorModel
    @State private var findingLogo = false
    @State private var dropTargeted = false
    @State private var idlePanesText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Logo") {
                    HStack(spacing: 14) {
                        ProjectIcon(image: model.image(for: draft), size: 64)
                            .overlay {
                                if dropTargeted {
                                    RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 3)
                                }
                            }
                            .dropDestination(for: URL.self) { urls, _ in
                                guard let url = urls.first else { return false }
                                model.setIcon(from: url, for: draft.id)
                                return true
                            } isTargeted: { dropTargeted = $0 }
                            .help("Drop an image here")
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Choose Image…", action: chooseImage)
                            Button("Find in Project…") { findingLogo = true }
                                .disabled(!FileManager.default.fileExists(atPath: draft.project.pathURL.path))
                                .popover(isPresented: $findingLogo, arrowEdge: .trailing) {
                                    LogoCandidates(root: draft.project.pathURL) { url in
                                        model.setIcon(from: url, for: draft.id)
                                        findingLogo = false
                                    }
                                }
                        }
                    }
                }
                Toggle("Show in Picker", isOn: $draft.project.isOn)
                    .help("Turn off projects you aren't working on; they stay here, ready to turn back on.")
                TextField("Name", text: $draft.project.name)
                TextField("Description", text: $draft.project.description.orEmpty, prompt: Text("Optional, shown as a tooltip"))
                TextField("ID", text: $draft.project.id, prompt: Text(EditorModel.slug(draft.project.name)))
            }

            Section("Launch") {
                PathField(title: "Launcher", path: $draft.project.launcher, choosesApp: true)
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Detect Settings from Launcher") { model.applyDetection(to: draft.id) }
                            .disabled(!FileManager.default.fileExists(atPath: draft.project.launcherURL.path))
                        if let detection = model.detection(for: draft) {
                            Text(detection.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } label: {
                    EmptyView()
                }
                PathField(title: "Project Folder", path: $draft.project.path, choosesApp: false)
                LabeledContent("GitHub Repo") {
                    HStack(spacing: 6) {
                        TextField("GitHub Repo", text: $draft.project.repo.orEmpty, prompt: Text("owner/name"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Button("Detect") { model.detectRepo(for: draft.id) }
                            .disabled(!FileManager.default.fileExists(atPath: draft.project.pathURL.path))
                            .help("Read it from the project folder's origin remote")
                    }
                }
                TextField("Browser URL", text: $draft.project.url.orEmpty, prompt: Text("http://localhost:5173/"))
            }

            Section {
                TextField("iTerm Variable", text: $draft.project.match.variable, prompt: Text("user.MyAppSession"))
                TextField("Must Equal", text: $draft.project.match.equals.orEmpty, prompt: Text("Any value"))
                if let roles = knownRoles {
                    LabeledContent("Monitored Panes") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(roles, id: \.self) { role in
                                Toggle(role, isOn: monitored(role, among: roles))
                            }
                        }
                    }
                } else {
                    TextField("Idle Panes", text: $idlePanesText, prompt: Text("Working, Tools"))
                        .onChange(of: idlePanesText) { _, text in
                            let panes = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            draft.project.idlePanes = panes.isEmpty ? nil : panes
                        }
                }
            } header: {
                Text("Status Detection")
            } footer: {
                Text("The launcher tags its iTerm panes with this variable, which is how the picker finds the project's window. Every pane is monitored by default; uncheck one to leave it out of the green/orange health dot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let issues = model.issues(for: draft)
            if !issues.isEmpty {
                Section {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: issue.isError ? "exclamationmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(issue.isError ? Color.red : Color.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { idlePanesText = (draft.project.idlePanes ?? []).joined(separator: ", ") }
        .task(id: draft.project.launcher) { await model.loadDetection(for: draft.project.launcher) }
    }

    /// The panes the launcher creates, when it uses this project's variable.
    private var knownRoles: [String]? {
        guard let detection = model.detection(for: draft),
              detection.variable == draft.project.match.variable,
              !detection.roles.isEmpty else { return nil }
        return detection.roles
    }

    private func monitored(_ role: String, among roles: [String]) -> Binding<Bool> {
        Binding(
            get: { !(draft.project.idlePanes ?? []).contains(role) },
            set: { isMonitored in
                var idle = Set(draft.project.idlePanes ?? [])
                if isMonitored { idle.remove(role) } else { idle.insert(role) }
                // Keep the launcher's pane order, plus any idle names it doesn't know about.
                let ordered = roles.filter(idle.contains) + idle.subtracting(roles).sorted()
                draft.project.idlePanes = ordered.isEmpty ? nil : ordered
            }
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.message = "Choose a logo. Square images become rounded tiles."
        panel.allowedContentTypes = [.image]
        if FileManager.default.fileExists(atPath: draft.project.pathURL.path) {
            panel.directoryURL = draft.project.pathURL
        }
        if panel.runModal() == .OK, let url = panel.url { model.setIcon(from: url, for: draft.id) }
    }
}

private struct PathField: View {
    let title: String
    @Binding var path: String
    let choosesApp: Bool

    private var exists: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $path, prompt: Text(choosesApp ? "~/projects/app/StartAppDev.app" : "~/projects/app"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(path.isEmpty || exists ? Color.primary : Color.orange)
                Button("Choose…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        if choosesApp {
            panel.allowedContentTypes = [.application]
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        }
        let current = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        panel.directoryURL = choosesApp ? current.deletingLastPathComponent() : current
        if panel.runModal() == .OK, let url = panel.url {
            path = EditorModel.abbreviate(url)
        }
    }
}

private struct LogoCandidates: View {
    let root: URL
    let onPick: (URL) -> Void
    @State private var candidates: [URL]?

    var body: some View {
        Group {
            if let candidates, candidates.isEmpty {
                Text("No logo-like images found in this project.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let candidates {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 5), spacing: 12) {
                        ForEach(candidates, id: \.self) { url in
                            Button { onPick(url) } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: 60, height: 60)
                                    Text(url.lastPathComponent)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(width: 84)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(url.path.replacingOccurrences(of: root.path + "/", with: ""))
                        }
                    }
                    .padding(14)
                }
            } else {
                ProgressView("Looking for logos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 360)
        .task {
            let root = root
            candidates = await Task.detached { IconFinder.candidates(in: root) }.value
        }
    }
}

extension Project {
    /// Two-state view of `enabled` for toggles; turning a project back on drops the key from the JSON.
    var isOn: Bool {
        get { isEnabled }
        set { enabled = newValue ? nil : false }
    }
}

@MainActor
private func chooseConfigFolder(model: EditorModel) {
    let panel = NSOpenPanel()
    panel.message = "Choose the folder holding projects.json, or an empty folder for a new config."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = model.baseURL
    if panel.runModal() == .OK, let url = panel.url { model.switchFolder(to: url) }
}

/// First run on a Mac: clone an existing config repo, or start a new config from the bundled example.
private struct SetupView: View {
    @ObservedObject var model: EditorModel
    @State private var repo = ""

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Set Up Project Launcher")
                    .font(.title2.bold())
                Text("Your project list lives in \(EditorModel.abbreviate(model.baseURL)).")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Already use Project Launcher on another Mac?").font(.headline)
                    Text("Clone your config repo. Saves here are pushed back to it, and changes from other Macs are pulled in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("owner/projectlauncher-config", text: $repo)
                            .onSubmit { model.cloneConfig(repo: repo) }
                        Button("Clone Config Repo") { model.cloneConfig(repo: repo) }
                            .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty || model.isSettingUp)
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Starting fresh?").font(.headline)
                    Text("Create a config from the example, then add your projects. Make the folder a git repo later to sync it between Macs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Create New Config") { model.createConfig() }
                            .disabled(model.isSettingUp)
                        Button("Choose a Different Folder…") { chooseConfigFolder(model: model) }
                            .disabled(model.isSettingUp)
                    }
                }
                .padding(6)
            }

            if model.isSettingUp {
                ProgressView("Cloning…")
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
