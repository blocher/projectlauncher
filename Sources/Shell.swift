import Foundation

/// Runs command-line tools for the app. Every call blocks its (background) thread, so never call it on the main thread.
enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Runs `tool` to completion, killing it after `timeout` seconds. stdout and stderr are drained concurrently,
    /// so a chatty child can't deadlock on a full pipe.
    static func run(
        _ tool: String,
        _ arguments: [String],
        in folder: URL? = nil,
        environment: [String: String]? = nil,
        input: String? = nil,
        timeout: TimeInterval
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let folder { process.currentDirectoryURL = folder }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        var errorData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut.isSet
        )
    }

    /// Set by the watchdog thread, read by the caller.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
