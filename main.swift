//
//  清醒 Qingxing v1.1.0 — macOS 菜单栏防睡眠小工具
//
//  功能：合盖/关屏/常亮三种模式 · 按电源条件生效 · App 触发 · 免密模式
//        电池阈值保护 · 启动自检 · SwiftUI 设置面板
//
//  构建：./build.sh
//

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let power = PowerMonitor()
    private let assertions = AssertionManager()
    private let triggers = AppTriggerMonitor()
    private let state = AppState()

    private var settingsWindow: NSWindow?
    private var batteryGuardTripped = false

    private lazy var panelActions = PanelActions(
        toggleLid: { [weak self] in self?.performLidToggle() },
        screenOffNow: { [weak self] in self?.screenOffNow() },
        pickApp: { [weak self] in self?.pickApp() },
        installHelper: { [weak self] in self?.installHelper() },
        uninstallHelper: { [weak self] in self?.uninstallHelper() },
        toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
        restoreDefaults: { [weak self] in self?.restoreDefaults() }
    )

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.onSettingsChange = { [weak self] in self?.applyAll() }

        if let button = statusItem.button {
            button.image = iconImage(active: false)
        }
        statusItem.menu = menu
        menu.delegate = self

        power.onChange = { [weak self] in
            self?.powerChanged()
        }

        state.helperInstalled = PrivilegedHelper.refresh()
        refreshLidState()
        refreshPowerText()
        applyAll()

        // 监听 App 启动/退出，重新评估触发
        let center = NotificationCenter.default
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyAll()
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyAll()
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWelcome()
        }

        // 命令行 --show-settings 直接打开设置面板（供测试/自动化）
        if CommandLine.arguments.contains("--show-settings") {
            showSettings()
        }

        // 启动自检（稍等电源/通知中心就绪）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startupSelfCheck()
        }
    }

    // MARK: 状态计算与应用

    private var scopeActive: Bool {
        state.powerScope.active(onAC: power.onAC) && !batteryGuardTripped
    }

    private func applyAll() {
        let active = scopeActive
        assertions.setSystemAwake(state.systemAwakeOn && active)
        assertions.setDisplayAwake(state.displayAwakeOn && active)
        triggers.reevaluate(triggers: state.triggerApps, allowed: active)
        state.activeTriggerNames = triggers.activeNames
        state.guardTripped = batteryGuardTripped
        updateIcon()
    }

    private func powerChanged() {
        refreshPowerText()
        batteryGuardCheck()
        applyAll()
    }

    private func refreshPowerText() {
        if !power.hasBattery {
            state.powerText = "🖥️  电源：未检测到电池"
        } else if power.onAC {
            state.powerText = "🔌  电源：交流电源（插电中）"
        } else {
            let percent = power.batteryPercent.map { " · \($0)%" } ?? ""
            state.powerText = "🔋  电源：电池供电中\(percent)"
        }
    }

    private func refreshLidState() {
        let lid = PMSet.lidSleepDisabled()
        state.lidOn = lid.battery || lid.ac
        updateIcon()
    }

    private func updateIcon() {
        let active = state.lidOn || assertions.systemHeld || assertions.displayHeld || triggers.held
        statusItem.button?.image = iconImage(active: active)
        var tips: [String] = []
        if state.lidOn { tips.append("合盖继续工作") }
        if assertions.systemHeld { tips.append("关屏继续工作") }
        if assertions.displayHeld { tips.append("屏幕常亮") }
        if triggers.held { tips.append("App 触发（" + triggers.activeNames.joined(separator: "、") + "）") }
        statusItem.button?.toolTip = tips.isEmpty
            ? "「清醒」— Mac 当前可正常睡眠"
            : "「清醒」保持清醒中：" + tips.joined(separator: "、")
    }

    private func iconImage(active: Bool) -> NSImage? {
        let symbol = active ? "cup.and.saucer.fill" : "moon.zzz.fill"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: active ? "保持清醒" : "允许睡眠") else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    // MARK: 电池保护

    private func batteryGuardCheck() {
        guard state.batteryGuardOn, power.hasBattery, !power.onAC,
              let percent = power.batteryPercent else {
            batteryGuardTripped = false
            state.guardTripped = false
            return
        }
        guard percent <= state.batteryThreshold else {
            batteryGuardTripped = false
            state.guardTripped = false
            return
        }
        guard !batteryGuardTripped else { return }
        batteryGuardTripped = true
        state.guardTripped = true

        // 断言类模式直接关（无需权限）
        if state.systemAwakeOn || state.displayAwakeOn {
            state.systemAwakeOn = false
            state.displayAwakeOn = false
        }

        // 合盖模式：免密则静默关闭；否则只能通知用户手动处理
        var lidHandled = true
        if state.lidOn {
            let result = PMSet.setLidSleepDisabled(false, profile: "-a", interactive: false)
            if result.ok {
                refreshLidState()
            } else {
                lidHandled = false
            }
        }

        if lidHandled {
            Notify.send("清醒 · 电池保护", body: "电量已低于 \(percent)%，已自动关闭所有防睡眠模式，恢复系统正常睡眠。")
        } else {
            Notify.send("清醒 · 电池保护", body: "电量已低于 \(percent)%，已关闭免权限的防睡眠模式。\"合盖继续工作\"需要密码才能关闭——点击菜单栏 🌙 图标选择\"恢复 macOS 默认\"，或在设置中安装免密组件实现全自动保护。")
        }
        applyAll()
    }

    // MARK: 启动自检

    private func startupSelfCheck() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "savedSleepB") != nil || defaults.object(forKey: "savedSleepC") != nil else {
            return
        }
        let lid = PMSet.lidSleepDisabled()
        if lid.battery || lid.ac {
            // 合盖模式还开着：保存的睡眠计时是将来关闭时恢复用的，属于正常
            return
        }
        // 合盖已关但保存值还在 → 检查闲置睡眠是否仍被改成"永不"（异常退出残留）
        let savedB = defaults.object(forKey: "savedSleepB") as? Int ?? 0
        let savedC = defaults.object(forKey: "savedSleepC") as? Int ?? 0
        let current = PMSet.sleepTimers()
        if (current.battery == 0 && savedB > 0) || (current.ac == 0 && savedC > 0) {
            let result = PMSet.setLidSleepDisabled(false, profile: "-a", interactive: false)
            if result.ok {
                Notify.send("清醒 · 启动自检", body: "检测到上次异常退出的残留设置（闲置睡眠被改为\"永不\"），已自动恢复原值。")
            } else {
                Notify.send("清醒 · 启动自检", body: "检测到残留设置：闲置睡眠计时仍为\"永不\"。请点击菜单栏图标选择\"恢复 macOS 默认\"修复（需要密码）。")
            }
        } else {
            PMSet.clearSavedSleepTimers()
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        power.refresh()
        refreshPowerText()
        refreshLidState()
        state.helperInstalled = PrivilegedHelper.refresh()
        state.loginItemEnabled = SMAppService.mainApp.status == .enabled

        // —— 状态区 ——
        addItem(state.powerText, enabled: false)

        var active: [String] = []
        if state.lidOn { active.append("合盖继续工作") }
        if assertions.systemHeld { active.append("关屏继续工作") }
        if assertions.displayHeld { active.append("屏幕常亮") }
        if !state.activeTriggerNames.isEmpty {
            active.append("App 触发（" + state.activeTriggerNames.joined(separator: "、") + "）")
        }

        if active.isEmpty {
            addItem("😴  Mac 可正常睡眠（未开启任何模式）", enabled: false)
        } else {
            addItem("✅  保持清醒中：" + active.joined(separator: "、"), enabled: false)
        }
        if (state.systemAwakeOn || state.displayAwakeOn) && !scopeActive {
            addItem("⏸️  当前电源不满足生效条件（\(state.powerScope.label)），暂不生效", enabled: false)
        }
        if state.guardTripped {
            addItem("🛡️  电池低于阈值，已自动恢复睡眠", enabled: false)
        }

        menu.addItem(.separator())

        // —— 模式开关 ——
        let lidItem = addItem("🌙  合盖继续工作（扣盖不休眠）", action: #selector(toggleLid(_:)))
        lidItem.state = state.lidOn ? .on : .off
        lidItem.toolTip = "合上盖子（扣盖）后 Mac 继续运行，屏幕关闭、任务不断。\n\(state.helperInstalled ? "免密已启用，切换无需密码。" : "切换需要输入管理员密码（可在设置中安装免密组件）。")\n⚠️ 合盖运行时请注意散热；用电池时也会持续耗电。"

        let systemItem = addItem("🌑  关屏继续工作（屏幕可熄、任务不断）", action: #selector(toggleSystemAwake(_:)))
        systemItem.state = state.systemAwakeOn ? .on : .off
        systemItem.toolTip = "系统保持唤醒，屏幕到时间会正常熄灭（也可点\"立即关屏\"）。\n下载、编译、跑任务都不中断。基于 IOKit 断言实现，无需任何权限。"

        let displayItem = addItem("☀️  屏幕常亮（不熄屏、不休眠）", action: #selector(toggleDisplayAwake(_:)))
        displayItem.state = state.displayAwakeOn ? .on : .off
        displayItem.toolTip = "屏幕和系统都不进入睡眠，相当于一直 caffeinate -d。"

        let triggerItem = addItem("🎯  App 触发\(state.activeTriggerNames.isEmpty ? "" : "：\(state.activeTriggerNames.joined(separator: "、"))")", action: #selector(openSettings(_:)))
        triggerItem.toolTip = "在设置面板中管理：指定 App 运行时自动保持唤醒。"

        let screenOff = addItem("⏻  一键：立即关屏并继续工作", action: #selector(screenOffAction(_:)))
        screenOff.toolTip = "自动打开\"关屏继续工作\"，然后立即熄灭屏幕；任务继续运行。\n按任意键 / 动一下鼠标即可点亮屏幕。"

        menu.addItem(.separator())

        // —— 生效条件 ——
        let scopeItem = addItem("⚡  生效条件（对以上模式）")
        scopeItem.toolTip = "决定各模式在什么电源状态下生效。\n· 断言类模式（关屏/常亮/App 触发）：切换电源时自动生效或恢复。\n· 合盖模式：按 pmset 的对应电源配置设置（修改后请重新开关一次合盖模式）。"
        let submenu = NSMenu()
        for s in PowerScope.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(setScope(_:)), keyEquivalent: "")
            item.target = self
            item.state = (s == state.powerScope) ? .on : .off
            item.representedObject = s.rawValue
            switch s {
            case .always: item.toolTip = "无论插不插电源，三种模式都生效"
            case .acOnly: item.toolTip = "插着电源时生效；拔掉电源后自动恢复正常睡眠"
            case .batteryOnly: item.toolTip = "只用电池时生效；插上电源后自动恢复正常"
            }
            submenu.addItem(item)
        }
        scopeItem.submenu = submenu

        menu.addItem(.separator())

        // —— 其他 ——
        let settings = addItem("⚙️  设置…", action: #selector(openSettings(_:)))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command

        let restore = addItem("↩️  恢复 macOS 默认（允许正常睡眠）", action: #selector(restoreDefaultsAction(_:)))
        restore.toolTip = "关闭所有模式，并清除 pmset 的 disablesleep 设置（需要管理员密码）"

        let loginItem = addItem("🚀  登录时自动启动", action: #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = state.loginItemEnabled ? .on : .off

        addItem("ℹ️  关于「清醒」", action: #selector(showAbout(_:)))
        addItem("✕  退出", action: #selector(NSApplication.terminate(_:)), targetSelf: false)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector? = nil, targetSelf: Bool = true, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = (action == nil || !targetSelf) ? nil : self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    // MARK: 设置面板

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView(state: state, actions: panelActions)))
            window.title = "清醒 · 设置"
            window.styleMask.insert(.closable)
            window.styleMask.insert(.miniaturizable)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 840))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要监视的 App"
        panel.message = "这些 App 运行时，自动保持 Mac 唤醒（屏幕可熄灭）"
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        if !state.triggerApps.contains(where: { $0.bundleId == bundleId }) {
            state.triggerApps.append(TriggerApp(bundleId: bundleId, name: name))
            applyAll()
        }
    }

    // MARK: 免密组件

    private func installHelper() {
        let result = PrivilegedHelper.install()
        state.helperInstalled = PrivilegedHelper.isInstalled
        if result.ok {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "免密模式已启用"
            alert.informativeText = "以后切换\"合盖继续工作\"、电池低电量自动保护都不再需要密码。\n\n已写入：\n· /usr/local/bin/qingxing-privileged（白名单助手，只接受固定的 pmset 变更）\n· /etc/sudoers.d/qingxing（仅允许当前用户免密执行该助手）\n\n可随时在设置中卸载。"
            alert.runModal()
        } else {
            showAlert("安装失败", informative: result.message)
        }
    }

    private func uninstallHelper() {
        let result = PrivilegedHelper.uninstall()
        state.helperInstalled = PrivilegedHelper.isInstalled
        if result.ok {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "免密模式已卸载"
            alert.informativeText = "已删除助手与 sudoers 规则。之后切换合盖模式会重新需要管理员密码。"
            alert.runModal()
        } else {
            showAlert("卸载失败", informative: result.message)
        }
    }

    // MARK: 动作

    @objc private func toggleLid(_ sender: NSMenuItem) {
        performLidToggle()
    }

    private func performLidToggle() {
        guard !state.lidBusy else { return }
        state.lidBusy = true
        // 授权弹窗不能在菜单追踪事件里同步执行，挪到下一个 runloop
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer { self.state.lidBusy = false }
            let turningOn = !self.state.lidOn
            // 关闭时始终清除全部配置（彻底恢复），开启时按生效条件对应配置
            let profile = turningOn ? self.state.powerScope.pmsetProfile : "-a"
            let result = PMSet.setLidSleepDisabled(turningOn, profile: profile)
            if result.ok {
                if result.usedGlobalFallback {
                    self.showAlert("已退回全局设置",
                                   informative: "当前 macOS 不支持按电源类型（插电/电池）分别设置合盖行为，已改为全局\(turningOn ? "开启" : "关闭")\"合盖继续工作\"。")
                }
            } else if !result.cancelled {
                self.showAlert("设置失败",
                               informative: "执行 pmset 失败：\(result.message)\n\n也可以在终端手动执行：\n/usr/bin/pmset \(profile) disablesleep \(turningOn ? "1" : "0")")
            }
            self.refreshLidState()
            self.applyAll()
        }
    }

    @objc private func toggleSystemAwake(_ sender: NSMenuItem) {
        state.systemAwakeOn.toggle()
        sender.state = state.systemAwakeOn ? .on : .off
    }

    @objc private func toggleDisplayAwake(_ sender: NSMenuItem) {
        state.displayAwakeOn.toggle()
        sender.state = state.displayAwakeOn ? .on : .off
    }

    @objc private func setScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let scope = PowerScope(rawValue: raw) else { return }
        state.powerScope = scope
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? Int) == raw ? .on : .off
        }
    }

    @objc private func screenOffAction(_ sender: NSMenuItem) {
        screenOffNow()
    }

    private func screenOffNow() {
        state.systemAwakeOn = true
        applyAll()
        // 稍等界面收起再熄屏，避免和动画打架
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            PMSet.run(["displaysleepnow"])
        }
    }

    @objc private func restoreDefaultsAction(_ sender: NSMenuItem) {
        restoreDefaults()
    }

    private func restoreDefaults() {
        state.systemAwakeOn = false
        state.displayAwakeOn = false
        batteryGuardTripped = false
        applyAll()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let result = PMSet.setLidSleepDisabled(false, profile: "-a")
            if result.ok {
                self.refreshLidState()
                self.showAlert("已恢复默认", informative: "所有防睡眠模式已关闭，macOS 恢复正常睡眠行为（含合盖睡眠）。")
            } else if !result.cancelled {
                self.showAlert("恢复失败", informative: "清除 pmset 设置失败：\(result.message)")
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        toggleLoginItem()
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            state.loginItemEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            state.loginItemEnabled = SMAppService.mainApp.status == .enabled
            showAlert("设置登录项失败", informative: "\(error.localizedDescription)\n\n提示：建议先把「清醒」放在\"应用程序\"文件夹后再开启登录启动。")
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        showSettings()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "清醒 Qingxing v1.1.0"
        alert.informativeText = """
        开源的 macOS 菜单栏防睡眠小工具（简体中文）。

        🌙 合盖继续工作 —— 扣盖不休眠，pmset disablesleep 实现
        🌑 关屏继续工作 —— IOKit 断言，屏幕可熄、任务不断
        ☀️ 屏幕常亮 —— 屏幕和系统都不睡眠
        ⚡ 生效条件 —— 始终 / 仅插电源时 / 仅用电池时
        🎯 App 触发 —— 指定 App 运行时自动保持唤醒
        🔑 免密模式 —— 白名单助手 + sudoers，切换不再要密码
        🛡️ 电池保护 —— 低电量自动恢复睡眠 + 启动自检

        注意：合盖运行时请注意散热；用电池合盖运行会持续耗电。
        设置面板：菜单 → ⚙️ 设置…（⌘,）
        """
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 提示

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "「清醒」已开始在菜单栏运行"
        alert.informativeText = "点击菜单栏的 🌙/☕ 图标即可：\n· 合盖继续工作（扣盖不休眠）\n· 关屏继续工作（屏幕可熄、任务不断）\n· 屏幕常亮 · App 触发 · 电池保护\n· 选择\"仅插电源 / 仅用电池\"时生效\n\n更多选项在 ⚙️ 设置… 中，随时可一键恢复 macOS 默认行为。"
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showAlert(_ title: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
