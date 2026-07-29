import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Network

private let appLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SkeletonKey/app.log")

private func appLog(_ line: String) {
    let message = "[SkeletonKey] \(line)\n"
    let data = Data(message.utf8)
    let directory = appLogURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: appLogURL.path) == false {
        FileManager.default.createFile(atPath: appLogURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: appLogURL) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    fputs(message, stderr)
}

private func requestAccessibilityAccess() {
    guard AXIsProcessTrusted() == false else { return }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

private func requestInputMonitoringAccess() {
    let alreadyGranted = CGPreflightListenEventAccess()
    appLog("Input Monitoring granted: \(alreadyGranted)")
    guard alreadyGranted == false else { return }
    // This does NOT show a system alert like Accessibility does, it just
    // silently adds SkeletonKey to Privacy & Security > Input Monitoring in an
    // unchecked state. It has to be enabled manually there, then the app
    // relaunched, before keyboard events will actually reach the tap.
    _ = CGRequestListenEventAccess()
}

private let defaultToggleKeyCode: UInt16 = UInt16(kVK_ANSI_K)
private let defaultToggleModifiers: NSEvent.ModifierFlags = [.command, .option]

private struct HotKeyBinding: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let `default` = HotKeyBinding(keyCode: defaultToggleKeyCode, modifiers: defaultToggleModifiers)

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let interesting: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return flags.intersection(interesting) == modifiers.intersection(interesting)
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard UInt16(keyCode) == self.keyCode else { return false }
        let wantsCommand = modifiers.contains(.command)
        let wantsOption = modifiers.contains(.option)
        let wantsControl = modifiers.contains(.control)
        let wantsShift = modifiers.contains(.shift)
        return flags.contains(.maskCommand) == wantsCommand
            && flags.contains(.maskAlternate) == wantsOption
            && flags.contains(.maskControl) == wantsControl
            && flags.contains(.maskShift) == wantsShift
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9",
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Escape): "Esc",
            UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ISO_Section): "§"
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

private enum SavedHotKey {
    private static let keyCodeKey = "SkeletonKey.hotKeyCode"
    private static let modifiersKey = "SkeletonKey.hotKeyModifiers"

    static func load() -> HotKeyBinding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return .default
        }
        let keyCode = UInt16(defaults.integer(forKey: keyCodeKey))
        let raw = UInt(defaults.integer(forKey: modifiersKey))
        let modifiers = NSEvent.ModifierFlags(rawValue: raw)
        return HotKeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    static func save(_ binding: HotKeyBinding) {
        let defaults = UserDefaults.standard
        defaults.set(Int(binding.keyCode), forKey: keyCodeKey)
        defaults.set(Int(binding.modifiers.rawValue), forKey: modifiersKey)
    }
}

struct HistoryEntry: Equatable {
    let host: String
    let port: UInt16

    var display: String { "\(host):\(port)" }
}

private enum SavedEndpoint {
    private static let hostKey = "SkeletonKey.savedHost"
    private static let portKey = "SkeletonKey.savedPort"
    private static let historyKey = "SkeletonKey.recentEndpoints"
    private static let historyLimit = 5

    static func load(defaultHost: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: hostKey) ?? defaultHost
        let storedPort = defaults.integer(forKey: portKey)
        let port = (storedPort > 0 && storedPort <= Int(UInt16.max)) ? UInt16(storedPort) : defaultPort
        return (host, port)
    }

    static func save(host: String, port: UInt16) {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: hostKey)
        defaults.set(Int(port), forKey: portKey)
    }

    static func loadHistory() -> [HistoryEntry] {
        let raw = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        return raw.compactMap { entry -> HistoryEntry? in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            return HistoryEntry(host: String(parts[0]), port: port)
        }
    }

    static func recordHistory(host: String, port: UInt16) {
        let key = "\(host):\(port)"
        var raw = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        raw.removeAll { $0 == key }
        raw.insert(key, at: 0)
        if raw.count > historyLimit {
            raw = Array(raw.prefix(historyLimit))
        }
        UserDefaults.standard.set(raw, forKey: historyKey)
    }
}

private enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

private final class SharedState {
    private let queue = DispatchQueue(label: "kvm.shared.state")
    private var remoteActive = false
    private var connectionState: ConnectionState = .disconnected

    func setRemoteActive(_ value: Bool) {
        queue.sync { remoteActive = value }
    }

    func isRemoteActive() -> Bool {
        queue.sync { remoteActive }
    }

    func setConnectionState(_ value: ConnectionState) {
        queue.sync { connectionState = value }
    }

    func connectionStateValue() -> ConnectionState {
        queue.sync { connectionState }
    }

    /// True only once the user has asked to forward *and* the connection is
    /// actually live, not merely while attempting/retrying. Input capture
    /// (event swallowing, cursor takeover) should key off this, not off the
    /// raw toggle intent, so a slow or dropped connection doesn't leave the
    /// Mac's own cursor frozen for no reason.
    func isCapturing() -> Bool {
        queue.sync { remoteActive && connectionState == .connected }
    }
}

private final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Remote: Off", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: Disconnected", action: nil, keyEquivalent: "")
    private let showWindowItem = NSMenuItem(title: "Show Window", action: nil, keyEquivalent: "")
    private let showWindowTarget = ActionTarget()
    private let quitTarget = ActionTarget()
    private let clickTarget = ClickTarget()
    private var pendingSingleClick: DispatchWorkItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarImage(badgeColor: .systemOrange)
            button.imagePosition = .imageOnly
            button.toolTip = "SkeletonKey — double-click to open"
            // Don't assign statusItem.menu permanently: that eats clicks and
            // makes double-click impossible. Route clicks ourselves so a
            // double-click can reopen the window (same as the Windows tray).
            clickTarget.onClick = { [weak self] event in
                self?.handleButtonEvent(event)
            }
            button.target = clickTarget
            button.action = #selector(ClickTarget.invoke(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        stateItem.isEnabled = false
        connectionItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(connectionItem)
        menu.addItem(.separator())
        showWindowItem.target = showWindowTarget
        showWindowItem.action = #selector(ActionTarget.invoke)
        menu.addItem(showWindowItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(ActionTarget.invoke), keyEquivalent: "q")
        quitItem.target = quitTarget
        menu.addItem(quitItem)
    }

    func setShowWindowAction(_ action: @escaping () -> Void) {
        showWindowTarget.action = action
    }

    func setQuitAction(_ action: @escaping () -> Void) {
        quitTarget.action = action
    }

    func update(remoteActive: Bool, connectionState: ConnectionState) {
        DispatchQueue.main.async {
            self.stateItem.title = remoteActive ? "Remote: On" : "Remote: Off"

            switch connectionState {
            case .disconnected:
                self.connectionItem.title = "Connection: Disconnected"
            case .connecting:
                self.connectionItem.title = "Connection: Connecting"
            case .connected:
                self.connectionItem.title = "Connection: Connected"
            }

            // Brand mark + semaphore badge: orange idle/waiting, green capturing.
            // Red is reserved for real failures — idle must not look like an error.
            let color: NSColor
            if remoteActive {
                color = connectionState == .connected ? .systemGreen : .systemOrange
            } else {
                color = .systemOrange
            }
            self.statusItem.button?.image = Self.menuBarImage(badgeColor: color)
            self.statusItem.button?.toolTip = remoteActive
                ? "SkeletonKey: active — double-click to open"
                : "SkeletonKey: inactive — double-click to open"
        }
    }

    private func handleButtonEvent(_ event: NSEvent) {
        if event.type == .rightMouseUp {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            popUpMenu()
            return
        }

        guard event.type == .leftMouseUp else { return }

        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            showWindowTarget.action?()
            return
        }

        // Delay the menu so a second click can still count as a double-click
        // instead of opening the menu under the cursor.
        pendingSingleClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.popUpMenu()
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func popUpMenu() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    /// Brand icon with a small colored semaphore so status stays glanceable.
    private static func menuBarImage(badgeColor: NSColor) -> NSImage {
        let menuSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: menuSize)
        image.lockFocus()

        let brand = brandSourceImage()
        brand.draw(
            in: NSRect(origin: .zero, size: menuSize),
            from: NSRect(origin: .zero, size: brand.size),
            operation: .sourceOver,
            fraction: 1.0
        )

        // Bottom-left semaphore (AppKit y=0 is the bottom edge).
        let badgeSide: CGFloat = 4.5
        let badgeRect = NSRect(x: 0, y: 0, width: badgeSide, height: badgeSide)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.6, dy: -0.6)).fill()
        badgeColor.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func brandSourceImage() -> NSImage {
        // Tight crop without the master artwork's empty black padding — the
        // full AppIcon.icns keeps that padding for Dock, but menu-bar size
        // needs the mark filling the pixel budget.
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return statusImage(color: .systemPurple)
    }

    private static func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        color.setFill()
        let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12))
        circle.fill()

        NSColor.black.withAlphaComponent(0.15).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private final class ActionTarget: NSObject {
        var action: (() -> Void)?

        @objc func invoke() {
            action?()
        }
    }

    private final class ClickTarget: NSObject {
        var onClick: ((NSEvent) -> Void)?

        @objc func invoke(_ sender: Any?) {
            guard let event = NSApp.currentEvent else { return }
            onClick?(event)
        }
    }
}

private final class ControlWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    private let addressField = NSComboBox()
    private let endpointLockButton = NSButton()
    private let statusDotView = NSImageView()
    private let statusTextField = NSTextField(labelWithString: "Off")
    private let statusPill = NSView()
    private let toggleButton = NSButton(title: "Start Forwarding", target: nil, action: nil)
    private let hotkeyButton = NSButton(title: "⌘⌥K", target: nil, action: nil)
    private let hotkeyLockButton = NSButton()
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let toggleTarget = ActionTarget()
    private let hotkeyTarget = ActionTarget()
    private let quitTarget = ActionTarget()
    private let endpointLockTarget = ActionTarget()
    private let hotkeyLockTarget = ActionTarget()
    private var historyEntries: [HistoryEntry] = []
    private var isRecordingHotkey = false
    private var hotkeyMonitor: Any?
    private var currentHotKey = HotKeyBinding.default
    private var endpointLocked = UserDefaults.standard.bool(forKey: "SkeletonKey.endpointLocked")
    private var hotkeyLocked = true
    /// When false, closing the window won't demote us to `.accessory`
    /// (capture needs that demotion not to yank CGAssociate out from under us).
    var canDemoteToAccessory: (() -> Bool)?
    var onHotKeyChanged: ((HotKeyBinding) -> Void)?
    var onHotKeyRecordingChanged: ((Bool) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SkeletonKey"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        hotkeyLocked = loadHotkeyLocked()
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setToggleAction(_ action: @escaping () -> Void) {
        toggleTarget.action = action
    }

    func setQuitAction(_ action: @escaping () -> Void) {
        quitTarget.action = action
    }

    func setEndpoint(host: String, port: UInt16) {
        addressField.stringValue = "\(host):\(port)"
    }

    func currentEndpoint() -> (host: String, port: UInt16)? {
        parseAddress()
    }

    func flashInvalidAddress() {
        NSSound(named: "Tink")?.play()
        flashInvalidField()
    }

    func updateHistory(_ entries: [HistoryEntry]) {
        historyEntries = entries
        addressField.removeAllItems()
        addressField.addItems(withObjectValues: entries.map { $0.display })
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard endpointLocked == false else { return }
        let index = addressField.indexOfSelectedItem
        guard index >= 0, index < historyEntries.count else { return }
        addressField.stringValue = historyEntries[index].display
    }

    func setHotKey(_ binding: HotKeyBinding) {
        currentHotKey = binding
        if isRecordingHotkey == false {
            hotkeyButton.title = binding.displayString
        }
        applyHotkeyLockState()
    }

    func updateStatus(remoteActive: Bool, connectionState: ConnectionState) {
        let color: NSColor
        let statusText: String

        switch (remoteActive, connectionState) {
        case (false, _):
            color = .systemOrange
            statusText = "Off"
        case (true, .connecting):
            color = .systemOrange
            statusText = "Connecting"
        case (true, .connected):
            color = .systemGreen
            statusText = "Forwarding"
        case (true, .disconnected):
            color = .systemOrange
            statusText = "Reconnecting"
        }

        statusDotView.image = Self.dotImage(color: color, diameter: 8)
        statusTextField.stringValue = statusText
        statusTextField.textColor = color
        statusPill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor

        toggleButton.layer?.backgroundColor = (remoteActive ? NSColor.systemRed : NSColor.systemGreen).cgColor
        styleCapsuleTitle(toggleButton, text: remoteActive ? "Stop Forwarding" : "Start Forwarding")
        toggleButton.keyEquivalent = remoteActive ? "" : "\r"
    }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopHotkeyRecording()
        hotkeyButton.title = currentHotKey.displayString
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.canDemoteToAccessory?() ?? true else {
                appLog("Keeping .regular while capturing with window closed")
                return
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let appNameLabel = NSTextField(labelWithString: "SKELETONKEY")
        appNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appNameLabel.textColor = .tertiaryLabelColor

        statusDotView.image = Self.dotImage(color: .systemOrange, diameter: 8)
        statusTextField.font = .systemFont(ofSize: 13, weight: .semibold)
        statusTextField.textColor = .systemOrange

        let pillStack = NSStackView(views: [statusDotView, statusTextField])
        pillStack.orientation = .horizontal
        pillStack.spacing = 6
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 12
        statusPill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 12),
            pillStack.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -12),
            pillStack.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 6),
            pillStack.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -6)
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let settingsCard = NSView()
        settingsCard.wantsLayer = true
        settingsCard.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        settingsCard.layer?.cornerRadius = 12
        settingsCard.translatesAutoresizingMaskIntoConstraints = false

        let endpointLabel = makeFieldLabel("Endpoint")
        configureAddressField(addressField, placeholder: "host:port, e.g. 0.tcp.ngrok.io:12653")
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false

        configureLockButton(endpointLockButton, target: endpointLockTarget) { [weak self] in
            self?.toggleEndpointLock()
        }

        let endpointRow = NSStackView(views: [addressField, endpointLockButton])
        endpointRow.orientation = .horizontal
        endpointRow.alignment = .centerY
        endpointRow.spacing = 6
        endpointRow.distribution = .fill
        endpointRow.translatesAutoresizingMaskIntoConstraints = false
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyEndpointLockState()

        let hotkeyLabel = makeFieldLabel("Hotkey")
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.controlSize = .regular
        hotkeyButton.target = hotkeyTarget
        hotkeyButton.action = #selector(ActionTarget.invoke)
        hotkeyTarget.action = { [weak self] in self?.beginHotkeyRecording() }
        hotkeyButton.translatesAutoresizingMaskIntoConstraints = false
        hotkeyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hotkeyButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureLockButton(hotkeyLockButton, target: hotkeyLockTarget) { [weak self] in
            self?.toggleHotkeyLock()
        }

        let hotkeyRow = NSStackView(views: [hotkeyButton, hotkeyLockButton])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.alignment = .centerY
        hotkeyRow.spacing = 6
        hotkeyRow.distribution = .fill
        hotkeyRow.translatesAutoresizingMaskIntoConstraints = false
        applyHotkeyLockState()

        let hotkeyTip = NSTextField(labelWithString: "Unlock to change · needs ⌘ ⌥ ⌃ or ⇧")
        hotkeyTip.font = .systemFont(ofSize: 10)
        hotkeyTip.textColor = .tertiaryLabelColor

        let cardStack = NSStackView(views: [endpointLabel, endpointRow, hotkeyLabel, hotkeyRow, hotkeyTip])
        cardStack.orientation = .vertical
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.setCustomSpacing(14, after: endpointRow)
        cardStack.setCustomSpacing(4, after: hotkeyRow)

        settingsCard.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: settingsCard.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: settingsCard.bottomAnchor, constant: -16),
            endpointRow.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor),
            endpointRow.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor),
            hotkeyRow.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor),
            hotkeyRow.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor)
        ])

        toggleButton.target = toggleTarget
        toggleButton.action = #selector(ActionTarget.invoke)
        toggleButton.isBordered = false
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = 20
        toggleButton.layer?.backgroundColor = NSColor.systemGreen.cgColor
        styleCapsuleTitle(toggleButton, text: "Start Forwarding")
        toggleButton.keyEquivalent = "\r"
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        quitButton.target = quitTarget
        quitButton.action = #selector(ActionTarget.invoke)
        quitButton.isBordered = true
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = .systemFont(ofSize: 11)

        let hintLabel = NSTextField(labelWithString: "Hotkey toggles forwarding")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor

        let footerSpacer = NSView()
        let footerRow = NSStackView(views: [hintLabel, footerSpacer, quitButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [appNameLabel, statusPill, divider, settingsCard, toggleButton, footerRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 18
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(10, after: appNameLabel)
        mainStack.setCustomSpacing(20, after: statusPill)
        mainStack.setCustomSpacing(22, after: divider)

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 36),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -28)
        ])

        for view in [divider, settingsCard, toggleButton, footerRow] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor)
            ])
        }
    }

    private func beginHotkeyRecording() {
        guard hotkeyLocked == false else { return }
        guard isRecordingHotkey == false else { return }
        isRecordingHotkey = true
        hotkeyButton.title = "Press new hotkey…"
        // Keep keystrokes out of the endpoint field while we wait for a shortcut.
        window?.makeFirstResponder(hotkeyButton)
        onHotKeyRecordingChanged?(true)
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopHotkeyRecording()
                self.hotkeyButton.title = self.currentHotKey.displayString
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty == false else {
                // Bare letters/numbers must not type into the endpoint field.
                return nil
            }
            let binding = HotKeyBinding(keyCode: event.keyCode, modifiers: mods)
            self.stopHotkeyRecording()
            self.currentHotKey = binding
            self.hotkeyButton.title = binding.displayString
            self.hotkeyLocked = true
            UserDefaults.standard.set(true, forKey: "SkeletonKey.hotkeyLocked")
            self.applyHotkeyLockState()
            self.onHotKeyChanged?(binding)
            return nil
        }
    }

    private func stopHotkeyRecording() {
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
        guard isRecordingHotkey else { return }
        isRecordingHotkey = false
        onHotKeyRecordingChanged?(false)
    }

    private func toggleEndpointLock() {
        endpointLocked.toggle()
        UserDefaults.standard.set(endpointLocked, forKey: "SkeletonKey.endpointLocked")
        applyEndpointLockState()
        if endpointLocked {
            window?.makeFirstResponder(nil)
        }
    }

    private func applyEndpointLockState() {
        addressField.isEnabled = !endpointLocked
        addressField.isEditable = !endpointLocked
        styleLockButton(endpointLockButton, locked: endpointLocked, subject: "endpoint")
    }

    private func toggleHotkeyLock() {
        if isRecordingHotkey {
            stopHotkeyRecording()
            hotkeyButton.title = currentHotKey.displayString
        }
        hotkeyLocked.toggle()
        UserDefaults.standard.set(hotkeyLocked, forKey: "SkeletonKey.hotkeyLocked")
        applyHotkeyLockState()
        if hotkeyLocked {
            window?.makeFirstResponder(nil)
        }
    }

    private func applyHotkeyLockState() {
        hotkeyButton.isEnabled = !hotkeyLocked
        hotkeyButton.toolTip = hotkeyLocked
            ? "Unlock to change the hotkey"
            : "Click, then press a shortcut with a modifier (Esc cancels)"
        styleLockButton(hotkeyLockButton, locked: hotkeyLocked, subject: "hotkey")
    }

    private func configureLockButton(_ button: NSButton, target: ActionTarget, action: @escaping () -> Void) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = target
        button.action = #selector(ActionTarget.invoke)
        target.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func styleLockButton(_ button: NSButton, locked: Bool, subject: String) {
        let symbol = locked ? "lock.fill" : "lock.open.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = locked ? .secondaryLabelColor : .tertiaryLabelColor
        button.toolTip = locked
            ? "Unlock \(subject) to edit"
            : "Lock \(subject) to prevent accidental edits"
    }

    private func loadHotkeyLocked() -> Bool {
        let defaults = UserDefaults.standard
        // Default locked so a stray click doesn't start listening.
        guard defaults.object(forKey: "SkeletonKey.hotkeyLocked") != nil else {
            return true
        }
        return defaults.bool(forKey: "SkeletonKey.hotkeyLocked")
    }

    private func styleCapsuleTitle(_ button: NSButton, text: String) {
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureAddressField(_ field: NSComboBox, placeholder: String) {
        field.isEditable = true
        field.isSelectable = true
        field.usesDataSource = false
        field.completes = false
        field.bezelStyle = .roundedBezel
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.numberOfVisibleItems = 5
    }

    private func parseAddress() -> (host: String, port: UInt16)? {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else {
            return nil
        }
        return (String(parts[0]), port)
    }

    private func flashInvalidField() {
        let original = addressField.textColor
        addressField.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.addressField.textColor = original
        }
    }

    private static func dotImage(color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private final class ActionTarget: NSObject {
        var action: (() -> Void)?

        @objc func invoke() {
            action?()
        }
    }
}

private final class ConnectionManager {
    private var host: String
    private var port: UInt16
    private let queue = DispatchQueue(label: "kvm.connection.queue")
    private var connection: NWConnection?
    private var ready = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var receiveBuffer = Data()
    var shouldReconnect: (() -> Bool)?
    var onStateChange: ((ConnectionState) -> Void)?
    /// Peer → Mac clipboard text (decoded). Delivered on the main queue.
    var onClipboard: ((String) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func ensureConnected() {
        queue.async {
            guard self.connection == nil else {
                return
            }

            // Default TCP parameters leave Nagle's algorithm on, which coalesces
            // small writes (every mouse-move packet here is tiny) and waits up
            // to ~200ms for more data or an ACK before sending. That's the
            // classic cause of choppy, bursty input forwarding. Disabling it
            // and marking the traffic as interactive fixes it without needing
            // any client-side interpolation.
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 5
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .responsiveData

            let endpointPort = NWEndpoint.Port(rawValue: self.port)!
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: endpointPort, using: parameters)
            self.connection = connection
            self.ready = false
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.publish(.connecting)

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }

            connection.start(queue: self.queue)
        }
    }

    func send(_ line: String) {
        queue.async {
            guard self.ready, let connection = self.connection else {
                return
            }

            let payload = Data((line + "\n").utf8)
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    appLog("Send error: \(error)")
                }
            })
        }
    }

    func disconnect() {
        queue.async {
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connection?.cancel()
            self.connection = nil
            self.ready = false
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.publish(.disconnected)
        }
    }

    func updateEndpoint(host: String, port: UInt16) {
        queue.async {
            self.host = host
            self.port = port
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connection?.cancel()
            self.connection = nil
            self.ready = false
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.publish(.disconnected)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing:
            publish(.connecting)
        case .ready:
            ready = true
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            publish(.connected)
            if let connection {
                startReceive(on: connection)
            }
        case .waiting(let error):
            ready = false
            publish(.connecting)
            scheduleReconnectIfNeeded(reason: error.localizedDescription)
        case .failed(let error):
            ready = false
            connection = nil
            receiveBuffer.removeAll(keepingCapacity: true)
            publish(.disconnected)
            scheduleReconnectIfNeeded(reason: error.localizedDescription)
        case .cancelled:
            ready = false
            connection = nil
            receiveBuffer.removeAll(keepingCapacity: true)
            publish(.disconnected)
        @unknown default:
            ready = false
        }
    }

    private func startReceive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consumeIncoming(data)
            }
            if let error {
                appLog("Receive error: \(error)")
                return
            }
            if isComplete {
                return
            }
            // Only continue if this is still the active connection.
            guard self.connection === connection else { return }
            self.startReceive(on: connection)
        }
    }

    private func consumeIncoming(_ data: Data) {
        receiveBuffer.append(data)
        let newline = Data([0x0A])
        while let range = receiveBuffer.range(of: newline) {
            let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
            if lineData.isEmpty { continue }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleIncomingLine(line)
        }
        // Bound a pathological unterminated buffer.
        let maxBuffered = 1024 * 1024
        if receiveBuffer.count > maxBuffered {
            receiveBuffer.removeAll(keepingCapacity: true)
            appLog("Receive buffer overflow; discarded")
        }
    }

    private func handleIncomingLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.first == "clipboard", parts.count == 2 else {
            appLog("clipboard: ignored inbound line \(parts.first.map(String.init) ?? "?")")
            return
        }
        let encoded = String(parts[1])
        guard let payload = Data(base64Encoded: encoded),
              payload.count <= ClipboardBridge.maxUTF8Bytes,
              let text = String(data: payload, encoding: .utf8) else {
            appLog("clipboard: ignored invalid/oversized payload (\(encoded.count) b64 chars)")
            return
        }
        appLog("clipboard: received \(text.utf8.count) bytes from PC")
        DispatchQueue.main.async { [weak self] in
            self?.onClipboard?(text)
        }
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard shouldReconnect?() == true else {
            return
        }

        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.connection == nil else { return }
                self.ensureConnected()
            }
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        appLog("Connection retry scheduled: \(reason)")
    }

    private func publish(_ state: ConnectionState) {
        onStateChange?(state)
    }
}

/// Text clipboard for the Off ↔ Forwarding workflow:
/// - While forwarding: keep both sides in sync
/// - On Start: push Mac clipboard to the PC
/// - On Stop: still accept one last PC → Mac push so paste works after return
private final class ClipboardBridge {
    static let maxUTF8Bytes = 512 * 1024

    private let connection: ConnectionManager
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSentText: String?
    private var suppressText: String?
    private var forwarding = false

    init(connection: ConnectionManager) {
        self.connection = connection
    }

    func setForwarding(_ forwarding: Bool) {
        if forwarding {
            appLog("clipboard: forwarding on — pushing Mac clipboard")
            startPolling()
        } else {
            // Ask the PC for its clipboard before we go Off, so paste works
            // after Stop. Keep receiving; only stop outbound polling.
            appLog("clipboard: forwarding off — requesting PC clipboard")
            connection.send("clipboard-request")
            stopPolling()
        }
    }

    /// Apply peer text even after Stop so the PC flush can land for paste.
    func applyRemote(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        suppressText = text
        lastSentText = text
        appLog("clipboard: applied remote text (\(text.utf8.count) bytes)")
    }

    private func startPolling() {
        stopPolling()
        forwarding = true
        lastChangeCount = NSPasteboard.general.changeCount
        poll(force: true)
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        forwarding = false
    }

    private func poll(force: Bool) {
        guard forwarding else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        if force == false {
            guard changeCount != lastChangeCount else { return }
        }
        lastChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string), text.isEmpty == false else {
            if force {
                appLog("clipboard: Mac pasteboard empty, nothing to push")
            }
            return
        }
        if text == suppressText {
            return
        }
        if force == false, text == lastSentText {
            return
        }
        let utf8Count = text.utf8.count
        guard utf8Count <= Self.maxUTF8Bytes else {
            appLog("clipboard: skipped oversized local paste (\(utf8Count) bytes)")
            return
        }

        let encoded = Data(text.utf8).base64EncodedString()
        lastSentText = text
        suppressText = nil
        connection.send("clipboard \(encoded)")
        appLog("clipboard: sent local text (\(utf8Count) bytes)")
    }
}

private final class MouseEventRouter {
    private let state: SharedState
    private let connection: ConnectionManager
    /// Quartz-space point we warp back to while capturing, so the Mac cursor
    /// can't drift even if CGAssociate is ignored (common when the control
    /// window is closed and we're only a menu-bar agent).
    private var cursorPin: CGPoint?

    init(state: SharedState, connection: ConnectionManager) {
        self.state = state
        self.connection = connection
    }

    func pinCursorToCurrentPosition() {
        cursorPin = CGEvent(source: nil)?.location
    }

    func clearCursorPin() {
        cursorPin = nil
    }

    /// Forwards the event to the remote host once actually connected, and
    /// reports whether the caller should suppress it locally. Returning
    /// `false` while merely "armed" but not yet connected lets the Mac
    /// behave normally instead of freezing input during a slow connect.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard state.isCapturing() else {
            return false
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            connection.send("move \(dx) \(dy)")
            if let pin = cursorPin {
                CGWarpMouseCursorPosition(pin)
            }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            let direction = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown) ? "down" : "up"
            connection.send("button \(buttonNumber) \(direction)")
        case .scrollWheel:
            let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if horizontal != 0 || vertical != 0 {
                connection.send("scroll \(horizontal) \(vertical)")
            }
        default:
            break
        }

        return true
    }
}

/// Translates physical key presses into what the Mac's *current keyboard
/// layout* actually produces (so a Spanish LatAm layout's dedicated ñ key, or
/// dead-key accents, resolve correctly) and forwards that to the remote host.
/// Plain character keys are sent as literal Unicode text (layout-independent
/// on the receiving end); Enter/arrows/modifiers/shortcuts are sent as real
/// virtual-key presses so the target app recognizes them as that key.
private final class KeyboardEventRouter {
    private let state: SharedState
    private let connection: ConnectionManager
    private var deadKeyState: UInt32 = 0
    private var pendingText: [CGKeyCode: String] = [:]
    private var toggleHotKey = HotKeyBinding.default
    /// Fired from the event tap when the toggle is pressed while capturing,
    /// so we can swallow the key (no local/remote character) and still stop.
    var onToggleHotKey: (() -> Void)?
    private var toggleHotKeyPressed = false

    // Modifier-down events are held here instead of being sent immediately.
    // If the next event turns out to be the app's own toggle hotkey, we drop
    // them silently; otherwise we flush them right before the key they're
    // modifying. This is what stops the toggle hotkey's own modifier presses
    // from leaking to the remote host as an unmatched "key down".
    private var armedModifiers: [CGKeyCode: UInt16] = [:]

    // Modifiers we've actually confirmed sending "down" for. A modifier can
    // be physically held (e.g. Option, from habit, or Cmd/Option already
    // down when capture turns on) without us ever having sent its "down" ,
    // forwarding its eventual "up" anyway sends Windows an unmatched key
    // release, and for the Windows key specifically that's enough to pop
    // open the Start Menu and steal focus, which looked like a "stuck" key.
    // Only release what we know we pressed.
    private var sentModifierKeyCodes: Set<CGKeyCode> = []

    init(state: SharedState, connection: ConnectionManager) {
        self.state = state
        self.connection = connection
    }

    func setToggleHotKey(_ binding: HotKeyBinding) {
        toggleHotKey = binding
        toggleHotKeyPressed = false
    }

    /// Called when capture turns off. Releases any modifier we told Windows
    /// was "down" but never got to release (e.g. capture was stopped mid
    /// key-combo) so it doesn't stay stuck down on the remote side.
    func releaseAllHeldModifiers() {
        for keyCode in sentModifierKeyCodes {
            guard let vk = Self.modifierVirtualCodes[keyCode] else { continue }
            appLog("keyboard: vk \(vk) up (released on capture end)")
            connection.send("vk \(vk) up")
        }
        sentModifierKeyCodes.removeAll()
        armedModifiers.removeAll()
        toggleHotKeyPressed = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Unconditional, regardless of capture state, this is the ground
        // truth for whether the tap is receiving keyboard events at all.
        // Mouse-only taps need just Accessibility permission; keyDown/keyUp
        // specifically also require Input Monitoring, a separate grant. If
        // this line never appears for plain letter keys while flagsChanged
        // lines do, that's the tell: Input Monitoring isn't actually active.
        let loggedKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        appLog("keyboard: tap saw type=\(type.rawValue) keyCode=\(loggedKeyCode) capturing=\(state.isCapturing())")

        // Always swallow the toggle hotkey — even when Off. Combos like ⇧§
        // insert a real character (° on many layouts); if we only intercept
        // while capturing, pressing the hotkey to Start types into whatever
        // app is focused. Cmd+Option+K never showed this because it doesn't
        // produce text. HotKeyController won't see a swallowed event, so the
        // callback is fired from here on keyDown.
        if isToggleHotkeyKeyEvent(type: type, event: event) {
            if !armedModifiers.isEmpty {
                appLog("keyboard: dropped toggle-hotkey modifiers \(armedModifiers.values.map { String($0) })")
            }
            armedModifiers.removeAll()
            if type == .keyDown {
                if toggleHotKeyPressed == false {
                    toggleHotKeyPressed = true
                    appLog("keyboard: toggle hotkey swallowed + fired (capturing=\(state.isCapturing()))")
                    onToggleHotKey?()
                }
            } else {
                toggleHotKeyPressed = false
            }
            return true
        }

        guard state.isCapturing() else {
            return false
        }

        switch type {
        case .keyDown, .keyUp:
            handleKey(event: event, isDown: type == .keyDown)
        case .flagsChanged:
            handleFlagsChanged(event: event)
        default:
            break
        }

        return true
    }

    private func isToggleHotkeyKeyEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else {
            return false
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let matched = toggleHotKey.matches(keyCode: keyCode, flags: event.flags)
        if matched == false, UInt16(keyCode) == toggleHotKey.keyCode {
            appLog("keyboard: toggle keyCode matched but modifiers did not (flags=\(event.flags.rawValue) want=\(toggleHotKey.displayString))")
        }
        return matched
    }

    private func handleKey(event: CGEvent, isDown: Bool) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Deliberately NOT including Option/Alt here. On Spanish/European
        // layouts, Option/AltGr is how you type ordinary punctuation that
        // has no direct key of its own (backslash, pipe, @, ~, brackets,
        // etc.), treating it as a shortcut modifier broke typing those
        // characters, which matters far more than Alt+letter menu shortcuts
        // working on Windows. That's a known limitation for now.
        let isShortcutContext = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if let vk = Self.controlKeyVirtualCodes[keyCode] {
            flushArmedModifiers()
            appLog("keyboard: vk \(vk) \(isDown ? "down" : "up")")
            connection.send("vk \(vk) \(isDown ? "down" : "up")")
            return
        }

        if isShortcutContext, let vk = Self.shortcutVirtualCodes[keyCode] {
            flushArmedModifiers()
            appLog("keyboard: vk \(vk) \(isDown ? "down" : "up") (shortcut)")
            connection.send("vk \(vk) \(isDown ? "down" : "up")")
            return
        }

        if isDown {
            guard let text = unicodeString(for: keyCode, flags: flags), !text.isEmpty else {
                // A dead key (e.g. the accent key alone) resolves to nothing
                // until the following key completes it, nothing to send yet.
                appLog("keyboard: keyCode \(keyCode) produced no text (dead key or unmapped)")
                return
            }
            // Any armed modifier (Shift, or Option/AltGr on layouts where it
            // produces punctuation like backslash) is already fully baked
            // into this character, drop it silently rather than also
            // forwarding it as a separate press. For Shift that's just
            // redundant; for Alt it could actually confuse the receiving
            // app mid-keystroke.
            armedModifiers.removeAll()
            let hex = Self.hexEncode(text)
            pendingText[keyCode] = hex
            appLog("keyboard: text \(hex) down")
            connection.send("text \(hex) down")
        } else {
            guard let hex = pendingText.removeValue(forKey: keyCode) else {
                return
            }
            appLog("keyboard: text \(hex) up")
            connection.send("text \(hex) up")
        }
    }

    /// Modifiers only get flushed automatically ahead of a *keyboard* key ,
    /// but Ctrl/Alt held for a mouse action (Ctrl+click, Alt+drag, etc.)
    /// would otherwise never get sent, since nothing keyboard-side ever
    /// triggers the flush. The tap dispatcher calls this ahead of every
    /// mouse event too, so Windows finds out about a held modifier before
    /// the click/drag it's modifying arrives.
    fileprivate func flushArmedModifiersForNonKeyActivity() {
        flushArmedModifiers()
    }

    private func flushArmedModifiers() {
        guard !armedModifiers.isEmpty else {
            return
        }
        for (keyCode, vk) in armedModifiers {
            appLog("keyboard: vk \(vk) down (flushed modifier)")
            connection.send("vk \(vk) down")
            sentModifierKeyCodes.insert(keyCode)
        }
        armedModifiers.removeAll()
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard let vk = Self.modifierVirtualCodes[keyCode] else {
            return
        }

        let isDown = Self.modifierIsCurrentlyDown(keyCode: keyCode, flags: event.flags)

        if isDown {
            armedModifiers[keyCode] = vk
            return
        }

        if armedModifiers.removeValue(forKey: keyCode) != nil {
            // Released while still only armed (never flushed by a following
            // key). If it were part of the toggle hotkey or a real shortcut,
            // that following key would already have cleared or flushed it ,
            // so reaching here means it was genuinely tapped alone (e.g. a
            // solo Windows-key tap to open the Start Menu). Send the full
            // down+up now rather than dropping it.
            appLog("keyboard: vk \(vk) down+up (standalone tap)")
            connection.send("vk \(vk) down")
            connection.send("vk \(vk) up")
            return
        }

        guard sentModifierKeyCodes.remove(keyCode) != nil else {
            // We never confirmed sending its "down" (e.g. it was already
            // held before capture turned on), forwarding this "up" alone
            // would tell Windows a key was released that, as far as it
            // knows, was never pressed. For the Windows key specifically
            // that's enough to pop the Start Menu, so skip it.
            appLog("keyboard: suppressed unmatched vk \(vk) up")
            return
        }

        appLog("keyboard: vk \(vk) up")
        connection.send("vk \(vk) up")
    }

    /// Uses the Mac's active input source (e.g. Spanish LatAm) to resolve
    /// what this physical key actually produces, including dead-key accent
    /// composition threaded across calls via `deadKeyState`.
    private func unicodeString(for keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> String? in
            guard let keyboardLayoutPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }

            var modifierKeyState: UInt32 = 0
            if flags.contains(.maskShift) { modifierKeyState |= UInt32(shiftKey) }
            if flags.contains(.maskAlphaShift) { modifierKeyState |= UInt32(alphaLock) }
            if flags.contains(.maskAlternate) { modifierKeyState |= UInt32(optionKey) }
            modifierKeyState = (modifierKeyState >> 8) & 0xFF

            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0

            let status = UCKeyTranslate(
                keyboardLayoutPtr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(0),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else {
                return nil
            }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    private static func hexEncode(_ text: String) -> String {
        text.utf16.map { String(format: "%04X", $0) }.joined(separator: ",")
    }

    private static func modifierIsCurrentlyDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Command, kVK_RightCommand:
            return flags.contains(.maskCommand)
        case kVK_CapsLock:
            return flags.contains(.maskAlphaShift)
        default:
            return false
        }
    }

    // Keys whose meaning depends on being recognized as that specific key,
    // not on the character they'd otherwise type, always sent as real
    // virtual-key presses regardless of modifiers.
    private static let controlKeyVirtualCodes: [CGKeyCode: UInt16] = [
        CGKeyCode(kVK_Return): 0x0D,
        CGKeyCode(kVK_Tab): 0x09,
        CGKeyCode(kVK_Space): 0x20,
        CGKeyCode(kVK_Delete): 0x08,
        CGKeyCode(kVK_ForwardDelete): 0x2E,
        CGKeyCode(kVK_Escape): 0x1B,
        CGKeyCode(kVK_LeftArrow): 0x25,
        CGKeyCode(kVK_UpArrow): 0x26,
        CGKeyCode(kVK_RightArrow): 0x27,
        CGKeyCode(kVK_DownArrow): 0x28,
        CGKeyCode(kVK_Home): 0x24,
        CGKeyCode(kVK_End): 0x23,
        CGKeyCode(kVK_PageUp): 0x21,
        CGKeyCode(kVK_PageDown): 0x22,
        CGKeyCode(kVK_F1): 0x70,
        CGKeyCode(kVK_F2): 0x71,
        CGKeyCode(kVK_F3): 0x72,
        CGKeyCode(kVK_F4): 0x73,
        CGKeyCode(kVK_F5): 0x74,
        CGKeyCode(kVK_F6): 0x75,
        CGKeyCode(kVK_F7): 0x76,
        CGKeyCode(kVK_F8): 0x77,
        CGKeyCode(kVK_F9): 0x78,
        CGKeyCode(kVK_F10): 0x79,
        CGKeyCode(kVK_F11): 0x7A,
        CGKeyCode(kVK_F12): 0x7B,
        CGKeyCode(kVK_CapsLock): 0x14
    ]

    // The modifier keys themselves, reported via flagsChanged rather than
    // keyDown/keyUp.
    private static let modifierVirtualCodes: [CGKeyCode: UInt16] = [
        CGKeyCode(kVK_Shift): 0x10,
        CGKeyCode(kVK_RightShift): 0x10,
        CGKeyCode(kVK_Control): 0x11,
        CGKeyCode(kVK_RightControl): 0x11,
        CGKeyCode(kVK_Option): 0x12,
        CGKeyCode(kVK_RightOption): 0x12,
        CGKeyCode(kVK_Command): 0x5B,
        CGKeyCode(kVK_RightCommand): 0x5B,
        CGKeyCode(kVK_CapsLock): 0x14
    ]

    // Letters/digits, used only when Cmd or Ctrl is held (i.e. a shortcut),
    // so Ctrl/Cmd+C etc. reach Windows as a real key combo instead of text.
    // CGKeyCode reflects physical key position, which matches US layout for
    // letters/digits on virtually all Latin-script layouts including Spanish
    // LatAm, so this table doesn't need to vary by layout.
    private static let shortcutVirtualCodes: [CGKeyCode: UInt16] = {
        var map: [CGKeyCode: UInt16] = [:]
        let letters: [Int] = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y, kVK_ANSI_Z
        ]
        for (index, keyCode) in letters.enumerated() {
            // Windows VK codes for letters are literally their ASCII
            // uppercase values (0x41 'A' ... 0x5A 'Z').
            map[CGKeyCode(keyCode)] = UInt16(65 + index)
        }

        let digits: [Int] = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        for (index, keyCode) in digits.enumerated() {
            // Same for digits (0x30 '0' ... 0x39 '9').
            map[CGKeyCode(keyCode)] = UInt16(48 + index)
        }

        return map
    }()
}

/// Owns the single CGEventTap covering both mouse and keyboard, dispatching
/// each event to the right router. One tap is required rather than one per
/// router since a process may only install a limited number of event taps.
private final class InputTapController {
    private let mouseRouter: MouseEventRouter
    private let keyboardRouter: KeyboardEventRouter

    init(mouseRouter: MouseEventRouter, keyboardRouter: KeyboardEventRouter) {
        self.mouseRouter = mouseRouter
        self.keyboardRouter = keyboardRouter
    }

    func installEventTap() -> CFMachPort? {
        let mouseMask =
            CGEventMask(1 << CGEventType.mouseMoved.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        let keyboardMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let mask = mouseMask | keyboardMask

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<InputTapController>.fromOpaque(userInfo).takeUnretainedValue()
            let consumedLocally = controller.route(type: type, event: event)
            if consumedLocally {
                // Forwarding is active: swallow the event so the Mac's own
                // cursor/keyboard focus don't also react. A KVM should hand
                // off control, not mirror it.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: userInfo
        )

        guard let tap else {
            return nil
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    private func route(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return keyboardRouter.handle(type: type, event: event)
        default:
            keyboardRouter.flushArmedModifiersForNonKeyActivity()
            return mouseRouter.handle(type: type, event: event)
        }
    }
}

private final class HotKeyController {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var togglePressed = false
    private var suspended = false
    private var binding = HotKeyBinding.default

    func registerToggleHotKey(binding: HotKeyBinding, callback: @escaping () -> Void) {
        unregister()
        self.binding = binding
        let keyCode = binding.keyCode

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.suspended == false else { return }
            if event.type == .keyUp && event.keyCode == keyCode {
                self.togglePressed = false
                return
            }

            if event.type == .keyDown && self.binding.matches(event) {
                guard !self.togglePressed else { return }
                self.togglePressed = true
                callback()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if self.suspended {
                return event
            }
            if event.type == .keyUp && event.keyCode == keyCode {
                self.togglePressed = false
                return event
            }

            if event.type == .keyDown && self.binding.matches(event) {
                guard !self.togglePressed else { return event }
                self.togglePressed = true
                callback()
                return nil
            }
            return event
        }
    }

    /// While the hotkey field is recording, ignore the previous binding so it
    /// can't toggle forwarding underneath the recorder.
    func setSuspended(_ value: Bool) {
        suspended = value
        togglePressed = false
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        togglePressed = false
        suspended = false
    }
}

final class SkeletonKeyAppDelegate: NSObject, NSApplicationDelegate {
    private let state = SharedState()
    private var host = "192.168.0.100"
    private var port: UInt16 = 12653
    private var statusController: StatusBarController!
    private var controlWindow: ControlWindowController!
    private var connectionManager: ConnectionManager!
    private var clipboardBridge: ClipboardBridge!
    private var mouseRouter: MouseEventRouter!
    private var keyboardRouter: KeyboardEventRouter!
    private var inputTapController: InputTapController!
    private let hotKeys = HotKeyController()
    private var hotKeyBinding = SavedHotKey.load()
    private var eventTap: CFMachPort?
    private var eventTapRetryTimer: Timer?
    private var permissionPrompted = false
    private var isCapturing = false
    /// Set around intentional endpoint changes so a reconnect doesn't disarm
    /// a Start Forwarding that just armed capture.
    private var ignoreDisconnectDisarm = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: stay out of the Dock. The status item is the
        // persistent home; the control window is summoned on demand.
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        let saved = SavedEndpoint.load(defaultHost: host, defaultPort: port)
        host = saved.host
        port = saved.port

        if let cliHost = CommandLine.arguments.dropFirst().first {
            host = cliHost
        }
        if let cliPort = CommandLine.arguments.dropFirst(2).first.flatMap({ UInt16($0) }) {
            port = cliPort
        }

        statusController = StatusBarController()
        controlWindow = ControlWindowController()
        connectionManager = ConnectionManager(host: host, port: port)
        clipboardBridge = ClipboardBridge(connection: connectionManager)
        connectionManager.onClipboard = { [weak self] text in
            self?.clipboardBridge.applyRemote(text)
        }
        mouseRouter = MouseEventRouter(state: state, connection: connectionManager)
        keyboardRouter = KeyboardEventRouter(state: state, connection: connectionManager)
        keyboardRouter.setToggleHotKey(hotKeyBinding)
        keyboardRouter.onToggleHotKey = { [weak self] in
            self?.toggleRemoteMode()
        }
        inputTapController = InputTapController(mouseRouter: mouseRouter, keyboardRouter: keyboardRouter)

        // The connection is a background service: Start Forwarding (re)applies
        // the endpoint and arms capture; actual cursor takeover waits until
        // SharedState.isCapturing() (armed + genuinely connected).
        connectionManager.shouldReconnect = { [weak self] in
            self?.state.isRemoteActive() == true
        }
        connectionManager.onStateChange = { [weak self] connectionState in
            guard let self else { return }
            let previous = self.state.connectionStateValue()
            self.state.setConnectionState(connectionState)

            // A dropped live session must not leave capture armed, or the next
            // successful reconnect would instantly take over the mouse. Stay
            // armed through connecting after Start, and through intentional
            // endpoint changes that briefly disconnect.
            if previous == .connected && connectionState != .connected {
                if self.ignoreDisconnectDisarm {
                    self.ignoreDisconnectDisarm = false
                    appLog("remoteActive kept through intentional reconnect")
                } else if self.state.isRemoteActive() {
                    self.state.setRemoteActive(false)
                    appLog("remoteActive=false (cleared on disconnect)")
                }
            }

            self.refreshCaptureState()
            let remoteActive = self.state.isRemoteActive()
            self.statusController.update(remoteActive: remoteActive, connectionState: connectionState)
            DispatchQueue.main.async {
                self.controlWindow.updateStatus(remoteActive: remoteActive, connectionState: connectionState)
            }
        }

        statusController.update(remoteActive: false, connectionState: .disconnected)
        statusController.setShowWindowAction { [weak self] in
            self?.controlWindow.showWindow(nil)
        }
        statusController.setQuitAction {
            NSApp.terminate(nil)
        }
        controlWindow.setToggleAction { [weak self] in
            self?.toggleRemoteMode()
        }
        controlWindow.setQuitAction {
            NSApp.terminate(nil)
        }
        controlWindow.setEndpoint(host: host, port: port)
        controlWindow.setHotKey(hotKeyBinding)
        controlWindow.onHotKeyChanged = { [weak self] binding in
            self?.updateHotKey(binding)
        }
        controlWindow.onHotKeyRecordingChanged = { [weak self] recording in
            self?.hotKeys.setSuspended(recording)
        }
        controlWindow.updateStatus(remoteActive: false, connectionState: .disconnected)
        controlWindow.updateHistory(SavedEndpoint.loadHistory())
        controlWindow.canDemoteToAccessory = { [weak self] in
            !(self?.isCapturing ?? false)
        }

        requestAccessibilityAccess()
        requestInputMonitoringAccess()
        installEventTapOrRetry()
        registerCurrentHotKey()

        appLog("SkeletonKey ready. Toggle with \(hotKeyBinding.displayString).")
        appLog("Host: \(host) Port: \(port)")
        controlWindow.showWindow(nil)
    }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag == false {
            controlWindow.showWindow(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTapRetryTimer?.invalidate()
        connectionManager.disconnect()
        hotKeys.unregister()
        // Safety net: never leave the Mac's own cursor disassociated / hidden
        // if we quit while forwarding was active.
        CGAssociateMouseAndMouseCursorPosition(1)
        if isCapturing {
            CGDisplayShowCursor(kCGNullDirectDisplay)
        }
    }

    @objc private func toggleRemoteMode() {
        if state.isRemoteActive() {
            stopForwarding()
        } else {
            startForwarding()
        }
    }

    private func startForwarding() {
        guard let endpoint = controlWindow.currentEndpoint() else {
            controlWindow.flashInvalidAddress()
            appLog("start ignored: invalid endpoint")
            return
        }

        let endpointChanged = endpoint.host != host || endpoint.port != port
        if endpointChanged {
            applyEndpoint(host: endpoint.host, port: endpoint.port)
        } else if state.connectionStateValue() != .connected {
            connectionManager.ensureConnected()
        }

        state.setRemoteActive(true)
        refreshCaptureState()

        let connectionState = state.connectionStateValue()
        statusController.update(remoteActive: true, connectionState: connectionState)
        controlWindow.updateStatus(remoteActive: true, connectionState: connectionState)
        appLog("remoteActive=true (start forwarding)")
    }

    private func stopForwarding() {
        state.setRemoteActive(false)
        refreshCaptureState()

        let connectionState = state.connectionStateValue()
        statusController.update(remoteActive: false, connectionState: connectionState)
        controlWindow.updateStatus(remoteActive: false, connectionState: connectionState)
        appLog("remoteActive=false (stop forwarding)")
    }

    private func updateHotKey(_ binding: HotKeyBinding) {
        hotKeyBinding = binding
        SavedHotKey.save(binding)
        keyboardRouter.setToggleHotKey(binding)
        controlWindow.setHotKey(binding)
        registerCurrentHotKey()
        appLog("Hotkey updated to \(binding.displayString)")
    }

    private func registerCurrentHotKey() {
        hotKeys.registerToggleHotKey(binding: hotKeyBinding) { [weak self] in
            self?.toggleRemoteMode()
        }
    }

    /// Disassociates (or restores) the Mac's cursor from the mouse hardware
    /// based on whether we're genuinely connected right now, not just whether
    /// the user asked to forward. Called both when the user toggles and
    /// whenever the connection state itself changes, so a drop mid-session
    /// hands control straight back to the Mac.
    private func refreshCaptureState() {
        let apply = { [weak self] in
            guard let self else { return }
            let capturing = self.state.isCapturing()
            guard capturing != self.isCapturing else { return }
            self.isCapturing = capturing

            if capturing {
                // Hotkey often fires while another app is frontmost and our
                // control window is closed (.accessory). CGAssociate silently
                // no-ops unless we're active — activate without reordering
                // the closed window front (no Dock/window jump). Pin+warp is
                // the backup so the Mac cursor still can't drift.
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
                NSApp.activate(ignoringOtherApps: true)
                CGAssociateMouseAndMouseCursorPosition(0)
                CGDisplayHideCursor(kCGNullDirectDisplay)
                self.mouseRouter.pinCursorToCurrentPosition()
            } else {
                self.mouseRouter.clearCursorPin()
                CGAssociateMouseAndMouseCursorPosition(1)
                CGDisplayShowCursor(kCGNullDirectDisplay)
                self.keyboardRouter.releaseAllHeldModifiers()
                // Window still closed → back to menu-bar-only.
                if self.controlWindow.window?.isVisible != true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }

            // The TCP connection itself is a persistent background service
            // that stays up regardless of the hotkey, so Windows can't
            // infer capture state from socket connect/disconnect alone —
            // tell it explicitly.
            // Clipboard handoff before capturing-off: request PC clipboard,
            // then tell Windows capture ended.
            if capturing == false {
                self.clipboardBridge.setForwarding(false)
            }
            self.connectionManager.send("capturing \(capturing ? "on" : "off")")
            if capturing {
                self.clipboardBridge.setForwarding(true)
            }
            appLog("capturing=\(capturing)")
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// The app never had a standard application menu, so Cmd+Q had nothing
    /// to bind to (it's unrelated to mouse capture). This gives it the usual
    /// "AppName / Quit AppName Cmd+Q" menu so Cmd+Q works whenever
    /// SkeletonKey is the active app on the Mac, exactly like any other Mac
    /// app.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit SkeletonKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func applyEndpoint(host newHost: String, port newPort: UInt16) {
        if state.connectionStateValue() == .connected {
            ignoreDisconnectDisarm = true
        }
        host = newHost
        port = newPort
        connectionManager.updateEndpoint(host: newHost, port: newPort)
        controlWindow.setEndpoint(host: newHost, port: newPort)
        SavedEndpoint.save(host: newHost, port: newPort)
        SavedEndpoint.recordHistory(host: newHost, port: newPort)
        controlWindow.updateHistory(SavedEndpoint.loadHistory())
        appLog("Endpoint updated. Host: \(newHost) Port: \(newPort)")
        connectionManager.ensureConnected()
    }

    private func installEventTapOrRetry() {
        if let tap = inputTapController.installEventTap() {
            eventTap = tap
            eventTapRetryTimer?.invalidate()
            eventTapRetryTimer = nil
            appLog("Input event tap installed.")
            return
        }

        appLog("Failed to create event tap. Waiting for Input Monitoring / Accessibility permission.")

        if permissionPrompted == false {
            permissionPrompted = true
            requestAccessibilityAccess()
            requestInputMonitoringAccess()
        }

        if eventTapRetryTimer == nil {
            eventTapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.installEventTapOrRetry()
            }
        }
    }
}
