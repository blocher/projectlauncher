import Foundation

struct Project: Codable, Equatable {
    /// An iTerm variable, read at session scope, that marks a pane as belonging to this project.
    /// Window variables are reachable as `tab.window.<name>`.
    struct Match: Codable, Equatable {
        var variable: String
        /// When set, the variable must equal this value; otherwise any non-empty value matches
        /// and that value is the pane's role (e.g. "Backend").
        var equals: String?
    }

    var id: String
    var name: String
    var description: String?
    /// Off hides the project from the picker without deleting it. Omitted in JSON means on.
    var enabled: Bool?
    var path: String
    /// GitHub `owner/name`, used to install the project on a Mac that doesn't have it yet.
    var repo: String?
    var launcher: String
    var icon: String?
    var url: String?
    var match: Match
    /// Panes that are idle shells by design and don't count toward service health.
    var idlePanes: [String]?

    var isEnabled: Bool { enabled ?? true }
    var pathURL: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    var launcherURL: URL { URL(fileURLWithPath: (launcher as NSString).expandingTildeInPath) }

    /// Declared so projects.json keeps a readable field order when the editor writes it.
    private enum CodingKeys: String, CodingKey {
        case id, name, description, enabled, path, repo, launcher, icon, url, match, idlePanes
    }
}

struct ConfigFile: Codable {
    var comment: String?
    var projects: [Project]

    private enum CodingKeys: String, CodingKey {
        case comment = "_comment", projects
    }

    /// Writes the file by hand: JSONEncoder doesn't keep key order, and this file is meant to be read and hand-edited.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quoted(_ string: String) throws -> String {
            String(decoding: try encoder.encode(string), as: UTF8.self)
        }

        var entries: [String] = []
        for project in projects {
            var fields = [("id", try quoted(project.id)), ("name", try quoted(project.name))]
            if let description = project.description { fields.append(("description", try quoted(description))) }
            if !project.isEnabled { fields.append(("enabled", "false")) }
            fields.append(("path", try quoted(project.path)))
            if let repo = project.repo { fields.append(("repo", try quoted(repo))) }
            fields.append(("launcher", try quoted(project.launcher)))
            if let icon = project.icon { fields.append(("icon", try quoted(icon))) }
            if let link = project.url { fields.append(("url", try quoted(link))) }
            var match = "{ \"variable\": \(try quoted(project.match.variable))"
            if let equals = project.match.equals { match += ", \"equals\": \(try quoted(equals))" }
            fields.append(("match", match + " }"))
            if let idle = project.idlePanes {
                fields.append(("idlePanes", "[" + (try idle.map(quoted)).joined(separator: ", ") + "]"))
            }
            entries.append("    {\n" + fields.map { "      \"\($0.0)\": \($0.1)" }.joined(separator: ",\n") + "\n    }")
        }

        var json = "{\n"
        if let comment { json += "  \"_comment\": \(try quoted(comment)),\n" }
        json += "  \"projects\": [\n" + entries.joined(separator: ",\n") + "\n  ]\n}\n"
        try Data(json.utf8).write(to: url, options: .atomic)
    }
}

/// Loads projects.json and re-reads it whenever it changes on disk, so edits apply without a rebuild.
final class ConfigStore {
    let fileURL: URL
    private(set) var projects: [Project] = []
    private(set) var error: String?
    private var loadedModDate: Date?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static let defaultFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/projectlauncher")
    private static let folderDefaultsKey = "ConfigFolder"

    /// The config folder chosen in the editor (remembered per Mac), or ~/.config/projectlauncher.
    static var folder: URL {
        get {
            UserDefaults.standard.string(forKey: folderDefaultsKey).map { URL(fileURLWithPath: $0) } ?? defaultFolder
        }
        set {
            if newValue.standardizedFileURL == defaultFolder.standardizedFileURL {
                UserDefaults.standard.removeObject(forKey: folderDefaultsKey)
            } else {
                UserDefaults.standard.set(newValue.path, forKey: folderDefaultsKey)
            }
        }
    }

    static func current() -> ConfigStore {
        ConfigStore(fileURL: folder.appendingPathComponent("projects.json"))
    }

    /// A config is available: on disk now, or loaded earlier (git rewrites files in place during a pull, so
    /// projects.json can vanish or be half-written for a moment).
    var exists: Bool { hasLoaded || FileManager.default.fileExists(atPath: fileURL.path) }
    private var hasLoaded = false

    /// Returns true when the project list was (re)loaded.
    @discardableResult
    func reloadIfChanged() -> Bool {
        let modDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if modDate != nil, modDate == loadedModDate { return false }
        do {
            let data = try Data(contentsOf: fileURL)
            projects = try JSONDecoder().decode(ConfigFile.self, from: data).projects
            loadedModDate = modDate
            hasLoaded = true
            error = nil
            return true
        } catch {
            // Keep the last good list through a momentary gap (e.g. mid-pull) and retry on the next call;
            // only report the problem when there's nothing good to fall back on.
            loadedModDate = nil
            guard !hasLoaded else { return false }
            self.error = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
            return true
        }
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    var baseURL: URL { fileURL.deletingLastPathComponent() }

    func iconURL(for project: Project) -> URL? {
        project.icon.map { Self.resolve($0, against: baseURL) }
    }

    /// Icon paths are relative to the folder holding projects.json unless absolute.
    static func resolve(_ path: String, against base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
    }
}

extension Notification.Name {
    /// Posted after the editor points Project Launcher at a different config folder.
    static let configFolderDidChange = Notification.Name("ProjectLauncherConfigFolderDidChange")
    /// Posted after a background pull changed projects.json, so an open editor can reload.
    static let configDidChangeOnDisk = Notification.Name("ProjectLauncherConfigDidChangeOnDisk")
}
