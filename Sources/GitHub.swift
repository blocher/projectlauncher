import Foundation

/// git and GitHub CLI operations: keeping the config repo in sync and installing projects.
/// Launched from Finder the app has a bare PATH (and none of the shell's aliases), so tools are found explicitly.
enum GitHub {
    struct Failure: Error {
        let message: String
    }

    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isRepository(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// `owner/name` of a checkout's GitHub origin, if it has one.
    static func repoName(of folder: URL) -> String? {
        guard case .success(let url) = git(["remote", "get-url", "origin"], in: folder) else { return nil }
        let pattern = #/github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?$/#
        return url.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: pattern).map { String($0.1) }
    }

    // MARK: - Config sync

    /// Fast-forwards the config to the remote, keeping any local edits on top.
    static func pull(_ folder: URL) -> Result<Void, Failure> {
        guard isRepository(folder) else { return .success(()) }
        if case .failure(let failure) = git(["pull", "--rebase", "--autostash", "--quiet"], in: folder) {
            // Leave the checkout usable rather than mid-rebase; the user can resolve it by hand.
            _ = git(["rebase", "--abort"], in: folder)
            return .failure(failure)
        }
        return .success(())
    }

    /// Commits everything in the config folder and pushes it, pulling first if the remote moved.
    static func commitAndPush(_ folder: URL, message: String) -> Result<Void, Failure> {
        guard isRepository(folder) else { return .success(()) }
        if case .failure(let failure) = git(["add", "-A"], in: folder) { return .failure(failure) }
        if case .failure = git(["diff", "--cached", "--quiet"], in: folder) {
            if case .failure(let failure) = git(["commit", "--quiet", "-m", message], in: folder) {
                return .failure(failure)
            }
        }
        if case .success = git(["push", "--quiet"], in: folder) { return .success(()) }
        if case .failure(let failure) = pull(folder) { return .failure(failure) }
        return git(["push", "--quiet"], in: folder).map { _ in () }
    }

    // MARK: - Cloning

    /// Clones `owner/name` into `destination`, creating parent folders as needed.
    static func clone(_ repo: String, to destination: URL) -> Result<Void, Failure> {
        guard let gh = ghPath else {
            return .failure(Failure(message: "GitHub CLI not found. Install it with `brew install gh`, then `gh auth login`."))
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        return run(gh, ["repo", "clone", repo, destination.path], in: nil).map { _ in () }
    }

    // MARK: - Running tools

    private static func git(_ arguments: [String], in folder: URL) -> Result<String, Failure> {
        run("/usr/bin/git", ["-C", folder.path] + arguments, in: folder)
    }

    private static func run(_ tool: String, _ arguments: [String], in folder: URL?) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"  // Fail instead of waiting on a password prompt nobody can see.
        process.environment = environment
        if let folder { process.currentDirectoryURL = folder }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(message: message.isEmpty ? "\(tool) exited with \(process.terminationStatus)" : message))
        }
        return .success(String(decoding: stdout, as: UTF8.self))
    }
}
