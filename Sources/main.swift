import Cocoa
import ApplicationServices
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Налаштування

enum JiggleMode: String {
    case zen      // невидимий зсув на 1px і назад
    case visible  // помітний рух курсору туди-назад
}

final class Settings {
    private let d = UserDefaults.standard

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// Скільки секунд бездіяльності чекати перед рухом миші.
    var interval: TimeInterval {
        get { d.object(forKey: "interval") as? Double ?? 60 }
        set { d.set(newValue, forKey: "interval") }
    }
    var mode: JiggleMode {
        get { JiggleMode(rawValue: d.string(forKey: "mode") ?? "") ?? .zen }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    var preventSleep: Bool {
        get { d.object(forKey: "preventSleep") as? Bool ?? true }
        set { d.set(newValue, forKey: "preventSleep") }
    }
}

// MARK: - Робота з мишею та сном

enum Mouse {
    /// Секунди з моменту останньої дії користувача (миша/клавіатура).
    static func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func jiggle(mode: JiggleMode) {
        let start = currentLocation()
        switch mode {
        case .zen:
            move(to: CGPoint(x: start.x + 1, y: start.y))
            move(to: start)
        case .visible:
            let steps = 10
            let dist: CGFloat = 30
            for i in 1...steps {
                move(to: CGPoint(x: start.x + dist * CGFloat(i) / CGFloat(steps), y: start.y))
                usleep(10_000)
            }
            for i in stride(from: steps - 1, through: 0, by: -1) {
                move(to: CGPoint(x: start.x + dist * CGFloat(i) / CGFloat(steps), y: start.y))
                usleep(10_000)
            }
        }
    }
}

final class SleepBlocker {
    private var id: IOPMAssertionID = 0
    private(set) var active = false

    func set(_ on: Bool) {
        if on && !active {
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Jiggle: keep awake" as CFString, &id)
            active = (r == kIOReturnSuccess)
        } else if !on && active {
            IOPMAssertionRelease(id)
            active = false
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings()
    let sleepBlocker = SleepBlocker()
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastJiggle: Date?

    let intervals: [(String, TimeInterval)] = [
        ("30 секунд", 30), ("1 хвилина", 60), ("2 хвилини", 120),
        ("5 хвилин", 300), ("10 хвилин", 600),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        requestAccessibilityIfNeeded()
        apply()

        // Перевіряємо бездіяльність кожні 5 секунд.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepBlocker.set(false)
    }

    func tick() {
        guard settings.enabled, AXIsProcessTrusted() else { return }
        if Mouse.idleSeconds() >= settings.interval {
            Mouse.jiggle(mode: settings.mode)
            lastJiggle = Date()
        }
    }

    func apply() {
        sleepBlocker.set(settings.enabled && settings.preventSleep)
        let symbol = settings.enabled ? "cursorarrow.motionlines" : "cursorarrow"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jiggle")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !settings.enabled
    }

    func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Меню будуємо щоразу при відкритті — так стан завжди актуальний.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(title: settings.enabled ? "Вимкнути" : "Увімкнути",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠︎ Надати доступ Accessibility…",
                                  action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // Інтервал
        let intervalItem = NSMenuItem(title: "Рухати після бездіяльності", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, value) in intervals {
            let it = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = value
            it.state = settings.interval == value ? .on : .off
            sub.addItem(it)
        }
        intervalItem.submenu = sub
        menu.addItem(intervalItem)

        // Режим
        let modeItem = NSMenuItem(title: "Режим", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for (title, mode) in [("Zen (непомітно)", JiggleMode.zen), ("Видимий рух", .visible)] {
            let it = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = settings.mode == mode ? .on : .off
            modeMenu.addItem(it)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let sleep = NSMenuItem(title: "Не давати Mac заснути",
                               action: #selector(togglePreventSleep), keyEquivalent: "")
        sleep.target = self
        sleep.state = settings.preventSleep ? .on : .off
        menu.addItem(sleep)

        let login = NSMenuItem(title: "Запускати під час входу",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let jiggleNow = NSMenuItem(title: "Поворушити зараз", action: #selector(jiggleNow), keyEquivalent: "")
        jiggleNow.target = self
        menu.addItem(jiggleNow)

        let quit = NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func statusText() -> String {
        guard settings.enabled else { return "Вимкнено" }
        guard let last = lastJiggle else { return "Активно · ще не рухав" }
        let f = DateFormatter()
        f.timeStyle = .medium
        return "Активно · останній рух о \(f.string(from: last))"
    }

    // MARK: Actions

    @objc func toggleEnabled() {
        settings.enabled.toggle()
        apply()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TimeInterval { settings.interval = v }
    }

    @objc func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = JiggleMode(rawValue: raw) {
            settings.mode = m
        }
    }

    @objc func togglePreventSleep() {
        settings.preventSleep.toggle()
        apply()
    }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не вдалося змінити автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func jiggleNow() {
        guard AXIsProcessTrusted() else { requestAccessibilityIfNeeded(); return }
        Mouse.jiggle(mode: settings.mode)
        lastJiggle = Date()
    }

    @objc func openAccessibility() {
        requestAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
