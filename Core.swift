//
//  Core.swift — 清醒 Qingxing 核心层
//  电源监控（含电量百分比）· IOKit 断言 · pmset 封装 · 免密特权组件 · 本地通知
//

import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import UserNotifications

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

// MARK: - 电源状态监控（含电池百分比）

final class PowerMonitor {
    private var runLoopSource: CFRunLoopSource?
    var onChange: (() -> Void)?

    private(set) var onAC: Bool = true
    private(set) var hasBattery: Bool = false
    private(set) var batteryPercent: Int?

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
            batteryPercent = nil
            return
        }
        hasBattery = true
        var ac = true
        var percent: Int?
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String, state == kIOPSBatteryPowerValue {
                ac = false
            }
            if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = max <= 100 ? capacity : Int((Double(capacity) / Double(max) * 100).rounded())
            }
        }
        onAC = ac
        batteryPercent = percent
    }
}

// MARK: - IOKit 电源断言（无需权限）

final class AssertionManager {
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var triggerAssertionID: IOPMAssertionID = 0

    var systemHeld: Bool { systemAssertionID != 0 }
    var displayHeld: Bool { displayAssertionID != 0 }
    var triggerHeld: Bool { triggerAssertionID != 0 }

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

    /// App 触发用的独立断言（与手动开关互不影响）
    @discardableResult
    func setTriggerActive(_ on: Bool) -> Bool {
        if on {
            guard triggerAssertionID == 0 else { return true }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Qingxing: app trigger (auto)" as CFString,
                &id)
            if result == kIOReturnSuccess {
                triggerAssertionID = id
                return true
            }
            return false
        } else {
            guard triggerAssertionID != 0 else { return true }
            let ok = IOPMAssertionRelease(triggerAssertionID) == kIOReturnSuccess
            triggerAssertionID = 0
            return ok
        }
    }
}

// MARK: - 免密特权组件（/usr/local/bin/qingxing-privileged + sudoers）

enum PrivilegedHelper {
    static let helperPath = "/usr/local/bin/qingxing-privileged"
    static let sudoersPath = "/etc/sudoers.d/qingxing"
    private(set) static var isInstalled = false

    /// 白名单 shell 助手：只接受固定的几个子命令，参数严格校验
    static let script = """
    #!/bin/sh
    # Qingxing (qingxing) privileged helper - whitelist-only pmset changes
    case "$1" in
      ping)
        exit 0 ;;
      lid-on)
        case "$2" in a|b|c) ;; *) exit 64 ;; esac
        /usr/bin/pmset -"$2" disablesleep 1 && exec /usr/bin/pmset -"$2" sleep 0 ;;
      lid-off)
        exec /usr/bin/pmset -a disablesleep 0 ;;
      sleep-set)
        case "$2" in b|c) ;; *) exit 64 ;; esac
        case "$3" in ''|*[!0-9]*) exit 64 ;; esac
        [ "$3" -le 240 ] || exit 64
        exec /usr/bin/pmset -"$2" sleep "$3" ;;
      *)
        exit 64 ;;
    esac
    """

    /// 检测免密组件是否可用（sudo -n ping，不弹任何框）
    @discardableResult
    static func refresh() -> Bool {
        guard FileManager.default.fileExists(atPath: helperPath) else {
            isInstalled = false
            return false
        }
        isInstalled = run(["ping"])
        return isInstalled
    }

    /// 免密执行白名单子命令
    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", helperPath] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    /// 一次性安装（弹一次管理员密码框）：写入助手 + 校验并落盘 sudoers
    static func install() -> (ok: Bool, message: String) {
        let base64 = Data(script.utf8).base64EncodedString()
        let user = NSUserName()
        let command = "mkdir -p /usr/local/bin && echo \(base64) | base64 -d > \(helperPath) && chmod 755 \(helperPath) && chown root:wheel \(helperPath) && "
            + "printf '%s\\n' '\(user) ALL=(root) NOPASSWD: \(helperPath)' > /etc/sudoers.d/qingxing.tmp && "
            + "visudo -cf /etc/sudoers.d/qingxing.tmp && mv /etc/sudoers.d/qingxing.tmp \(sudoersPath) && chmod 440 \(sudoersPath)"
        let (result, message) = PMSet.runPrivileged(command, prompt: "「清醒」安装免密组件（写入 /usr/local/bin 与 /etc/sudoers.d）")
        refresh()
        return (result == .ok, message)
    }

    /// 卸载免密组件（弹一次管理员密码框）
    static func uninstall() -> (ok: Bool, message: String) {
        let (result, message) = PMSet.runPrivileged("rm -f \(helperPath) \(sudoersPath)", prompt: "「清醒」卸载免密组件")
        refresh()
        return (result == .ok, message)
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

    /// 读取各电源配置当前的闲置睡眠时长（分钟）；未知返回 1（非 0 即可）
    static func sleepTimers() -> (battery: Int, ac: Int) {
        var battery = 1
        var ac = 1
        guard let text = run(["-g", "custom"]) else { return (battery, ac) }
        var section = ""
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery") { section = "b"; continue }
            if line.hasPrefix("AC") { section = "a"; continue }
            if line.hasPrefix("UPS") { section = ""; continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.first == "sleep", parts.count >= 2, let minutes = Int(parts[1]) {
                if section == "b" { battery = minutes }
                if section == "a" { ac = minutes }
            }
        }
        return (battery, ac)
    }

    enum PrivilegedResult { case ok, cancelled, failed }

    /// 以管理员权限执行命令（弹出系统授权对话框），返回结果和真实错误信息
    static func runPrivileged(_ command: String, prompt: String = "「清醒」修改合盖睡眠设置需要管理员权限") -> (result: PrivilegedResult, message: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
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
    static func saveSleepTimers() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "savedSleepB") == nil else { return }
        let timers = sleepTimers()
        defaults.set(timers.battery, forKey: "savedSleepB")
        defaults.set(timers.ac, forKey: "savedSleepC")
    }

    static func restoredSleepCommands() -> [(profile: String, minutes: Int)] {
        let defaults = UserDefaults.standard
        var items: [(String, Int)] = []
        if let battery = defaults.object(forKey: "savedSleepB") as? Int {
            items.append(("-b", battery))
        }
        if let ac = defaults.object(forKey: "savedSleepC") as? Int {
            items.append(("-c", ac))
        }
        return items
    }

    static func clearSavedSleepTimers() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "savedSleepB")
        defaults.removeObject(forKey: "savedSleepC")
    }

    /// 设置合盖睡眠开关。
    /// 返回 (是否成功, 是否退回了全局设置, 是否被用户取消, 错误信息)。
    /// interactive=false 时绝不弹密码框（用于自动场景：优先免密，失败即返回）。
    /// macOS 26/27 上仅设 disablesleep 在电池下可能仍被闲置睡眠策略覆盖，
    /// 因此开启时同步把对应配置的 sleep 计时改为 0，关闭时恢复原值。
    static func setLidSleepDisabled(_ disabled: Bool, profile: String, interactive: Bool = true) -> (ok: Bool, usedGlobalFallback: Bool, cancelled: Bool, message: String) {
        let shortProfile = String(profile.dropFirst()) // "-a" → "a"
        // 优先走免密组件
        if PrivilegedHelper.isInstalled {
            if disabled {
                saveSleepTimers()
                if PrivilegedHelper.run(["lid-on", shortProfile]) {
                    return (true, false, false, "")
                }
            } else {
                if PrivilegedHelper.run(["lid-off"]) {
                    for item in restoredSleepCommands() {
                        _ = PrivilegedHelper.run(["sleep-set", String(item.profile.dropFirst()), String(item.minutes)])
                    }
                    clearSavedSleepTimers()
                    return (true, false, false, "")
                }
            }
            // 免密组件声称可用但执行失败 → 回落到交互路径重试
        }
        guard interactive else {
            return (false, false, false, "此操作需要管理员密码")
        }
        func appleScriptCommand(for prof: String) -> String {
            if disabled {
                saveSleepTimers()
                return "/usr/bin/pmset \(prof) disablesleep 1; /usr/bin/pmset \(prof) sleep 0"
            }
            var restore = "/usr/bin/pmset -a disablesleep 0"
            for item in restoredSleepCommands() {
                restore += "; /usr/bin/pmset \(item.profile) sleep \(item.minutes)"
            }
            return restore
        }
        switch runPrivileged(appleScriptCommand(for: profile)) {
        case (.ok, _):
            if !disabled { clearSavedSleepTimers() }
            return (true, false, false, "")
        case (.cancelled, let message):
            return (false, false, true, message)
        case (.failed, let message):
            // 个别系统版本不支持按电源配置设置 disablesleep，退回全局
            if profile != "-a" {
                switch runPrivileged(appleScriptCommand(for: "-a")) {
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

// MARK: - 本地通知

enum Notify {
    private static var requested = false

    static func requestAuthorization() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
