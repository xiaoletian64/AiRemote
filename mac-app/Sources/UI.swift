import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var e: Engine
    @State private var selectedTab = 0
    @State private var showDiagnostics = false

    private var remoteReady: Bool { e.btOn && e.remoteConnected && e.handshakeReady }
    private var voiceReady: Bool { remoteReady && e.blackholeSelectedAsInput && e.hardwareGlobeReady }
    /// 当前选中遥控器的显示名（无则返回占位）
    private var currentRemoteName: String {
        if let id = e.selectedRemoteID, let r = e.discoveredRemotes.first(where: { $0.id == id }) {
            return r.name
        }
        return e.lastFoundName ?? "遥控器"
    }

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
                permissionBanner
                voiceHero

                Text("连接状态")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatusCard(
                        title: "遥控器",
                        detail: remoteReady
                            ? "已连接：\(currentRemoteName)"
                            : (e.btOn ? "正在等待遥控器" : "蓝牙未开启"),
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

                // 多遥控器选择区：列出已发现设备，单选切换当前活跃遥控器
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("遥控器").font(.headline)
                        Spacer()
                        if e.scanning { Text("正在扫描…").font(.caption).foregroundStyle(.secondary) }
                        Button(e.scanning ? "扫描中" : "重新扫描") { e.retryScan() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(e.scanning)
                    }
                    if e.discoveredRemotes.isEmpty {
                        Text("未发现遥控器。请长按遥控器【主页 + 菜单】5 秒进入配对模式，再点「重新扫描」。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ForEach(e.discoveredRemotes) { remote in
                            remoteRow(remote)
                        }
                    }
                }
                .padding(14)
                .background(Color.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

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

    /// 权限横幅：任一权限未授权时醒目提示，点击一键申请并跳转设置页。
    @ViewBuilder
    private var permissionBanner: some View {
        if !allPermissionsGranted {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("需要完成系统授权才能用按键控制").font(.headline)
                    Text(permissionSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("一键授权") { e.requestAllPermissions() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var allPermissionsGranted: Bool {
        e.axTrusted && e.inputMonitoringOK
    }
    private var permissionSummary: String {
        var missing: [String] = []
        if !e.axTrusted { missing.append("辅助功能") }
        if !e.inputMonitoringOK { missing.append("输入监控") }
        return missing.isEmpty ? "全部已授权" : "未授权：" + missing.joined(separator: "、")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("小米超级键盘")
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
                    Text(e.config.voiceMode == .leftControl
                         ? "语音键映射为左 Control 修饰键，按住可与其它键组成 Ctrl 快捷键。"
                         : "语音键保持原生 Fn / Globe，微信输入法可直接识别。")
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
                    Text("兼容小米 BLE 遥控器的多种 HID 报告格式。语音键可在「地球/Fn」与「左 Control」间切换；其他键可录制 Mac 快捷键或选择系统动作。")
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
                            Text("语音键映射模式").font(.body.weight(.medium))
                            Picker("", selection: Binding(
                                get: { e.config.voiceMode },
                                set: { e.setVoiceMode($0) }
                            )) {
                                ForEach(VoiceMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Text(e.config.voiceMode.detail)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(e.hardwareGlobeReady ? "✓ 设备层映射已启用" : "遥控器连接后会自动启用")
                                .font(.caption).foregroundStyle(e.hardwareGlobeReady ? .green : .secondary)
                        }
                        Spacer()
                        Toggle("转发音频", isOn: Binding(
                            get: { e.config.voiceStartsMic },
                            set: { e.config.voiceStartsMic = $0; e.saveConfig() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("把遥控器采集的语音转发到 BlackHole，作为系统麦克风输入")
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

    /// 遥控器候选行：名称 + RSSI + 连接状态，点击切换为当前设备。
    @ViewBuilder
    private func remoteRow(_ remote: RemoteCandidate) -> some View {
        let isSelected = e.selectedRemoteID == remote.id
        Button {
            e.selectRemote(remote.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .indigo : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.name).font(.body.weight(.medium))
                    Text(remote.connected ? "已连接" : (remote.rssi != 0 ? "RSSI \(remote.rssi) dBm" : "点击连接"))
                        .font(.caption).foregroundStyle(remote.connected ? .green : .secondary)
                }
                Spacer()
                if remote.connected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
            .padding(10)
            .background(
                (isSelected ? Color.indigo.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Button(e.blackholeInstalling ? "正在安装…" : "一键安装语音驱动") {
                                        e.installBlackHole()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(e.blackholeInstalling)
                                    if e.blackholeInstalling {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                Text("BlackHole 是系统级音频驱动。点击后系统会弹出密码框，请输入管理员密码；安装完成需要【重启 Mac】才能生效。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 12)
                        }
                    }
                }

                GroupBox("Pro 圆盘") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("启用圆盘滚动（默认关闭，防误触）", isOn: Binding(
                            get: { e.ringEnabled },
                            set: { e.setRingEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        Text("开启后，Pro 圆盘转动会快速滚动页面（3 帧稳定同方向才触发）。默认关闭——圆盘容易误触，按需开启。")
                            .font(.caption).foregroundStyle(.secondary)
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
