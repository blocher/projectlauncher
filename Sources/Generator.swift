import Foundation

/// A launcher spec, as defined by generator/SPEC.md. Edited in the New Launcher window; the generator renders it.
struct GeneratorSpec: Codable, Equatable {
    struct Pane: Codable, Equatable, Identifiable {
        var id = UUID()
        var role: String
        var note: String?
        var dir: String?
        var port: Int?
        var freePort: Bool?
        var env: [String]?
        var setup: [String]?
        var waitFor: [String]?
        var enabledBy: String?
        var color: String?
        var message: Message?
        var command: String?

        private enum CodingKeys: String, CodingKey {
            case role, note, dir, port, freePort, env, setup, waitFor, enabledBy, color, message, command
        }
    }

    /// A line, or a list of lines.
    enum Message: Codable, Equatable {
        case line(String)
        case lines([String])

        var lines: [String] {
            switch self {
            case .line(let line): [line]
            case .lines(let lines): lines
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let line = try? container.decode(String.self) {
                self = .line(line)
            } else {
                self = .lines(try container.decode([String].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .line(let line): try container.encode(line)
            case .lines(let lines): try container.encode(lines)
            }
        }
    }

    /// `"cmd"` or `{"run": "cmd", "label": "…", "background": true}`.
    struct PreLaunchStep: Codable, Equatable {
        var run: String
        var label: String?
        var background: Bool?

        init(from decoder: Decoder) throws {
            if let run = try? decoder.singleValueContainer().decode(String.self) {
                self.run = run
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            run = try container.decode(String.self, forKey: .run)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            background = try container.decodeIfPresent(Bool.self, forKey: .background)
        }

        private enum CodingKeys: String, CodingKey {
            case run, label, background
        }
    }

    var spec = 1
    var id: String
    var name: String
    var description: String?
    var launcher: String?
    var url: String?
    var openWhenReady: String?
    var focus: String?
    var requires: [String]?
    var env: [String]?
    var setup: [String]?
    var preLaunch: [PreLaunchStep]?
    var panes: [Pane]

    /// The launcher's file name without extension, matching the generator's default.
    var launcherName: String {
        if let launcher, !launcher.isEmpty { return launcher }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return "Start" + words.joined() + "Dev"
    }

    var ports: [Int] { panes.compactMap(\.port) }

    /// The browser URL with each `{port:Role}` replaced by that pane's port.
    var resolvedURL: String? {
        guard var url else { return nil }
        for pane in panes {
            if let port = pane.port { url = url.replacingOccurrences(of: "{port:\(pane.role)}", with: "\(port)") }
        }
        return url
    }
}

/// A local-dev config edit proposed by the analysis, applied only if the user keeps it checked.
struct ConfigChange: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var find: String
    var replace: String
    var why: String

    private enum CodingKeys: String, CodingKey {
        case path, find, replace, why
    }
}

/// Runs the bundled generator (generator/launcher.py) with the system Python. Everything blocks; call off the main thread.
enum Generator {
    struct Draft: Decodable {
        var spec: GeneratorSpec
        var notes: [String]
        var configChanges: [ConfigChange]
    }

    struct Failure: Error {
        let message: String
    }

    static var scriptURL: URL? {
        // PROJECTLAUNCHER_GENERATOR points tests (and development runs) at a checkout's generator/launcher.py.
        if let override = ProcessInfo.processInfo.environment["PROJECTLAUNCHER_GENERATOR"] { return URL(fileURLWithPath: override) }
        return Bundle.main.url(forResource: "generator", withExtension: nil)?.appendingPathComponent("launcher.py")
    }

    /// Drafts a spec from the repo's files: fast, offline, no Claude.
    static func detect(_ repo: URL, taken: Set<Int>) -> Result<Draft, Failure> {
        decode(run(["detect", repo.path, "--taken", taken.map(String.init).joined(separator: ",")], timeout: 60))
    }

    /// Drafts a spec with Claude Code (`claude -p`, read-only tools). Takes a minute or two.
    static func analyze(_ repo: URL, taken: Set<Int>) -> Result<Draft, Failure> {
        decode(run(["analyze", repo.path, "--taken", taken.map(String.init).joined(separator: ",")], timeout: 660))
    }

    /// Reads the spec embedded in a generated launcher.
    static func extract(_ launcher: URL) -> Result<GeneratorSpec, Failure> {
        run(["extract", launcher.path], timeout: 30).flatMap { output in
            Result { try JSONDecoder().decode(GeneratorSpec.self, from: Data(output.utf8)) }
                .mapError { Failure(message: "Couldn't read the launcher's spec: \($0.localizedDescription)") }
        }
    }

    /// Writes `<repo>/<launcher>.applescript` and compiles the `.app`. Returns the two paths.
    static func render(_ spec: GeneratorSpec, into repo: URL) -> Result<[URL], Failure> {
        withTemporaryJSON(spec) { file in
            run(["render", file.path, "--repo", repo.path, "--json"], timeout: 120).flatMap { output in
                guard let paths = try? JSONDecoder().decode([String: String?].self, from: Data(output.utf8)) else {
                    return .failure(Failure(message: "Unexpected output from the generator: \(output)"))
                }
                return .success(paths.values.compactMap { $0 }.map(URL.init(fileURLWithPath:)))
            }
        }
    }

    static func validate(_ spec: GeneratorSpec) -> Result<Void, Failure> {
        withTemporaryJSON(spec) { run(["validate", $0.path], timeout: 30).map { _ in () } }
    }

    /// Applies config changes (each must match exactly once; nothing is written unless all do). Returns changed paths.
    static func apply(_ changes: [ConfigChange], to repo: URL) -> Result<[String], Failure> {
        guard !changes.isEmpty else { return .success([]) }
        return withTemporaryJSON(changes) { file in
            run(["apply", file.path, "--repo", repo.path], timeout: 30).map { $0.split(separator: "\n").map(String.init) }
        }
    }

    /// Rebuilds a generated launcher from its embedded spec.
    static func regenerate(_ launcher: URL) -> Result<Void, Failure> {
        run(["regenerate", launcher.path], timeout: 120).map { _ in () }
    }

    // MARK: - Running the generator

    private static func decode(_ result: Result<String, Failure>) -> Result<Draft, Failure> {
        result.flatMap { output in
            Result { try JSONDecoder().decode(Draft.self, from: Data(output.utf8)) }
                .mapError { Failure(message: "Couldn't read the generator's draft: \($0.localizedDescription)") }
        }
    }

    private static func withTemporaryJSON<T: Encodable, R>(_ value: T, _ body: (URL) -> Result<R, Failure>) -> Result<R, Failure> {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("projectlauncher-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try JSONEncoder().encode(value).write(to: file)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        return body(file)
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) -> Result<String, Failure> {
        guard let script = scriptURL else { return .failure(Failure(message: "The generator isn't bundled with this build.")) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
        let output = Shell.run("/usr/bin/python3", ["-I", script.path] + arguments, environment: environment, timeout: timeout)
        if output.timedOut { return .failure(Failure(message: "The generator timed out.")) }
        guard output.status == 0 else {
            let message = output.stderr.replacingOccurrences(of: "error: ", with: "")
            return .failure(Failure(message: message.isEmpty ? "The generator failed (\(output.status))." : message))
        }
        return .success(output.stdout)
    }
}

extension GitHub {
    /// Commits `paths` in a project repo and optionally pushes the current branch. For generated launchers.
    static func commit(_ paths: [String], in repo: URL, message: String, push: Bool) -> Result<String, Failure> {
        guard isRepository(repo) else { return .failure(Failure(message: "\(repo.path) isn't a git repository.")) }
        let git = { (arguments: [String], timeout: TimeInterval) -> Result<String, Failure> in
            let output = Shell.run("/usr/bin/git", ["-C", repo.path] + arguments, environment: gitEnvironment, timeout: timeout)
            if output.timedOut { return .failure(Failure(message: "git \(arguments.first ?? "") timed out.")) }
            return output.succeeded ? .success(output.stdout) : .failure(Failure(message: output.stderr))
        }
        if case .failure(let failure) = git(["add", "-A", "--"] + paths, 30) { return .failure(failure) }
        if case .failure = git(["diff", "--cached", "--quiet"], 30) {
            if case .failure(let failure) = git(["commit", "--quiet", "-m", message, "--"] + paths, 60) { return .failure(failure) }
        }
        guard push else { return .success("Committed.") }
        let hasUpstream = (try? git(["rev-parse", "--abbrev-ref", "@{u}"], 10).get()) != nil
        let pushArguments = hasUpstream ? ["push", "--quiet"] : ["push", "--quiet", "-u", "origin", "HEAD"]
        return git(pushArguments, 120).map { _ in "Committed and pushed." }
    }
}
