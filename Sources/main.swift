// HeptaFloat — today's Heptabase journal in a floating, editable card, summoned with a hotkey.
// The web editor (src/editor.js) does the editing; this host reads, saves, and searches through the
// `heptabase` CLI and provides the Raycast-style window behavior.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
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
        guard let cli = cliPath else { throw Failure(message: "heptabase CLI not found. Enable it in Heptabase → Settings.") }
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
        if let e = obj?["error"] { throw Failure(message: "\(e)") }
        guard p.terminationStatus == 0, let obj else {
            let msg = String(data: errData.isEmpty ? data : errData, encoding: .utf8) ?? ""
            throw Failure(message: msg.isEmpty ? "Heptabase isn't responding. Is the app running?" : msg)
        }
        return obj
    }

    static func readJournal(_ date: String) throws -> [String: Any] {
        try run(["journal", "read", date])
    }

    /// Replaces the journal's content, guarded by the md5 of the version the edit was based on.
    static func saveJournal(_ date: String, content: String, md5: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heptafloat-\(UUID().uuidString).json")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try run(["journal", "save", date, "--content-md5", md5, "--content-file", file.path])
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
    static var fontScale: Double {
        get { defaults.object(forKey: "fontScale") as? Double ?? 1.0 }
        set { defaults.set(min(max(newValue, 0.7), 1.8), forKey: "fontScale") }
    }
    /// e.g. "ctrl+opt+j". Chosen from the menu bar's Shortcut menu; any spec works via `defaults write`.
    static var hotkey: String {
        get { defaults.string(forKey: "hotkey") ?? "ctrl+opt+j" }
        set { defaults.set(newValue, forKey: "hotkey") }
    }
}

// MARK: - Global hotkey

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
final class HotKey {
    static let presets = ["ctrl+opt+j", "opt+n", "opt+space", "cmd+shift+j", "ctrl+opt+n"]

    let display: String
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
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
            default: key = keyCodes[part]; symbols += part == "space" ? " Space" : part.uppercased()
            }
        }
        return key.map { ($0, mods, symbols) }
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

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class JournalWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let panel: FloatPanel
    let web: DragWebView

    override init() {
        panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
                           styleMask: [.titled, .resizable, .fullSizeContentView, .closable],
                           backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
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

    var isShown: Bool { panel.isVisible && NSApp.isActive && panel.isKeyWindow }

    func show() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        web.evaluateJavaScript("window.hf && window.hf.shown()")
    }

    /// Hides and hands focus back to whatever app was in front, like Raycast.
    func hide() {
        web.evaluateJavaScript("window.hf && window.hf.flush()")
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func toggle() { isShown ? hide() : show() }

    // MARK: settings

    func togglePinned() {
        Settings.pinned.toggle()
        applyPinned()
    }

    /// Pinned: floats above everything and stays when you click away. Unpinned: a normal window
    /// that tucks itself away when you switch apps.
    private func applyPinned() {
        let pinned = Settings.pinned
        panel.level = pinned ? .floating : .normal
        panel.hidesOnDeactivate = !pinned
        web.evaluateJavaScript("window.hf && window.hf.setPinned(\(pinned))")
    }

    func applyAppearance() {
        panel.appearance = Settings.appearance.nsAppearance
    }

    func adjustFont(by delta: Double?) {
        Settings.fontScale = delta.map { Settings.fontScale + $0 } ?? 1.0
        web.evaluateJavaScript("window.hf.setScale(\(Settings.fontScale))")
    }

    func openInHeptabase() {
        web.evaluateJavaScript("document.getElementById('open').click()")
    }

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
            guard let date = body["date"] as? String else { return }
            Heptabase.queue.async {
                do {
                    let r = try Heptabase.readJournal(date)
                    self.reply(requestId, r)
                    if let content = r["content"] as? String { self.pushTitles(for: content) }
                } catch {
                    self.reply(requestId, ["error": Self.message(error)])
                }
            }
        case "save":
            guard let date = body["date"] as? String, let content = body["content"] as? String,
                  let md5 = body["md5"] as? String else { return }
            Heptabase.queue.async {
                var result: [String: Any] = [:]
                do {
                    try Heptabase.saveJournal(date, content: content, md5: md5)
                } catch {
                    result["error"] = Self.message(error)
                }
                // Hand back what Heptabase now has: its md5 and the ids it assigned to new blocks.
                result["current"] = try? Heptabase.readJournal(date)
                self.reply(requestId, result)
            }
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
        case "togglePin":
            togglePinned()
            (NSApp.delegate as? AppDelegate)?.refreshMenu()
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("window.hf.setScale(\(Settings.fontScale)); window.hf.setPinned(\(Settings.pinned))")
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var journal: JournalWindow!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var flushed = false

    func applicationDidFinishLaunching(_ n: Notification) {
        journal = JournalWindow()
        registerHotKey()
        buildMainMenu()
        buildStatusItem()
        journal.show()
    }

    /// When HeptaFloat was last brought to the front (by a launcher or by clicking it).
    private var activatedAt = Date.distantPast
    /// When our own global hotkey last fired.
    private var hotkeyPressedAt = Date.distantPast

    func applicationWillBecomeActive(_ notification: Notification) {
        activatedAt = Date()
    }

    /// Launchers like Raycast "open" the app on every press, and an accessory app never counts as
    /// frontmost for their own hide-if-frontmost toggle. So reopening toggles here instead: if this
    /// open is what just brought us forward, show; if we were already up front, hide.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // A launcher bound to the same keys as our hotkey opens the app right after the hotkey has
        // already toggled; ignore that echo, and give focus back if it re-activated a hidden card.
        if Date().timeIntervalSince(hotkeyPressedAt) < 0.6 {
            if !journal.panel.isVisible { NSApp.hide(nil) }
            return false
        }
        let justActivated = Date().timeIntervalSince(activatedAt) < 0.5
        if journal.isShown && !justActivated { journal.hide() } else { journal.show() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if flushed { return .terminateNow }
        journal.flush {
            self.flushed = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(Settings.hotkey) { [weak self] in
            self?.hotkeyPressedAt = Date()
            self?.journal.toggle()
        }
    }

    // MARK: actions

    @objc func setShortcut(_ item: NSMenuItem) {
        guard let spec = item.representedObject as? String else { return }
        Settings.hotkey = spec
        registerHotKey()
        if hotKey == nil {
            let alert = NSAlert()
            alert.messageText = "Couldn't use \(item.title)"
            alert.informativeText = "macOS didn't accept this shortcut. Pick a different one."
            alert.runModal()
        }
        refreshMenu()
    }

    @objc func toggleJournal() { journal.toggle() }
    @objc func hideJournal() { journal.hide() }
    @objc func togglePinned() { journal.togglePinned(); refreshMenu() }
    @objc func openInHeptabase() { journal.openInHeptabase() }
    @objc func biggerText() { journal.adjustFont(by: 0.1) }
    @objc func smallerText() { journal.adjustFont(by: -0.1) }
    @objc func resetText() { journal.adjustFont(by: nil) }

    @objc func setAppearance(_ item: NSMenuItem) {
        guard let a = item.representedObject as? String, let appearance = Appearance(rawValue: a) else { return }
        Settings.appearance = appearance
        journal.applyAppearance()
        refreshMenu()
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshMenu()
    }

    // MARK: menus

    private var pinItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var appearanceItems: [NSMenuItem] = []
    private var shortcutItems: [NSMenuItem] = []
    private var toggleItem: NSMenuItem?

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "HeptaFloat")
        let menu = NSMenu()
        menu.delegate = self
        toggleItem = menu.addItem(withTitle: "Show / Hide Journal", action: #selector(toggleJournal), keyEquivalent: "")
        toggleItem?.target = self
        menu.addItem(.separator())
        pinItem = menu.addItem(withTitle: "Keep on Top", action: #selector(togglePinned), keyEquivalent: "")
        pinItem?.target = self
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        appearanceItems = Appearance.allCases.map { a in
            let item = sub.addItem(withTitle: a.title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a.rawValue
            return item
        }
        appearance.submenu = sub
        menu.addItem(appearance)
        let shortcut = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let specs = HotKey.presets.contains(Settings.hotkey) ? HotKey.presets : HotKey.presets + [Settings.hotkey]
        shortcutItems = specs.compactMap { spec in
            guard let parsed = HotKey.parse(spec) else { return nil }
            let item = shortcuts.addItem(withTitle: parsed.display, action: #selector(setShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            return item
        }
        shortcut.submenu = shortcuts
        menu.addItem(shortcut)
        menu.addItem(withTitle: "Open in Heptabase", action: #selector(openInHeptabase), keyEquivalent: "").target = self
        loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit HeptaFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    func refreshMenu() {
        pinItem?.state = Settings.pinned ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in appearanceItems { item.state = item.representedObject as? String == Settings.appearance.rawValue ? .on : .off }
        for item in shortcutItems { item.state = item.representedObject as? String == Settings.hotkey ? .on : .off }
        toggleItem?.title = "Show / Hide Journal" + (hotKey.map { "    \($0.display)" } ?? "")
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Hide", action: #selector(hideJournal), keyEquivalent: "w").target = self
        m.addItem(withTitle: "Quit HeptaFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m

        // Undo/redo are left to the editor's own keymap; only clipboard actions go through AppKit.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let e = NSMenu(title: "Edit")
        e.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = e

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let v = NSMenu(title: "View")
        v.addItem(withTitle: "Keep on Top", action: #selector(togglePinned), keyEquivalent: "P").target = self
        v.addItem(withTitle: "Open in Heptabase", action: #selector(openInHeptabase), keyEquivalent: "o").target = self
        v.addItem(withTitle: "Bigger Text", action: #selector(biggerText), keyEquivalent: "=").target = self
        v.addItem(withTitle: "Smaller Text", action: #selector(smallerText), keyEquivalent: "-").target = self
        v.addItem(withTitle: "Actual Size", action: #selector(resetText), keyEquivalent: "0").target = self
        viewItem.submenu = v

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
