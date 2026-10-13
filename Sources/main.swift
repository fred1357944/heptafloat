// HeptaFloat — today's Heptabase journal in a floating, editable card, summoned with a hotkey.
// The web editor (src/editor.js) does the editing; this host reads, saves, and searches through the
// `heptabase` CLI and provides the Raycast-style window behavior.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Heptabase CLI

enum Heptabase {
    static let cliPath: String? = ["/opt/homebrew/bin/heptabase", "/usr/local/bin/heptabase"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Writes and polls run one at a time so a poll never races a save.
    static let queue = DispatchQueue(label: "heptafloat.cli")
    /// Searches run alongside, so typing in the mention menu never waits behind a save.
    static let searchQueue = DispatchQueue(label: "heptafloat.search")

    struct Failure: Error { let message: String }

    static func run(_ args: [String]) throws -> [String: Any] {
        guard let cli = cliPath else { throw Failure(message: "Heptabase's CLI is off — turn it on in Heptabase → Settings → AI Features.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // Errors come back as JSON on stdout or stderr: {"error": "..."}
        let errObj = (try? JSONSerialization.jsonObject(with: errData)) as? [String: Any]
        if let e = obj?["error"] ?? errObj?["error"] { throw Failure(message: friendly("\(e)")) }
        guard p.terminationStatus == 0, let obj else {
            let msg = String(data: errData.isEmpty ? data : errData, encoding: .utf8) ?? ""
            throw Failure(message: friendly(msg))
        }
        return obj
    }

    /// Short, plain messages for the CLI's errors, which are written for developers.
    static func friendly(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if text.isEmpty || lower.contains("cannot connect") || lower.contains("not running") || lower.contains("econnrefused") {
            return "Can't reach Heptabase — open Heptabase to keep syncing."
        }
        if lower.contains("subscription") { return "Heptabase's CLI needs an active Heptabase subscription." }
        if lower.contains("enable cli") || lower.contains("register cli") || lower.contains("runtime was not found") {
            return "Heptabase's CLI is off — turn it on in Heptabase → Settings → AI Features."
        }
        if lower.contains("md5") || lower.contains("conflict") { return "Changed in Heptabase since the last save." }
        // Otherwise keep the first sentence.
        let first = text.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? text
        return first.count > 140 ? String(first.prefix(140)) + "…" : first
    }

    /// HeptaFloat edits two kinds of cards: journals (id is a date) and notes (id is a UUID).
    enum Kind: String { case journal, note }

    static func read(_ kind: Kind, _ id: String) throws -> [String: Any] {
        var r = try run([kind.rawValue, "read", id])
        r["kind"] = kind.rawValue
        r["id"] = id
        return r
    }

    static func readJournal(_ date: String) throws -> [String: Any] { try read(.journal, date) }

    /// Replaces the card's content, guarded by the md5 of the version the edit was based on.
    static func save(_ kind: Kind, _ id: String, content: String, md5: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heptafloat-\(UUID().uuidString).json")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try run([kind.rawValue, "save", id, "--content-md5", md5, "--content-file", file.path])
    }

    // MARK: files (images stored in Heptabase)

    /// Where exported Heptabase files are kept; a file ID's contents never change.
    static let fileCache: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ianhsiao.heptafloat/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cached(_ fileId: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: fileCache, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == fileId }
    }

    /// A Heptabase file's bytes and MIME type, exported once through the CLI and then cached.
    static func file(_ fileId: String) throws -> (data: Data, mimeType: String) {
        let url: URL
        if let hit = cached(fileId) {
            url = hit
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("heptafloat-export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let r = try run(["file", "export", fileId, "--output-dir", scratch.path])
            guard let path = r["path"] as? String else { throw Failure(message: "Heptabase didn't export the image.") }
            let ext = URL(fileURLWithPath: path).pathExtension
            url = fileCache.appendingPathComponent(fileId).appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: url)
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (try Data(contentsOf: url), mime)
    }

    /// Imports image bytes into the workspace (streamed, so large screenshots are fine) and caches
    /// them under the new file ID. Returns { fileId, name, mimeType, size, width, height }.
    static func importImage(_ data: Data, name: String) throws -> [String: Any] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("heptafloat-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent(name)
        try data.write(to: file)
        let r = try run(["file", "import", file.path])
        if let id = r["fileId"] as? String {
            try? data.write(to: fileCache.appendingPathComponent(id).appendingPathExtension(file.pathExtension))
        }
        return r
    }

    /// Creates a note you wrote (not marked "Created by AI") and fills it with the editor's content.
    /// Returns the note as read back from Heptabase.
    /// Links a card at the end of today's journal ({{card id}} is Heptabase's Markdown for a mention).
    static func linkInTodaysJournal(_ cardId: String) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        _ = try run(["journal", "append", formatter.string(from: Date()), "--content", "{{card \(cardId)}}"])
    }

    static func createNote(title: String, content: String) throws -> [String: Any] {
        let line = title.replacingOccurrences(of: "\n", with: " ")
        let created = try run(["note", "create", "--no-created-by-ai", "--content", "# \(line.isEmpty ? "Untitled" : line)"])
        guard let id = created["id"] as? String else { throw Failure(message: "Heptabase didn't create the note.") }
        let fresh = try read(.note, id)
        try save(.note, id, content: content, md5: fresh["contentMd5"] as? String ?? "")
        return try read(.note, id)
    }

    /// The card's type ("note", "journal", "pdfCard", …), to decide whether HeptaFloat can open it.
    static func cardType(_ id: String) throws -> [String: Any] {
        try run(["card", "properties", id])
    }

    /// Cards for the mention menu: recent ones for an empty query, otherwise matches with title hits first.
    static func searchCards(_ query: String) throws -> [[String: Any]] {
        var args = ["card", "list", "--limit", "20", "--card-types", "note,journal,pdf,highlightElement,image,video,audio"]
        if !query.isEmpty { args += ["-q", query] }
        let results = (try run(args)["results"] as? [[String: Any]]) ?? []
        let q = query.lowercased()
        let ranked = q.isEmpty ? results : results.enumerated().sorted { a, b in
            let ta = (a.element["title"] as? String ?? "").lowercased().contains(q)
            let tb = (b.element["title"] as? String ?? "").lowercased().contains(q)
            return ta != tb ? ta : a.offset < b.offset
        }.map(\.element)
        return Array(ranked.prefix(8))
    }

    private static var titleCache: [String: String] = [:]

    /// Titles of cards mentioned in a document, for mention chips. Call on `queue`.
    static func mentionTitles(in docJSON: String) -> [String: String] {
        guard let data = docJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var ids = Set<String>()
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let attrs = d["attrs"] as? [String: Any] {
                    for key in ["cardId", "pdfCardId", "objectId", "highlightElementId"] {
                        if let id = attrs[key] as? String, id.count == 36 { ids.insert(id) }
                    }
                }
                d.values.forEach(walk)
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }
        walk(root)
        var out: [String: String] = [:]
        for id in ids {
            if titleCache[id] == nil, let t = (try? run(["card", "properties", id]))?["title"] as? String {
                titleCache[id] = t
            }
            out[id] = titleCache[id]
        }
        return out
    }
}

// MARK: - Settings

enum Appearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Settings {
    static let defaults = UserDefaults.standard
    static var pinned: Bool {
        get { defaults.object(forKey: "pinned") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pinned") }
    }
    static var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }
    /// Off (default): no Dock icon or menu bar, like Raycast — opening HeptaFloat can never make
    /// macOS switch desktops or leave full screen. On: Dock icon and menus.
    /// When on, each ⌘N card is linked at the end of today's journal as it's created.
    static var addNewCardsToJournal: Bool {
        get { defaults.bool(forKey: "addNewCardsToJournal") }
        set { defaults.set(newValue, forKey: "addNewCardsToJournal") }
    }

    static var showInDock: Bool {
        get { defaults.object(forKey: "showInDock") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "showInDock") }
    }
    static func applyActivationPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    static var fontScale: Double {
        get { defaults.object(forKey: "fontScale") as? Double ?? 1.0 }
        set { defaults.set(min(max(newValue, 0.7), 1.8), forKey: "fontScale") }
    }
    static let defaultHotkey = "ctrl+opt+j"
    /// e.g. "ctrl+opt+j"; recorded in Settings.
    static var hotkey: String {
        get { defaults.string(forKey: "hotkey") ?? defaultHotkey }
        set { defaults.set(newValue, forKey: "hotkey") }
    }

    /// Posted when a setting changes outside the Settings window (menus, the pin button).
    static let changed = Notification.Name("HeptaFloatSettingsChanged")
}

// MARK: - Recent cards

/// Cards opened in HeptaFloat — our own history, kept on this Mac, separate from Heptabase's.
enum Recents {
    private static let key = "recentCards"
    private static let limit = 40

    static var all: [[String: Any]] {
        get { UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(limit)), forKey: key) }
    }

    /// Moves a card to the top (or refreshes its title and length), keeping its pin. With
    /// keepPlace, a card already in the list is updated where it is (⌘[ / ⌘] and saves).
    static func touch(_ card: [String: Any]) {
        guard let id = card["id"] as? String else { return }
        var list = all
        if card["keepPlace"] as? Bool == true, let i = list.firstIndex(where: { $0["id"] as? String == id }) {
            for key in ["title", "chars", "objectType"] { if let v = card[key] { list[i][key] = v } }
            all = list
            return
        }
        let old = list.first { $0["id"] as? String == id }
        list.removeAll { $0["id"] as? String == id }
        var entry = old ?? [:]
        for (k, v) in card where !["action", "requestId", "keepPlace"].contains(k) { entry[k] = v }
        entry["openedAt"] = ISO8601DateFormatter().string(from: Date())
        list.insert(entry, at: 0)
        all = list
    }

    static func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        all = all.map { var c = $0; if c["id"] as? String == id { change(&c) }; return c }
    }

    static func forget(_ id: String) { all = all.filter { $0["id"] as? String != id } }
}

// MARK: - Keyboard shortcuts

/// Every remappable shortcut. Global toggles the card from any app; app shortcuts live in the menus;
/// editor shortcuts are also menu items (Format) and are pushed to the editor's keymap.
struct ShortcutDef {
    enum Scope { case global, app, editor }
    let id: String
    let title: String
    let group: String
    let defaultSpec: String
    let scope: Scope

    static let all: [ShortcutDef] = [
        .init(id: "toggle", title: "Show / hide HeptaFloat", group: "Anywhere", defaultSpec: "ctrl+opt+j", scope: .global),
        .init(id: "newCard", title: "New card", group: "Cards", defaultSpec: "cmd+n", scope: .app),
        .init(id: "search", title: "Search cards", group: "Cards", defaultSpec: "cmd+o", scope: .app),
        .init(id: "recent", title: "Recent cards", group: "Cards", defaultSpec: "cmd+p", scope: .app),
        .init(id: "today", title: "Today's journal", group: "Cards", defaultSpec: "cmd+t", scope: .app),
        .init(id: "back", title: "Back", group: "Cards", defaultSpec: "cmd+[", scope: .app),
        .init(id: "forward", title: "Forward", group: "Cards", defaultSpec: "cmd+]", scope: .app),
        .init(id: "openInHeptabase", title: "Open in Heptabase", group: "Cards", defaultSpec: "cmd+shift+o", scope: .app),
        .init(id: "settings", title: "Settings", group: "Window", defaultSpec: "cmd+,", scope: .app),
        .init(id: "keepOnTop", title: "Keep on top", group: "Window", defaultSpec: "cmd+shift+p", scope: .app),
        .init(id: "biggerText", title: "Bigger text", group: "Window", defaultSpec: "cmd+=", scope: .app),
        .init(id: "smallerText", title: "Smaller text", group: "Window", defaultSpec: "cmd+-", scope: .app),
        .init(id: "actualSize", title: "Actual size", group: "Window", defaultSpec: "cmd+0", scope: .app),
        .init(id: "bold", title: "Bold", group: "Editing", defaultSpec: "cmd+b", scope: .editor),
        .init(id: "italic", title: "Italic", group: "Editing", defaultSpec: "cmd+i", scope: .editor),
        .init(id: "underline", title: "Underline", group: "Editing", defaultSpec: "cmd+u", scope: .editor),
        .init(id: "strike", title: "Strikethrough", group: "Editing", defaultSpec: "cmd+shift+x", scope: .editor),
        .init(id: "code", title: "Inline code", group: "Editing", defaultSpec: "cmd+e", scope: .editor),
        .init(id: "link", title: "Link", group: "Editing", defaultSpec: "cmd+k", scope: .editor),
        .init(id: "highlight", title: "Highlight", group: "Editing", defaultSpec: "cmd+shift+h", scope: .editor),
        .init(id: "toggleTodo", title: "Tick / untick to-do", group: "Editing", defaultSpec: "cmd+return", scope: .editor),
        .init(id: "paragraph", title: "Plain text", group: "Editing", defaultSpec: "cmd+opt+0", scope: .editor),
        .init(id: "heading1", title: "Heading 1", group: "Editing", defaultSpec: "cmd+opt+1", scope: .editor),
        .init(id: "heading2", title: "Heading 2", group: "Editing", defaultSpec: "cmd+opt+2", scope: .editor),
        .init(id: "heading3", title: "Heading 3", group: "Editing", defaultSpec: "cmd+opt+3", scope: .editor),
    ]
    static let groups = ["Anywhere", "Cards", "Window", "Editing"]

    /// Keys every Mac app shares; shown in Settings but not remappable.
    static let builtIn: [(String, String)] = [
        ("Undo / Redo", "⌘Z  ⌘⇧Z"), ("Cut / Copy / Paste", "⌘X  ⌘C  ⌘V"), ("Select all", "⌘A"),
        ("Hide card", "Esc  ⌘W  ⌘H"), ("Quit", "⌘Q"), ("Indent / outdent", "Tab  ⇧Tab"),
        ("Block menu", "/"), ("Mention a card", "@  [["), ("In menus and pickers", "↑ ↓  ↵  Esc"),
        ("Markdown", "-  1.  []  +  >  #  ```  ---"),
    ]
    static let reserved = ["cmd+z", "cmd+shift+z", "cmd+x", "cmd+c", "cmd+v", "cmd+a", "cmd+w", "cmd+h", "cmd+q"]

    static func spec(_ id: String) -> String {
        if id == "toggle" { return Settings.hotkey }
        return (UserDefaults.standard.dictionary(forKey: "shortcuts") as? [String: String])?[id]
            ?? all.first { $0.id == id }?.defaultSpec ?? ""
    }

    static func set(_ id: String, _ spec: String) {
        if id == "toggle" { Settings.hotkey = spec; return }
        var map = UserDefaults.standard.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
        map[id] = spec == all.first(where: { $0.id == id })?.defaultSpec ? nil : spec
        UserDefaults.standard.set(map, forKey: "shortcuts")
    }

    /// Menu key equivalent for a spec like "cmd+shift+o".
    static func menuKey(_ spec: String) -> (key: String, mods: NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = [], key = ""
        for part in spec.split(separator: "+").map(String.init) {
            switch part {
            case "cmd": mods.insert(.command)
            case "ctrl": mods.insert(.control)
            case "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "return": key = "\r"
            case "space": key = " "
            default: key = part
            }
        }
        return (key, mods)
    }

    /// The editor's keymap name for a spec, e.g. "Mod-Shift-o".
    static func editorKey(_ spec: String) -> String {
        spec.split(separator: "+").map { part -> String in
            switch part {
            case "cmd": return "Mod"
            case "ctrl": return "Ctrl"
            case "opt": return "Alt"
            case "shift": return "Shift"
            case "return": return "Enter"
            case "space": return "Space"
            default: return String(part)
            }
        }.joined(separator: "-")
    }
}

// MARK: - Global hotkey

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
final class HotKey {
    let display: String
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash,
    ]

    /// Parses "ctrl+opt+j" into a Carbon key code, modifier mask, and "⌃⌥J".
    static func parse(_ spec: String) -> (key: Int, mods: Int, display: String)? {
        var mods = 0, key: Int?, symbols = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": mods |= controlKey; symbols += "⌃"
            case "opt", "option", "alt": mods |= optionKey; symbols += "⌥"
            case "shift": mods |= shiftKey; symbols += "⇧"
            case "cmd", "command": mods |= cmdKey; symbols += "⌘"
            default: key = keyCodes[part]; symbols += ["space": " Space", "return": "↩"][part] ?? part.uppercased()
            }
        }
        return key.map { ($0, mods, symbols) }
    }

    /// Turns a key press into a spec like "ctrl+opt+j". Needs ⌘, ⌃ or ⌥, so plain typing never
    /// becomes a global shortcut.
    static func spec(from event: NSEvent) -> String? {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = keyCodes.first(where: { $0.value == Int(event.keyCode) })?.key else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    init?(_ spec: String, action: @escaping () -> Void) {
        guard let (key, mods, display) = Self.parse(spec) else { return nil }
        self.action = action
        self.display = display

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &type, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4846_4C54), id: 1) // "HFLT"
        guard RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Images

/// Serves `hf-file://<fileId>` to the editor: images pasted in Heptabase live there as files, not URLs.
final class HeptabaseFileScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "hf-file"
    private let queue = DispatchQueue(label: "heptafloat.files", attributes: .concurrent)
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, UUID(uuidString: id) != nil else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let key = ObjectIdentifier(task)
        queue.async {
            let result = Result { try Heptabase.file(id) }
            DispatchQueue.main.async {
                guard self.stopped.remove(key) == nil else { return }
                switch result {
                case .success(let file):
                    task.didReceive(URLResponse(url: url, mimeType: file.mimeType, expectedContentLength: file.data.count, textEncodingName: nil))
                    task.didReceive(file.data)
                    task.didFinish()
                case .failure(let error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

// MARK: - Window

/// Web view whose top strip drags the window, so the card can sit anywhere.
final class DragWebView: WKWebView {
    static let dragStripHeight: CGFloat = 36
    static let buttonsWidth: CGFloat = 100

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        if fromTop < Self.dragStripHeight && p.x < bounds.width - Self.buttonsWidth {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// A non-activating panel (like Raycast's or Spotlight's): it takes typing without making
/// HeptaFloat the active app, so it can float over any space, including other apps' full screen.
final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// HeptaFloat's menus usually aren't on screen (no menu bar, or another app owns it), so the
    /// card offers every key equivalent to them itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class JournalWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let panel: FloatPanel
    let web: DragWebView

    override init() {
        panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
                           styleMask: [.titled, .resizable, .fullSizeContentView, .closable, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(HeptabaseFileScheme(), forURLScheme: HeptabaseFileScheme.scheme) // the configuration keeps it
        web = DragWebView(frame: .zero, configuration: config)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 260, height: 180)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        config.userContentController.add(self, name: "hf")
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self

        // Translucent backdrop like Raycast; the page paints Heptabase's card color over it.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.roundedMask(radius: 12)
        panel.contentView = backdrop
        web.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            web.topAnchor.constraint(equalTo: backdrop.topAnchor),
            web.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        if !panel.setFrameUsingName("HeptaFloat") { panel.center() }
        panel.setFrameAutosaveName("HeptaFloat")
        applyPinned()
        applyAppearance()

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: show / hide

    var isShown: Bool { panel.isVisible && panel.isKeyWindow && !NSApp.isHidden }

    /// The app that was in front before the card appeared, to hand focus back to on hide.
    private var previousApp: NSRunningApplication?

    /// Shows the card on the current space — over full-screen apps too — without activating
    /// HeptaFloat, so the app you're in stays in front and keeps its full screen.
    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(web)
        web.evaluateJavaScript("window.hf && window.hf.shown()")
    }

    func flushSoon() { web.evaluateJavaScript("window.hf && window.hf.flush()") }

    /// Hides the card. If HeptaFloat had become the active app (Dock, ⌘-Tab), hand focus back
    /// to the app you were in; otherwise that app never lost it.
    func hide() {
        flushSoon()
        panel.orderOut(nil)
        if NSApp.isActive { returnFocus() }
    }

    /// Steps aside for the app that was in front before the card appeared.
    func returnFocus() {
        NSApp.hide(nil)
        if let previousApp, !previousApp.isTerminated { previousApp.activate() }
    }

    func toggle() { isShown ? hide() : show() }

    // MARK: settings

    func togglePinned() {
        Settings.pinned.toggle()
        applyPinned()
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }

    /// The card always floats — a normal-level window can't layer over another app's full
    /// screen, so macOS would switch desktops instead. Pinned only decides whether it stays
    /// open when you click into another app (see windowDidResignKey).
    func applyPinned() {
        panel.level = .floating
        panel.hidesOnDeactivate = false // the card rarely makes HeptaFloat active, so this would hide it at once
        web.evaluateJavaScript("window.hf && window.hf.setPinned(\(Settings.pinned))")
    }

    func applyAppearance() {
        panel.appearance = Settings.appearance.nsAppearance
    }

    func adjustFont(by delta: Double?) {
        Settings.fontScale = delta.map { Settings.fontScale + $0 } ?? 1.0
        applyFontScale()
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }

    func applyFontScale() {
        web.evaluateJavaScript("window.hf.setScale(\(Settings.fontScale))")
    }

    func undo() { web.evaluateJavaScript("window.hf.undo()") }
    func redo() { web.evaluateJavaScript("window.hf.redo()") }

    func openInHeptabase() { command("openInHeptabase") }

    /// Waits for any pending save, so the last keystrokes reach Heptabase.
    func flush(then done: @escaping () -> Void) {
        var called = false
        let once = { if !called { called = true; done() } }
        web.callAsyncJavaScript("return await window.hf.flush()", arguments: [:], in: nil, in: .page) { _ in once() }
        // Don't hang forever if the page is wedged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: once)
    }

    // MARK: bridge

    private func reply(_ requestId: Any, _ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web.evaluateJavaScript("window.hf.reply(\(requestId), \(json))") }
    }

    private func pushTitles(for content: String) {
        Heptabase.queue.async {
            let titles = Heptabase.mentionTitles(in: content)
            guard !titles.isEmpty, let data = try? JSONSerialization.data(withJSONObject: titles),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.web.evaluateJavaScript("window.hf.titles(\(json))") }
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? Heptabase.Failure)?.message ?? "\(error)"
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let requestId = body["requestId"] ?? 0
        switch action {
        case "read":
            guard let kind = Heptabase.Kind(rawValue: body["kind"] as? String ?? ""), let id = body["id"] as? String else { return }
            Heptabase.queue.async {
                do {
                    let r = try Heptabase.read(kind, id)
                    self.reply(requestId, r)
                    if let content = r["content"] as? String { self.pushTitles(for: content) }
                } catch {
                    self.reply(requestId, ["error": Self.message(error)])
                }
            }
        case "save":
            guard let kind = Heptabase.Kind(rawValue: body["kind"] as? String ?? ""), let id = body["id"] as? String,
                  let content = body["content"] as? String, let md5 = body["md5"] as? String else { return }
            Heptabase.queue.async {
                var result: [String: Any] = [:]
                do {
                    try Heptabase.save(kind, id, content: content, md5: md5)
                } catch {
                    result["error"] = Self.message(error)
                }
                // Hand back what Heptabase now has: its md5 and the ids it assigned to new blocks.
                result["current"] = try? Heptabase.read(kind, id)
                self.reply(requestId, result)
            }
        case "importImage":
            guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pasted image.png"
            Heptabase.searchQueue.async {
                do { self.reply(requestId, try Heptabase.importImage(data, name: name)) }
                catch { self.reply(requestId, ["error": Self.message(error)]) }
            }
        case "createNote":
            guard let content = body["content"] as? String else { return }
            let title = body["title"] as? String ?? ""
            Heptabase.queue.async {
                do {
                    let note = try Heptabase.createNote(title: title, content: content)
                    var result: [String: Any] = ["current": note]
                    if Settings.addNewCardsToJournal, let id = note["id"] as? String {
                        // The card exists either way; a failed link only shows a note in the footer.
                        do { try Heptabase.linkInTodaysJournal(id); result["linkedInJournal"] = true }
                        catch { result["journalError"] = Self.message(error) }
                    }
                    self.reply(requestId, result)
                }
                catch { self.reply(requestId, ["error": Self.message(error)]) }
            }
        case "setupStatus":
            Heptabase.searchQueue.async { self.reply(requestId, Heptabase.setupStatus()) }
        case "openHeptabase":
            if let url = Heptabase.appURL { NSWorkspace.shared.open(url) }
        case "cardType":
            guard let id = body["id"] as? String else { return }
            Heptabase.searchQueue.async {
                do { self.reply(requestId, try Heptabase.cardType(id)) } catch { self.reply(requestId, ["error": Self.message(error)]) }
            }
        case "recents":
            reply(requestId, ["cards": Recents.all])
        case "touchRecent":
            Recents.touch(body)
        case "pinCard":
            if let id = body["id"] as? String { Recents.update(id) { $0["pinned"] = body["pinned"] as? Bool ?? false } }
            reply(requestId, [:])
        case "forgetCard":
            if let id = body["id"] as? String { Recents.forget(id) }
            reply(requestId, [:])
        case "search":
            let query = body["query"] as? String ?? ""
            Heptabase.searchQueue.async {
                let results = (try? Heptabase.searchCards(query)) ?? []
                self.reply(requestId, ["results": results])
            }
        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "hide":
            hide()
        case "settings":
            (NSApp.delegate as? AppDelegate)?.showSettings()
        case "togglePin":
            togglePinned()
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("window.hf.setScale(\(Settings.fontScale)); window.hf.setPinned(\(Settings.pinned))")
        pushShortcuts()
    }

    /// Sends the editor its keymap: { bold: "Mod-b", … }.
    func pushShortcuts() {
        let map = Dictionary(uniqueKeysWithValues: ShortcutDef.all.filter { $0.scope != .global }.map { ($0.id, ShortcutDef.editorKey(ShortcutDef.spec($0.id))) })
        guard let data = try? JSONSerialization.data(withJSONObject: map), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.hf && window.hf.setShortcuts(\(json))")
    }

    /// Runs an editor or card command by name ("bold", "search", "today", …).
    func command(_ name: String) {
        web.evaluateJavaScript("window.hf && window.hf.command('\(name)')")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// Unpinned, the card tucks away once you click into another app.
    func windowDidResignKey(_ notification: Notification) {
        guard !Settings.pinned else { return }
        DispatchQueue.main.async {
            if NSApp.keyWindow == nil && self.panel.isVisible { self.flushSoon(); self.panel.orderOut(nil) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

// MARK: - Heptabase connection check

/// What the Settings window shows about Heptabase: is it installed, running, and letting us in.
struct ConnectionStatus {
    enum Level { case checking, ok, problem }
    var level: Level
    var title: String
    var detail: String

    static let checking = ConnectionStatus(level: .checking, title: "Checking…", detail: "")
}

extension Heptabase {
    static let appBundleID = "app.projectmeta.projectmeta"

    static var isAppRunning: Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty { return true }
        return NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Heptabase" }
    }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
            ?? ["/Applications/Heptabase.app", NSHomeDirectory() + "/Applications/Heptabase.app"]
                .map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Which setup step stands between the user and a working card, for the card's setup checklist
    /// (steps from https://support.heptabase.com/en/articles/14715462-heptabase-cli).
    static func setupStatus() -> [String: Any] {
        guard let app = appURL else { return ["step": "install"] }
        if let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String,
           version.compare("1.91.0", options: .numeric) == .orderedAscending {
            return ["step": "update", "version": version]
        }
        guard isAppRunning else { return ["step": "open"] }
        guard cliPath != nil else { return ["step": "enableCLI"] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            _ = try readJournal(formatter.string(from: Date()))
            return ["step": "ready"]
        } catch {
            let message = (error as? Failure)?.message ?? "\(error)"
            if message.contains("subscription") { return ["step": "subscription"] }
            // Heptabase is running but its CLI server isn't answering: the CLI switch is off.
            if message.contains("CLI is off") || message.contains("Can't reach Heptabase") { return ["step": "enableCLI"] }
            return ["step": "other", "message": message]
        }
    }

    /// Tries a real read of today's journal, so a passing check means saving will work too.
    static func checkConnection() -> ConnectionStatus {
        guard appURL != nil else {
            return ConnectionStatus(level: .problem, title: "Heptabase isn't installed",
                                    detail: "Install the Heptabase desktop app from heptabase.com.")
        }
        guard cliPath != nil else {
            return ConnectionStatus(level: .problem, title: "Heptabase CLI is off",
                                    detail: "In Heptabase, open Settings → AI Features and turn on the CLI, then check again.")
        }
        guard isAppRunning else {
            return ConnectionStatus(level: .problem, title: "Heptabase isn't running",
                                    detail: "Open Heptabase — HeptaFloat saves through it.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            let journal = try readJournal(formatter.string(from: Date()))
            let title = journal["title"] as? String ?? "today's journal"
            return ConnectionStatus(level: .ok, title: "Connected", detail: "Reading and saving \(title).")
        } catch {
            let message = (error as? Failure)?.message ?? "\(error)"
            return ConnectionStatus(level: .problem, title: "Heptabase didn't respond", detail: message)
        }
    }
}

// MARK: - Settings window

final class SettingsModel: ObservableObject {
    @Published var appearance = Settings.appearance
    @Published var pinned = Settings.pinned
    @Published var fontScale = Settings.fontScale
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showInDock = Settings.showInDock
    @Published var addNewCardsToJournal = Settings.addNewCardsToJournal
    @Published var loginProblem: String?
    @Published var connection = ConnectionStatus.checking
    @Published var shortcuts: [String: String] = [:]
    @Published var shortcutProblems: [String: String] = [:]

    /// Hooks into the running app, set by AppDelegate.
    var applyShortcuts: () -> Bool = { true }  // false if the global hotkey couldn't register
    var pauseHotkey: () -> Void = {}
    var applyAppearance: () -> Void = {}
    var applyPinned: () -> Void = {}
    var applyFontScale: () -> Void = {}

    init() {
        reload()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        appearance = Settings.appearance
        pinned = Settings.pinned
        fontScale = Settings.fontScale
        launchAtLogin = SMAppService.mainApp.status == .enabled
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutDef.all.map { ($0.id, ShortcutDef.spec($0.id)) })
    }

    /// Assigns keys to a shortcut, refusing ones that are taken.
    func setShortcut(_ id: String, _ spec: String) {
        shortcutProblems[id] = nil
        if let other = ShortcutDef.all.first(where: { $0.id != id && shortcuts[$0.id] == spec }) {
            shortcutProblems[id] = "Already used by “\(other.title)”."
            return
        }
        if ShortcutDef.reserved.contains(spec) {
            shortcutProblems[id] = "That's a standard Mac shortcut. Pick another one."
            return
        }
        let previous = ShortcutDef.spec(id)
        ShortcutDef.set(id, spec)
        if applyShortcuts() {
            shortcuts[id] = spec
        } else {
            ShortcutDef.set(id, previous)
            _ = applyShortcuts()
            shortcutProblems[id] = "macOS didn't accept that shortcut. Try another one."
        }
    }

    func resetAllShortcuts() {
        UserDefaults.standard.removeObject(forKey: "shortcuts")
        Settings.hotkey = Settings.defaultHotkey
        shortcutProblems = [:]
        _ = applyShortcuts()
        reload()
    }

    func setAppearance(_ a: Appearance) { Settings.appearance = a; appearance = a; applyAppearance() }
    func setPinned(_ on: Bool) { Settings.pinned = on; pinned = on; applyPinned() }
    func setFontScale(_ v: Double) { Settings.fontScale = v; fontScale = Settings.fontScale; applyFontScale() }
    func setAddNewCardsToJournal(_ on: Bool) { Settings.addNewCardsToJournal = on; addNewCardsToJournal = on }

    func setShowInDock(_ on: Bool) {
        Settings.showInDock = on
        showInDock = on
        Settings.applyActivationPolicy()
        if !on { NSApp.activate(ignoringOtherApps: true) } // keep Settings in front after the switch
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            loginProblem = "Allow HeptaFloat in System Settings → General → Login Items."
        }
    }

    func checkConnection() {
        connection = .checking
        Heptabase.queue.async {
            let status = Heptabase.checkConnection()
            DispatchQueue.main.async { self.connection = status }
        }
    }
}

/// Click, then press the keys you want. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var model: SettingsModel
    let def: ShortcutDef
    @State private var recording = false
    @State private var monitor: Any?

    private var spec: String { model.shortcuts[def.id] ?? def.defaultSpec }

    var body: some View {
        HStack(spacing: 6) {
            if spec != def.defaultSpec && !recording {
                Button("Reset") { model.setShortcut(def.id, def.defaultSpec) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press keys…" : (HotKey.parse(spec)?.display ?? "None"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 84)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        model.pauseHotkey() // so pressing the current shortcut doesn't toggle the card
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let spec = HotKey.spec(from: event) {
                recording = false
                removeMonitor()
                model.setShortcut(def.id, spec)
                _ = model.applyShortcuts()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        removeMonitor()
        _ = model.applyShortcuts()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let def: ShortcutDef

    var body: some View {
        LabeledContent(def.title) { ShortcutRecorder(model: model, def: def) }
        if let problem = model.shortcutProblems[def.id] {
            Text(problem).font(.callout).foregroundStyle(.red)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ShortcutRow(model: model, def: ShortcutDef.all[0])
                Toggle("Keep on top of other windows", isOn: Binding(get: { model.pinned }, set: model.setPinned))
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Add new cards to today's journal", isOn: Binding(get: { model.addNewCardsToJournal }, set: model.setAddNewCardsToJournal))
                    Text("Each card you start with ⌘N gets a link at the end of that day's journal.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show in Dock and menu bar", isOn: Binding(get: { model.showInDock }, set: model.setShowInDock))
                    Text(model.showInDock
                         ? "Opening HeptaFloat from a launcher may switch desktops or leave full screen."
                         : "HeptaFloat stays out of the way, like Raycast: it pops up on whatever screen you're on and never switches desktops.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let problem = model.loginProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("General")
            } footer: {
                Text("With “Keep on top” off, the card tucks away when you switch to another app.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.appearance }, set: model.setAppearance)) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.fontScale }, set: model.setFontScale), in: 0.7...1.8, step: 0.05)
                            .frame(width: 160)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Heptabase") {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        switch model.connection.level {
                        case .checking: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connection.title).fontWeight(.medium)
                        if !model.connection.detail.isEmpty {
                            Text(model.connection.detail).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Check Again", action: model.checkConnection)
                        .disabled(model.connection.level == .checking)
                }
                if model.connection.level == .problem, let url = Heptabase.appURL {
                    Button("Open Heptabase") { NSWorkspace.shared.open(url) }
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Button("Quit HeptaFloat") { NSApp.terminate(nil) }
                Link("HeptaFloat on GitHub", destination: URL(string: "https://github.com/madeyexz/heptafloat")!)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.checkConnection)
    }
}

struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            ForEach(ShortcutDef.groups, id: \.self) { group in
                Section(group) {
                    ForEach(ShortcutDef.all.filter { $0.group == group }, id: \.id) { def in
                        ShortcutRow(model: model, def: def)
                    }
                }
            }
            Section {
                ForEach(ShortcutDef.builtIn, id: \.0) { title, keys in
                    LabeledContent(title) { Text(keys).foregroundStyle(.secondary).font(.system(.body, design: .rounded)) }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("Click a shortcut, then press the new keys. Esc cancels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Shortcuts", role: .destructive, action: model.resetAllShortcuts)
            }
        }
        .formStyle(.grouped)
    }
}

/// Titles the settings window after the selected tab, as Mac settings windows do.
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        retitle()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        retitle()
    }

    /// AppKit resets the title while switching tabs, so set it once that settles.
    private func retitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabViewItems.indices.contains(self.selectedTabViewItemIndex) else { return }
            self.view.window?.title = self.tabViewItems[self.selectedTabViewItemIndex].label
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var journal: JournalWindow!
    private var hotKey: HotKey?
    private var flushed = false
    private let settings = SettingsModel()
    private var settingsWindow: NSWindow?
    private var pinItem: NSMenuItem?
    private var appearanceItems: [NSMenuItem] = []
    private var showItem: NSMenuItem?

    /// When our own global hotkey last fired, and whether that press showed the card.
    private var hotkeyPressedAt = Date.distantPast
    private var hotkeyShowed = false

    func applicationDidFinishLaunching(_ n: Notification) {
        journal = JournalWindow()
        settings.applyShortcuts = { [weak self] in self?.applyShortcuts() ?? false }
        settings.pauseHotkey = { [weak self] in self?.hotKey = nil }
        settings.applyAppearance = { [weak self] in self?.journal.applyAppearance(); self?.refreshMenu() }
        settings.applyPinned = { [weak self] in self?.journal.applyPinned(); self?.refreshMenu() }
        settings.applyFontScale = { [weak self] in self?.journal.applyFontScale() }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenu()
        }
        _ = applyShortcuts()
        journal.show()
    }

    /// Re-registers the global hotkey and rebuilds the menus and editor keymap from the current
    /// shortcuts. Returns false if the global hotkey couldn't be registered.
    @discardableResult
    private func applyShortcuts() -> Bool {
        hotKey = nil
        hotKey = HotKey(Settings.hotkey) { [weak self] in
            guard let self else { return }
            self.hotkeyPressedAt = Date()
            self.hotkeyShowed = !self.journal.isShown
            self.journal.toggle()
        }
        buildMainMenu()
        journal.pushShortcuts()
        return hotKey != nil
    }

    private var hotkeyJustFired: Bool { Date().timeIntervalSince(hotkeyPressedAt) < 0.6 }

    /// Dock clicks and launchers "reopen" the app. A launcher bound to the same keys as our hotkey
    /// sends one right after the hotkey has already toggled; ignore that echo, and give focus back
    /// if it re-activated a hidden card.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hotkeyJustFired {
            if !journal.panel.isVisible { journal.returnFocus() }
        } else if journal.isShown && Date().timeIntervalSince(activatedAt) > 0.5 {
            journal.hide() // the card was already up: a second launcher press hides it
        } else {
            journal.show()
        }
        return false
    }

    /// When HeptaFloat last became the active app (a launcher, the Dock, ⌘-Tab).
    private var activatedAt = Date.distantPast
    func applicationWillBecomeActive(_ notification: Notification) { activatedAt = Date() }

    /// Hidden by anything (⌘H, a launcher): save first. If a launcher bound to the same keys
    /// hid us right after our hotkey showed the card, undo that.
    func applicationDidHide(_ notification: Notification) {
        journal.flushSoon()
        if hotkeyJustFired && hotkeyShowed { DispatchQueue.main.async { self.journal.show() } }
    }

    /// ⌘-Tab into HeptaFloat while the card is hidden brings the card back.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !hotkeyJustFired, !journal.panel.isVisible, settingsWindow?.isVisible != true else { return }
        journal.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if flushed { return .terminateNow }
        journal.flush {
            self.flushed = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    // MARK: actions

    /// Standard Mac settings window: icon tabs in the toolbar, each tab its own grouped form.
    @objc func showSettings() {
        if settingsWindow == nil {
            func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
                let host = NSHostingController(rootView: view)
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                return item
            }
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab("General", "gearshape",
                                    GeneralSettings(model: settings).frame(width: 480).fixedSize(horizontal: false, vertical: true)))
            tabs.addTabViewItem(tab("Shortcuts", "keyboard",
                                    ShortcutSettings(model: settings).frame(width: 480, height: 600)))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.title = "General"
            window.isReleasedWhenClosed = false
            window.level = .floating // stay above the floating card
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary] // open where you are, never switch desktops
            window.center()
            settingsWindow = window
        }
        settings.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showJournal() { journal.show() }
    @objc func hideJournal() { journal.hide() }
    @objc func togglePinned() { journal.togglePinned() }
    @objc func biggerText() { journal.adjustFont(by: 0.1) }
    @objc func smallerText() { journal.adjustFont(by: -0.1) }
    @objc func resetText() { journal.adjustFont(by: nil) }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/madeyexz/heptafloat")!) }
    @objc func reportIssue() { NSWorkspace.shared.open(URL(string: "https://github.com/madeyexz/heptafloat/issues/new")!) }

    /// Card and editor commands run in the editor; the card comes forward first if needed.
    @objc func runCommand(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        if !journal.isShown { journal.show() }
        journal.command(name)
    }

    /// ⌘W closes Settings when it's in front, otherwise hides the card.
    @objc func closeWindow() {
        if let key = NSApp.keyWindow, key !== journal.panel { key.performClose(nil) } else { journal.hide() }
    }

    /// Undo/redo go to the editor's own history when the card is in front.
    @objc func undo(_ sender: Any?) {
        if NSApp.keyWindow === journal.panel { journal.undo() } else { NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: sender) }
    }
    @objc func redo(_ sender: Any?) {
        if NSApp.keyWindow === journal.panel { journal.redo() } else { NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: sender) }
    }

    @objc func setAppearance(_ item: NSMenuItem) {
        guard let a = item.representedObject as? String, let appearance = Appearance(rawValue: a) else { return }
        settings.setAppearance(appearance)
    }

    /// Editing commands only apply while the card is the key window (not in Settings).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(runCommand(_:)), item.tag == 1 { return NSApp.keyWindow === journal.panel }
        return true
    }

    // MARK: menus

    func refreshMenu() {
        pinItem?.state = Settings.pinned ? .on : .off
        for item in appearanceItems { item.state = item.representedObject as? String == Settings.appearance.rawValue ? .on : .off }
        showItem?.title = "Show Journal" + (hotKey.map { "  (\($0.display))" } ?? "")
    }

    private func buildMainMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
            main.addItem(item)
            return m
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target ?? self
            return item
        }
        /// A menu item whose keys come from the shortcut registry.
        func shortcut(_ m: NSMenu, _ id: String, _ title: String? = nil, action: Selector? = nil) -> NSMenuItem {
            let def = ShortcutDef.all.first { $0.id == id }!
            let (key, mods) = ShortcutDef.menuKey(ShortcutDef.spec(id))
            let item = add(m, title ?? def.title, action ?? #selector(runCommand(_:)), key, mods)
            item.representedObject = id
            item.tag = def.scope == .editor ? 1 : 0
            return item
        }

        _ = menu("HeptaFloat") { m in
            _ = add(m, "About HeptaFloat", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            m.addItem(.separator())
            _ = shortcut(m, "settings", "Settings…", action: #selector(showSettings))
            m.addItem(.separator())
            _ = add(m, "Hide HeptaFloat", #selector(hideJournal), "h")
            _ = add(m, "Quit HeptaFloat", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        _ = menu("File") { m in
            _ = shortcut(m, "newCard", "New Card")
            _ = shortcut(m, "search", "Search Cards…")
            _ = shortcut(m, "recent", "Recent Cards…")
            _ = shortcut(m, "today", "Today's Journal")
            _ = shortcut(m, "back", "Back")
            _ = shortcut(m, "forward", "Forward")
            m.addItem(.separator())
            _ = shortcut(m, "openInHeptabase")
            m.addItem(.separator())
            _ = add(m, "Close", #selector(closeWindow), "w")
        }
        _ = menu("Edit") { m in
            _ = add(m, "Undo", #selector(undo(_:)), "z")
            _ = add(m, "Redo", #selector(redo(_:)), "z", [.command, .shift])
            m.addItem(.separator())
            for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                         ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
                m.addItem(withTitle: title, action: action, keyEquivalent: key) // first responder
            }
        }
        _ = menu("Format") { m in
            for id in ["bold", "italic", "underline", "strike", "code", "link", "highlight"] { _ = shortcut(m, id) }
            m.addItem(.separator())
            for id in ["paragraph", "heading1", "heading2", "heading3", "toggleTodo"] { _ = shortcut(m, id) }
        }
        _ = menu("View") { m in
            pinItem = shortcut(m, "keepOnTop", "Keep on Top", action: #selector(togglePinned))
            let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            appearanceItems = Appearance.allCases.map { a in
                let item = add(sub, a.title, #selector(setAppearance(_:)))
                item.representedObject = a.rawValue
                return item
            }
            appearance.submenu = sub
            m.addItem(appearance)
            m.addItem(.separator())
            _ = shortcut(m, "biggerText", "Bigger Text", action: #selector(biggerText))
            _ = shortcut(m, "smallerText", "Smaller Text", action: #selector(smallerText))
            _ = shortcut(m, "actualSize", "Actual Size", action: #selector(resetText))
        }
        let window = menu("Window") { m in
            showItem = add(m, "Show Journal", #selector(showJournal))
            m.addItem(.separator())
        }
        NSApp.windowsMenu = window
        let help = menu("Help") { m in
            _ = add(m, "HeptaFloat on GitHub", #selector(openGitHub))
            _ = add(m, "Report a Problem…", #selector(reportIssue))
        }
        NSApp.helpMenu = help
        NSApp.mainMenu = main
        refreshMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
Settings.applyActivationPolicy()
app.delegate = delegate
app.run()
