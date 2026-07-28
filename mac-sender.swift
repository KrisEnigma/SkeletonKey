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
    private var connectionManager: ConnectionManager!
    private var mouseRouter: MouseEventRouter!
    private let hotKeys = HotKeyController()
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let host = CommandLine.arguments.dropFirst().first ?? "192.168.0.100"
        let portArgument = CommandLine.arguments.dropFirst(2).first
        let port = UInt16(portArgument.flatMap { UInt16($0) } ?? 12653)

        connectionManager = ConnectionManager(host: host, port: port)
        mouseRouter = MouseEventRouter(state: state, connection: connectionManager)

        connectionManager.shouldReconnect = { [weak self] in
            self?.state.isRemoteActive() == true
        }
        connectionManager.onStateChange = { [weak self] connectionState in
            guard let self else { return }
            self.state.setConnectionState(connectionState)
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

        print("remoteActive=\(newValue)")
    }
}
