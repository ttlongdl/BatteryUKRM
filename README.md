# BatteryUKRM

BatteryUKRM is a **rootless jailbreak tweak** for iOS that restores useful Battery Health information on supported replaced-battery configurations while keeping each feature independently configurable.

Package: `com.ttlongdl.batteryukrm`

## BatteryUKRM 1.1.0

Version 1.1.0 turns the original all-or-nothing tweak into three independent modules:

- **Hide Battery Repair Warnings** — hides battery-related “Unknown Part / Repair Needed” information in Settings and About and suppresses the Settings repair badge.
- **Restore Maximum Capacity** — restores the native Maximum Capacity / Battery Health state on supported replacement batteries.
- **Show Cycle Count** — reads the real `CycleCount` value from `AppleSmartBattery` and displays it in Battery Health & Charging.

All three modules are **enabled by default**, preserving the behavior of BatteryUKRM 1.0.2 after upgrading. A respring is required after changing switches.

### New in 1.1.0

- Added a native Settings preference pane under **Settings → Tweaks → BatteryUKRM**.
- Added independent switches for repair warnings, Maximum Capacity and Cycle Count.
- Added a working **Respring** button.
- Added Vietnamese and English localization based on the system language.
- Added the BatteryUKRM preference icon.
- Refactored hook installation so a disabled module does **not install its corresponding hooks**. This makes compatibility testing and troubleshooting much easier without uninstalling the whole tweak.
- Keeps the real Cycle Count implementation introduced in 1.0.2.

## Compatibility and known issues

BatteryUKRM relies on private iOS Battery Health / Settings classes. Apple can change these implementations between iOS versions, so behavior is not guaranteed to be identical on every release.

> **iOS 17.7 known compatibility issue:** a real-device report showed that the **Maximum Capacity** portion may fail to hook correctly and can leave the Maximum Capacity area loading/spinning or unavailable. The **Cycle Count** module was still able to display the reported cycle count on that device. If this occurs, disable **Restore Maximum Capacity**, keep the other desired modules enabled, and respring. This is one of the reasons the features are separated in 1.1.0.

This should be treated as a compatibility limitation rather than evidence that the battery itself is faulty.

## Tested configuration

BatteryUKRM has been confirmed working on:

- **Device:** iPhone 12 Pro
- **iOS:** 17.0
- **Jailbreak:** Dopamine rootless
- **Battery:** replaced with an Apple battery
- **Battery BMS/flex:** original battery BMS/flex was **not transplanted** to the replacement battery

Additional community testing has confirmed the Cycle Count feature on other devices/configurations as well.

## Upgrading from 1.0.2

Install 1.1.0 over 1.0.2 normally. The three new options default to ON, so existing behavior is retained unless you disable a module.

If a Battery Health feature behaves incorrectly on your iOS version, use the switches to isolate the affected module before reporting the issue.

## Display / screen replacement

BatteryUKRM is focused on **battery-related** repair information. Display/screen replacement behavior has not been validated, and no claim is made that the tweak hides or modifies replaced-display information.

The repair-warning hooks may incidentally affect other repair information, but such behavior should be considered untested.
