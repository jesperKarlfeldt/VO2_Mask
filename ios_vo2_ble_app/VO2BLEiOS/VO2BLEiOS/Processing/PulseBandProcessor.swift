import Foundation

private enum PulseScale {
    static let accelGPerLSB = 0.000122
    static let gyroDpsPerLSB = 0.0175
}

private final class SampleGapTracker {
    private var last: UInt32?
    private(set) var gaps: UInt64 = 0

    func observe(_ count: UInt32) {
        guard let previous = last else {
            last = count
            return
        }
        let delta = count &- previous
        if delta > 1 {
            gaps += UInt64(delta - 1)
        }
        last = count
    }
}

final class PulseBandProcessor {
    private(set) var heart: [ChartPoint] = []
    private(set) var breath: [ChartPoint] = []
    private(set) var accelX: [ChartPoint] = []
    private(set) var accelY: [ChartPoint] = []
    private(set) var accelZ: [ChartPoint] = []
    private(set) var gyroX: [ChartPoint] = []
    private(set) var gyroY: [ChartPoint] = []
    private(set) var gyroZ: [ChartPoint] = []

    private let ecgGap = SampleGapTracker()
    private let imuGap = SampleGapTracker()

    private var startedAtUptime: TimeInterval?
    private var lastEcgPacketElapsed: Double?
    private var lastImuPacketElapsed: Double?
    private var pendingRows: [PulseCsvRow] = []

    var gapSummary: String {
        "heart_breath_missing=\(ecgGap.gaps), imu_missing=\(imuGap.gaps)"
    }

    func popRows() -> [PulseCsvRow] {
        let rows = pendingRows
        pendingRows.removeAll(keepingCapacity: true)
        return rows
    }

    private func elapsedS(from uptime: TimeInterval) -> Double {
        if startedAtUptime == nil {
            startedAtUptime = uptime
        }
        return max(0.0, uptime - (startedAtUptime ?? uptime))
    }

    private func distributeTimes(lastPacketElapsed: inout Double?, end: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if let last = lastPacketElapsed, end > last {
            let step = (end - last) / Double(count)
            let times = (0..<count).map { last + step * Double($0 + 1) }
            lastPacketElapsed = times.last
            return times
        }
        let times = Array(repeating: end, count: count)
        lastPacketElapsed = end
        return times
    }

    func handleEcgPayload(_ data: Data, timestamp: Date, uptime: TimeInterval) {
        guard data.count % 12 == 0 else { return }
        let endElapsed = elapsedS(from: uptime)
        let sampleCount = data.count / 12
        var last = lastEcgPacketElapsed
        let times = distributeTimes(lastPacketElapsed: &last, end: endElapsed, count: sampleCount)
        lastEcgPacketElapsed = last

        for i in 0..<sampleCount {
            let base = i * 12
            let idx = data.u32LE(at: base)
            let heartRaw = data.i32LE(at: base + 4)
            let breathRaw = data.i32LE(at: base + 8)
            let t = times[i]

            ecgGap.observe(idx)
            appendBounded(&heart, ChartPoint(t: t, v: Double(heartRaw)), maxCount: 12000)
            appendBounded(&breath, ChartPoint(t: t, v: Double(breathRaw)), maxCount: 12000)

            let wall = timestamp.addingTimeInterval(t - endElapsed)
            pendingRows.append(
                PulseCsvRow(
                    timestamp: wall,
                    elapsedS: t,
                    heart: heartRaw,
                    breath: breathRaw,
                    axG: nil,
                    ayG: nil,
                    azG: nil,
                    gxDps: nil,
                    gyDps: nil,
                    gzDps: nil,
                    imuSampleIdx: nil
                )
            )
        }
    }

    func handleImuPayload(_ data: Data, timestamp: Date, uptime: TimeInterval) {
        guard data.count % 16 == 0 else { return }
        let endElapsed = elapsedS(from: uptime)
        let sampleCount = data.count / 16
        var last = lastImuPacketElapsed
        let times = distributeTimes(lastPacketElapsed: &last, end: endElapsed, count: sampleCount)
        lastImuPacketElapsed = last

        for i in 0..<sampleCount {
            let base = i * 16
            let idx = data.u32LE(at: base)
            let ax = data.i16LE(at: base + 4)
            let ay = data.i16LE(at: base + 6)
            let az = data.i16LE(at: base + 8)
            let gx = data.i16LE(at: base + 10)
            let gy = data.i16LE(at: base + 12)
            let gz = data.i16LE(at: base + 14)
            let t = times[i]

            let axG = Double(ax) * PulseScale.accelGPerLSB
            let ayG = Double(ay) * PulseScale.accelGPerLSB
            let azG = Double(az) * PulseScale.accelGPerLSB
            let gxD = Double(gx) * PulseScale.gyroDpsPerLSB
            let gyD = Double(gy) * PulseScale.gyroDpsPerLSB
            let gzD = Double(gz) * PulseScale.gyroDpsPerLSB

            imuGap.observe(idx)
            appendBounded(&accelX, ChartPoint(t: t, v: axG), maxCount: 12000)
            appendBounded(&accelY, ChartPoint(t: t, v: ayG), maxCount: 12000)
            appendBounded(&accelZ, ChartPoint(t: t, v: azG), maxCount: 12000)
            appendBounded(&gyroX, ChartPoint(t: t, v: gxD), maxCount: 12000)
            appendBounded(&gyroY, ChartPoint(t: t, v: gyD), maxCount: 12000)
            appendBounded(&gyroZ, ChartPoint(t: t, v: gzD), maxCount: 12000)

            let wall = timestamp.addingTimeInterval(t - endElapsed)
            pendingRows.append(
                PulseCsvRow(
                    timestamp: wall,
                    elapsedS: t,
                    heart: nil,
                    breath: nil,
                    axG: axG,
                    ayG: ayG,
                    azG: azG,
                    gxDps: gxD,
                    gyDps: gyD,
                    gzDps: gzD,
                    imuSampleIdx: idx
                )
            )
        }
    }
}
