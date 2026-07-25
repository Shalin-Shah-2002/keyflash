import SwiftUI
import AppKit
import CoreGraphics
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
//
// Uses a Quartz Event Tap (CGEventTap) to detect keyboard and mouse input
// system-wide. Unlike NSEvent.addGlobalMonitorForEvents, CGEventTap can
// monitor keyDown events — NSEvent global monitors explicitly exclude them.

class BacklightFlickerController {
    static let shared = BacklightFlickerController()
    private var flashTask: Process?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // C callback for CGEventTap — receives the controller via the refcon pointer.
    private static let eventTapCallback: @convention(c) (
        CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }

        // Re-enable tap if macOS disabled it due to timeout.
        if type == .tapDisabledByTimeout {
            let controller = Unmanaged<BacklightFlickerController>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = controller.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore tap-disabled-by-user-input — that's a system event, not user input.
        if type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        // All other monitored event types = user interaction → stop flash.
        let controller = Unmanaged<BacklightFlickerController>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async {
            controller.userDidInteract()
        }
        return Unmanaged.passUnretained(event)
    }

    func flickerUntilInteraction() {
        log("BacklightFlicker: starting")
        flashTask?.terminate()
        flashTask = nil
        removeEventTap()

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

        installEventTap()
    }

    private func installEventTap() {
        // Monitor all user-input events system-wide via Quartz Event Services.
        // This catches keyboard keys AND mouse clicks/trackpad taps — unlike
        // NSEvent global monitors, which explicitly exclude keyDown delivery.
        let eventMask = (1 << CGEventType.keyDown.rawValue)
                      | (1 << CGEventType.leftMouseDown.rawValue)
                      | (1 << CGEventType.rightMouseDown.rawValue)
                      | (1 << CGEventType.otherMouseDown.rawValue)
                      | (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("BacklightFlicker: CGEventTap creation failed — add keyflash to "
                + "System Settings > Privacy & Security > Accessibility.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("BacklightFlicker: CGEvent tap installed")
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func userDidInteract() {
        log("BacklightFlicker: user interacted — stopping flash")
        removeEventTap()
        flashTask?.terminate()
        flashTask = nil
    }

    deinit {
        removeEventTap()
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
