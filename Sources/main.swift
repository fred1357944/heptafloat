// HeptaFloat — today's Heptabase journal in a floating, editable card, summoned with a hotkey.
// The web editor (src/editor.js) does the editing; this host reads, saves, and searches through the
// `heptabase` CLI and provides the Raycast-style window behavior.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
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
    static let defaultHotkey = "ctrl+opt+j"
    /// e.g. "ctrl+opt+j"; recorded in Settings.
    static var hotkey: String {
        get { defaults.string(forKey: "hotkey") ?? defaultHotkey }
        set { defaults.set(newValue, forKey: "hotkey") }
    }

    /// Posted when a setting changes outside the Settings window (menus, the pin button).
    static let changed = Notification.Name("HeptaFloatSettingsChanged")
}

// MARK: - Global hotkey

/// A system-wide hotkey via Carbon, which needs no Accessibility permission.
final class HotKey {
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

    /// The app that was in front before the card appeared, to hand focus back to on hide.
    private var previousApp: NSRunningApplication?

    func show() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        web.evaluateJavaScript("window.hf && window.hf.shown()")
    }

    func flushSoon() { web.evaluateJavaScript("window.hf && window.hf.flush()") }

    /// Hides and hands focus back to whatever app was in front, like Raycast.
    func hide() {
        flushSoon()
        panel.orderOut(nil)
        returnFocus()
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

    /// Pinned: floats above everything and stays when you click away. Unpinned: a normal window
    /// that tucks itself away when you switch apps.
    func applyPinned() {
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
        applyFontScale()
        NotificationCenter.default.post(name: Settings.changed, object: nil)
    }

    func applyFontScale() {
        web.evaluateJavaScript("window.hf.setScale(\(Settings.fontScale))")
    }

    func undo() { web.evaluateJavaScript("window.hf.undo()") }
    func redo() { web.evaluateJavaScript("window.hf.redo()") }

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

    /// Tries a real read of today's journal, so a passing check means saving will work too.
    static func checkConnection() -> ConnectionStatus {
        guard appURL != nil else {
            return ConnectionStatus(level: .problem, title: "Heptabase isn't installed",
                                    detail: "Install the Heptabase desktop app from heptabase.com.")
        }
        guard cliPath != nil else {
            return ConnectionStatus(level: .problem, title: "Heptabase CLI is off",
                                    detail: "In Heptabase, open Settings and turn on the CLI, then check again.")
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
    @Published var hotkey = Settings.hotkey
    @Published var hotkeyProblem: String?
    @Published var appearance = Settings.appearance
    @Published var pinned = Settings.pinned
    @Published var fontScale = Settings.fontScale
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginProblem: String?
    @Published var connection = ConnectionStatus.checking

    /// Hooks into the running app, set by AppDelegate.
    var applyHotkey: () -> Bool = { true }
    var pauseHotkey: () -> Void = {}
    var applyAppearance: () -> Void = {}
    var applyPinned: () -> Void = {}
    var applyFontScale: () -> Void = {}

    init() {
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        hotkey = Settings.hotkey
        appearance = Settings.appearance
        pinned = Settings.pinned
        fontScale = Settings.fontScale
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setHotkey(_ spec: String) {
        let previous = Settings.hotkey
        Settings.hotkey = spec
        if applyHotkey() {
            hotkey = spec
            hotkeyProblem = nil
        } else {
            Settings.hotkey = previous
            _ = applyHotkey()
            hotkeyProblem = "That shortcut isn't available. Try another one."
        }
    }

    func setAppearance(_ a: Appearance) { Settings.appearance = a; appearance = a; applyAppearance() }
    func setPinned(_ on: Bool) { Settings.pinned = on; pinned = on; applyPinned() }
    func setFontScale(_ v: Double) { Settings.fontScale = v; fontScale = Settings.fontScale; applyFontScale() }

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
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press keys…" : (HotKey.parse(model.hotkey)?.display ?? "None"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if model.hotkey != Settings.defaultHotkey && !recording {
                Button("Reset") { model.setHotkey(Settings.defaultHotkey) }
                    .buttonStyle(.borderless)
            }
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
                model.setHotkey(spec)
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
        _ = model.applyHotkey()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Show / hide shortcut") { ShortcutRecorder(model: model) }
                if let problem = model.hotkeyProblem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
                Toggle("Keep on top of other windows", isOn: Binding(get: { model.pinned }, set: model.setPinned))
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
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
                Link("HeptaFloat on GitHub", destination: URL(string: "https://github.com/madeyexz/heptafloat")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: model.checkConnection)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        settings.applyHotkey = { [weak self] in self?.registerHotKey() ?? false }
        settings.pauseHotkey = { [weak self] in self?.hotKey = nil }
        settings.applyAppearance = { [weak self] in self?.journal.applyAppearance(); self?.refreshMenu() }
        settings.applyPinned = { [weak self] in self?.journal.applyPinned(); self?.refreshMenu() }
        settings.applyFontScale = { [weak self] in self?.journal.applyFontScale() }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenu()
        }
        _ = registerHotKey()
        buildMainMenu()
        journal.show()
    }

    @discardableResult
    private func registerHotKey() -> Bool {
        hotKey = nil
        hotKey = HotKey(Settings.hotkey) { [weak self] in
            guard let self else { return }
            self.hotkeyPressedAt = Date()
            self.hotkeyShowed = !self.journal.isShown
            self.journal.toggle()
        }
        refreshMenu()
        return hotKey != nil
    }

    private var hotkeyJustFired: Bool { Date().timeIntervalSince(hotkeyPressedAt) < 0.6 }

    /// Dock clicks and launchers "reopen" the app. A launcher bound to the same keys as our hotkey
    /// sends one right after the hotkey has already toggled; ignore that echo, and give focus back
    /// if it re-activated a hidden card.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hotkeyJustFired {
            if !journal.panel.isVisible { journal.returnFocus() }
        } else {
            journal.show()
        }
        return false
    }

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

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            window.title = "HeptaFloat Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating // stay above the floating card
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
    @objc func openInHeptabase() { journal.openInHeptabase() }
    @objc func biggerText() { journal.adjustFont(by: 0.1) }
    @objc func smallerText() { journal.adjustFont(by: -0.1) }
    @objc func resetText() { journal.adjustFont(by: nil) }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/madeyexz/heptafloat")!) }
    @objc func reportIssue() { NSWorkspace.shared.open(URL(string: "https://github.com/madeyexz/heptafloat/issues/new")!) }

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

        _ = menu("HeptaFloat") { m in
            _ = add(m, "About HeptaFloat", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            m.addItem(.separator())
            _ = add(m, "Settings…", #selector(showSettings), ",")
            m.addItem(.separator())
            _ = add(m, "Hide HeptaFloat", #selector(hideJournal), "h")
            _ = add(m, "Quit HeptaFloat", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        _ = menu("File") { m in
            _ = add(m, "Open in Heptabase", #selector(openInHeptabase), "o")
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
        _ = menu("View") { m in
            pinItem = add(m, "Keep on Top", #selector(togglePinned), "p", [.command, .shift])
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
            _ = add(m, "Bigger Text", #selector(biggerText), "=")
            _ = add(m, "Smaller Text", #selector(smallerText), "-")
            _ = add(m, "Actual Size", #selector(resetText), "0")
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
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
