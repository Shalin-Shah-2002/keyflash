import SwiftUI
import AppKit
import KeyflashCore
import OSLog

// ── Debug logging ──

private let logFile = "/tmp/keyflash.log"

func log(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    os_log(.debug, "keyflash: %{public}s", msg)
    if let data = line.data(using: .utf8) {
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
    private var flashTask: Process?

    func flickerUntilInteraction() {
        log("BacklightFlicker: starting")
        flashTask?.terminate()
        flashTask = nil
        eventMonitor = nil

        // Use Backlight() from KeyflashCore to find mac-brightnessctl in all
        // known locations (/opt/homebrew/bin, /usr/local/bin, etc.).
        guard let backlight = Backlight() else {
            log("BacklightFlicker: mac-brightnessctl not found, cannot flash")
            return
        }

        let task = Process()
        task.launchPath = backlight.binaryPath
        task.arguments = ["-f", "99999", "0.4", "200"]
        task.terminationHandler = { [weak self] _ in
            log("BacklightFlicker: flash exited, restoring brightness")
            self?.flashTask = nil
            let restore = Process()
            restore.launchPath = backlight.binaryPath
            restore.arguments = ["1"]
            try? restore.run()
        }
        do {
            try task.run()
            flashTask = task
        } catch { return }
        log("BacklightFlicker: flash running")

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.userDidInteract()
        }
    }

    private func userDidInteract() {
        log("BacklightFlicker: user interacted")
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        flashTask?.terminate()
        flashTask = nil
    }

    func testFlicker() { log("BacklightFlicker: test pulse"); flickerUntilInteraction() }
}

// ── AppDelegate ──

class AppDelegate: NSObject, NSApplicationDelegate {
    var notificationService: NotificationService?
    var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: applicationDidFinishLaunching")
        // Configure as an accessory (menu-bar-only) app. This ensures the
        // NSStatusItem / MenuBarExtra icon appears immediately, even on a
        // fresh DMG install where macOS hasn't cached the app's activation policy.
        NSApp.setActivationPolicy(.accessory)
        startNotificationService()
    }

    private func startNotificationService() {
        notificationService = NotificationService { [weak self] agent, pid in
            log("AppDelegate: received task done — agent=\(agent) pid=\(pid)")
            self?.handleTaskComplete()
        }
        notificationService?.startListening()
        log("AppDelegate: NotificationService started")
    }

    func handleTaskComplete() {
        log("AppDelegate: handleTaskComplete")
        let config = ConfigLoader.load()
        if config.enabled {
            BacklightFlickerController.shared.flickerUntilInteraction()
        }
    }

    @objc func testFlicker() { BacklightFlickerController.shared.testFlicker() }

    @objc func openSettings() {
        log("AppDelegate: opening settings")
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
        settingsWindowController = NSWindowController(window: window)
    }

    @objc func installHook() {
        ShellHookInstaller.installIfNeeded()
        let alert = NSAlert()
        alert.messageText = "Shell hook installed"
        alert.runModal()
    }
}

// ── Menu Bar Icon ──

private let menuBarIcon: NSImage = {
    let image = NSImage(named: "KeyFlash_MenuIcon")
        ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "keyflash")!
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    return image
}()

// ── SwiftUI Menu Bar App ──

@main
struct KeyflashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            Text("keyflash v0.2")
            Divider()
            Button("Test Flicker") { delegate.testFlicker() }
            Button("Settings…") { delegate.openSettings() }
            Button("Install Shell Hook") { delegate.installHook() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: menuBarIcon)
        }

        Settings {
            EmptyView()
        }
    }
}
