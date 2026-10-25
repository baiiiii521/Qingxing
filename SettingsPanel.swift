//
//  SettingsPanel.swift — 设置面板（SwiftUI，macOS 系统设置风格）
//

import SwiftUI

// MARK: - 应用状态（SwiftUI 与菜单共同的数据源）

final class AppState: ObservableObject {
    // —— 用户设置（持久化到 UserDefaults）——
    @Published var systemAwakeOn: Bool {
        didSet { persist("systemAwakeOn", systemAwakeOn); settingsChanged() }
    }
    @Published var displayAwakeOn: Bool {
        didSet { persist("displayAwakeOn", displayAwakeOn); settingsChanged() }
    }
    @Published var powerScope: PowerScope {
        didSet { persist("powerScope", powerScope.rawValue); settingsChanged() }
    }
    @Published var batteryGuardOn: Bool {
        didSet { persist("batteryGuardOn", batteryGuardOn) }
    }
    @Published var batteryThreshold: Int {
        didSet { persist("batteryThreshold", batteryThreshold) }
    }
    @Published var triggerApps: [TriggerApp] {
        didSet { persistTriggers(); settingsChanged() }
    }

    // —— 实时状态（不持久化）——
    @Published var lidOn = false
    @Published var lidBusy = false
    @Published var helperInstalled = false
    @Published var loginItemEnabled = false
    @Published var powerText = ""
    @Published var activeTriggerNames: [String] = []
    @Published var guardTripped = false

    private var loaded = false
    var onSettingsChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        systemAwakeOn = defaults.bool(forKey: "systemAwakeOn")
        displayAwakeOn = defaults.bool(forKey: "displayAwakeOn")
        powerScope = PowerScope(rawValue: defaults.integer(forKey: "powerScope")) ?? .always
        batteryGuardOn = defaults.object(forKey: "batteryGuardOn") == nil ? true : defaults.bool(forKey: "batteryGuardOn")
        batteryThreshold = defaults.object(forKey: "batteryThreshold") == nil ? 20 : defaults.integer(forKey: "batteryThreshold")
        if let data = defaults.data(forKey: "triggerApps"),
           let apps = try? JSONDecoder().decode([TriggerApp].self, from: data) {
            triggerApps = apps
        } else {
            triggerApps = []
        }
        loaded = true
    }

    private func persist(_ key: String, _ value: Any) {
        guard loaded else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persistTriggers() {
        guard loaded else { return }
        if let data = try? JSONEncoder().encode(triggerApps) {
            UserDefaults.standard.set(data, forKey: "triggerApps")
        }
    }

    private func settingsChanged() {
        guard loaded else { return }
        onSettingsChange?()
    }
}

// MARK: - 面板动作（由 AppDelegate 注入）

struct PanelActions {
    let toggleLid: () -> Void
    let screenOffNow: () -> Void
    let pickApp: () -> Void
    let installHelper: () -> Void
    let uninstallHelper: () -> Void
    let toggleLoginItem: () -> Void
    let restoreDefaults: () -> Void
}

// MARK: - 设置界面

struct SettingsView: View {
    @ObservedObject var state: AppState
    let actions: PanelActions

    var body: some View {
        Form {
            modeSection
            scopeSection
            batterySection
            triggerSection
            helperSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 500, minHeight: 560, idealHeight: 640)
    }

    // MARK: 模式

    private var modeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.lidOn },
                set: { _ in actions.toggleLid() }
            )) {
                Label {
                    Text("合盖继续工作")
                } icon: {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .foregroundStyle(.blue)
                }
            }
            .disabled(state.lidBusy)

            Toggle(isOn: $state.systemAwakeOn) {
                Label {
                    Text("关屏继续工作")
                } icon: {
                    Image(systemName: "moon.dots")
                        .foregroundStyle(.indigo)
                }
            }
            Toggle(isOn: $state.displayAwakeOn) {
                Label {
                    Text("屏幕常亮")
                } icon: {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Label {
                    Text("立即关屏")
                } icon: {
                    Image(systemName: "moon.stars")
                        .foregroundStyle(.purple)
                }
                Spacer()
                Button("关屏并继续工作") { actions.screenOffNow() }
            }
        } header: {
            Label("模式", systemImage: "sparkles")
        } footer: {
            Text("合盖继续工作：扣盖不休眠（\(state.helperInstalled ? "免密已启用" : "切换需要管理员密码")）\n关屏继续工作：屏幕可熄灭、任务不断\n屏幕常亮：不熄屏、不休眠")
        }
    }

    // MARK: 生效条件

    private var scopeSection: some View {
        Section {
            Picker("生效条件", selection: $state.powerScope) {
                ForEach(PowerScope.allCases, id: \.self) { scope in
                    Text(scope.label.replacingOccurrences(of: "生效", with: "")).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Label("生效条件（对以上模式）", systemImage: "bolt.fill")
        } footer: {
            Text("拔插电源时自动切换。合盖模式按 pmset 对应电源配置生效，修改条件后请重新开关一次合盖模式。")
        }
    }

    // MARK: 电池保护

    private var batterySection: some View {
        Section {
            Toggle("低电量自动恢复睡眠", isOn: $state.batteryGuardOn)
            if state.batteryGuardOn {
                Picker("电量阈值", selection: $state.batteryThreshold) {
                    ForEach([10, 15, 20, 25, 30], id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
        } header: {
            Label("电池保护", systemImage: "battery.25")
        } footer: {
            Text("使用电池且电量低于阈值时，自动关闭所有防睡眠模式，防止合盖放包里耗尽电量、持续发热。启动时也会自检上次异常退出的残留设置并自动修复。")
        }
    }

    // MARK: App 触发

    private var triggerSection: some View {
        Section {
            if state.triggerApps.isEmpty {
                HStack {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.secondary)
                    Text("尚未添加。列表中的 App 运行时会自动保持系统唤醒。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(state.triggerApps) { app in
                    HStack {
                        Image(systemName: "app.fill")
                            .foregroundStyle(.blue)
                        Text(app.name)
                        Spacer()
                        Button {
                            state.triggerApps.removeAll { $0.id == app.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                actions.pickApp()
            } label: {
                Label("添加 App…", systemImage: "plus.circle.fill")
            }
        } header: {
            Label("App 触发", systemImage: "app.badge.checkmark")
        } footer: {
            Text(state.activeTriggerNames.isEmpty
                 ? "例如：终端编译、Docker、下载器、AI 助手运行时自动保持唤醒（屏幕可熄灭），全部退出后自动恢复。"
                 : "当前触发中：\(state.activeTriggerNames.joined(separator: "、"))")
        }
    }

    // MARK: 免密模式

    private var helperSection: some View {
        Section {
            HStack {
                Label("免密切换合盖模式", systemImage: "key.fill")
                    .foregroundStyle(.yellow)
                Spacer()
                if state.helperInstalled {
                    Label("已启用", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Button("卸载") { actions.uninstallHelper() }
                } else {
                    Button("安装") { actions.installHelper() }
                }
            }
        } header: {
            Label("免密模式", systemImage: "lock.open")
        } footer: {
            Text(state.helperInstalled
                 ? "已安装白名单助手（/usr/local/bin/qingxing-privileged）与一条限定严格的 sudoers 规则，切换合盖模式、电池自动保护都不再需要密码。"
                 : "安装后切换\"合盖继续工作\"、电池低电量自动保护都不再需要管理员密码。需要一次授权，写入：白名单助手脚本 + 仅允许该脚本的 sudoers 规则，可随时卸载。")
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        Section {
            Toggle("登录时自动启动", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { _ in actions.toggleLoginItem() }
            ))
            HStack {
                Label("恢复 macOS 默认", systemImage: "arrow.uturn.backward")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部关闭并还原") { actions.restoreDefaults() }
            }
        } header: {
            Label("通用", systemImage: "gearshape")
        } footer: {
            Text("清醒 Qingxing v1.1.0 · 开源（MIT）· github.com/baiiiii521/Qingxing")
                .font(.footnote)
        }
    }
}
