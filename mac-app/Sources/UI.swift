import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var e: Engine
    @State private var selectedTab = 0
    @State private var showDiagnostics = false

    private var remoteReady: Bool { e.btOn && e.remoteConnected && e.handshakeReady }
    private var voiceReady: Bool { remoteReady && e.blackholeSelectedAsInput && e.hardwareGlobeReady }
    private var needsPermissions: Bool { !e.axTrusted || !e.inputMonitoringOK }

    var body: some View {
        TabView(selection: $selectedTab) {
            useTab
                .tabItem { Label("使用", systemImage: "mic.and.signal.meter") }
                .tag(0)
            mappingTab
                .tabItem { Label("按键", systemImage: "keyboard") }
                .tag(1)
            settingsTab
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .frame(minWidth: 760, minHeight: 650)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            e.checkPermissions()
        }
        .onAppear { e.start() }
    }

    // MARK: - Daily use

    private var useTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                voiceHero

                Text("连接状态")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatusCard(
                        title: "遥控器",
                        detail: remoteReady ? "已连接，语音通道已就绪" : (e.btOn ? "正在等待遥控器" : "蓝牙未开启"),
                        icon: "dot.radiowaves.left.and.right",
                        state: remoteReady ? .ready : .waiting
                    )
                    StatusCard(
                        title: "微信输入法 Fn",
                        detail: e.hardwareGlobeReady ? "原生 Globe/Fn 已启用" : "正在准备硬件映射",
                        icon: "globe.asia.australia.fill",
                        state: e.hardwareGlobeReady ? .ready : .waiting
                    )
                    StatusCard(
                        title: "语音输入",
                        detail: e.blackholeSelectedAsInput ? "BlackHole 已作为系统输入" : "等待 BlackHole 输入设备",
                        icon: "waveform",
                        state: e.blackholeSelectedAsInput ? .ready : .attention
                    )
                    StatusCard(
                        title: "Mac 控制",
                        detail: e.axTrusted && e.inputMonitoringOK ? "按键控制已就绪" : "还需完成系统授权",
                        icon: "cursorarrow.click",
                        state: e.axTrusted && e.inputMonitoringOK ? .ready : .attention
                    )
                }

                if !e.lastKeyMapping.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill").foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("刚刚操作") .font(.caption).foregroundStyle(.secondary)
                            Text("\(e.lastKeyLabel)  →  \(e.lastKeyMapping)") .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack {
                    Button(e.scanning ? "正在搜索遥控器…" : "重新连接遥控器") { e.retryScan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(e.scanning)
                    Spacer()
                    Button("调整按键") { selectedTab = 1 }
                    Button("打开设置") { selectedTab = 2 }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("MiVibeBoard")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("小米蓝牙语音遥控器 · Mac 语音与快捷控制")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            readinessBadge
        }
    }

    private var readinessBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(voiceReady ? .green : .orange).frame(width: 8, height: 8)
            Text(voiceReady ? "可以使用" : "需要完成设置")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((voiceReady ? Color.green : Color.orange).opacity(0.13), in: Capsule())
        .foregroundStyle(voiceReady ? .green : .orange)
    }

    private var voiceHero: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(e.micStreaming ? Color.red.opacity(0.16) : Color.indigo.opacity(0.13))
                    .frame(width: 112, height: 112)
                Circle()
                    .stroke(e.micStreaming ? Color.red.opacity(0.40) : Color.indigo.opacity(0.25), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Image(systemName: e.micStreaming ? "mic.fill" : "mic")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(e.micStreaming ? .red : .indigo)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(e.micStreaming ? "正在转发你的语音" : "按住遥控器语音键说话")
                    .font(.title2.weight(.semibold))
                if e.micStreaming {
                    Text("音频正送入 BlackHole · 已接收 \(e.voicePacketCount) 帧")
                        .foregroundStyle(.secondary)
                } else if !e.voiceFailure.isEmpty {
                    Text(e.voiceFailure).foregroundStyle(.orange)
                } else {
                    Text("语音键会保持原生 Fn / Globe，微信输入法可直接识别。")
                        .foregroundStyle(.secondary)
                }
                Label("松开语音键即停止", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.indigo.opacity(0.13), Color.cyan.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    // MARK: - Mapping

    private var mappingTab: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按键控制") .font(.title2.bold())
                    Text("兼容小米 BLE 遥控器的两种 HID 报告格式。语音键固定为原生 Fn；其他键可录制 Mac 快捷键或选择系统动作。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("配置自动保存", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)

            List {
                Section("语音键") {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill").foregroundStyle(.indigo).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("语音键  →  Fn（原生 Globe/Fn）").font(.body.weight(.medium))
                            Text(e.hardwareGlobeReady ? "已启用，微信输入法可以识别" : "遥控器连接后会自动启用")
                                .font(.caption).foregroundStyle(e.hardwareGlobeReady ? .green : .secondary)
                        }
                        Spacer()
                        Toggle("转发音频", isOn: Binding(
                            get: { e.config.voiceStartsMic },
                            set: { e.config.voiceStartsMic = $0; e.saveConfig() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .padding(.vertical, 5)
                }

                Section("遥控器按键") {
                    ForEach(e.config.buttons) { button in mappingRow(button) }
                }
            }
            .listStyle(.inset)
        }
    }

    private func mappingRow(_ button: ButtonMapping) -> some View {
        let capturing = e.capturingUsage == button.usage
        return HStack(spacing: 12) {
            Image(systemName: icon(for: button.usage))
                .frame(width: 24).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(button.name).font(.body.weight(.medium))
                if let long = button.longPressKeycode {
                    Text("长按：\(KeyNames.label(keycode: long, cmd: false, shift: false, opt: false, ctrl: false))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Text(capturing ? "请按 Mac 键盘…" : button.display)
                .lineLimit(1)
                .foregroundStyle(capturing ? .blue : .secondary)
                .frame(minWidth: 150, alignment: .trailing)
            if capturing {
                Button("取消") { e.cancelCapture() }
            } else {
                Menu {
                    Button("录制 Mac 快捷键") { e.beginCapture(usage: button.usage) }
                    Divider()
                    ForEach(KeyNames.specials, id: \.code) { special in
                        Button(special.name) { e.setSpecial(usage: button.usage, keycode: special.code) }
                    }
                    if button.usage >= 0 {
                        Divider()
                        Menu("长按动作") {
                            Button("无") { e.setLongPressSpecial(usage: button.usage, keycode: nil) }
                            ForEach(KeyNames.specials, id: \.code) { special in
                                Button(special.name) { e.setLongPressSpecial(usage: button.usage, keycode: special.code) }
                            }
                        }
                    }
                    Divider()
                    Button("保持遥控器原样") { e.clearMapping(usage: button.usage) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
        .padding(.vertical, 5)
    }

    private func icon(for usage: Int) -> String {
        switch usage {
        case 0x52: return "arrow.up"
        case 0x51: return "arrow.down"
        case 0x50: return "arrow.left"
        case 0x4F: return "arrow.right"
        case 0x28: return "return"
        case 0xF1: return "delete.left"
        case 0x4A: return "house"
        case 0x65: return "list.bullet"
        case 0x66: return "power"
        default: return "button.programmable"
        }
    }

    // MARK: - Setup and diagnostics

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置") .font(.title2.bold())
                Text("只需设置一次；应用会记住选择并在下次启动时自动连接。")
                    .foregroundStyle(.secondary)

                GroupBox("系统授权") {
                    VStack(spacing: 0) {
                        SetupRow(
                            icon: "accessibility",
                            title: "辅助功能",
                            detail: "允许遥控器发送键盘、锁屏和鼠标控制",
                            ready: e.axTrusted,
                            actionTitle: "授权",
                            action: e.requestAX
                        )
                        Divider().padding(.leading, 42)
                        SetupRow(
                            icon: "eye",
                            title: "输入监控",
                            detail: "允许应用读取小米遥控器的按住与松开",
                            ready: e.inputMonitoringOK,
                            actionTitle: "授权",
                            action: e.requestInputMonitoring
                        )
                    }
                }

                GroupBox("语音输入") {
                    VStack(spacing: 0) {
                        SetupRow(
                            icon: "waveform",
                            title: "BlackHole 2ch",
                            detail: e.blackholeSelectedAsInput ? "已自动选为系统输入" : (e.blackholeFound ? "已检测到，尚未设为系统输入" : "未被系统识别"),
                            ready: e.blackholeSelectedAsInput,
                            actionTitle: "设为输入",
                            action: e.selectBlackHoleAsSystemInput,
                            actionVisible: e.blackholeFound && !e.blackholeSelectedAsInput
                        )
                        if !e.blackholeFound {
                            Divider().padding(.leading, 42)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                                Text("安装 BlackHole 2ch 后，重新打开此应用即可自动选择。应用不会安装驱动或索取管理员密码。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 12)
                        }
                    }
                }

                GroupBox("应用") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("登录时自动启动", isOn: Binding(get: { e.launchAtLogin }, set: e.setLaunchAtLogin))
                        Toggle("仅保留菜单栏图标", isOn: Binding(get: { e.menuBarOnly }, set: e.setMenuBarOnly))
                        Text("开启后可从菜单栏图标查看状态、重新连接或重新打开主窗口。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }

                DisclosureGroup("诊断与事件日志", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("仅用于排查连接问题") .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清空") { e.log.removeAll() }.controlSize(.small)
                        }
                        ScrollViewReader { scroll in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(e.log.enumerated()), id: \.offset) { index, line in
                                        Text(line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(index)
                                    }
                                }
                            }
                            .frame(height: 160)
                            .padding(10)
                            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: e.log.count) { _ in
                                if let last = e.log.indices.last { scroll.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

private enum StatusState { case ready, waiting, attention }

private struct StatusCard: View {
    let title: String
    let detail: String
    let icon: String
    let state: StatusState

    private var tint: Color {
        switch state { case .ready: return .green; case .waiting: return .indigo; case .attention: return .orange }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct SetupRow: View {
    let icon: String
    let title: String
    let detail: String
    let ready: Bool
    let actionTitle: String
    let action: () -> Void
    var actionVisible = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(ready ? .green : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ready {
                Label("已就绪", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else if actionVisible {
                Button(actionTitle, action: action).controlSize(.small)
            } else {
                Label("需要处理", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 9)
    }
}
