//
//  清醒 (Qingxing) — macOS 菜单栏防睡眠小工具
//
//  三种模式：
//    1. 合盖继续工作   —— pmset disablesleep（需一次管理员授权）
//    2. 关屏继续工作   —— IOKit 系统断言（屏幕可熄、任务不断）
//    3. 屏幕常亮       —— IOKit 显示断言（不熄屏、不休眠）
//  生效条件：始终 / 仅插电源时 / 仅用电池时
//
//  构建：./build.sh
//

import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

// MARK: - 生效条件

enum PowerScope: Int, CaseIterable {
    case always = 0
    case acOnly = 1
    case batteryOnly = 2

    var label: String {
        switch self {
        case .always: return "始终生效"
        case .acOnly: return "仅插电源时生效"
        case .batteryOnly: return "仅用电池时生效"
        }
    }

    var pmsetProfile: String {
        switch self {
        case .always: return "-a"
        case .acOnly: return "-c"
        case .batteryOnly: return "-b"
        }
    }

    func active(onAC: Bool) -> Bool {
        switch self {
        case .always: return true
        case .acOnly: return onAC
        case .batteryOnly: return !onAC
        }
    }
}

// MARK: - 电源状态监控

final class PowerMonitor {
    private var runLoopSource: CFRunLoopSource?
    var onChange: (() -> Void)?

    private(set) var onAC: Bool = true
    private(set) var hasBattery: Bool = false

    init() {
        refresh()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refresh()
            monitor.onChange?()
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, pointer)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject],
              !list.isEmpty else {
            // 没有电池设备（台式机 / 未装电池），视为一直插电
            hasBattery = false
            onAC = true
            return
        }
        hasBattery = true
        var ac = true
        for source in list {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                ac = false
            }
        }
        onAC = ac
    }
}

// MARK: - IOKit 电源断言（无需权限）

final class AssertionManager {
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0

    var systemHeld: Bool { systemAssertionID != 0 }
    var displayHeld: Bool { displayAssertionID != 0 }

    @discardableResult
    func setSystemAwake(_ on: Bool) -> Bool {
        if on {
            guard systemAssertionID == 0 else { return true }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Qingxing: system awake (display may sleep)" as CFString,
                &id)
            if result == kIOReturnSuccess {
                systemAssertionID = id
                return true
            }
            return false
        } else {
            guard systemAssertionID != 0 else { return true }
            let ok = IOPMAssertionRelease(systemAssertionID) == kIOReturnSuccess
            systemAssertionID = 0
            return ok
        }
    }

    @discardableResult
    func setDisplayAwake(_ on: Bool) -> Bool {
        if on {
            guard displayAssertionID == 0 else { return true }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Qingxing: display awake" as CFString,
                &id)
            if result == kIOReturnSuccess {
                displayAssertionID = id
                return true
            }
            return false
        } else {
            guard displayAssertionID != 0 else { return true }
            let ok = IOPMAssertionRelease(displayAssertionID) == kIOReturnSuccess
            displayAssertionID = 0
            return ok
        }
    }
}

// MARK: - pmset 封装

enum PMSet {
    /// 同步执行 pmset（只用于无需 root 的查询 / displaysleepnow）
    @discardableResult
    static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// 读取合盖睡眠开关的实际状态。
    /// 注意：macOS 26+ 的 `pmset -g custom` 不再列出 disablesleep，
    /// 权威位置是 `pmset -g` 输出里的 SleepDisabled（live 值）；
    /// 旧系统若 custom 里区分了电源配置，则用它细化。
    static func lidSleepDisabled() -> (battery: Bool, ac: Bool) {
        var live = false
        if let text = run(["-g"]) {
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("SleepDisabled") { live = line.contains("1") }
            }
        }
        var battery = live
        var ac = live
        var section = ""
        var sawCustomDetail = false
        if let text = run(["-g", "custom"]) {
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("Battery") { section = "b"; continue }
                if line.hasPrefix("AC") { section = "a"; continue }
                if line.hasPrefix("UPS") { section = ""; continue }
                if line.hasPrefix("disablesleep") {
                    sawCustomDetail = true
                    let on = line.contains("1")
                    if section == "b" { battery = on }
                    if section == "a" { ac = on }
                }
            }
        }
        if !sawCustomDetail {
            battery = live
            ac = live
        }
        return (battery, ac)
    }

    enum PrivilegedResult { case ok, cancelled, failed }

    /// 以管理员权限执行命令（弹出系统授权对话框），返回结果和真实错误信息
    static func runPrivileged(_ command: String) -> (result: PrivilegedResult, message: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"「清醒」修改合盖睡眠设置需要管理员权限\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error == nil { return (.ok, "") }
        let number = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error?[NSAppleScript.errorMessage] as? String)
            ?? (error?[NSAppleScript.errorBriefMessage] as? String)
            ?? "未知错误"
        // -128 = 用户取消了授权对话框
        return (number == -128 ? .cancelled : .failed, message)
    }

    /// 记录启用合盖模式前各电源配置的闲置睡眠时长（分钟），关闭时恢复
    private static func saveSleepTimers() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "savedSleepB") == nil else { return }
        guard let text = run(["-g", "custom"]) else { return }
        var section = ""
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery") { section = "b"; continue }
            if line.hasPrefix("AC") { section = "a"; continue }
            if line.hasPrefix("UPS") { section = ""; continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.first == "sleep", parts.count >= 2, let minutes = Int(parts[1]) {
                if section == "b" { defaults.set(minutes, forKey: "savedSleepB") }
                if section == "a" { defaults.set(minutes, forKey: "savedSleepC") }
            }
        }
    }

    private static func restoredSleepCommands() -> [String] {
        let defaults = UserDefaults.standard
        var commands: [String] = []
        if let battery = defaults.object(forKey: "savedSleepB") as? Int {
            commands.append("-b sleep \(battery)")
        }
        if let ac = defaults.object(forKey: "savedSleepC") as? Int {
            commands.append("-c sleep \(ac)")
        }
        return commands
    }

    private static func clearSavedSleepTimers() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "savedSleepB")
        defaults.removeObject(forKey: "savedSleepC")
    }

    /// 设置合盖睡眠开关。返回 (是否成功, 是否退回了全局设置, 是否被用户取消, 错误信息)
    /// macOS 26/27 上仅设 disablesleep 在电池下可能仍被闲置睡眠策略覆盖，
    /// 因此开启时同步把对应配置的 sleep 计时改为 0，关闭时恢复原值。
    static func setLidSleepDisabled(_ disabled: Bool, profile: String) -> (ok: Bool, usedGlobalFallback: Bool, cancelled: Bool, message: String) {
        func command(for profile: String) -> String {
            if disabled {
                saveSleepTimers()
                return "/usr/bin/pmset \(profile) disablesleep 1; /usr/bin/pmset \(profile) sleep 0"
            }
            var restore = "/usr/bin/pmset -a disablesleep 0"
            for item in restoredSleepCommands() {
                restore += "; /usr/bin/pmset \(item)"
            }
            return restore
        }
        switch runPrivileged(command(for: profile)) {
        case (.ok, _):
            if !disabled { clearSavedSleepTimers() }
            return (true, false, false, "")
        case (.cancelled, let message):
            return (false, false, true, message)
        case (.failed, let message):
            // 个别系统版本不支持按电源配置设置 disablesleep，退回全局
            if profile != "-a" {
                switch runPrivileged(command(for: "-a")) {
                case (.ok, _):
                    if !disabled { clearSavedSleepTimers() }
                    return (true, true, false, "")
                case (.cancelled, let message2):
                    return (false, false, true, message2)
                case (.failed, let message2):
                    return (false, false, false, message2)
                }
            }
            return (false, false, false, message)
        }
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let power = PowerMonitor()
    private let assertions = AssertionManager()
    private var lidOnCached = false

    // MARK: 持久化设置

    private var systemAwakeOn: Bool {
        get { UserDefaults.standard.bool(forKey: "systemAwakeOn") }
        set { UserDefaults.standard.set(newValue, forKey: "systemAwakeOn") }
    }

    private var displayAwakeOn: Bool {
        get { UserDefaults.standard.bool(forKey: "displayAwakeOn") }
        set { UserDefaults.standard.set(newValue, forKey: "displayAwakeOn") }
    }

    private var scopeRaw: Int {
        get { UserDefaults.standard.integer(forKey: "powerScope") }
        set { UserDefaults.standard.set(newValue, forKey: "powerScope") }
    }

    private var scope: PowerScope { PowerScope(rawValue: scopeRaw) ?? .always }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = iconImage(active: false)
        }
        statusItem.menu = menu
        menu.delegate = self

        power.onChange = { [weak self] in
            self?.applyAssertions()
        }
        let lid = PMSet.lidSleepDisabled()
        lidOnCached = lid.battery || lid.ac
        applyAssertions()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWelcome()
        }
    }

    // MARK: 状态计算

    /// 断言类开关在当前电源下是否应生效
    private var assertionsEffective: Bool {
        scope.active(onAC: power.onAC)
    }

    private func applyAssertions() {
        let shouldHold = assertionsEffective
        assertions.setSystemAwake(systemAwakeOn && shouldHold)
        assertions.setDisplayAwake(displayAwakeOn && shouldHold)
        updateIcon()
    }

    private func updateIcon() {
        let active = assertions.systemHeld || assertions.displayHeld || lidOnCached
        statusItem.button?.image = iconImage(active: active)
        var tips: [String] = []
        if lidOnCached { tips.append("合盖继续工作") }
        if assertions.systemHeld { tips.append("关屏继续工作") }
        if assertions.displayHeld { tips.append("屏幕常亮") }
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

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        power.refresh()
        let lid = PMSet.lidSleepDisabled()
        lidOnCached = lid.battery || lid.ac
        updateIcon()

        // —— 状态区 ——
        let powerText: String
        if !power.hasBattery {
            powerText = "🖥️  电源：未检测到电池"
        } else {
            powerText = power.onAC ? "🔌  电源：交流电源（插电中）" : "🔋  电源：电池供电中"
        }
        addItem(powerText, enabled: false)

        var active: [String] = []
        if lid.ac || lid.battery {
            var label = "合盖继续工作"
            if lid.ac != lid.battery {
                label += lid.ac ? "（插电源时）" : "（用电池时）"
            }
            active.append(label)
        }
        if assertions.systemHeld { active.append("关屏继续工作") }
        if assertions.displayHeld { active.append("屏幕常亮") }

        if active.isEmpty {
            addItem("😴  Mac 可正常睡眠（未开启任何模式）", enabled: false)
        } else {
            addItem("✅  保持清醒中：" + active.joined(separator: "、"), enabled: false)
        }
        if (systemAwakeOn || displayAwakeOn) && !assertionsEffective {
            addItem("⏸️  当前电源不满足生效条件（\(scope.label)），暂不生效", enabled: false)
        }

        menu.addItem(.separator())

        // —— 模式开关 ——
        let lidItem = addItem("🌙  合盖继续工作（扣盖不休眠）", action: #selector(toggleLid(_:)))
        lidItem.state = lidOnCached ? .on : .off
        lidItem.toolTip = "合上盖子（扣盖）后 Mac 继续运行，屏幕关闭、任务不断。\n通过系统 pmset 修改 disablesleep 设置，首次切换需要输入一次管理员密码。\n⚠️ 合盖运行时请注意散热；用电池时也会持续耗电。"

        let systemItem = addItem("🌑  关屏继续工作（屏幕可熄、任务不断）", action: #selector(toggleSystemAwake(_:)))
        systemItem.state = systemAwakeOn ? .on : .off
        systemItem.toolTip = "系统保持唤醒，屏幕到时间会正常熄灭（也可点“立即关屏”）。\n下载、编译、跑任务都不中断。基于 IOKit 断言实现，无需任何权限。"

        let displayItem = addItem("☀️  屏幕常亮（不熄屏、不休眠）", action: #selector(toggleDisplayAwake(_:)))
        displayItem.state = displayAwakeOn ? .on : .off
        displayItem.toolTip = "屏幕和系统都不进入睡眠，相当于一直 caffeinate -d。"

        let screenOff = addItem("⏻  一键：立即关屏并继续工作", action: #selector(screenOffNow(_:)))
        screenOff.toolTip = "自动打开“关屏继续工作”，然后立即熄灭屏幕；任务继续运行。\n按任意键 / 动一下鼠标即可点亮屏幕。"

        menu.addItem(.separator())

        // —— 生效条件 ——
        let scopeItem = addItem("⚡  生效条件（对以上模式）")
        scopeItem.toolTip = "决定各模式在什么电源状态下生效。\n· 断言类模式（关屏/常亮）：切换电源时自动生效或恢复。\n· 合盖模式：按 pmset 的对应电源配置设置（修改后请重新开关一次合盖模式）。"
        let submenu = NSMenu()
        for s in PowerScope.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(setScope(_:)), keyEquivalent: "")
            item.target = self
            item.state = (s.rawValue == scopeRaw) ? .on : .off
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
        let restore = addItem("↩️  恢复 macOS 默认（允许正常睡眠）", action: #selector(restoreDefaults(_:)))
        restore.toolTip = "关闭所有模式，并清除 pmset 的 disablesleep 设置（需要管理员密码）"

        let loginItem = addItem("🚀  登录时自动启动", action: #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

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

    // MARK: 动作

    @objc private func toggleLid(_ sender: NSMenuItem) {
        // 授权弹窗不能在菜单追踪事件里同步执行，挪到下一个 runloop
        DispatchQueue.main.async { [weak self] in
            self?.performLidToggle()
        }
    }

    private func performLidToggle() {
        let current = PMSet.lidSleepDisabled()
        let turningOn = !(current.battery || current.ac)
        // 关闭时始终清除全部配置（彻底恢复），开启时按生效条件对应配置
        let profile = turningOn ? scope.pmsetProfile : "-a"
        let result = PMSet.setLidSleepDisabled(turningOn, profile: profile)
        if result.ok {
            if result.usedGlobalFallback {
                showAlert("已退回全局设置",
                          informative: "当前 macOS 不支持按电源类型（插电/电池）分别设置合盖行为，已改为全局\(turningOn ? "开启" : "关闭")“合盖继续工作”。")
            }
        } else if !result.cancelled {
            showAlert("设置失败",
                      informative: "执行 pmset 失败：\(result.message)\n\n也可以在终端手动执行：\n/usr/bin/pmset \(profile) disablesleep \(turningOn ? "1" : "0")")
        }
        let newState = PMSet.lidSleepDisabled()
        lidOnCached = newState.battery || newState.ac
        updateIcon()
    }

    @objc private func toggleSystemAwake(_ sender: NSMenuItem) {
        systemAwakeOn.toggle()
        sender.state = systemAwakeOn ? .on : .off
        applyAssertions()
    }

    @objc private func toggleDisplayAwake(_ sender: NSMenuItem) {
        displayAwakeOn.toggle()
        sender.state = displayAwakeOn ? .on : .off
        applyAssertions()
    }

    @objc private func setScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int else { return }
        scopeRaw = raw
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? Int) == raw ? .on : .off
        }
        applyAssertions()
    }

    @objc private func screenOffNow(_ sender: NSMenuItem) {
        systemAwakeOn = true
        applyAssertions()
        // 稍等菜单收起再熄屏，避免和菜单动画打架
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            PMSet.run(["displaysleepnow"])
        }
    }

    @objc private func restoreDefaults(_ sender: NSMenuItem) {
        systemAwakeOn = false
        displayAwakeOn = false
        applyAssertions()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let result = PMSet.setLidSleepDisabled(false, profile: "-a")
            if result.ok {
                self.lidOnCached = false
                self.updateIcon()
                self.showAlert("已恢复默认", informative: "所有防睡眠模式已关闭，macOS 恢复正常睡眠行为（含合盖睡眠）。")
            } else if !result.cancelled {
                self.showAlert("恢复失败", informative: "清除 pmset 设置失败：\(result.message)")
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } catch {
            showAlert("设置登录项失败", informative: "\(error.localizedDescription)\n\n提示：建议先把「清醒」拖到“应用程序”文件夹后再开启登录启动。")
        }
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "清醒 Qingxing v1.0.0"
        alert.informativeText = """
        开源的 macOS 菜单栏防睡眠小工具（简体中文）。

        🌙 合盖继续工作 —— 通过系统 pmset 设置 disablesleep 实现，合上盖子（扣盖）后 Mac 继续运行、屏幕关闭。切换时需要一次管理员密码。
        🌑 关屏继续工作 —— IOKit 电源断言，屏幕可以正常熄灭，下载 / 编译等任务不中断，无需权限。
        ☀️ 屏幕常亮 —— 屏幕和系统都不睡眠。
        ⚡ 生效条件 —— 始终 / 仅插电源时 / 仅用电池时。

        注意：合盖运行时请注意散热；用电池合盖运行会持续耗电。
        """
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 提示

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "「清醒」已开始在菜单栏运行"
        alert.informativeText = "点击菜单栏的 🌙/☕ 图标即可：\n· 合盖继续工作（扣盖不休眠）\n· 关屏继续工作（屏幕可熄、任务不断）\n· 屏幕常亮\n· 选择“仅插电源 / 仅用电池”时生效\n\n随时可一键恢复 macOS 默认行为。"
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
