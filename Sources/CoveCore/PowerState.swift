import Foundation
#if os(macOS)
import IOKit.ps
#endif

/// Whether the device should go gently on background downloads: a Mac on battery, or Low Power Mode.
public enum PowerState {
  public static var onBattery: Bool {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
    #if os(macOS)
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
    return type == kIOPSBatteryPowerValue
    #else
    // An iPhone is nearly always on battery; only Low Power Mode slows Cove down there, and iOS
    // already limits how long Cove can run in the background.
    return false
    #endif
  }
}
