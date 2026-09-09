import AppKit
import Carbon
import ServiceManagement
import ImageIO
import CoreImage

final class HistoryTable: NSTableView {
    var deleteSelection: (() -> Void)?
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { choose?() }
        else if event.keyCode == 53 { dismiss?() }
        else if event.keyCode == 51 && !event.isARepeat { deleteSelection?() }
        else if event.keyCode == 51 { return }
        else { super.keyDown(with: event) }
    }
}

final class HistoryPanel: NSPanel {
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() }
        else if event.keyCode == 36 || event.keyCode == 76 { choose?() }
        else { super.keyDown(with: event) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let queue = DispatchQueue(label: "Clip.storage", qos: .utility)
    private var store: HistoryStore!
    private var status: NSStatusItem!
    private let hotKey = HotKey()
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var paused = false
    private var busy = false
    private var items: [ClipItem] = []
    private var thumbnails: [String: NSImage] = [:]
    private var panel: HistoryPanel!
    private let table = HistoryTable()
    private var settings: NSWindow?
    private var target: NSRunningApplication?
    private var pastePending = false
    private var pauseItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Clip", isDirectory: true)
            store = try HistoryStore(directory: directory)
        } catch { alert(Self.errorMessage(error)); NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuIcon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clip")
        menuIcon?.isTemplate = true
        status.button?.image = menuIcon
        let menu = NSMenu()
        menu.addItem(withTitle: "Open History", action: #selector(showHistory), keyEquivalent: "")
        pauseItem = menu.addItem(withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clip", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        makePanel()
        hotKey.action = { [weak self] in self?.showHistory() }
        let defaults = UserDefaults.standard
        let key = defaults.object(forKey: "shortcutKey") as? UInt32 ?? UInt32(kVK_ANSI_V)
        let modifiers = defaults.object(forKey: "shortcutModifiers") as? UInt32 ?? UInt32(cmdKey | shiftKey)
        if !hotKey.register(key: key, modifiers: modifiers) { alert("Could not register the shortcut. Choose another combination in Settings.") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.1
    }
    private func makePanel() {
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.setAccessibilityLabel("Clipboard History")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.choose = { [weak self] in self?.pasteSelected() }
        panel.dismiss = { [weak self] in self?.dismiss() }
        let root = NSView(frame: panel.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        panel.contentView = root

        // Keep opacity and blur on the background, never on the history contents.
        let background = NSVisualEffectView(frame: root.bounds.insetBy(dx: -9, dy: -9))
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.alphaValue = 0.3
        background.wantsLayer = true
        // AppKit controls the material's backdrop blur; this is an additional blur.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(3.0, forKey: kCIInputRadiusKey)
            background.contentFilters = [blur]
        }
        root.addSubview(background)

        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 8, dy: 8))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.setAccessibilityLabel("Clipboard History")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content")))
        table.deleteSelection = { [weak self] in self?.deleteSelected() }
        table.choose = { [weak self] in self?.pasteSelected() }
        table.dismiss = { [weak self] in self?.dismiss() }
        table.tableColumns.first?.width = 408
        table.headerView = nil
        table.rowHeight = 56
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(clicked)
        table.allowsEmptySelection = false
        scroll.documentView = table
        root.addSubview(scroll)
    }
    private func poll() {
        guard !paused, !busy, !pastePending else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        let observed = pasteboard.changeCount
        changeCount = observed
        let ignored = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !ignored.contains(where: { pasteboard.availableType(from: [NSPasteboard.PasteboardType($0)]) != nil }) else { return }
        let data: Data
        let kind: String
        let preview: String
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            data = image; kind = "image"; preview = "Image"
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            data = Data(string.utf8); kind = "text"
            preview = String(string.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        } else { return }
        guard pasteboard.changeCount == observed else { changeCount = observed - 1; return }
        guard data.count <= 20 * 1024 * 1024 else { return }
        busy = true
        queue.async { [self] in
            do {
                var payload = data
                if kind == "image" {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        DispatchQueue.main.async { self.busy = false }; return
                    }
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                        DispatchQueue.main.async { self.busy = false }; return
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else {
                        DispatchQueue.main.async { self.busy = false }; return
                    }
                    payload = output as Data
                }
                _ = try store.insert(data: payload, kind: kind, preview: preview)
                DispatchQueue.main.async {
                    self.busy = false
                    if self.panel.isVisible { self.reload() }
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.alert(Self.errorMessage(error)) } }
        }
    }
    @objc private func showHistory() {
        guard !pastePending else { return }
        if panel.isVisible { dismiss(); return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { target = front }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(table)
        reload()
    }
    private func reload() {
        queue.async { [self] in
            do {
                let result = try store.items()
                var images: [String: NSImage] = [:]
                for item in result where item.kind == "image" {
                    if let source = CGImageSourceCreateWithURL(store.file(item.id) as CFURL, nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                        images[item.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
                DispatchQueue.main.async {
                    let previousRow = self.table.selectedRow
                    let selected = self.items.indices.contains(self.table.selectedRow) ? self.items[self.table.selectedRow].id : nil
                    self.items = result; self.thumbnails = images; self.table.reloadData()
                    if !result.isEmpty { self.table.selectRowIndexes(IndexSet(integer: result.firstIndex(where: { $0.id == selected }) ?? min(max(previousRow, 0), result.count - 1)), byExtendingSelection: false) }
                }
            } catch { DispatchQueue.main.async { self.alert(Self.errorMessage(error)) } }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
        let label = NSTextField(labelWithString: item.kind == "image" ? "" : item.preview)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: item.kind == "image" ? 72 : 12, y: 18, width: item.kind == "image" ? 300 : 380, height: 20)
        cell.addSubview(label)
        if item.kind == "image" {
            let image = NSImageView(frame: NSRect(x: 8, y: 4, width: 56, height: 48))
            image.setAccessibilityLabel("Image")
            image.image = thumbnails[item.id]; image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
        }
        return cell
    }
    @objc private func clicked() { if table.clickedRow >= 0 { pasteSelected() } }
    private func dismiss() { panel.orderOut(nil); thumbnails.removeAll(); target?.activate(options: []) }
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { panel.orderOut(nil); thumbnails.removeAll() }
    }
    private func pasteSelected() {
        guard !pastePending, items.indices.contains(table.selectedRow), let destination = target, !destination.isTerminated else { return }
        guard AXIsProcessTrusted() else {
            panel.orderOut(nil)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            alert("To paste automatically, allow Clip in System Settings → Privacy & Security → Accessibility. Then open History again.")
            return
        }
        let item = items[table.selectedRow]
        pastePending = true
        queue.async { [self] in
            do {
                let data = try store.data(item)
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    let success = pb.setData(data, forType: item.kind == "image" ? .png : .string)
                    self.changeCount = pb.changeCount
                    guard success else { self.pastePending = false; self.alert("Could not copy the item to the clipboard."); return }
                    self.panel.orderOut(nil)
                    self.thumbnails.removeAll()
                    destination.activate(options: [])
                    self.finishPaste(to: destination, attempts: 20)
                }
            } catch { DispatchQueue.main.async { self.pastePending = false; self.alert(Self.errorMessage(error)) } }
        }
    }
    private func finishPaste(to destination: NSRunningApplication, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let released = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier && released {
                defer { self.pastePending = false }
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
                down.flags = .maskCommand; up.flags = .maskCommand
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            } else if attempts > 0 && !destination.isTerminated {
                self.finishPaste(to: destination, attempts: attempts - 1)
            } else {
                self.pastePending = false
                self.alert("Could not confirm the destination app. The item has been copied. Press ⌘V to paste it.")
            }
        }
    }
    @objc private func togglePause() {
        paused.toggle(); changeCount = NSPasteboard.general.changeCount
        pauseItem.title = paused ? "Resume Recording" : "Pause Recording"
        status.button?.appearsDisabled = paused
    }
    @objc private func deleteSelected() {
        guard items.indices.contains(table.selectedRow) else { return }
        let id = items[table.selectedRow].id
        queue.async { do { try self.store.remove(id); DispatchQueue.main.async { self.reload() } } catch { DispatchQueue.main.async { self.alert(Self.errorMessage(error)) } } }
    }
    @objc private func clearHistory() {
        let dialog = NSAlert(); dialog.messageText = "Clear all history?"; dialog.informativeText = "All saved text and images will be deleted."; dialog.addButton(withTitle: "Delete"); dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        queue.async { do { try self.store.clear(); DispatchQueue.main.async { self.reload() } } catch { DispatchQueue.main.async { self.alert(Self.errorMessage(error)) } } }
    }
    @objc private func showSettings() {
        if let settings { NSApp.activate(ignoringOtherApps: true); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 205), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clip Settings"; window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Open History Shortcut")
        label.frame = NSRect(x: 24, y: 160, width: 350, height: 20); window.contentView?.addSubview(label)
        let recorder = ShortcutRecorder(title: UserDefaults.standard.string(forKey: "shortcutLabel") ?? "⇧⌘V", target: nil, action: nil)
        recorder.frame = NSRect(x: 24, y: 118, width: 360, height: 32)
        recorder.recorded = { [weak self, weak recorder] event in
            guard let self else { return }
            let modifiers = HotKey.carbon(event.modifierFlags)
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "shortcutKey") == Int(event.keyCode) && defaults.integer(forKey: "shortcutModifiers") == Int(modifiers) {
                recorder?.title = defaults.string(forKey: "shortcutLabel") ?? "⇧⌘V"; return
            }
            guard self.hotKey.register(key: UInt32(event.keyCode), modifiers: modifiers) else {
                recorder?.title = defaults.string(forKey: "shortcutLabel") ?? "⇧⌘V"
                self.alert("This shortcut is unavailable. Choose another combination."); return
            }
            let flags = event.modifierFlags
            let title = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            defaults.set(Int(event.keyCode), forKey: "shortcutKey"); defaults.set(Int(modifiers), forKey: "shortcutModifiers"); defaults.set(title, forKey: "shortcutLabel")
            recorder?.title = title
        }
        window.contentView?.addSubview(recorder)
        let login = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.frame = NSRect(x: 24, y: 75, width: 350, height: 25); window.contentView?.addSubview(login)
        let note = NSTextField(wrappingLabelWithString: "Limits: 100 items / 200MB total / 20MB per item\nText and still images are saved on this Mac.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 20, width: 360, height: 40); window.contentView?.addSubview(note)
        settings = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { alert(Self.errorMessage(error)) }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private static func errorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == "Clip.Storage" { return error.localizedDescription }
        return "The operation could not be completed. (\(error.domain), code \(error.code))"
    }
    private func alert(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Clip"; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        queue.async { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct ClipApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
