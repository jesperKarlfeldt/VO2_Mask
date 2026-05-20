import Foundation
import CoreBluetooth

struct DeviceTarget {
    var name: String
    var identifier: UUID?
}

struct DiscoveredDevice: Identifiable, Hashable {
    var id: UUID { identifier }
    let identifier: UUID
    let name: String
    let serviceUUIDs: [CBUUID]

    var displayName: String {
        let base = name.isEmpty ? "<unnamed>" : name
        return "\(base) [\(identifier.uuidString)]"
    }
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let t: Double
    let v: Double
}

struct StreamConfig {
    var sampleRateHz: Double = 200.0
    var area1: Double = 0.000531
    var area2: Double = 0.000201
    var correction: Double = 0.92
    var tempC: Double = 15.0
    var presPa: Double = 101325.0
    var fiO2: Double = 20.90
    var pressureScale: Double = 10.0
    var pressureSign: Int = 1
}

struct ProcessingSettings {
    var weightKg: Double = 80.0
    var vo2WindowSec: Double = 15.0
    var pressureDeadbandPa: Double = 0.5
    var flowStartLS: Double = 0.3
    var flowEndLS: Double = 0.15
    var minBreathL: Double = 0.1
    var minBreathS: Double = 0.05
    var breathStartHoldMs: Double = 50.0
    var breathEndHoldMs: Double = 150.0
}

struct VO2CsvRow {
    let tS: Double
    let sampleIdx: UInt32
    let pressurePa: Double
    let flowLS: Double
    let breathVolL: Double
    let veLMin: Double
    let o2Pct: Double?
    let co2Pct: Double?
    let vo2MlKgMin: Double?
    let vo2RollMlKgMin: Double?
    let vo2RollMaxMlKgMin: Double
    let kcalTotal: Double

    func csv() -> String {
        [
            String(format: "%.4f", tS),
            "\(sampleIdx)",
            String(format: "%.5f", pressurePa),
            String(format: "%.5f", flowLS),
            String(format: "%.5f", breathVolL),
            String(format: "%.5f", veLMin),
            o2Pct.map { String(format: "%.3f", $0) } ?? "",
            co2Pct.map { String(format: "%.3f", $0) } ?? "",
            vo2MlKgMin.map { String(format: "%.3f", $0) } ?? "",
            vo2RollMlKgMin.map { String(format: "%.3f", $0) } ?? "",
            String(format: "%.3f", vo2RollMaxMlKgMin),
            String(format: "%.4f", kcalTotal),
        ].joined(separator: ",")
    }
}

struct PulseCsvRow {
    let timestamp: Date
    let elapsedS: Double
    let heart: Int32?
    let breath: Int32?
    let axG: Double?
    let ayG: Double?
    let azG: Double?
    let gxDps: Double?
    let gyDps: Double?
    let gzDps: Double?
    let imuSampleIdx: UInt32?

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampText = iso.string(from: timestamp)
        let elapsedText = String(format: "%.4f", elapsedS)
        let heartText = heart.map { String($0) } ?? ""
        let breathText = breath.map { String($0) } ?? ""
        let axText = axG.map { String(format: "%.6f", $0) } ?? ""
        let ayText = ayG.map { String(format: "%.6f", $0) } ?? ""
        let azText = azG.map { String(format: "%.6f", $0) } ?? ""
        let gxText = gxDps.map { String(format: "%.6f", $0) } ?? ""
        let gyText = gyDps.map { String(format: "%.6f", $0) } ?? ""
        let gzText = gzDps.map { String(format: "%.6f", $0) } ?? ""
        let imuIdxText = imuSampleIdx.map { String($0) } ?? ""

        let fields = [
            timestampText,
            elapsedText,
            heartText,
            breathText,
            axText,
            ayText,
            azText,
            gxText,
            gyText,
            gzText,
            imuIdxText,
        ]
        return fields.joined(separator: ",")
    }
}
