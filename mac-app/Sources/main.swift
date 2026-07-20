import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var lastMenuBarOnly: Bool?

    func applicationDidFinishLaunching(_ n: Notification) {
        engine.start()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "小米语音遥控器"
        w.contentView = NSHostingView(rootView: ContentView(e: engine))
        w.center()
        w.isReleasedWhenClosed = false
        window = w

        configureStatusItem()
        refreshStatusItem()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusItem() }
        }
        if !engine.menuBarOnly { showMainWindow(nil) }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) {
        statusTimer?.invalidate()
        engine.stop()
        engine.saveConfig()
    }

    private func configureStatusItem() {
        // Use an explicit text-only control instead of a tiny SF Symbol. macOS
        // menus are crowded, and this app intentionally has no Dock icon.
        let item = NSStatusBar.system.statusItem(withLength: 108)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.alignment = .center
            button.title = "● 小米遥控器"
            button.setAccessibilityLabel("小米语音遥控器菜单")
        }
        statusItem = item
        engine.L("✅ 菜单栏入口已创建：● 小米遥控器（屏幕顶部右侧）")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = engine.micStreaming ? "正在转发语音" : (engine.remoteConnected ? "遥控器已连接" : "遥控器未连接")
        let stateItem = NSMenuItem(title: "小米语音遥控器 · \(state)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新连接遥控器", action: #selector(reconnect(_:)), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出小米语音遥控器", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        let state = engine.micStreaming ? "正在语音" : (engine.remoteConnected ? "已连接" : "未连接")
        button.title = engine.micStreaming ? "● 正在语音" : "● 小米遥控器"
        button.toolTip = "小米语音遥控器：\(state)"

        if lastMenuBarOnly != engine.menuBarOnly {
            lastMenuBarOnly = engine.menuBarOnly
            if engine.menuBarOnly { window?.orderOut(nil) }
        }
    }

    @objc private func showMainWindow(_ sender: Any?) {
        guard let window else { return }
        engine.setMenuBarOnly(false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reconnect(_ sender: Any?) {
        engine.retryScan()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
