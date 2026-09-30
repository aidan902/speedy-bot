import AppKit

/// An incident label as the tech types it ("12345", "inc 12,345", "#INC - 12,345") turned into one spelling.
enum Incident {
    static let placeholder = "#INC - 12,345"
    static let unfiledFolder = "No incident number"

    /// "#INC - 12,345" for anything that is just an incident number; other text is kept as a plain,
    /// file-system-safe label (a project or customer name). Empty when there is nothing usable.
    static func canonical(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var digits = trimmed.uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        digits = digits.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("INC") { digits.removeFirst(3) }
        digits.removeAll { " -,.#:".contains($0) }
        if !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits) {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US")
            return "#INC - " + (f.string(from: NSNumber(value: n)) ?? digits)
        }

        // Free text: drop what a folder name cannot hold.
        var label = String(trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        label = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while label.hasPrefix(".") { label.removeFirst() }
        return String(label.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}

/// Saved screenshots: <root>/<incident>/<incident> <date> at <time>.png
enum Documentation {
    static let folderName = "SpeedyBot Documentation"

    static var defaultRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent(folderName, isDirectory: true)
    }

    static func folder(root: URL, incident: String) -> URL {
        root.appendingPathComponent(incident.isEmpty ? Incident.unfiledFolder : incident, isDirectory: true)
    }

    /// The picture a screenshot left on the clipboard. This reads pasteboard DATA, which is the one place
    /// macOS may ask the tech to allow Speedy Bot to read the clipboard.
    @MainActor
    static func screenshotOnClipboard(_ pb: NSPasteboard = .general) -> (data: Data, ext: String)? {
        guard PasteboardWatcher.looksLikeScreenshot(pb), let item = pb.pasteboardItems?.first, let type = item.types.first,
              let data = item.data(forType: type), !data.isEmpty else { return nil }
        let ext: String
        switch type.rawValue {
        case "public.jpeg": ext = "jpg"
        case "public.heic": ext = "heic"
        default: ext = "png"
        }
        return (data, ext)
    }

    /// Writes the picture and returns where it went. Never overwrites: a second shot in the same second gets " 2".
    static func save(_ data: Data, ext: String, root: URL, incident: String, at date: Date = Date()) throws -> URL {
        let dir = folder(root: root, incident: incident)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = (incident.isEmpty ? "Screenshot" : incident) + " " + stamp.string(from: date)
        var url = dir.appendingPathComponent(base + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// The small "which incident is this for?" question.
@MainActor
enum IncidentPrompt {
    /// Returns the new incident label ("" = none), or nil when cancelled.
    static func ask(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Incident number"
        alert.informativeText = "Screenshots are saved in a folder with this number under SpeedyBot Documentation."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = Incident.placeholder
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Incident.canonical(field.stringValue)
    }
}
