import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var indicatorObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identity: Identity
        do {
            identity = try Identity.loadOrCreate()
        } catch {
            let alert = NSAlert()
            alert.messageText = "ToggleMouse can't load its identity"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        model = AppModel(identity: identity)
        model.onNeedsWindow = { [weak self] in self?.showWindow() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        indicatorObserver = model.$indicator.sink { [weak self] in self?.updateIcon($0) }

        if !model.isTrusted { model.requestAccessibility() }
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Releases the frozen cursor and anything held on the receiver.
        model?.shutdown()
    }

    private func updateIcon(_ indicator: AppModel.Indicator) {
        let color: NSColor = switch indicator {
        case .idle: .systemGray
        case .emitting: .systemRed
        case .receiving: .systemGreen
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "ToggleMouse")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabledItem(statusLine()))
        menu.addItem(.separator())

        if let emitter = model.emitter {
            for peer in model.store.receivers {
                let shortcut = peer.hotkey.map { "  \($0.displayString)" } ?? ""
                let item = NSMenuItem(title: "Stream to \(peer.name)\(shortcut)", action: #selector(toggleReceiver(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                item.state = emitter.activeReceiverID == peer.id ? .on : .off
                item.isEnabled = emitter.linkStates[peer.id] == .connected || emitter.activeReceiverID == peer.id
                menu.addItem(item)
            }
            if !model.store.receivers.isEmpty { menu.addItem(.separator()) }
        }

        let open = NSMenuItem(title: "Open ToggleMouse…", action: #selector(openWindow), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit ToggleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusLine() -> String {
        if let emitter = model.emitter {
            if let id = emitter.activeReceiverID, let peer = model.store.receivers.first(where: { $0.id == id }) {
                return "Emitter: streaming to \(peer.name)"
            }
            return "Emitter: idle"
        }
        if let receiver = model.receiver {
            if let id = receiver.streamingEmitterID, let peer = model.store.emitters.first(where: { $0.id == id }) {
                return "Receiver: controlled by \(peer.name)"
            }
            return "Receiver: idle"
        }
        return "ToggleMouse"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleReceiver(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.emitter?.toggle(id)
    }

    @objc private func openWindow() {
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ToggleMouse"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
