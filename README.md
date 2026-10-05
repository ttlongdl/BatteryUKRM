# BatteryUKRM

BatteryUKRM is a rootless jailbreak tweak for iOS that preserves the native Battery Health experience on supported replaced-battery configurations.

## 1.0.2

- Preserves the 1.0.1 repair-warning and genuine-battery behavior.
- Keeps the native Maximum Capacity value supplied by iOS.
- Adds the real battery Cycle Count read from AppleSmartBattery.
- Adds localized Vietnamese/English Cycle Count text.
- Suppresses the Settings repair badge.

## Tested configuration

BatteryUKRM 1.0.2 has been tested successfully on:

- **Device:** iPhone 12 Pro
- **iOS:** 17.0
- **Jailbreak:** rootless
- **Battery:** replaced with an Apple battery
- **Battery BMS/flex:** original battery BMS/flex was **not transplanted** to the replacement battery

On this configuration, BatteryUKRM 1.0.2 works as intended, including the native Battery Health experience and real Cycle Count display.

### Display / screen replacement

BatteryUKRM is currently focused on battery-related repair information. Display/screen replacement behavior has **not been tested**, and no claim is made that the tweak hides or modifies replaced-display information.

The existing repair/Unknown Part hooks may potentially affect other repair warnings, but this has not been verified. Treat display-related behavior as **untested** until confirmed on a real device.

Package: `com.ttlongdl.batteryukrm`
