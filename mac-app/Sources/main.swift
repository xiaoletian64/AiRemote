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
        w.title = "小米超级键盘"
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
        // 菜单栏空间宝贵，用 NSVariableStatusItemLength 自适应宽度，避免长设备名溢出被截断。
        // 完整设备名放在 tooltip 和下拉菜单里，标题只保留状态点 + 简称。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.title = "● 遥控器"
            button.setAccessibilityLabel("小米超级键盘菜单")
        }
        statusItem = item
        engine.L("✅ 菜单栏入口已创建：● 遥控器（屏幕顶部右侧）")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let devName = currentRemoteName
        let state = engine.micStreaming ? "正在转发语音" : (engine.remoteConnected ? "已连接" : "未连接")
        let stateItem = NSMenuItem(title: "\(devName) · \(state)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新连接遥控器", action: #selector(reconnect(_:)), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出小米超级键盘", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        let state = engine.micStreaming ? "正在语音" : (engine.remoteConnected ? "已连接" : "未连接")
        // 菜单栏标题保持简短：语音中/已连接/未连接，避免长设备名把菜单栏挤出屏幕。
        // 状态点颜色感：语音=橙、已连接=绿、未连接=灰（用字符 ● 统一，色差靠标题文字区分）。
        button.title = engine.micStreaming ? "● 正在语音" : (engine.remoteConnected ? "● 已连接" : "● 遥控器")
        // 完整设备名 + 状态放 tooltip，鼠标悬停可见。
        button.toolTip = "\(currentRemoteName)：\(state)"

        if lastMenuBarOnly != engine.menuBarOnly {
            lastMenuBarOnly = engine.menuBarOnly
            if engine.menuBarOnly { window?.orderOut(nil) }
        }
    }

    /// 当前选中遥控器的显示名（tooltip / 下拉菜单用）。无选中时回落到通用名。
    private var currentRemoteName: String {
        if let id = engine.selectedRemoteID,
           let r = engine.discoveredRemotes.first(where: { $0.id == id }) {
            return r.name
        }
        return "小米遥控器"
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
