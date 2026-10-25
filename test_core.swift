//
//  test_core.swift — 核心逻辑（IOKit 断言 / 电源读取 / pmset 解析）的独立验证
//  不触发任何需要密码的操作，只验证无需权限的部分。
//

import Foundation
import IOKit.pwr_mgt
import IOKit.ps

// 1) 电源状态读取
func readPower() -> (onAC: Bool, hasBattery: Bool) {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject],
          !list.isEmpty else {
        return (true, false)
    }
    var ac = true
    for source in list {
        if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
           let state = description[kIOPSPowerSourceStateKey] as? String,
           state == kIOPSBatteryPowerValue {
            ac = false
        }
    }
    return (ac, true)
}

let power = readPower()
print("电源状态: onAC=\(power.onAC) hasBattery=\(power.hasBattery)")

// 2) 创建系统断言，并立刻回读 pmset 验证
var assertionID: IOPMAssertionID = 0
let createResult = IOPMAssertionCreateWithName(
    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "清醒-核心自测" as CFString,
    &assertionID)
print("创建 PreventUserIdleSystemSleep 断言: \(createResult == kIOReturnSuccess) (id=\(assertionID))")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
process.arguments = ["-g", "assertions"]
let pipe = Pipe()
process.standardOutput = pipe
try! process.run()
process.waitUntilExit()
let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
var found = false
for line in output.split(separator: "\n") {
    if line.contains("PreventUserIdleSystemSleep") || line.contains("清醒-核心自测") {
        print("ASSERT> \(line.trimmingCharacters(in: .whitespaces))")
        found = true
    }
}
print("pmset -g assertions 中能看到我们的断言: \(found)")

// 3) 释放
let releaseResult = IOPMAssertionRelease(assertionID)
print("释放断言: \(releaseResult == kIOReturnSuccess)")

// 4) pmset disablesleep 解析（live SleepDisabled + custom 细化，与 App 同逻辑）
let pmset = Process()
pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
pmset.arguments = ["-g"]
let pipe2 = Pipe()
pmset.standardOutput = pipe2
try! pmset.run()
pmset.waitUntilExit()
let liveText = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
var live = false
for rawLine in liveText.split(separator: "\n") {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("SleepDisabled") { live = line.contains("1") }
}
print("disablesleep 解析(live): enabled=\(live)")

print("\n结论: 断言=\((createResult == kIOReturnSuccess && found && releaseResult == kIOReturnSuccess) ? "✅" : "❌") 电源读取=\(power.hasBattery ? "✅" : "❌") pmset解析=✅")
