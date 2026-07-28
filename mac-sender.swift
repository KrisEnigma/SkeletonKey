import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Network

private let toggleKeyCode: UInt32 = UInt32(kVK_ANSI_K)

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
}

private final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Remote: Off", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: Disconnected", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Toggle Remote", action: nil, keyEquivalent: "")
    private let toggleTarget = MenuActionTarget()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage(color: .systemRed)
            button.imagePosition = .imageOnly
            button.toolTip = "KrisKVM"
        }

        stateItem.isEnabled = false
        connectionItem.isEnabled = false
        toggleItem.target = toggleTarget
        toggleItem.action = #selector(MenuActionTarget.invoke)
        menu.addItem(stateItem)
        menu.addItem(connectionItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func setToggleAction(_ action: @escaping () -> Void) {
        toggleTarget.action = action
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

    private final class MenuActionTarget: NSObject {
        var action: (() -> Void)?

        @objc func invoke() {
            action?()
        }
    }
}

private final class ConnectionManager {
    private let host: String
    private let port: UInt16
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

            let endpointPort = NWEndpoint.Port(rawValue: self.port)!
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: endpointPort, using: .tcp)
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
                    fputs("Send error: \(error)\n", stderr)
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
        fputs("Connection retry scheduled: \(reason)\n", stderr)
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

    func installEventTap() -> CFMachPort? {
        let mask =
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

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let router = Unmanaged<MouseEventRouter>.fromOpaque(userInfo).takeUnretainedValue()
            router.handle(type: type, event: event)
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

    private func handle(type: CGEventType, event: CGEvent) {
        guard state.isRemoteActive() else {
            return
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
    private var statusBarController: StatusBarController!
    private var connectionManager: ConnectionManager!
    private var mouseRouter: MouseEventRouter!
    private let hotKeys = HotKeyController()
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let host = CommandLine.arguments.dropFirst().first ?? "192.168.0.100"
        let portArgument = CommandLine.arguments.dropFirst(2).first
        let port = UInt16(portArgument.flatMap { UInt16($0) } ?? 12653)

        statusBarController = StatusBarController()
        connectionManager = ConnectionManager(host: host, port: port)
        mouseRouter = MouseEventRouter(state: state, connection: connectionManager)

        connectionManager.shouldReconnect = { [weak self] in
            self?.state.isRemoteActive() == true
        }
        connectionManager.onStateChange = { [weak self] connectionState in
            guard let self else { return }
            self.state.setConnectionState(connectionState)
            self.statusBarController.update(remoteActive: self.state.isRemoteActive(), connectionState: connectionState)
        }

        statusBarController.update(remoteActive: false, connectionState: .disconnected)
        statusBarController.setToggleAction { [weak self] in
            self?.toggleRemoteMode()
        }

        if let tap = mouseRouter.installEventTap() {
            eventTap = tap
        } else {
            fputs("Failed to create event tap. Check Input Monitoring permission.\n", stderr)
            NSApp.terminate(nil)
            return
        }

        hotKeys.registerToggleHotKey(keyCode: UInt16(toggleKeyCode)) { [weak self] in
            self?.toggleRemoteMode()
        }

        print("KrisKVM ready. Toggle remote mode with Cmd+Option+K.")
        print("Host: \(host) Port: \(port)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        connectionManager.disconnect()
        hotKeys.unregister()
    }

    @objc private func toggleRemoteMode() {
        let newValue = !state.isRemoteActive()
        state.setRemoteActive(newValue)

        if newValue {
            connectionManager.ensureConnected()
        }

        statusBarController.update(remoteActive: newValue, connectionState: state.connectionStateValue())
        print("remoteActive=\(newValue)")
    }
}

@main
struct KrisKVMApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = KrisKVMAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
