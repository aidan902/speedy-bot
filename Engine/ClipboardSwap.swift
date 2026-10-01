// Borrow the clipboard for one paste: remember what is on it, put a picture there, and put the old
// contents back afterwards. Used when screenshots are saved as files, where the tech does not expect a
// screenshot to disturb what they copied.
import AppKit

public struct ClipboardSnapshot {
    fileprivate let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
}

@MainActor
public enum ClipboardSwap {
    /// Reading clipboard DATA raises a "paste from other apps" question on recent macOS unless the tech has set
    /// this app to Allow. Only an explicit Allow counts: the system's default is to ask, every time.
    public static var canReadSilently: Bool {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior == .alwaysAllow
        }
        return true
    }

    /// Everything on the clipboard, or nil when it cannot be read quietly or is too big to be worth holding.
    public static func snapshot(of pb: NSPasteboard = .general, limitBytes: Int = 64 << 20) -> ClipboardSnapshot? {
        guard canReadSilently else { return nil }
        var total = 0
        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var flavours: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > limitBytes { return nil }
                flavours.append((type, data))
            }
            items.append(flavours)
        }
        return ClipboardSnapshot(items: items)
    }

    /// Puts one picture on the clipboard, shaped like a screenshot. Returns the clipboard's change count afterwards.
    public static func putImage(_ data: Data, fileExtension: String, on pb: NSPasteboard = .general) -> Int {
        let type: NSPasteboard.PasteboardType
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": type = NSPasteboard.PasteboardType("public.jpeg")
        case "heic": type = NSPasteboard.PasteboardType("public.heic")
        case "tif", "tiff": type = .tiff
        case "gif": type = NSPasteboard.PasteboardType("com.compuserve.gif")
        case "pdf": type = .pdf
        default: type = .png
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        pb.writeObjects([item])
        return pb.changeCount
    }

    public static func restore(_ snapshot: ClipboardSnapshot, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.compactMap { flavours in
            guard !flavours.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for f in flavours { item.setData(f.data, forType: f.type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
