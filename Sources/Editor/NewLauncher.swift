import AppKit
import SwiftUI

/// Drafts, edits and writes a generated launcher for a repo: from scratch ("New Project from Folder…") or by
/// editing an existing generated launcher's embedded spec.
@MainActor
final class LauncherDraftModel: ObservableObject, Identifiable {
    enum Mode {
        /// A repo without a generated launcher; the project is added to Project Launcher afterwards.
        case new
        /// An existing generated launcher; it's rewritten in place.
        case edit(launcher: URL)
    }

    enum Phase: Equatable {
        case idle, detecting, analyzing, writing
        case done(String)
    }

    let repo: URL
    let mode: Mode
    @Published var spec: GeneratorSpec?
    @Published var notes: [String] = []
    @Published var changes: [ConfigChange] = []
    @Published var keptChanges: Set<ConfigChange.ID> = []
    @Published var phase: Phase = .idle
    @Published var error: String?
    @Published var commit = true
    @Published var push = true
    @Published var jsonText = ""
    private var taken: Set<Int>
    /// Called with the written launcher app when a new project should be added to the list.
    var onCreated: ((URL) -> Void)?

    init(repo: URL, mode: Mode, taken: Set<Int>) {
        self.repo = repo
        self.mode = mode
        self.taken = taken
    }

    var isBusy: Bool { [.detecting, .analyzing, .writing].contains(phase) }

    var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    var repoIsGit: Bool { GitHub.isRepository(repo) }

    // MARK: - Drafting

    func start() {
        switch mode {
        case .new: detect()
        case .edit(let launcher): loadExisting(launcher)
        }
    }

    private func detect() {
        phase = .detecting
        let repo = repo, taken = taken
        Task {
            let result = await Task.detached { Generator.detect(repo, taken: taken) }.value
            phase = .idle
            switch result {
            case .success(let draft): adopt(draft)
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func loadExisting(_ launcher: URL) {
        phase = .detecting
        Task {
            let result = await Task.detached { Generator.extract(launcher) }.value
            phase = .idle
            switch result {
            case .success(let spec): adopt(Generator.Draft(spec: spec, notes: [], configChanges: []))
            case .failure(let failure): error = failure.message
            }
        }
    }

    /// Re-drafts with Claude Code, which reads the repo (read-only) and can propose config changes for the ports.
    func improveWithClaude() {
        phase = .analyzing
        error = nil
        // Ports this draft already uses stay available to it.
        let repo = repo, taken = taken.subtracting(spec?.ports ?? [])
        Task {
            let result = await Task.detached { Generator.analyze(repo, taken: taken) }.value
            phase = .idle
            switch result {
            case .success(var draft):
                if case .edit = mode, let current = spec {
                    // Keep the existing launcher's identity and file name when re-drafting it.
                    draft.spec.id = current.id
                    draft.spec.launcher = current.launcherName
                }
                adopt(draft)
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func adopt(_ draft: Generator.Draft) {
        spec = draft.spec
        notes = draft.notes
        changes = draft.configChanges
        keptChanges = Set(draft.configChanges.map(\.id))
        syncJSONFromSpec()
    }

    // MARK: - Editing

    func syncJSONFromSpec() {
        guard let spec else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        jsonText = (try? encoder.encode(spec)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func applyJSON() {
        do {
            spec = try JSONDecoder().decode(GeneratorSpec.self, from: Data(jsonText.utf8))
            error = nil
        } catch {
            self.error = "The JSON isn't a valid spec: \(error.localizedDescription)"
        }
    }

    func addPane() {
        spec?.panes.insert(.init(role: "Service\((spec?.panes.count ?? 0) + 1)", command: ""), at: max((spec?.panes.count ?? 1) - 1, 0))
    }

    func removePane(_ id: GeneratorSpec.Pane.ID) {
        spec?.panes.removeAll { $0.id == id }
    }

    func movePane(_ id: GeneratorSpec.Pane.ID, by offset: Int) {
        guard var panes = spec?.panes, let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard panes.indices.contains(target) else { return }
        panes.swapAt(index, target)
        spec?.panes = panes
    }

    // MARK: - Writing

    /// Validates, applies the kept config changes, writes and compiles the launcher, then commits (and pushes).
    func write() {
        guard let spec else { return }
        phase = .writing
        error = nil
        let repo = repo, commit = commit && repoIsGit, push = push
        let kept = changes.filter { keptChanges.contains($0.id) }
        let message = isNew ? "Add a dev launcher generated by Project Launcher" : "Update the dev launcher (regenerated by Project Launcher)"
        Task {
            let result = await Task.detached { () -> Result<(URL, String), Generator.Failure> in
                if case .failure(let failure) = Generator.validate(spec) { return .failure(failure) }
                let changed: [String]
                switch Generator.apply(kept, to: repo) {
                case .success(let paths): changed = paths
                case .failure(let failure): return .failure(failure)
                }
                let written: [URL]
                switch Generator.render(spec, into: repo) {
                case .success(let urls): written = urls
                case .failure(let failure): return .failure(failure)
                }
                let app = repo.appendingPathComponent("\(spec.launcherName).app")
                var summary = "Wrote \(spec.launcherName).applescript and .app"
                if !changed.isEmpty { summary += " and updated \(changed.joined(separator: ", "))" }
                summary += "."
                if commit {
                    let paths = written.map { $0.lastPathComponent } + changed
                    switch GitHub.commit(paths, in: repo, message: message, push: push) {
                    case .success(let outcome): summary += " \(outcome)"
                    case .failure(let failure):
                        summary += " Couldn't commit: \(failure.message)"
                    }
                }
                return .success((app, summary))
            }.value
            switch result {
            case .success(let (app, summary)):
                phase = .done(summary)
                if isNew { onCreated?(app) }
            case .failure(let failure):
                phase = .idle
                error = failure.message
            }
        }
    }
}

struct LauncherDraftView: View {
    @ObservedObject var model: LauncherDraftModel
    let dismiss: () -> Void
    @State private var showingJSON = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 620, idealHeight: 720)
        .onAppear { if model.spec == nil, model.phase == .idle { model.start() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isNew ? "wand.and.stars" : "square.and.pencil")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isNew ? "New Launcher" : "Edit Launcher").font(.title3.bold())
                Text(EditorModel.abbreviate(model.repo)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch model.phase {
            case .detecting: ProgressView("Reading the repo…").controlSize(.small)
            case .analyzing: ProgressView("Claude is analyzing the repo (a minute or two)…").controlSize(.small)
            case .writing: ProgressView("Writing the launcher…").controlSize(.small)
            default: EmptyView()
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if case .done(let summary) = model.phase {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text(summary).multilineTextAlignment(.center).frame(maxWidth: 520)
                if model.isNew { Text("It's been added to your projects.").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.spec != nil {
            Form {
                projectSection
                panesSection
                if !model.notes.isEmpty {
                    Section("Notes") {
                        ForEach(model.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.changes.isEmpty { changesSection }
                Section {
                    DisclosureGroup("Edit the spec as JSON", isExpanded: $showingJSON) {
                        TextEditor(text: $model.jsonText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                        HStack {
                            Text("Every field is described in generator/SPEC.md.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply JSON") { model.applyJSON() }
                        }
                    }
                    .onChange(of: showingJSON) { _, open in if open { model.syncJSONFromSpec() } }
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 10) {
                if model.isBusy { ProgressView() }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var specBinding: Binding<GeneratorSpec> {
        Binding(get: { model.spec ?? GeneratorSpec(id: "", name: "", panes: []) }, set: { model.spec = $0 })
    }

    private var projectSection: some View {
        Section("Project") {
            TextField("Name", text: specBinding.name)
            TextField("ID", text: specBinding.id)
                .disabled(!model.isNew)
                .help("Tags the iTerm panes and prefixes per-machine port variables")
            TextField("Browser URL", text: specBinding.url.orEmpty, prompt: Text("http://localhost:{port:Frontend}/"))
            LabeledContent("Launcher", value: "\(model.spec?.launcherName ?? "").app")
        }
    }

    private var panesSection: some View {
        Section {
            ForEach(specBinding.panes) { $pane in
                PaneEditor(pane: $pane, otherRoles: (model.spec?.panes ?? []).map(\.role).filter { $0 != pane.role },
                           move: { model.movePane(pane.id, by: $0) }, remove: { model.removePane(pane.id) })
            }
            Button("Add Pane", systemImage: "plus") { model.addPane() }
        } header: {
            Text("Panes, top to bottom")
        } footer: {
            Text("Use {port} for a pane's own port, {port:Role} for another's and {root} for the repo folder. The last pane is usually the Working shell.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var changesSection: some View {
        Section {
            ForEach(model.changes) { change in
                Toggle(isOn: Binding(
                    get: { model.keptChanges.contains(change.id) },
                    set: { keep in if keep { model.keptChanges.insert(change.id) } else { model.keptChanges.remove(change.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.path).font(.callout.monospaced())
                        Text(change.why).font(.caption).foregroundStyle(.secondary)
                        Text("− \(change.find)\n+ \(change.replace)")
                            .font(.caption.monospaced())
                            .lineLimit(6)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            Text("Config changes for the new ports")
        } footer: {
            Text("Proposed by Claude; only checked changes are applied, and each must match exactly once.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            if case .done = model.phase {
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            } else {
                if model.repoIsGit {
                    Toggle("Commit", isOn: $model.commit).toggleStyle(.checkbox)
                    Toggle("Push", isOn: $model.push).toggleStyle(.checkbox).disabled(!model.commit)
                }
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Improve with Claude") { model.improveWithClaude() }
                    .disabled(model.isBusy)
                    .help("Claude Code reads the repo (read-only) and drafts the panes, ports and needed config changes")
                Button(model.isNew ? "Write Launcher" : "Regenerate Launcher") { model.write() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.spec == nil)
            }
        }
        .padding(14)
    }
}

private struct PaneEditor: View {
    @Binding var pane: GeneratorSpec.Pane
    let otherRoles: [String]
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Role", text: $pane.role).frame(width: 130).font(.headline)
                TextField("Folder", text: $pane.dir.orEmpty, prompt: Text("repo root")).frame(width: 140)
                TextField("Port", value: $pane.port, format: .number.grouping(.never), prompt: Text("none")).frame(width: 70)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("Move up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Move down")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove pane")
            }
            .labelsHidden()
            TextField("Command", text: $pane.command.orEmpty, prompt: Text("command to run"), axis: .vertical)
                .font(.callout.monospaced())
                .labelsHidden()
            HStack(spacing: 8) {
                TextField("Setup", text: Binding(
                    get: { (pane.setup ?? []).joined(separator: " ; ") },
                    set: { text in
                        let lines = text.components(separatedBy: " ; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        pane.setup = lines.isEmpty ? nil : lines
                    }
                ), prompt: Text("setup lines, separated by “ ; ”"))
                .font(.caption.monospaced())
                if !otherRoles.isEmpty {
                    Menu {
                        ForEach(otherRoles, id: \.self) { role in
                            Toggle(role, isOn: Binding(
                                get: { (pane.waitFor ?? []).contains(role) },
                                set: { on in
                                    var roles = pane.waitFor ?? []
                                    if on { roles.append(role) } else { roles.removeAll { $0 == role } }
                                    pane.waitFor = roles.isEmpty ? nil : roles
                                }
                            ))
                        }
                    } label: {
                        Text(pane.waitFor.map { "Waits for \($0.joined(separator: ", "))" } ?? "Waits for…").font(.caption)
                    }
                    .fixedSize()
                }
            }
            .labelsHidden()
            if let note = pane.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
