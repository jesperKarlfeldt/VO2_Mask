import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var maskStatus: String = "Starting..."
    @Published var bandStatus: String = "Starting..."

    @Published var pressure: [ChartPoint] = []
    @Published var breathVolume: [ChartPoint] = []
    @Published var o2: [ChartPoint] = []
    @Published var co2: [ChartPoint] = []
    @Published var vo2: [ChartPoint] = []
    @Published var ve: [ChartPoint] = []

    @Published var ecgHeart: [ChartPoint] = []
    @Published var ecgBreath: [ChartPoint] = []
    @Published var accelX: [ChartPoint] = []
    @Published var accelY: [ChartPoint] = []
    @Published var accelZ: [ChartPoint] = []
    @Published var gyroX: [ChartPoint] = []
    @Published var gyroY: [ChartPoint] = []
    @Published var gyroZ: [ChartPoint] = []

    @Published var vo2Max: Double = 0
    @Published var vo2Roll: Double?
    @Published var veLatest: Double?
    @Published var batteryPercent: Int?
    @Published var vtStatus: String?
    @Published var kcalTotal: Double = 0
    @Published var pulseGapSummary: String = ""

    @Published var isRecording: Bool = false
    @Published var vo2RecordingPath: String = ""
    @Published var pulseRecordingPath: String = ""

    @Published var discoveredDevices: [DiscoveredDevice] = []

    @Published var maskTargetName: String = AppConfig.maskDeviceName
    @Published var maskTargetID: UUID?
    @Published var bandTargetName: String = AppConfig.bandDeviceName
    @Published var bandTargetID: UUID?

    @Published var settings: ProcessingSettings {
        didSet {
            vo2Processor.update(settings: settings)
            saveSettings()
        }
    }

    private let vo2Processor: VO2Processor
    private let pulseProcessor = PulseBandProcessor()
    private let recorder = DualCSVRecorder()
    private let ble: BLEController
    private var timer: Timer?

    init() {
        let loaded = Self.loadSettings()
        settings = loaded
        vo2Processor = VO2Processor(settings: loaded)

        ble = BLEController(
            maskTarget: DeviceTarget(name: AppConfig.maskDeviceName, identifier: nil),
            bandTarget: DeviceTarget(name: AppConfig.bandDeviceName, identifier: nil)
        )

        configureBLECallbacks()

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        ble.start()
    }

    deinit {
        timer?.invalidate()
        recorder.stop()
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            isRecording = false
            return
        }

        do {
            try recorder.start(config: vo2Processor.config)
            isRecording = true
            vo2RecordingPath = recorder.vo2URL?.path ?? ""
            pulseRecordingPath = recorder.pulseURL?.path ?? ""
        } catch {
            maskStatus = "Recording failed: \(error.localizedDescription)"
        }
    }

    func resetSessionPeakVO2Max() {
        vo2Processor.resetVO2MaxTracking()
        vo2Max = vo2Processor.vo2Max
        vo2Roll = vo2Processor.vo2Roll
    }

    func scanDevices() {
        ble.scanDevicesOnce(seconds: 4.5) { [weak self] devices in
            Task { @MainActor in
                self?.discoveredDevices = devices.sorted { $0.name < $1.name }
            }
        }
    }

    func useDeviceAsMask(_ device: DiscoveredDevice) {
        maskTargetName = device.name.isEmpty ? AppConfig.maskDeviceName : device.name
        maskTargetID = device.identifier
        applyTargets()
    }

    func useDeviceAsBand(_ device: DiscoveredDevice) {
        bandTargetName = device.name.isEmpty ? AppConfig.bandDeviceName : device.name
        bandTargetID = device.identifier
        applyTargets()
    }

    func applyManualTargets(maskName: String, bandName: String) {
        if !maskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            maskTargetName = maskName
            maskTargetID = nil
        }
        if !bandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bandTargetName = bandName
            bandTargetID = nil
        }
        applyTargets()
    }

    private func applyTargets() {
        let mask = DeviceTarget(name: maskTargetName, identifier: maskTargetID)
        let band = DeviceTarget(name: bandTargetName, identifier: bandTargetID)
        ble.updateTargets(mask: mask, band: band)
    }

    private func configureBLECallbacks() {
        ble.onMaskStatus = { [weak self] text in
            guard let self else { return }
            self.maskStatus = text
            if text.lowercased().contains("disconnected") {
                self.vo2Processor.resetOnDisconnect()
            }
        }

        ble.onBandStatus = { [weak self] text in
            self?.bandStatus = text
        }

        ble.onMaskPacket = { [weak self] packet in
            guard let self else { return }
            self.vo2Processor.handle(packet: packet)
            let rows = self.vo2Processor.popRows()
            if self.recorder.isRecording {
                self.recorder.writeVO2Rows(rows)
            }
        }

        ble.onBandECGPacket = { [weak self] packet, ts, uptime in
            guard let self else { return }
            self.pulseProcessor.handleEcgPayload(packet, timestamp: ts, uptime: uptime)
            let rows = self.pulseProcessor.popRows()
            if self.recorder.isRecording {
                self.recorder.writePulseRows(rows)
            }
        }

        ble.onBandIMUPacket = { [weak self] packet, ts, uptime in
            guard let self else { return }
            self.pulseProcessor.handleImuPayload(packet, timestamp: ts, uptime: uptime)
            let rows = self.pulseProcessor.popRows()
            if self.recorder.isRecording {
                self.recorder.writePulseRows(rows)
            }
        }
    }

    private func refreshSnapshot() {
        pressure = vo2Processor.pressure
        breathVolume = vo2Processor.breathContinuous
        o2 = vo2Processor.o2
        co2 = vo2Processor.co2
        vo2 = vo2Processor.vo2
        ve = vo2Processor.ve

        ecgHeart = pulseProcessor.heart
        ecgBreath = pulseProcessor.breath
        accelX = pulseProcessor.accelX
        accelY = pulseProcessor.accelY
        accelZ = pulseProcessor.accelZ
        gyroX = pulseProcessor.gyroX
        gyroY = pulseProcessor.gyroY
        gyroZ = pulseProcessor.gyroZ

        vo2Max = vo2Processor.vo2Max
        vo2Roll = vo2Processor.vo2Roll
        veLatest = vo2Processor.veLatest
        batteryPercent = vo2Processor.batteryPercent
        vtStatus = vo2Processor.vtStatus
        kcalTotal = vo2Processor.kcalTotal
        pulseGapSummary = pulseProcessor.gapSummary
    }

    private static let defaultsPrefix = "vo2bleios.settings."

    private static func loadSettings() -> ProcessingSettings {
        let d = UserDefaults.standard
        func get(_ key: String, _ fallback: Double) -> Double {
            let k = defaultsPrefix + key
            if d.object(forKey: k) == nil { return fallback }
            return d.double(forKey: k)
        }

        return ProcessingSettings(
            weightKg: get("weightKg", 80.0),
            vo2WindowSec: get("vo2WindowSec", 15.0),
            pressureDeadbandPa: get("pressureDeadbandPa", 0.5),
            flowStartLS: get("flowStartLS", 0.3),
            flowEndLS: get("flowEndLS", 0.15),
            minBreathL: get("minBreathL", 0.1),
            minBreathS: get("minBreathS", 0.05),
            breathStartHoldMs: get("breathStartHoldMs", 50.0),
            breathEndHoldMs: get("breathEndHoldMs", 150.0)
        )
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(settings.weightKg, forKey: Self.defaultsPrefix + "weightKg")
        d.set(settings.vo2WindowSec, forKey: Self.defaultsPrefix + "vo2WindowSec")
        d.set(settings.pressureDeadbandPa, forKey: Self.defaultsPrefix + "pressureDeadbandPa")
        d.set(settings.flowStartLS, forKey: Self.defaultsPrefix + "flowStartLS")
        d.set(settings.flowEndLS, forKey: Self.defaultsPrefix + "flowEndLS")
        d.set(settings.minBreathL, forKey: Self.defaultsPrefix + "minBreathL")
        d.set(settings.minBreathS, forKey: Self.defaultsPrefix + "minBreathS")
        d.set(settings.breathStartHoldMs, forKey: Self.defaultsPrefix + "breathStartHoldMs")
        d.set(settings.breathEndHoldMs, forKey: Self.defaultsPrefix + "breathEndHoldMs")
    }
}
