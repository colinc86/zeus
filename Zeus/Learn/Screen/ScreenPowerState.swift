import Foundation
import IOKit.ps

@MainActor enum ScreenPowerState {
    static var deferDescriptions: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = values[kIOPSCurrentCapacityKey] as? Int, let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return false }
            return Double(current) / Double(maximum) < 0.3
        }
    }
}
