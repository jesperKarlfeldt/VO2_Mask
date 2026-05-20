import Foundation

final class VO2Processor {
    private(set) var settings: ProcessingSettings
    private(set) var config = StreamConfig()

    private(set) var pressure: [ChartPoint] = []
    private(set) var breathContinuous: [ChartPoint] = []
    private(set) var breathEvents: [ChartPoint] = []
    private(set) var o2: [ChartPoint] = []
    private(set) var co2: [ChartPoint] = []
    private(set) var vo2: [ChartPoint] = []
    private(set) var ve: [ChartPoint] = []
    private(set) var veVo2: [ChartPoint] = []
    private(set) var veVco2: [ChartPoint] = []

    private(set) var vo2Max: Double = 0.0
    private(set) var vo2Roll: Double?
    private(set) var veLatest: Double?
    private(set) var batteryPercent: Int?
    private(set) var vtStatus: String?
    private(set) var kcalTotal: Double = 0.0

    private var lastO2: Double?
    private var lastCO2: Double?
    private var lastVO2Total: Double?
    private var lastVCO2Total: Double?
    private var vo2Window: [(Double, Double)] = []
    private var veMean: Double = 0.0
    private var lastVO2Time: Double?

    private var breathActive = false
    private var breathStartT: Double?
    private var breathVolML: Double = 0.0
    private var startCount = 0
    private var endCount = 0
    private let maxBreathS: Double = 10.0

    private var pendingRows: [VO2CsvRow] = []

    init(settings: ProcessingSettings) {
        self.settings = settings
    }

    func update(settings: ProcessingSettings) {
        self.settings = settings
    }

    func resetVO2MaxTracking() {
        vo2Max = 0
        vo2Roll = nil
        vo2Window.removeAll(keepingCapacity: true)
    }

    func resetOnDisconnect() {
        pressure.removeAll(keepingCapacity: true)
        breathContinuous.removeAll(keepingCapacity: true)
        breathEvents.removeAll(keepingCapacity: true)
        o2.removeAll(keepingCapacity: true)
        co2.removeAll(keepingCapacity: true)
        vo2.removeAll(keepingCapacity: true)
        ve.removeAll(keepingCapacity: true)
        veVo2.removeAll(keepingCapacity: true)
        veVco2.removeAll(keepingCapacity: true)
        vo2Max = 0
        vo2Roll = nil
        veLatest = nil
        batteryPercent = nil
        vtStatus = nil
        kcalTotal = 0
        lastO2 = nil
        lastCO2 = nil
        lastVO2Total = nil
        lastVCO2Total = nil
        vo2Window.removeAll(keepingCapacity: true)
        veMean = 0
        lastVO2Time = nil
        breathActive = false
        breathStartT = nil
        breathVolML = 0
        startCount = 0
        endCount = 0
        pendingRows.removeAll(keepingCapacity: true)
    }

    func popRows() -> [VO2CsvRow] {
        let rows = pendingRows
        pendingRows.removeAll(keepingCapacity: true)
        return rows
    }

    func handle(packet: Data) {
        guard !packet.isEmpty else { return }
        switch packet.u8(at: 0) {
        case 0x01: updateConfig(packet)
        case 0x02: updatePressure(packet)
        case 0x03: updateO2(packet)
        case 0x04: updateCO2(packet)
        case 0x05: updateBattery(packet)
        default: break
        }
    }

    private func updateConfig(_ packet: Data) {
        let minLen = 1 + 1 + (8 * 4) + 1
        guard packet.count >= minLen else { return }
        let version = packet.u8(at: 1)
        guard version == 1 else { return }
        config.sampleRateHz = Double(packet.f32LE(at: 2 + 0 * 4))
        config.area1 = Double(packet.f32LE(at: 2 + 1 * 4))
        config.area2 = Double(packet.f32LE(at: 2 + 2 * 4))
        config.correction = Double(packet.f32LE(at: 2 + 3 * 4))
        config.tempC = Double(packet.f32LE(at: 2 + 4 * 4))
        config.presPa = Double(packet.f32LE(at: 2 + 5 * 4))
        config.fiO2 = Double(packet.f32LE(at: 2 + 6 * 4))
        config.pressureScale = Double(packet.f32LE(at: 2 + 7 * 4))
        let signByte = Int8(bitPattern: packet.u8(at: 2 + 8 * 4))
        config.pressureSign = Int(signByte)
    }

    private func updateO2(_ packet: Data) {
        guard packet.count >= 7 else { return }
        let t = Double(packet.u32LE(at: 1)) / 1000.0
        let o2Pct = Double(packet.u16LE(at: 5)) / 100.0
        lastO2 = o2Pct
        appendBounded(&o2, ChartPoint(t: t, v: o2Pct), maxCount: 600)
    }

    private func decodeCO2(_ rawX100: UInt16) -> Double {
        if rawX100 > 2500 {
            return max(0.0, min(25.0, Double(rawX100) / 10_000.0))
        }
        return max(0.0, min(25.0, Double(rawX100) / 100.0))
    }

    private func updateCO2(_ packet: Data) {
        guard packet.count >= 7 else { return }
        let t = Double(packet.u32LE(at: 1)) / 1000.0
        let co2Pct = decodeCO2(packet.u16LE(at: 5))
        lastCO2 = co2Pct
        appendBounded(&co2, ChartPoint(t: t, v: co2Pct), maxCount: 600)
    }

    private func updateBattery(_ packet: Data) {
        guard packet.count >= 6 else { return }
        batteryPercent = Int(packet.u8(at: 5))
    }

    private func calcFlowLS(_ pressurePa: Double) -> Double {
        let rho = config.presPa / (config.tempC + 273.15) / 287.058
        let denom = (1.0 / (config.area2 * config.area2)) - (1.0 / (config.area1 * config.area1))
        guard denom > 0 else { return 0 }
        let massFlow = 1000.0 * sqrt((abs(pressurePa) * 2.0 * rho) / denom)
        let volFlow = (massFlow / rho) * config.correction
        return volFlow
    }

    private func updateVO2(veLMin: Double, t: Double) {
        guard let o2 = lastO2 else { return }
        let o2Diff = max(0.0, config.fiO2 - o2)
        let rhoBpts = config.presPa / (35.0 + 273.15) / 292.9
        let rhoStpd = 1.292
        let vo2Total = veLMin * (rhoBpts / rhoStpd) * o2Diff * 10.0
        let vo2Kg = vo2Total / max(1e-6, settings.weightKg)

        lastVO2Total = vo2Total
        appendBounded(&vo2, ChartPoint(t: t, v: vo2Kg), maxCount: 600)
        vo2Window.append((t, vo2Kg))
        while let first = vo2Window.first, (t - first.0) > settings.vo2WindowSec {
            vo2Window.removeFirst()
        }
        if !vo2Window.isEmpty {
            let avg = vo2Window.reduce(0.0) { $0 + $1.1 } / Double(vo2Window.count)
            vo2Roll = avg
            vo2Max = max(vo2Max, avg)
        }

        if let prev = lastVO2Time {
            let dtMin = max(0.0, t - prev) / 60.0
            let kcalPerMin = (vo2Total / 1000.0) * 5.0
            kcalTotal += kcalPerMin * dtMin
        }
        lastVO2Time = t

        if vo2Total > 0 {
            let ratio = veLMin / (vo2Total / 1000.0)
            appendBounded(&veVo2, ChartPoint(t: t, v: ratio), maxCount: 600)
        }

        if let co2 = lastCO2 {
            let co2Diff = max(0.0, co2 - AppConfig.fiCO2)
            let vco2Total = veLMin * (rhoBpts / rhoStpd) * co2Diff * 10.0
            lastVCO2Total = vco2Total
            if vco2Total > 0 {
                let ratio = veLMin / (vco2Total / 1000.0)
                appendBounded(&veVco2, ChartPoint(t: t, v: ratio), maxCount: 600)
            }
        }

        updateVTStatus()
    }

    private func finishBreath(_ t: Double, force: Bool = false) {
        let volL = breathVolML / 1000.0
        if let startT = breathStartT {
            let dur = max(1e-3, t - startT)
            if force || (volL >= settings.minBreathL && dur >= settings.minBreathS) {
                appendBounded(&breathEvents, ChartPoint(t: t, v: volL), maxCount: 600)
                let veInst = (volL / dur) * 60.0
                veMean = (veMean * 0.75) + (veInst * 0.25)
                veLatest = veMean
                appendBounded(&ve, ChartPoint(t: t, v: veMean), maxCount: 600)
                updateVO2(veLMin: veMean, t: t)
            }
        }
        breathVolML = 0
        breathActive = false
        startCount = 0
        endCount = 0
    }

    private func windowAvg(_ values: [ChartPoint], windowS: Double, minSamples: Int = 5) -> Double? {
        guard let last = values.last else { return nil }
        let tStart = last.t - windowS
        let filtered = values.reversed().prefix { $0.t >= tStart }.map(\.v)
        guard filtered.count >= minSamples else { return nil }
        return filtered.reduce(0.0, +) / Double(filtered.count)
    }

    private func updateVTStatus() {
        guard
            let vo2Short = windowAvg(veVo2, windowS: 30.0),
            let vo2Long = windowAvg(veVo2, windowS: 180.0),
            let vco2Short = windowAvg(veVco2, windowS: 30.0),
            let vco2Long = windowAvg(veVco2, windowS: 180.0)
        else {
            vtStatus = nil
            return
        }
        let incVO2 = (vo2Short - vo2Long) >= 2.0
        let incVCO2 = (vco2Short - vco2Long) >= 2.0
        if incVO2 && incVCO2 {
            vtStatus = "Above VT2"
        } else if incVO2 {
            vtStatus = "Between VT1 and VT2"
        } else {
            vtStatus = "Below VT1"
        }
    }

    private func updatePressure(_ packet: Data) {
        guard packet.count >= 7 else { return }
        let startIdx = packet.u32LE(at: 1)
        let count = Int(packet.u16LE(at: 5))
        let expectedLen = 7 + (count * 2)
        guard packet.count >= expectedLen else { return }

        let sr = max(1.0, config.sampleRateHz)
        let dt = 1.0 / sr
        let startHoldSamples = max(1, Int((settings.breathStartHoldMs / 1000.0) * sr))
        let endHoldSamples = max(1, Int((settings.breathEndHoldMs / 1000.0) * sr))

        for i in 0..<count {
            let raw = packet.i16LE(at: 7 + (i * 2))
            let pressurePa = (Double(raw) / config.pressureScale) * Double(config.pressureSign)
            let sampleIdx = startIdx &+ UInt32(i)
            let t = Double(sampleIdx) / sr

            appendBounded(&pressure, ChartPoint(t: t, v: pressurePa), maxCount: 4000)

            let flowLS: Double
            if abs(pressurePa) < settings.pressureDeadbandPa {
                flowLS = 0.0
            } else {
                flowLS = calcFlowLS(pressurePa)
            }

            if !breathActive {
                if flowLS >= settings.flowStartLS {
                    startCount += 1
                    if startCount >= startHoldSamples {
                        breathActive = true
                        breathStartT = t
                        breathVolML = 0
                        endCount = 0
                    }
                } else {
                    startCount = 0
                }
            } else {
                if flowLS >= settings.flowEndLS {
                    endCount = 0
                } else {
                    endCount += 1
                    if endCount >= endHoldSamples {
                        finishBreath(t)
                    }
                }
                if let start = breathStartT, (t - start) >= maxBreathS {
                    finishBreath(t, force: true)
                }
            }

            if breathActive && flowLS > 0 {
                breathVolML += flowLS * dt * 1000.0
            }

            let breathVolL = breathVolML / 1000.0
            appendBounded(&breathContinuous, ChartPoint(t: t, v: breathVolL), maxCount: 4000)

            let row = VO2CsvRow(
                tS: t,
                sampleIdx: sampleIdx,
                pressurePa: pressurePa,
                flowLS: flowLS,
                breathVolL: breathVolL,
                veLMin: veMean,
                o2Pct: lastO2,
                co2Pct: lastCO2,
                vo2MlKgMin: vo2.last?.v,
                vo2RollMlKgMin: vo2Roll,
                vo2RollMaxMlKgMin: vo2Max,
                kcalTotal: kcalTotal
            )
            pendingRows.append(row)
        }
    }
}
