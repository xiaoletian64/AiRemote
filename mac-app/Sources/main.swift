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
        // 连接/断开：根据当前状态动态显示
        if engine.remoteConnected {
            menu.addItem(NSMenuItem(title: "断开设备", action: #selector(disconnectDevice(_:)), keyEquivalent: ""))
        } else {
            let item = NSMenuItem(title: "连接设备", action: #selector(connectDevice(_:)), keyEquivalent: "")
            item.isEnabled = engine.selectedRemoteID != nil || !engine.discoveredRemotes.isEmpty
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "重新扫描设备", action: #selector(reconnect(_:)), keyEquivalent: "r"))
        // 全局暂停：一键拦截遥控器所有导航键（离开时防自发误触）
        let pauseTitle = engine.remotePaused ? "▶️ 恢复遥控器" : "⏸ 暂停遥控器"
        menu.addItem(NSMenuItem(title: pauseTitle, action: #selector(togglePause(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "查看日志", action: #selector(showLog(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "重启 App", action: #selector(restartApp(_:)), keyEquivalent: ""))
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

    @objc private func connectDevice(_ sender: Any?) {
        engine.connectSelectedRemote()
    }

    @objc private func disconnectDevice(_ sender: Any?) {
        engine.disconnectCurrentRemote()
    }

    @objc private func togglePause(_ sender: Any?) {
        engine.toggleRemotePause()
    }

    @objc private func showLog(_ sender: Any?) {
        // 打开持久日志文件（控制台打开，便于查看带时间戳的事件流）
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/小米超级键盘/superkeyboard.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            engine.L("⚠️ 日志文件不存在：\(logURL.path)")
        }
    }

    @objc private func restartApp(_ sender: Any?) {
        // 重启：先调度重新打开自己，再终止当前进程
        let appURL = Bundle.main.bundleURL
        engine.L("🔄 用户请求重启 App")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
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
