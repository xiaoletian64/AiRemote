import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var e: Engine

    var body: some View {
        TabView {
            overview.tabItem { Label("状态", systemImage: "dot.radiowaves.left.and.right") }
            mappings.tabItem { Label("按键映射", systemImage: "keyboard") }
            setup.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .frame(minWidth: 620, minHeight: 620)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in e.checkPermissions() }
        .onAppear { e.start() }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.indigo.opacity(0.18), Color.cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 12) {
                    Image(systemName: e.micStreaming ? "mic.fill" : "keyboard")
                        .font(.system(size: 64)).foregroundStyle(e.micStreaming ? .red : .primary)
                    Text(e.lastKeyLabel).font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(e.lastKeyMapping.isEmpty ? "等待遥控器按键" : "→ \(e.lastKeyMapping)")
                        .font(.title3).foregroundStyle(.secondary)
                    if e.micStreaming {
                        Label("正在转发语音到 BlackHole（\(e.voicePacketCount) 帧）", systemImage: "waveform").foregroundStyle(.red)
                    } else if !e.voiceFailure.isEmpty {
                        Text(e.voiceFailure).font(.caption).foregroundStyle(.orange)
                    }
                }.padding(28)
            }.frame(maxWidth: .infinity, minHeight: 235)

            HStack(spacing: 12) {
                status("蓝牙", e.btOn)
                status("遥控器", e.remoteConnected)
                status("语音通道", e.handshakeReady)
                status("BlackHole", e.blackholeFound)
                Spacer()
                Button(e.scanning ? "正在扫描…" : "重新连接") { e.retryScan() }
                    .disabled(e.scanning)
                    .buttonStyle(.borderedProminent)
            }.padding(14)
            Divider()
            logView.padding(14)
        }
    }

    private var mappings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("遥控器按键映射").font(.title2.bold())
            Text("点“录制”，再按 Mac 键盘上的目标按键。语音键可同时把音频转发给系统输入法/听写。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Section("普通按键") {
                    ForEach(e.config.buttons) { button in mappingRow(button) }
                }
                Section("语音键（固定 Fn）") {
                    HStack {
                        Text("语音键").frame(width: 105, alignment: .leading)
                        Text("ATVV").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 48)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text("Fn（原生 Globe/Fn）")
                    }
                    Toggle("语音键同时转发麦克风音频", isOn: Binding(
                        get: { e.config.voiceStartsMic },
                        set: { e.config.voiceStartsMic = $0; e.saveConfig() }))
                    Label(e.hardwareGlobeReady ? "已启用原生 Fn（微信输入法可识别）" : "正在等待遥控器原生 Fn 映射",
                          systemImage: e.hardwareGlobeReady ? "checkmark.circle.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(e.hardwareGlobeReady ? .green : .orange)
                }
            }
        }.padding()
    }

    private func mappingRow(_ button: ButtonMapping) -> some View {
        let capturing = e.capturingUsage == button.usage
        return HStack(spacing: 10) {
            Text(button.name).frame(width: 105, alignment: .leading)
            Text(button.usage < 0 ? "ATVV" : String(format: "0x%02X", button.usage))
                .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 48)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(capturing ? "请按目标键…" : button.display)
                    .foregroundStyle(capturing ? .blue : .primary)
                if let long = button.longPressKeycode {
                    Text("长按：\(KeyNames.label(keycode: long, cmd: false, shift: false, opt: false, ctrl: false))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
            if capturing {
                Button("取消") { e.cancelCapture() }
            } else {
                Button("录制") { e.beginCapture(usage: button.usage) }
                Menu("鼠标") {
                    ForEach(KeyNames.specials, id: \.code) { special in
                        Button(special.name) { e.setSpecial(usage: button.usage, keycode: special.code) }
                    }
                }
                if button.usage >= 0 {
                    Menu("长按") {
                        Button("无") { e.setLongPressSpecial(usage: button.usage, keycode: nil) }
                        ForEach(KeyNames.specials, id: \.code) { special in
                            Button(special.name) { e.setLongPressSpecial(usage: button.usage, keycode: special.code) }
                        }
                    }
                }
                Button("原样") { e.clearMapping(usage: button.usage) }
            }
        }.padding(.vertical, 3)
    }

    private var setup: some View {
        Form {
            Section("权限") {
                permissionRow("辅助功能", ok: e.axTrusted, action: { e.requestAX() })
                permissionRow("输入监控", ok: e.inputMonitoringOK, action: { e.requestInputMonitoring() })
                permissionRow("蓝牙", ok: e.btOn, action: { e.retryScan() })
            }
            Section("语音输入") {
                HStack {
                    Label("BlackHole 2ch", systemImage: e.blackholeSelectedAsInput ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(e.blackholeSelectedAsInput ? .green : .orange)
                    Spacer()
                    Text(e.blackholeSelectedAsInput ? "已作为系统输入" : (e.blackholeFound ? "已检测到，未选中" : "驱动未被 CoreAudio 识别"))
                        .foregroundStyle(.secondary)
                    if e.blackholeFound && !e.blackholeSelectedAsInput {
                        Button("设为输入") { e.selectBlackHoleAsSystemInput() }
                    }
                }
                Text("应用发现设备后会自动选择它作为系统输入。若仍未被识别：安装 `brew install --cask blackhole-2ch` 后重启 Mac。输入法或系统听写会直接使用这路音频。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("应用") {
                Toggle("登录时启动", isOn: Binding(get: { e.launchAtLogin }, set: e.setLaunchAtLogin))
                Button("打开辅助功能设置") { e.openAXSettings() }
                Button("打开输入监控设置") { e.openInputMonitoringSettings() }
            }
        }.padding()
    }

    private func permissionRow(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
            Text(title); Spacer()
            Text(ok ? "已授权" : "需要授权").foregroundStyle(.secondary)
            if !ok { Button("授权", action: action) }
        }
    }

    private func status(_ title: String, _ ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(ok ? .green : .secondary)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("事件日志").font(.headline); Spacer(); Button("清空") { e.log.removeAll() } }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(e.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).id(index)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: e.log.count) { _ in
                    if let last = e.log.indices.last { scroll.scrollTo(last, anchor: .bottom) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
