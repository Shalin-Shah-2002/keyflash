import SwiftUI
import AppKit
import KeyflashCore
import OSLog

// ── Debug logging ──

private let logFile = "/tmp/keyflash.log"

func log(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    // Write to both os_log (system) and file (for tail)
    os_log(.debug, "keyflash: %{public}s", msg)
    if let data = line.data(using: .utf8) {
        // Use FileHandle with O_APPEND via low-level POSIX to ensure it works
        let fd = open(logFile, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            data.withUnsafeBytes { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
            close(fd)
        }
    }
}

// ── Keyboard Backlight Flicker Controller ──

class BacklightFlickerController {
    static let shared = BacklightFlickerController()
    private var eventMonitor: Any?
    private var flashTask: Process?  // Keep reference to prevent dealloc (kills child!)

    /// Flash keyboard backlight continuously until user interaction.
    func flickerUntilInteraction() {
        log("BacklightFlicker: starting")
        flashTask?.terminate()
        flashTask = nil
        eventMonitor = nil

        let task = Process()
        task.launchPath = "/opt/homebrew/bin/mac-brightnessctl"
        task.arguments = ["-f", "99999", "0.4", "200"]
        task.terminationHandler = { [weak self] _ in
            log("BacklightFlicker: flash exited, restoring brightness")
            self?.flashTask = nil
            let restore = Process()
            restore.launchPath = "/opt/homebrew/bin/mac-brightnessctl"
            restore.arguments = ["1"]
            try? restore.run()
        }
        do {
            try task.run()
            flashTask = task  // Keep reference alive!
        } catch { return }
        log("BacklightFlicker: flash running")

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.userDidInteract()
        }
    }

    private func userDidInteract() {
        log("BacklightFlicker: user interacted")
        eventMonitor = nil
        flashTask?.terminate()
        flashTask = nil
    }

    func testPulse() { flickerUntilInteraction() }
}

// ── Task Complete Manager ──

class TaskCompleteManager: ObservableObject {
    static let shared = TaskCompleteManager()
    @Published var statusText: String = "Idle"
    @Published var isActive: Bool = false

    func handleTaskComplete(agent: String, pid: Int) {
        log("TaskCompleteManager.handleTaskComplete: agent=\(agent) pid=\(pid)")
        DispatchQueue.main.async {
            self.isActive = true
            self.statusText = "Wrapping: \(agent) (pid \(pid))"
        }

        // MUST run on main thread — Timer needs a run loop
        DispatchQueue.main.async {
            let config = ConfigLoader.load()
            if config.enabled {
                log("TaskCompleteManager: calling flickerUntilInteraction")
                BacklightFlickerController.shared.flickerUntilInteraction()
            }
            self.isActive = false
            self.statusText = "Idle"
        }
    }
}

// ── AppDelegate ──

class AppDelegate: NSObject, NSApplicationDelegate {
    var notificationService: NotificationService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: applicationDidFinishLaunching")
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        notificationService = NotificationService { agent, pid in
            log("AppDelegate: received task done — agent=\(agent) pid=\(pid)")
            TaskCompleteManager.shared.handleTaskComplete(agent: agent, pid: pid)
        }
        notificationService?.startListening()
        log("AppDelegate: NotificationService started")

        // Flash backlight on launch to confirm it works
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            log("AppDelegate: startup flash test")
            let task = Process()
            task.launchPath = "/opt/homebrew/bin/mac-brightnessctl"
            task.arguments = ["-f", "3", "0.3", "200"]
            try? task.run()
            task.waitUntilExit()
            log("AppDelegate: startup flash complete")
        }
    }
}

// ── App Entry ──

@main
struct KeyflashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = TaskCompleteManager.shared

    var body: some Scene {
        MenuBarExtra("keyflash", systemImage: "bolt.fill") {
            Text("keyflash v0.2")
            Text("Status: \(manager.statusText)")
            Divider()
            Button("Test Flicker") { BacklightFlickerController.shared.testPulse() }
            Button("Settings…") { openSettings() }
            Button("Install Shell Hook") {
                ShellHookInstaller.installIfNeeded()
                let alert = NSAlert()
                alert.messageText = "Shell hook installed"
                alert.runModal()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

func openSettings() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false
    )
    window.title = "keyflash Settings"
    window.contentView = NSHostingView(rootView: SettingsWindow())
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
