import Foundation
import IOKit.ps

/// Whether the Mac is running on battery (or in Low Power Mode), so background downloads go gently.
public enum PowerState {
  public static var onBattery: Bool {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
    return type == kIOPSBatteryPowerValue
  }
}
