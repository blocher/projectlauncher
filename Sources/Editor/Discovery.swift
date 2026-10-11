import AppKit
import ImageIO

/// What a launcher app reveals about the project it starts.
struct LauncherDetection: Equatable {
    var suggestedName: String?
    var variable: String?
    var equals: String?
    /// Pane roles (or, for window-tagged launchers, pane names) in the order the launcher defines them.
    var roles: [String] = []
    var url: String?

    var summary: String {
        guard let variable else { return "Couldn't find an iTerm variable in this launcher." }
        if let equals {
            let panes = roles.isEmpty ? "" : " Panes: \(roles.joined(separator: ", "))."
            return "Matches windows where \(variable) = \"\(equals)\".\(panes)"
        }
        return "Found \(variable) on panes \(roles.joined(separator: ", "))."
    }
}

enum LauncherInspector {
    /// Reads the launcher's script: an AppleScript applet's main.scpt, or an Automator app's shell step
    /// (following it into a Python iTerm2-API script when it runs one).
    static func inspect(_ app: URL) -> LauncherDetection {
        var detection = LauncherDetection(suggestedName: suggestedName(for: app))
        let source = scriptSource(of: app)

        // AppleScript launchers: `set variable named "user.BIYSession" to "Backend"`.
        for match in source.matches(of: #/set variable named "([^"]+)" to "([^"]+)"/#) {
            let (variable, role) = (String(match.1), String(match.2))
            if detection.variable == nil { detection.variable = variable }
            if variable == detection.variable, !detection.roles.contains(role) { detection.roles.append(role) }
        }
        // iTerm2 Python API launchers may tag the window instead: `window.async_set_variable("user.name", "myapp")`.
        if detection.variable == nil,
           let match = source.firstMatch(of: #/window\.async_set_variable\("([^"]+)",\s*"([^"]+)"\)/#) {
            detection.variable = "tab.window.\(match.1)"
            detection.equals = String(match.2)
            // Its panes are told apart by the names it gives them: `set_session_title_and_color(session, "API", …)`.
            // Only count pane builders main() actually calls (`Commands.api(…)`), not ones it merely defines.
            let builders = source.matches(of: #/async def (\w+)\(session\):(?:(?!async def ).)*?set_session_title_and_color\(\s*session,\s*"([^"]+)"/#.dotMatchesNewlines())
            for match in builders where source.contains("Commands.\(match.1)(") {
                let name = String(match.2)
                if !detection.roles.contains(name) { detection.roles.append(name) }
            }
        }

        // Only local dev servers; launchers also mention download links and the like.
        detection.url = source.matches(of: #/https?://(localhost|127\.0\.0\.1|local\.)[^\s'"\\]*/#).first.map { String($0.0) }
        return detection
    }

    private static func suggestedName(for app: URL) -> String {
        var name = app.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Start") { name.removeFirst(5) }
        if name.hasSuffix("Dev") { name.removeLast(3) }
        // "ElizabethSermons" → "Elizabeth Sermons", leaving acronyms like "BIY" intact.
        return name.replacing(#/([a-z])([A-Z])/#) { "\($0.1) \($0.2)" }
    }

    private static func scriptSource(of app: URL) -> String {
        let contents = app.appendingPathComponent("Contents")
        let script = contents.appendingPathComponent("Resources/Scripts/main.scpt")
        if FileManager.default.fileExists(atPath: script.path) {
            return run("/usr/bin/osadecompile", [script.path])
        }
        let workflow = contents.appendingPathComponent("document.wflow")
        guard let data = try? Data(contentsOf: workflow),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = plist["actions"] as? [[String: Any]] else { return "" }
        var source = ""
        for action in actions {
            let parameters = (action["action"] as? [String: Any])?["ActionParameters"] as? [String: Any]
            for key in ["COMMAND_STRING", "source"] {
                guard let command = parameters?[key] as? String else { continue }
                source += command + "\n"
                for match in command.matches(of: #/[~/][^\s;&|]*\.py/#) {
                    let path = (String(match.0) as NSString).expandingTildeInPath
                    source += (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                }
            }
        }
        return source
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Finds likely logos inside a project folder.
enum IconFinder {
    private static let skippedFolders: Set<String> = [
        "node_modules", ".git", ".venv", "venv", "env", "dist", "build", "Pods", "DerivedData",
        "site-packages", "staticfiles", "static_root", "android", "coverage", ".next", "vendor",
    ]
    private static let extensions: Set<String> = ["png", "svg", "jpg", "jpeg", "icns", "webp"]

    static func candidates(in root: URL, limit: Int = 30) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsPackageDescendants]
        ) else { return [] }

        // Files named after the project ("myapp-logo-square.png") beat partner and vendor logos.
        let projectSlug = root.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }
        var scored: [(url: URL, score: Int)] = []
        var seen = Set<String>()
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 60_000 { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(name) || name.hasSuffix(".app") { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let lower = name.lowercased()
            guard lower.contains("logo") || lower.contains("icon") || lower.contains("favicon")
                    || lower.contains("apple-touch") || lower.contains("mark") else { continue }
            if lower == "icons.svg" || url.path.contains("/test") { continue }
            // Capacitor copies public/ into ios/; keep one of each.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard seen.insert("\(name)|\(size)").inserted else { continue }
            let bonus = projectSlug.count >= 3 && lower.contains(projectSlug) ? 45 : 0
            scored.append((url, score(url, name: lower) + bonus))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.url)
    }

    private static func score(_ url: URL, name: String) -> Int {
        var score = 0
        if name.contains("appicon") || name.contains("apple-touch") { score += 60 }
        if name.contains("logo") { score += 40 }
        if name.contains("1024") || name.contains("512") { score += 30 }
        if name.contains("favicon") { score += 20 }
        if url.pathExtension.lowercased() == "svg" { score += 25 }
        // Variants meant for dark backgrounds or banners make poor tiles.
        if name.contains("white") || name.contains("dark") || name.contains("light") { score -= 30 }
        if name.contains("horizontal") || name.contains("wordmark") || name.contains("banner") { score -= 25 }
        if url.pathComponents.contains(where: { $0.hasPrefix(".") || $0 == "prototypes" }) { score -= 40 }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 {
            score += min(width / 16, 64)
            if width < 64 { score -= 40 }
            if abs(Double(width) / Double(height) - 1) < 0.05 { score += 35 }
        }
        return score
    }
}

enum IconImage {
    /// Renders a logo as a 256px rounded-square tile, matching the rest of the picker.
    /// Square art fills the tile; anything else is fitted inside it on a transparent background.
    static func normalizedPNG(from source: NSImage) -> Data? {
        let side = 256
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: side, height: side)

        let tile = NSRect(x: 0, y: 0, width: side, height: side)
        let imageSize = source.size
        let isSquare = imageSize.height > 0 && abs(imageSize.width / imageSize.height - 1) < 0.05

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        if isSquare {
            NSBezierPath(roundedRect: tile, xRadius: CGFloat(side) * 0.2237, yRadius: CGFloat(side) * 0.2237).addClip()
            source.draw(in: tile)
        } else {
            let scale = min(tile.width / imageSize.width, tile.height / imageSize.height)
            let fitted = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            source.draw(in: NSRect(x: (tile.width - fitted.width) / 2, y: (tile.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
