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
// Flashes the keyboard backlight until the user presses a key, clicks or
// scrolls, then restores the brightness they had before.
//
// Input is detected two ways so the flash always stops:
//  1. A listen-only Quartz Event Tap (instant; needs Input Monitoring permission).
//  2. Polling CGEventSource "seconds since last input" (no permission needed).
// A safety cap ends the flash after `maxFlashDuration` even if both fail.
//
// All mac-brightnessctl process work runs on one serial queue, so starting a
// new flash, stopping one, and restoring brightness can never interleave.

final class BacklightFlickerController {
    static let shared = BacklightFlickerController()

    /// The flash can never run longer than this.
    private let maxFlashDuration: TimeInterval = 30 * 60

    // Main-thread state
    private(set) var isFlashing = false
    private var flashStartedAt: Date?
    private var generation = 0
    private var inputPollTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Backlight-queue state (only touched on `hw`)
    private let hw = DispatchQueue(label: "keyflash.backlight")
    private var hwBacklight: Backlight?
    private var hwFlashTask: Process?
    private var hwSavedLevel: Float?

    // C callback for CGEventTap — receives the controller via the refcon pointer.
    private static let eventTapCallback: @convention(c) (
        CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<BacklightFlickerController>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable tap if macOS disabled it due to timeout.
        if type == .tapDisabledByTimeout {
            DispatchQueue.main.async {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore tap-disabled-by-user-input — that's a system event, not user input.
        if type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        // All other monitored event types = user interaction → stop flash.
        DispatchQueue.main.async {
            controller.stop(reason: "user input (event tap)")
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Public (main thread)

    func flickerUntilInteraction() {
        log("BacklightFlicker: starting")
        generation += 1
        let gen = generation
        isFlashing = true
        flashStartedAt = Date()
        startInputWatchers()
        hw.async { self.hwStartFlash(generation: gen) }
    }

    func stop(reason: String) {
        guard isFlashing else { return }
        log("BacklightFlicker: stopping — \(reason)")
        isFlashing = false
        flashStartedAt = nil
        stopInputWatchers()
        hw.async { self.hwStopFlash() }
    }

    /// Stops the flash and waits until brightness is restored (used at quit).
    func stopAndWait() {
        stop(reason: "app quitting")
        hw.sync {}
    }

    func testFlicker() { log("BacklightFlicker: test"); flickerUntilInteraction() }

    // MARK: - Backlight queue

    private func hwStartFlash(generation gen: Int) {
        guard let backlight = hwBacklight ?? Backlight() else {
            log("BacklightFlicker: mac-brightnessctl not found, cannot flash")
            DispatchQueue.main.async { if self.generation == gen { self.stop(reason: "no backlight tool") } }
            return
        }
        hwBacklight = backlight

        // Restarting while already flashing: stop the old flasher and put the
        // user's brightness back first, so the new one sees (and later restores)
        // the right level.
        hwKillFlash()
        if let saved = hwSavedLevel {
            backlight.setLevel(saved)
        } else {
            hwSavedLevel = backlight.currentLevel() ?? 1.0
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: backlight.binaryPath)
        task.arguments = Backlight.flashArguments(duration: maxFlashDuration)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] finished in
            self?.hw.async {
                guard let self, self.hwFlashTask === finished else { return } // stopped on purpose
                self.hwFlashTask = nil
                log("BacklightFlicker: flash process ended by itself (status \(finished.terminationStatus))")
                DispatchQueue.main.async {
                    if self.generation == gen { self.stop(reason: "flash ended") }
                }
            }
        }
        do {
            try task.run()
            hwFlashTask = task
            log("BacklightFlicker: flash running (saved brightness \(hwSavedLevel ?? -1))")
        } catch {
            log("BacklightFlicker: failed to launch flash: \(error.localizedDescription)")
            DispatchQueue.main.async { if self.generation == gen { self.stop(reason: "launch failed") } }
        }
    }

    private func hwKillFlash() {
        guard let task = hwFlashTask else { return }
        hwFlashTask = nil // before terminate, so its termination handler ignores it
        if task.isRunning {
            task.terminate()
            // Let it exit and any in-flight fade finish before we set brightness.
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func hwStopFlash() {
        hwKillFlash()
        if let backlight = hwBacklight, let saved = hwSavedLevel {
            backlight.setLevel(saved)
            log("BacklightFlicker: restored brightness \(saved)")
        }
        hwSavedLevel = nil
    }

    // MARK: - Input detection (main thread)

    private func startInputWatchers() {
        if eventTap == nil { installEventTap() }
        if inputPollTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.pollForInput()
            }
            RunLoop.main.add(timer, forMode: .common)
            inputPollTimer = timer
        }
    }

    private func stopInputWatchers() {
        inputPollTimer?.invalidate()
        inputPollTimer = nil
        removeEventTap()
    }

    private func pollForInput() {
        guard isFlashing, let start = flashStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        if Self.secondsSinceLastUserInput() < elapsed - 0.05 {
            stop(reason: "user input (idle poll)")
        } else if elapsed > maxFlashDuration + 5 {
            stop(reason: "safety timeout")
        }
    }

    /// Seconds since the last key press, click or scroll. Needs no permissions.
    static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
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
            log("BacklightFlicker: CGEventTap unavailable (no Input Monitoring permission) — using idle polling")
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
        autoInstallAgentHooks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BacklightFlickerController.shared.stopAndWait()
        notificationService?.stopListening()
    }

    private func startNotificationService() {
        notificationService = NotificationService { [weak self] agent, pid in
            log("AppDelegate: received task done — agent=\(agent) pid=\(pid)")
            self?.handleTaskComplete()
        }
        notificationService?.startListening()
        log("AppDelegate: NotificationService started")
    }

    /// Keeps the Claude Code / OpenCode hooks installed and pointing at this
    /// copy of keyflash-run (e.g. after the app is moved or updated).
    private func autoInstallAgentHooks() {
        guard ConfigLoader.load().shouldAutoInstall else { return }
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            log("AppDelegate: not running from an .app bundle — skipping hook auto-install")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            for line in AgentHooks.installAll() {
                log("AppDelegate: \(line)")
            }
        }
    }

    func handleTaskComplete() {
        log("AppDelegate: handleTaskComplete")
        let config = ConfigLoader.load()
        if config.enabled && config.backlightEnabled {
            BacklightFlickerController.shared.flickerUntilInteraction()
        }
    }

    @objc func testFlicker() { BacklightFlickerController.shared.testFlicker() }

    @objc func stopFlashing() { BacklightFlickerController.shared.stop(reason: "menu") }

    @objc func openSettings() {
        log("AppDelegate: opening settings")
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "keyflash Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsWindow())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController = NSWindowController(window: window)
    }

    @objc func installHooks() {
        var lines = AgentHooks.installAll()
        lines.append(ShellHookInstaller.installIfNeeded())
        lines.forEach { log("AppDelegate: \($0)") }

        let alert = NSAlert()
        alert.messageText = "Agent hooks installed"
        alert.informativeText = lines.joined(separator: "\n\n")
            + "\n\nRestart any running claude / opencode sessions to pick them up."
        NSApp.activate(ignoringOtherApps: true)
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
            Text("keyflash v0.3")
            Divider()
            Button("Test Flicker") { delegate.testFlicker() }
            Button("Stop Flashing") { delegate.stopFlashing() }
            Button("Settings…") { delegate.openSettings() }
            Button("Install Agent Hooks") { delegate.installHooks() }
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
