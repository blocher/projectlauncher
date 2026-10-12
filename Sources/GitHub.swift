import Foundation

/// git and GitHub CLI operations: keeping the config repo in sync and installing projects.
/// Launched from Finder the app has a bare PATH (and none of the shell's aliases), so tools are found explicitly.
/// Everything here blocks, so call it off the main thread.
enum GitHub {
    struct Failure: Error {
        let message: String
    }

    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    /// Network operations give up if they stall instead of hanging forever.
    private static let networkTimeout: TimeInterval = 120
    private static let localTimeout: TimeInterval = 20
    /// Only one git operation runs against the config repo at a time: the editor's pull, its save, and the
    /// background pull would otherwise race on the index and on each other's rebases.
    private static let configLock = NSLock()

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether `folder` is itself the root of a git checkout (a parent repo, like a dotfiles repo, doesn't count).
    static func isRepository(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// `owner/name` of a checkout's GitHub origin, if the folder is a repo with one.
    static func repoName(of folder: URL) -> String? {
        guard isRepository(folder), case .success(let url) = git(["remote", "get-url", "origin"], in: folder, timeout: localTimeout)
        else { return nil }
        return parseRepoName(url)
    }

    /// Accepts https and ssh forms, including ssh host aliases (`git@github-work:owner/name.git`) and a trailing `/`.
    static func parseRepoName(_ url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.contains("github") else { return nil }
        return url.firstMatch(of: #/[:/]([^/:\s]+/[^/\s]+?)(?:\.git)?/?$/#).map { String($0.1) }
    }

    // MARK: - Config sync

    /// Rebases the config onto the remote, keeping any local edits on top.
    static func pull(_ folder: URL) -> Result<Void, Failure> {
        guard isRepository(folder) else { return .success(()) }
        return configLock.withLock { pullLocked(folder) }
    }

    /// Commits the editor's files (projects.json and icons/) and pushes them, pulling first if the remote moved.
    static func commitAndPush(_ folder: URL, message: String) -> Result<Void, Failure> {
        guard isRepository(folder) else { return .success(()) }
        return configLock.withLock {
            let paths = ["projects.json", "icons"].filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            if case .failure(let failure) = git(["add", "-A", "--"] + paths, in: folder, timeout: localTimeout) {
                return .failure(failure)
            }
            if case .failure = git(["diff", "--cached", "--quiet"], in: folder, timeout: localTimeout) {
                if case .failure(let failure) = git(["commit", "--quiet", "-m", message], in: folder, timeout: localTimeout) {
                    return .failure(explain(failure))
                }
            }
            if case .success = git(["push", "--quiet"], in: folder, timeout: networkTimeout) { return .success(()) }
            if case .failure(let failure) = pullLocked(folder) { return .failure(failure) }
            return git(["push", "--quiet"], in: folder, timeout: networkTimeout).map { _ in () }.mapError(explain)
        }
    }

    private static func pullLocked(_ folder: URL) -> Result<Void, Failure> {
        let gitDir = folder.appendingPathComponent(".git")
        let rebaseInProgress = {
            ["rebase-merge", "rebase-apply"].contains {
                FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path)
            }
        }
        // A rebase left over from something else (e.g. the user in a terminal) is theirs to finish.
        if rebaseInProgress() {
            return .failure(Failure(message: "The config repo is in the middle of a rebase. Finish it in a terminal first."))
        }
        let result = git(["pull", "--rebase", "--autostash", "--quiet"], in: folder, timeout: networkTimeout)
        if case .failure(let failure) = result {
            // Leave the checkout usable rather than mid-rebase; this rebase is ours, since we hold the lock.
            if rebaseInProgress() { _ = git(["rebase", "--abort"], in: folder, timeout: localTimeout) }
            return .failure(explain(failure))
        }
        return .success(())
    }

    /// Turns common git failures into something actionable.
    private static func explain(_ failure: Failure) -> Failure {
        let message = failure.message
        if message.contains("Please tell me who you are") || message.contains("user.email") {
            return Failure(message: "git doesn't know who you are on this Mac. Run `git config --global user.name \"…\"` and `git config --global user.email …`.")
        }
        if message.contains("terminal prompts disabled") || message.contains("Authentication failed") || message.contains("could not read Username") {
            return Failure(message: "git couldn't sign in to GitHub. Run `gh auth setup-git` once so git uses the GitHub CLI's login.")
        }
        if message.contains("CONFLICT") || message.contains("could not apply") {
            return Failure(message: "Your config changed on another Mac in a way that conflicts with this one. Resolve it with git in the config folder.")
        }
        return failure
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
        return run(gh, ["repo", "clone", repo, destination.path], in: nil, timeout: 600).map { _ in () }
    }

    // MARK: - Running tools

    private static func git(_ arguments: [String], in folder: URL, timeout: TimeInterval) -> Result<String, Failure> {
        run("/usr/bin/git", ["-C", folder.path] + arguments, in: folder, timeout: timeout)
    }

    private static func run(_ tool: String, _ arguments: [String], in folder: URL?, timeout: TimeInterval) -> Result<String, Failure> {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"  // Fail instead of waiting on a password prompt nobody can see.
        environment["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"  // Abandon transfers stuck under 1 KB/s…
        environment["GIT_HTTP_LOW_SPEED_TIME"] = "30"  // …for 30 seconds.
        let output = Shell.run(tool, arguments, in: folder, environment: environment, timeout: timeout)
        if output.timedOut {
            return .failure(Failure(message: "\((tool as NSString).lastPathComponent) \(arguments.first ?? "") timed out."))
        }
        guard output.succeeded else {
            return .failure(Failure(message: output.stderr.isEmpty ? "\(tool) exited with \(output.status)" : output.stderr))
        }
        return .success(output.stdout)
    }
}
