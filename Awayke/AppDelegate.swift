//
//  AppDelegate.swift
//  Awayke
//

import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let powerManager = PowerManager()
    private let helper = HelperManager.shared
    private let displayKeeper = DisplayWakeKeeper()
    private let batteryMonitor = BatteryMonitor()

    private let thresholdDefaultsKey = "autoOffThreshold"
    private let thresholdOptions = [0, 10, 20, 30]

    /// The user's intent: do they want Awayke on?
    private var intent = false
    /// Battery auto-off is currently holding Awayke off.
    private var suspendedForBattery = false
    /// Most recent battery reading, for re-evaluating on threshold change.
    private var lastSnapshot: BatterySnapshot?

    /// Low-battery floor; 0 disables the feature. Persisted.
    private var threshold: Int {
        get { UserDefaults.standard.integer(forKey: thresholdDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: thresholdDefaultsKey) }
    }

    /// What is actually applied to the system.
    private var effectiveActive: Bool { intent && !suspendedForBattery }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        helper.register()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Tightens the horizontal slot around the icon.
        item.length = 14
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshStatusItem()

        // Recovery from crash / force-kill: pmset disablesleep is a
        // persistent system setting, so a previous instance that died
        // without running its quit cleanup leaves SleepDisabled = 1.
        // Silently reset it via the helper. Skipped if the helper isn't
        // approved (no password prompt for cleanup the user didn't ask for).
        if helper.isUsable {
            powerManager.disableSleep(false) { _ in }
        }

        if threshold > 0 {
            requestNotificationAuthorization()
        }

        batteryMonitor.onChange = { [weak self] snapshot in
            self?.handleBattery(snapshot)
        }
        batteryMonitor.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never leave the system with sleep disabled. Defer termination
        // until the helper (or osascript fallback) finishes flipping
        // pmset back off, so the main run loop stays alive for any auth
        // UI the fallback path may need to show.
        guard effectiveActive else { return .terminateNow }

        powerManager.disableSleep(false) { _ in
            DispatchQueue.main.async {
                self.displayKeeper.allow()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            setIntent(!effectiveActive)
        }
    }

    // MARK: - State application

    /// Manual on/off. Always clears any battery suspension — the user
    /// overrides the auto-off machine.
    private func setIntent(_ on: Bool) {
        powerManager.disableSleep(on) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.intent = on
                    self.suspendedForBattery = false
                    self.syncDisplayKeeper()
                    self.refreshStatusItem()
                case .failure(let error):
                    self.presentError(error)
                }
            }
        }
    }

    private func syncDisplayKeeper() {
        if effectiveActive { displayKeeper.prevent() } else { displayKeeper.allow() }
    }

    private func handleBattery(_ snapshot: BatterySnapshot) {
        lastSnapshot = snapshot
        let action = AutoOffPolicy.decide(
            intent: intent,
            suspended: suspendedForBattery,
            percent: snapshot.percent,
            onAC: snapshot.onAC,
            threshold: threshold
        )
        switch action {
        case .none:
            break
        case .suspend:
            powerManager.disableSleep(false) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, case .success = result else { return }
                    self.suspendedForBattery = true
                    self.syncDisplayKeeper()
                    self.refreshStatusItem()
                    self.notify(title: "Awayke turned off",
                                body: "Battery dropped below \(self.threshold)%.")
                }
            }
        case .resume:
            powerManager.disableSleep(true) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, case .success = result else { return }
                    self.suspendedForBattery = false
                    self.syncDisplayKeeper()
                    self.refreshStatusItem()
                    self.notify(title: "Awayke back on",
                                body: "Charging — sleep prevention resumed.")
                }
            }
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()

        let stateTitle: String
        if suspendedForBattery {
            stateTitle = "Awayke: Paused (low battery)"
        } else {
            stateTitle = effectiveActive ? "Awayke: Active" : "Awayke: Inactive"
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: effectiveActive ? "Turn Off" : "Turn On",
                                action: #selector(menuToggle), keyEquivalent: ""))

        menu.addItem(autoOffSubmenuItem())

        if let helperRow = helperStatusMenuItem() {
            menu.addItem(.separator())
            menu.addItem(helperRow)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Uninstall Awayke…", action: #selector(menuUninstall), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Awayke", action: #selector(menuQuit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func autoOffSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Auto-off on low battery", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = threshold
        for value in thresholdOptions {
            let label = value == 0 ? "Off" : "At \(value)%"
            let item = NSMenuItem(title: label, action: #selector(menuSetThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = (value == current) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func helperStatusMenuItem() -> NSMenuItem? {
        switch helper.state {
        case .enabled:
            return nil
        case .awaitingApproval:
            return NSMenuItem(title: "Approve helper in System Settings…", action: #selector(menuApproveHelper), keyEquivalent: "")
        case .notRegistered:
            let item = NSMenuItem(title: "Installing helper…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .notFound:
            let item = NSMenuItem(title: "Helper not found (using fallback)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    @objc private func menuToggle() { setIntent(!effectiveActive) }

    @objc private func menuSetThreshold(_ sender: NSMenuItem) {
        threshold = sender.tag
        if threshold > 0 {
            requestNotificationAuthorization()
        }
        // Re-evaluate against the latest reading so a newly-set threshold
        // that is already breached suspends immediately.
        if let snapshot = lastSnapshot {
            handleBattery(snapshot)
        }
    }

    @objc private func menuApproveHelper() { helper.revealInSystemSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Awayke?"
        alert.informativeText = "This will remove Awayke's background helper from System Settings and quit the app. You can then move Awayke.app to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        helper.unregister()
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Status item rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        guard let base = NSImage(named: "StatusIcon") else { return }
        base.size = NSSize(width: 16, height: 14)

        if effectiveActive {
            button.image = orangeTinted(base)
        } else {
            base.isTemplate = true
            button.image = base
        }
        button.contentTintColor = nil
        button.title = ""
        if suspendedForBattery {
            button.toolTip = "Awayke paused — battery below \(threshold)%. Plug in to resume."
        } else {
            button.toolTip = effectiveActive ? "Awayke is on!" : "Awayke is off. Click to turn it on."
        }
    }

    private func orangeTinted(_ source: NSImage) -> NSImage {
        let image = source.copy() as! NSImage
        image.isTemplate = false
        image.lockFocus()
        NSColor(red: 1, green: 0.6, blue: 0.1, alpha: 1).set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Awayke couldn't toggle sleep."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
