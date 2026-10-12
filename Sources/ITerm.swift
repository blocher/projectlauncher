import AppKit

/// One iTerm session (pane), as reported by the status query.
struct Pane {
    let windowID: String
    /// Device name as `ps` prints it, e.g. "ttys016".
    let tty: String
    let name: String
    /// Requested variable → value ("" when unset).
    let values: [String: String]
    /// `user.launcherPane`, set by generated launchers on every pane ("" for older launchers).
    var role: String = ""
}

struct ScanResult {
    var panes: [Pane] = []
    /// Windows that belong to no project.
    var unclaimed: Set<String> = []
    /// Windows passed in `skip` that still exist.
    var skipped: Set<String> = []
}

struct ScriptError: Error {
    let message: String
    let code: Int?

    /// errAEEventNotPermitted: the user hasn't allowed us to control iTerm.
    var isNotAuthorized: Bool { code == -1743 }
}

enum ITerm {
    static let bundleID = "com.googlecode.iterm2"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Lists the panes of every iTerm window that belongs to a project.
    ///
    /// Each Apple event costs iTerm's main thread a few milliseconds, so instead of reading every variable on
    /// every pane, a window is identified once from its first pane: `known` maps window id → the variable that
    /// matched, and windows in `skip` were recently found to belong to no project. Unknown windows come back
    /// as `.unclaimed` and skipped ones as `.skipped`, so callers can keep their caches in step.
    /// Only call while iTerm is running; `tell application` would otherwise launch it.
    static func scan(variables: [String], known: [String: String], skip: Set<String>) -> Result<ScanResult, ScriptError> {
        let source = """
        on run argv
            set TB to character id 9
            set LF to character id 10
            set AppleScript's text item delimiters to LF
            set vars to text items of item 1 of argv
            set known to text items of item 2 of argv
            set skip to text items of item 3 of argv
            set out to ""
            tell application "iTerm"
                repeat with w in windows
                    set wid to (id of w) as text
                    if skip contains wid then
                        set out to out & "K" & TB & wid & LF
                    else
                        set projVar to ""
                        repeat with k in known
                            if (k as text) starts with (wid & "=") then set projVar to text ((length of wid) + 2) thru -1 of (k as text)
                        end repeat
                        if projVar is "" then
                            try
                                tell first session of first tab of w
                                    repeat with v in vars
                                        set val to variable named (v as text)
                                        if val is not missing value and val is not "" then
                                            set projVar to v as text
                                            exit repeat
                                        end if
                                    end repeat
                                end tell
                            end try
                        end if
                        if projVar is "" then
                            set out to out & "N" & TB & wid & LF
                        else
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    try
                                        tell s
                                            set val to variable named projVar
                                            if val is missing value then set val to ""
                                            set paneRole to variable named "user.launcherPane"
                                            if paneRole is missing value then set paneRole to ""
                                            set out to out & "S" & TB & wid & TB & projVar & TB & (tty as text) & TB & (name as text) & TB & val & TB & paneRole & LF
                                        end tell
                                    end try
                                end repeat
                            end repeat
                        end if
                    end if
                end repeat
            end tell
            return out
        end run
        """
        let args = [
            variables.joined(separator: "\n"),
            known.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"),
            skip.joined(separator: "\n"),
        ]
        return runAppleScript(source, arguments: args).map { output in
            var result = ScanResult()
            for line in output.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                switch (f.first, f.count) {
                case ("K", 2): result.skipped.insert(f[1])
                case ("N", 2): result.unclaimed.insert(f[1])
                case ("S", 7):
                    let tty = (f[3] as NSString).lastPathComponent
                    result.panes.append(Pane(windowID: f[1], tty: tty, name: f[4], values: [f[2]: f[5]], role: f[6]))
                default: continue
                }
            }
            return result
        }
    }

    static func focus(windowID: String) {
        guard let id = Int(windowID) else { return }
        runAppleScriptInBackground("""
        tell application "iTerm"
            select window id \(id)
            activate
        end tell
        """)
    }

    static func close(windowID: String, completion: @escaping () -> Void) {
        guard let id = Int(windowID) else { return }
        runAppleScriptInBackground("tell application \"iTerm\" to close window id \(id)", completion: completion)
    }

    private static func literal(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAppleScriptInBackground(_ source: String, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            if case .failure(let error) = runAppleScript(source) {
                NSLog("ProjectLauncher: AppleScript failed: \(error.message)")
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Runs AppleScript through osascript so it can execute off the main thread. Apple events to a busy iTerm can
    /// otherwise wait up to two minutes; status is polled every few seconds, so give up quickly instead.
    private static func runAppleScript(_ source: String, arguments: [String] = [], timeout: TimeInterval = 8) -> Result<String, ScriptError> {
        // "-" reads the script from stdin; the rest become the run handler's argv.
        let output = Shell.run("/usr/bin/osascript", ["-"] + arguments, input: source, timeout: timeout)
        if output.timedOut {
            return .failure(ScriptError(message: "iTerm didn't respond within \(Int(timeout)) seconds.", code: nil))
        }
        guard output.status == 0 else {
            // osascript ends its error text with the code, e.g. "… (-1743)".
            let code = output.stderr.range(of: #"\((-?\d+)\)$"#, options: .regularExpression)
                .flatMap { Int(output.stderr[$0].dropFirst().dropLast()) }
            return .failure(ScriptError(message: output.stderr, code: code))
        }
        return .success(output.stdout)
    }
}

enum Processes {
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login"]

    /// TTYs whose foreground job is something other than an idle shell — i.e. a pane that's running a server.
    static func busyTTYs() -> Set<String> {
        let output = Shell.run("/bin/ps", ["-A", "-o", "tty=,stat=,comm="], timeout: 5)
        guard output.succeeded else { return [] }

        var busy = Set<String>()
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " })
            guard fields.count == 3 else { continue }
            let (tty, stat) = (String(fields[0]), fields[1])
            // "+" marks the terminal's foreground process group.
            guard tty != "??", stat.contains("+") else { continue }
            var command = (String(fields[2]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if command.hasPrefix("-") { command.removeFirst() }
            if !shells.contains(command) { busy.insert(tty) }
        }
        return busy
    }
}
