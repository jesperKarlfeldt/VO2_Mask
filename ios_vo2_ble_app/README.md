# VO2 BLE iPhone App

This folder contains a native iOS SwiftUI app that mirrors the desktop BLE flow in `tools/ble_vo2_stream/vo2_ble_plot_plus_ecg.py`:

- Connects to **SpiroVO2-RAW** (mask)
- Connects to **ECG_Sensor** (pulse band)
- Subscribes to required notify characteristics
- Decodes mask + ECG + IMU payloads
- Computes breath detection + VE/VO2 metrics
- Shows live charts
- Records CSV files in the app Documents directory

## Open in Xcode

1. (Optional) regenerate project files:
   `cd ios_vo2_ble_app/VO2BLEiOS && ruby generate_project.rb`
2. Open `ios_vo2_ble_app/VO2BLEiOS/VO2BLEiOS.xcodeproj`
3. Select an iPhone target device
4. Configure your signing team in **Signing & Capabilities**
5. Build and run

## Notes

- iOS requires Bluetooth permissions (already included in `Info.plist`).
- For reliable high-rate BLE streaming, keep the app in the foreground.
- If Xcode says there are no iOS destinations, install iOS platform components from Xcode settings.
