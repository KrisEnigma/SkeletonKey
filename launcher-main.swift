import AppKit
import Foundation

private final class LauncherStatusController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "CLI: Stopped", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "Start CLI", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop CLI", action: nil, keyEquivalent: "")
    private let startTarget = MenuActionTarget()
    private let stopTarget = MenuActionTarget()
    private let quitTarget = MenuActionTarget()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage(color: .systemRed)
            button.imagePosition = .imageOnly
            button.toolTip = "KrisKVM Launcher"
        }

        stateItem.isEnabled = false
        startItem.target = startTarget
        startItem.action = #selector(MenuActionTarget.invoke)
        stopItem.target = stopTarget
        stopItem.action = #selector(MenuActionTarget.invoke)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(MenuActionTarget.invoke), keyEquivalent: "q")
        quitItem.target = quitTarget

        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func setStartAction(_ action: @escaping () -> Void) {
        startTarget.action = action
    }

    func setStopAction(_ action: @escaping () -> Void) {
        stopTarget.action = action
    }

    func setQuitAction(_ action: @escaping () -> Void) {
        quitTarget.action = action
    }

    func update(running: Bool) {
        DispatchQueue.main.async {
            self.stateItem.title = running ? "CLI: Running" : "CLI: Stopped"
            self.startItem.isEnabled = !running
            self.stopItem.isEnabled = running
            self.statusItem.button?.image = Self.statusImage(color: running ? .systemGreen : .systemRed)
        }
    }

    private static func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12)).fill()
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

private final class CLIController {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let cliURL: URL
    private let host: String
    private let port: String
    var onStateChange: ((Bool) -> Void)?

    init(cliURL: URL, host: String, port: String) {
        self.cliURL = cliURL
        self.host = host
        self.port = port
    }

    func start() {
        guard process.isRunning == false else {
            return
        }

        process.executableURL = cliURL
        process.arguments = [host, port]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            self?.onStateChange?(false)
        }

        do {
            try process.run()
            onStateChange?(true)
            pump(pipe: outputPipe)
            pump(pipe: errorPipe)
        } catch {
            fputs("Failed to launch CLI: \(error)\n", stderr)
        }
    }

    func stop() {
        guard process.isRunning else {
            return
        }

        process.terminate()
    }

    private func pump(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(data)
                if !text.hasSuffix("\n") {
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
            }
        }
    }
}

@main
final class KrisKVMLauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: LauncherStatusController!
    private var cliController: CLIController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let host = CommandLine.arguments.dropFirst().first ?? "192.168.0.100"
        let port = CommandLine.arguments.dropFirst(2).first ?? "12653"
        let cliURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mac-sender")

        statusController = LauncherStatusController()
        cliController = CLIController(cliURL: cliURL, host: host, port: port)
        cliController.onStateChange = { [weak self] running in
            self?.statusController.update(running: running)
        }
        statusController.setStartAction { [weak self] in self?.cliController.start() }
        statusController.setStopAction { [weak self] in self?.cliController.stop() }
        statusController.setQuitAction { [weak self] in
            self?.cliController.stop()
            NSApp.terminate(nil)
        }

        statusController.update(running: false)
        cliController.start()
    }
}
