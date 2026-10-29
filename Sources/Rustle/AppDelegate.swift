import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private let audio = CrunchAudio()
    private let tools = ToolController()
    private var overlays: OverlayController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlays = OverlayController(prefs: prefs, audio: audio, tools: tools)
        tools.onChange = { [weak self] in self?.overlays.toolChanged() }
        if let name = ProcessInfo.processInfo.environment["RUSTLE_EQUIP"] {
            // Debugging: start with a tool in hand.
            tools.equip(name == "blower" ? .blower : .rake)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem.sectionHeader(title: "Leaf Fall"))
        for mode in LeafFall.allCases {
            let item = makeItem(mode.title, #selector(setLeafFall(_:)), on: prefs.leafFall == mode)
            item.representedObject = mode.rawValue
            item.indentationLevel = 1
            menu.addItem(item)
        }

        let breezeMenu = NSMenu()
        for breeze in Breeze.allCases {
            let item = makeItem(breeze.title, #selector(setBreeze(_:)), on: prefs.breeze == breeze)
            item.representedObject = breeze.rawValue
            breezeMenu.addItem(item)
        }
        let breezeItem = NSMenuItem(title: "Breeze", action: nil, keyEquivalent: "")
        breezeItem.submenu = breezeMenu
        menu.addItem(breezeItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Accumulate", #selector(toggleAccumulate), on: prefs.accumulate))
        menu.addItem(makeItem("Wind Blows Leaves Away", #selector(toggleWindClears), on: prefs.windClears,
                              enabled: prefs.accumulate))
        menu.addItem(makeItem("Leaves on Windows", #selector(toggleLeavesOnWindows),
                              on: prefs.leavesOnWindows && !prefs.behindWindows, enabled: !prefs.behindWindows))
        menu.addItem(makeItem("Sound", #selector(toggleCrunch), on: prefs.crunchSound))
        menu.addItem(makeItem("Clear Leaves", #selector(clearLeaves), on: false))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Tools"))
        for (tool, title) in [(EquippedTool.rake, "Rake"), (.blower, "Leaf Blower")] {
            let item = makeItem(title, #selector(toggleTool(_:)), on: tools.equipped == tool)
            item.representedObject = tool == .rake ? "rake" : "blower"
            item.indentationLevel = 1
            if let kind = tool.kind {
                let icon = NSImage(cgImage: ToolArt.menuIcon(kind), size: NSSize(width: 18, height: 18))
                icon.isTemplate = true
                item.image = icon
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Behind Windows", #selector(toggleBehindWindows), on: prefs.behindWindows))
        menu.addItem(makeItem("Show in Screenshots", #selector(toggleScreenshots), on: prefs.showInScreenshots))
        let login = makeItem("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        if SMAppService.mainApp.status == .requiresApproval { login.state = .mixed }
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Rustle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func makeItem(_ title: String, _ action: Selector, on: Bool, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func updateIcon() {
        let name = prefs.leafFall == .off ? "leaf" : "leaf.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Rustle")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func changed() {
        overlays.apply()
        updateIcon()
    }

    // MARK: Actions

    @objc private func setLeafFall(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LeafFall(rawValue: raw) else { return }
        prefs.leafFall = mode
        changed()
    }

    @objc private func setBreeze(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let breeze = Breeze(rawValue: raw) else { return }
        prefs.breeze = breeze
        changed()
    }

    @objc private func toggleAccumulate() {
        prefs.accumulate.toggle()
        changed()
    }

    @objc private func toggleWindClears() {
        prefs.windClears.toggle()
        changed()
    }

    @objc private func toggleLeavesOnWindows() {
        prefs.leavesOnWindows.toggle()
        changed()
    }

    @objc private func toggleCrunch() {
        prefs.crunchSound.toggle()
        changed()
    }

    @objc private func clearLeaves() {
        overlays.clearLeaves()
    }

    @objc private func toggleTool(_ sender: NSMenuItem) {
        tools.toggle(sender.representedObject as? String == "rake" ? .rake : .blower)
    }

    @objc private func toggleBehindWindows() {
        prefs.behindWindows.toggle()
        changed()
    }

    @objc private func toggleScreenshots() {
        prefs.showInScreenshots.toggle()
        changed()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            // Registered, but waiting for the user to allow it in System Settings.
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Rustle to the Applications folder and try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
