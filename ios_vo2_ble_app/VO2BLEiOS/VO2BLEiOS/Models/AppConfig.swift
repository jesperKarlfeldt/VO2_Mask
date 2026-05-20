import Foundation
import CoreBluetooth

enum AppConfig {
    static let maskDeviceName = "SpiroVO2-RAW"
    static let maskServiceUUID = CBUUID(string: "7a1b7d30-2e4b-4b2f-8f1a-2dfe3e5c0e11")
    static let maskStreamCharUUID = CBUUID(string: "7a1b7d31-2e4b-4b2f-8f1a-2dfe3e5c0e11")

    static let bandDeviceName = "ECG_Sensor"
    static let bandServiceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    static let bandEcgCharUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")
    static let bandImuCharUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")

    static let fiCO2 = 0.04
}
