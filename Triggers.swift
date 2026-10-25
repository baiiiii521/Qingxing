//
//  Triggers.swift — App 触发：指定 App 运行时自动保持唤醒
//

import AppKit
import IOKit.pwr_mgt

struct TriggerApp: Codable, Identifiable, Equatable {
    let bundleId: String
    let name: String
    var id: String { bundleId }
}

final class AppTriggerMonitor {
    private(set) var activeNames: [String] = []

    private var assertionID: IOPMAssertionID = 0
    var held: Bool { assertionID != 0 }

    private func runningMatches(from triggers: [TriggerApp]) -> [TriggerApp] {
        let running = NSWorkspace.shared.runningApplications
        return triggers.filter { trigger in
            running.contains { $0.bundleIdentifier == trigger.bundleId }
        }
    }

    /// 重新评估触发断言（主线程调用）。返回当前是否有触发生效。
    @discardableResult
    func reevaluate(triggers: [TriggerApp], allowed: Bool) -> Bool {
        let matches = allowed ? runningMatches(from: triggers) : []
        activeNames = Array(Set(matches.map(\.name))).sorted()
        let shouldHold = !matches.isEmpty
        if shouldHold && assertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Qingxing: app trigger (auto)" as CFString,
                &id)
            if result == kIOReturnSuccess {
                assertionID = id
            }
        } else if !shouldHold && assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        return shouldHold
    }
}
