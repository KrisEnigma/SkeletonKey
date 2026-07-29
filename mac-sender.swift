import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Network

private let appLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/KrisKVM/app.log")

private func appLog(_ line: String) {
    let message = "[KrisKVM] \(line)\n"
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
    // This does NOT show a system alert like Accessibility does — it just
    // silently adds KrisKVM to Privacy & Security > Input Monitoring in an
    // unchecked state. It has to be enabled manually there, then the app
    // relaunched, before keyboard events will actually reach the tap.
    _ = CGRequestListenEventAccess()
}

private let toggleKeyCode: UInt32 = UInt32(kVK_ANSI_K)

struct HistoryEntry: Equatable {
    let host: String
    let port: UInt16

    var display: String { "\(host):\(port)" }
}

private enum SavedEndpoint {
    private static let hostKey = "KrisKVM.savedHost"
    private static let portKey = "KrisKVM.savedPort"
    private static let historyKey = "KrisKVM.recentEndpoints"
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
    /// actually live — not merely while attempting/retrying. Input capture
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

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage(color: .systemRed)
            button.imagePosition = .imageOnly
            button.toolTip = "KrisKVM"
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
        statusItem.menu = menu
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

            let color: NSColor
            if remoteActive {
                color = connectionState == .connected ? .systemGreen : .systemOrange
            } else {
                color = .systemRed
            }

            self.statusItem.button?.image = Self.statusImage(color: color)
            self.statusItem.button?.toolTip = remoteActive ? "KrisKVM: active" : "KrisKVM: inactive"
        }
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

}

private final class ControlWindowController: NSWindowController, NSComboBoxDelegate {
    private let addressField = NSComboBox()
    private let statusDotView = NSImageView()
    private let statusTextField = NSTextField(labelWithString: "Off")
    private let statusPill = NSView()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let toggleButton = NSButton(title: "Start Forwarding", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let applyTarget = ActionTarget()
    private let toggleTarget = ActionTarget()
    private let quitTarget = ActionTarget()
    private var historyEntries: [HistoryEntry] = []
    private var historySelectAction: ((String, UInt16) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KrisKVM"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setToggleAction(_ action: @escaping () -> Void) {
        toggleTarget.action = action
    }

    func setApplyAction(_ action: @escaping (String, UInt16) -> Void) {
        applyTarget.action = { [weak self] in
            guard let self else { return }
            guard let (host, port) = self.parseAddress() else {
                NSSound(named: "Tink")?.play()
                self.flashInvalidField()
                return
            }
            action(host, port)
        }
    }

    func setQuitAction(_ action: @escaping () -> Void) {
        quitTarget.action = action
    }

    func setHistorySelectAction(_ action: @escaping (String, UInt16) -> Void) {
        historySelectAction = action
    }

    func setEndpoint(host: String, port: UInt16) {
        addressField.stringValue = "\(host):\(port)"
    }

    func updateHistory(_ entries: [HistoryEntry]) {
        historyEntries = entries
        addressField.removeAllItems()
        addressField.addItems(withObjectValues: entries.map { $0.display })
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = addressField.indexOfSelectedItem
        guard index >= 0, index < historyEntries.count else { return }
        let entry = historyEntries[index]
        addressField.stringValue = entry.display
        historySelectAction?(entry.host, entry.port)
    }

    func updateStatus(remoteActive: Bool, connectionState: ConnectionState) {
        let color: NSColor
        let statusText: String

        switch (remoteActive, connectionState) {
        case (false, _):
            color = .systemRed
            statusText = "Off"
        case (true, .connecting):
            color = .systemOrange
            statusText = "Connecting"
        case (true, .connected):
            color = .systemGreen
            statusText = "Connected"
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
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
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

        let appNameLabel = NSTextField(labelWithString: "KRISKVM")
        appNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appNameLabel.textColor = .tertiaryLabelColor

        statusDotView.image = Self.dotImage(color: .systemRed, diameter: 8)
        statusTextField.font = .systemFont(ofSize: 13, weight: .semibold)
        statusTextField.textColor = .systemRed

        let pillStack = NSStackView(views: [statusDotView, statusTextField])
        pillStack.orientation = .horizontal
        pillStack.spacing = 6
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 12
        statusPill.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
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

        // Endpoint card: one address field that doubles as the recent-history
        // picker (native combo box dropdown, arrow lives right in the input)
        // plus a real Apply button for typed-in addresses.
        let settingsCard = NSView()
        settingsCard.wantsLayer = true
        settingsCard.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        settingsCard.layer?.cornerRadius = 12
        settingsCard.translatesAutoresizingMaskIntoConstraints = false

        let sectionLabel = makeFieldLabel("Endpoint")

        configureAddressField(addressField, placeholder: "host:port — e.g. 0.tcp.ngrok.io:12653")
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false

        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .regular
        applyButton.keyEquivalent = "\r"
        applyButton.target = applyTarget
        applyButton.action = #selector(ActionTarget.invoke)
        applyButton.toolTip = "Apply this host and port"
        applyButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let applyRowSpacer = NSView()
        let applyRow = NSStackView(views: [applyRowSpacer, applyButton])
        applyRow.orientation = .horizontal
        applyRow.alignment = .centerY
        applyRow.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = NSStackView(views: [sectionLabel, addressField, applyRow])
        cardStack.orientation = .vertical
        cardStack.spacing = 10
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        settingsCard.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: settingsCard.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: settingsCard.bottomAnchor, constant: -16),
            addressField.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor),
            addressField.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor),
            applyRow.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor),
            applyRow.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor)
        ])

        toggleButton.target = toggleTarget
        toggleButton.action = #selector(ActionTarget.invoke)
        toggleButton.isBordered = false
        toggleButton.wantsLayer = true
        toggleButton.layer?.cornerRadius = 20
        toggleButton.layer?.backgroundColor = NSColor.systemGreen.cgColor
        styleCapsuleTitle(toggleButton, text: "Start Forwarding")
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        quitButton.target = quitTarget
        quitButton.action = #selector(ActionTarget.invoke)
        quitButton.isBordered = true
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = .systemFont(ofSize: 11)

        let shortcutHintLabel = NSTextField(labelWithString: "⌘⌥K to toggle")
        shortcutHintLabel.font = .systemFont(ofSize: 11)
        shortcutHintLabel.textColor = .tertiaryLabelColor

        let footerSpacer = NSView()
        let footerRow = NSStackView(views: [shortcutHintLabel, footerSpacer, quitButton])
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
    var shouldReconnect: (() -> Bool)?
    var onStateChange: ((ConnectionState) -> Void)?

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
        case .waiting(let error):
            ready = false
            publish(.connecting)
            scheduleReconnectIfNeeded(reason: error.localizedDescription)
        case .failed(let error):
            ready = false
            connection = nil
            publish(.disconnected)
            scheduleReconnectIfNeeded(reason: error.localizedDescription)
        case .cancelled:
            ready = false
            connection = nil
            publish(.disconnected)
        @unknown default:
            ready = false
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

private final class MouseEventRouter {
    private let state: SharedState
    private let connection: ConnectionManager

    init(state: SharedState, connection: ConnectionManager) {
        self.state = state
        self.connection = connection
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

    // Modifier-down events are held here instead of being sent immediately.
    // If the next event turns out to be the app's own Cmd+Option+K toggle,
    // we drop them silently; otherwise we flush them right before the key
    // they're modifying. This is what stops the toggle hotkey's own Cmd/Alt
    // presses from leaking to the remote host as an unmatched "key down".
    private var armedModifiers: [CGKeyCode: UInt16] = [:]

    // Modifiers we've actually confirmed sending "down" for. A modifier can
    // be physically held (e.g. Option, from habit, or Cmd/Option already
    // down when capture turns on) without us ever having sent its "down" —
    // forwarding its eventual "up" anyway sends Windows an unmatched key
    // release, and for the Windows key specifically that's enough to pop
    // open the Start Menu and steal focus, which looked like a "stuck" key.
    // Only release what we know we pressed.
    private var sentModifierKeyCodes: Set<CGKeyCode> = []

    init(state: SharedState, connection: ConnectionManager) {
        self.state = state
        self.connection = connection
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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Unconditional, regardless of capture state — this is the ground
        // truth for whether the tap is receiving keyboard events at all.
        // Mouse-only taps need just Accessibility permission; keyDown/keyUp
        // specifically also require Input Monitoring, a separate grant. If
        // this line never appears for plain letter keys while flagsChanged
        // lines do, that's the tell: Input Monitoring isn't actually active.
        let loggedKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        appLog("keyboard: tap saw type=\(type.rawValue) keyCode=\(loggedKeyCode) capturing=\(state.isCapturing())")

        guard state.isCapturing() else {
            return false
        }

        // The toggle hotkey is the app's own local control gesture, not
        // something the remote machine should ever see — and it must keep
        // reaching the separate global-hotkey listener even while we're
        // capturing, or there'd be no way to turn capture back off.
        if isToggleHotkeyKeyEvent(type: type, event: event) {
            if !armedModifiers.isEmpty {
                appLog("keyboard: dropped toggle-hotkey modifiers \(armedModifiers.values.map { String($0) })")
            }
            armedModifiers.removeAll()
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
        guard keyCode == CGKeyCode(kVK_ANSI_K) else {
            return false
        }
        let flags = event.flags
        return flags.contains(.maskCommand) && flags.contains(.maskAlternate)
            && !flags.contains(.maskControl) && !flags.contains(.maskShift)
    }

    private func handleKey(event: CGEvent, isDown: Bool) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Deliberately NOT including Option/Alt here. On Spanish/European
        // layouts, Option/AltGr is how you type ordinary punctuation that
        // has no direct key of its own (backslash, pipe, @, ~, brackets,
        // etc.) — treating it as a shortcut modifier broke typing those
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
                // until the following key completes it — nothing to send yet.
                appLog("keyboard: keyCode \(keyCode) produced no text (dead key or unmapped)")
                return
            }
            // Any armed modifier (Shift, or Option/AltGr on layouts where it
            // produces punctuation like backslash) is already fully baked
            // into this character — drop it silently rather than also
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

    /// Modifiers only get flushed automatically ahead of a *keyboard* key —
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
            // that following key would already have cleared or flushed it —
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
            // held before capture turned on) — forwarding this "up" alone
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
    // not on the character they'd otherwise type — always sent as real
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

    func registerToggleHotKey(keyCode: UInt16, callback: @escaping () -> Void) {
        let matchesHotKey: (NSEvent) -> Bool = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event.type == .keyDown
                && event.keyCode == keyCode
                && flags.contains(.command)
                && flags.contains(.option)
                && !flags.contains(.control)
                && !flags.contains(.shift)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyUp && event.keyCode == keyCode {
                self.togglePressed = false
                return
            }

            if matchesHotKey(event) {
                guard !self.togglePressed else { return }
                self.togglePressed = true
                callback()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyUp && event.keyCode == keyCode {
                self.togglePressed = false
                return event
            }

            if matchesHotKey(event) {
                guard !self.togglePressed else { return event }
                self.togglePressed = true
                callback()
                return nil
            }
            return event
        }
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
    }
}

final class KrisKVMAppDelegate: NSObject, NSApplicationDelegate {
    private let state = SharedState()
    private var host = "192.168.0.100"
    private var port: UInt16 = 12653
    private var statusController: StatusBarController!
    private var controlWindow: ControlWindowController!
    private var connectionManager: ConnectionManager!
    private var mouseRouter: MouseEventRouter!
    private var keyboardRouter: KeyboardEventRouter!
    private var inputTapController: InputTapController!
    private let hotKeys = HotKeyController()
    private var eventTap: CFMachPort?
    private var eventTapRetryTimer: Timer?
    private var permissionPrompted = false
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        mouseRouter = MouseEventRouter(state: state, connection: connectionManager)
        keyboardRouter = KeyboardEventRouter(state: state, connection: connectionManager)
        inputTapController = InputTapController(mouseRouter: mouseRouter, keyboardRouter: keyboardRouter)

        // The connection is a background service independent of the hotkey:
        // it connects on launch and keeps itself alive/reconnecting on its
        // own. Capture (actually moving the remote cursor) is a separate
        // on/off flag the hotkey controls, gated by SharedState.isCapturing()
        // so it can only ever be true once the connection is genuinely live.
        connectionManager.shouldReconnect = { true }
        connectionManager.onStateChange = { [weak self] connectionState in
            guard let self else { return }
            self.state.setConnectionState(connectionState)
            self.refreshCaptureState()
            self.statusController.update(remoteActive: self.state.isRemoteActive(), connectionState: connectionState)
            self.controlWindow.updateStatus(remoteActive: self.state.isRemoteActive(), connectionState: connectionState)
        }
        connectionManager.ensureConnected()

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
        controlWindow.setApplyAction { [weak self] newHost, newPort in
            self?.applyEndpoint(host: newHost, port: newPort)
        }
        controlWindow.setHistorySelectAction { [weak self] newHost, newPort in
            self?.applyEndpoint(host: newHost, port: newPort)
        }
        controlWindow.setQuitAction {
            NSApp.terminate(nil)
        }
        controlWindow.setEndpoint(host: host, port: port)
        controlWindow.updateStatus(remoteActive: false, connectionState: .disconnected)
        controlWindow.updateHistory(SavedEndpoint.loadHistory())

        requestAccessibilityAccess()
        requestInputMonitoringAccess()
        installEventTapOrRetry()

        hotKeys.registerToggleHotKey(keyCode: UInt16(toggleKeyCode)) { [weak self] in
            self?.toggleRemoteMode()
        }

        appLog("KrisKVM ready. Toggle remote mode with Cmd+Option+K.")
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
        // Safety net: never leave the Mac's own cursor disassociated if we quit
        // (or crash) while forwarding was active.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    @objc private func toggleRemoteMode() {
        // Pure capture on/off — it never itself starts or retries the
        // connection. The connection already runs on its own in the
        // background; this just decides whether we act on it. If we're not
        // actually connected yet, refreshCaptureState() below will simply
        // leave capture off (and re-evaluate automatically the moment the
        // connection comes up), rather than immediately grabbing the cursor.
        let newValue = !state.isRemoteActive()
        state.setRemoteActive(newValue)
        refreshCaptureState()

        statusController.update(remoteActive: newValue, connectionState: state.connectionStateValue())
        controlWindow.updateStatus(remoteActive: newValue, connectionState: state.connectionStateValue())
        appLog("remoteActive=\(newValue)")
    }

    /// Disassociates (or restores) the Mac's cursor from the mouse hardware
    /// based on whether we're genuinely connected right now, not just whether
    /// the user asked to forward. Called both when the user toggles and
    /// whenever the connection state itself changes, so a drop mid-session
    /// hands control straight back to the Mac until it reconnects.
    private func refreshCaptureState() {
        let capturing = state.isCapturing()
        guard capturing != isCapturing else { return }
        isCapturing = capturing

        if capturing {
            // CGAssociateMouseAndMouseCursorPosition only reliably takes
            // effect while the calling app is the active/foreground app.
            // Triggering capture via the *global* hotkey happens while some
            // other app is frontmost, so without this, the call below would
            // silently do nothing and the Mac's cursor would keep moving.
            NSApp.activate(ignoringOtherApps: true)
        }

        CGAssociateMouseAndMouseCursorPosition(capturing ? 0 : 1)
        if !capturing {
            keyboardRouter.releaseAllHeldModifiers()
        }

        // The TCP connection itself is a persistent background service that
        // stays up regardless of the hotkey, so Windows can't infer capture
        // state from socket connect/disconnect alone — tell it explicitly.
        connectionManager.send("capturing \(capturing ? "on" : "off")")
        appLog("capturing=\(capturing)")
    }

    /// The app never had a standard application menu, so ⌘Q had nothing to
    /// bind to — it's unrelated to mouse capture. This gives it the usual
    /// "AppName / Quit AppName ⌘Q" menu so Cmd+Q works whenever KrisKVM is
    /// the active app on the Mac, exactly like any other Mac app.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit KrisKVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func applyEndpoint(host newHost: String, port newPort: UInt16) {
        host = newHost
        port = newPort
        connectionManager.updateEndpoint(host: newHost, port: newPort)
        controlWindow.setEndpoint(host: newHost, port: newPort)
        SavedEndpoint.save(host: newHost, port: newPort)
        SavedEndpoint.recordHistory(host: newHost, port: newPort)
        controlWindow.updateHistory(SavedEndpoint.loadHistory())
        appLog("Endpoint updated. Host: \(newHost) Port: \(newPort)")

        // The connection is independent of capture intent, so always
        // (re)connect to the new endpoint here regardless of whether the
        // hotkey has been toggled on.
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
