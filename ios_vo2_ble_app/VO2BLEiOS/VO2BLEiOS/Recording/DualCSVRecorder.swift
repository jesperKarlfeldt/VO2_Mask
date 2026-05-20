import Foundation

final class DualCSVRecorder {
    private(set) var isRecording = false
    private(set) var vo2URL: URL?
    private(set) var pulseURL: URL?

    private var vo2Handle: FileHandle?
    private var pulseHandle: FileHandle?

    func start(config: StreamConfig) throws {
        guard !isRecording else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Self.timestamp()
        vo2URL = dir.appendingPathComponent("vo2_recording_\(stamp).csv")
        pulseURL = dir.appendingPathComponent("pulse_recording_\(stamp).csv")

        guard let vo2URL, let pulseURL else { throw NSError(domain: "recorder", code: 1) }

        FileManager.default.createFile(atPath: vo2URL.path, contents: nil)
        FileManager.default.createFile(atPath: pulseURL.path, contents: nil)
        vo2Handle = try FileHandle(forWritingTo: vo2URL)
        pulseHandle = try FileHandle(forWritingTo: pulseURL)

        writeVO2Line("# SpiroVO2 recording")
        writeVO2Line("# sample_rate_hz=\(config.sampleRateHz), area_1=\(config.area1), area_2=\(config.area2), correction=\(config.correction), temp_c=\(config.tempC), pres_pa=\(config.presPa), fi_o2=\(config.fiO2), pressure_scale=\(config.pressureScale), pressure_sign=\(config.pressureSign)")
        writeVO2Line("t_s,sample_idx,pressure_pa,flow_l_s,breath_vol_l,ve_l_min,o2_pct,co2_pct,vo2_ml_kg_min,vo2_roll_ml_kg_min,vo2_roll_max_ml_kg_min,kcal_total")
        writePulseLine("timestamp,elapsed_s,heart,breath,accel_x_g,accel_y_g,accel_z_g,gyro_x_dps,gyro_y_dps,gyro_z_dps,imu_sample_idx")

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        try? vo2Handle?.close()
        try? pulseHandle?.close()
        vo2Handle = nil
        pulseHandle = nil
        isRecording = false
    }

    func writeVO2Rows(_ rows: [VO2CsvRow]) {
        guard isRecording, !rows.isEmpty else { return }
        for row in rows {
            writeVO2Line(row.csv())
        }
    }

    func writePulseRows(_ rows: [PulseCsvRow]) {
        guard isRecording, !rows.isEmpty else { return }
        for row in rows {
            writePulseLine(row.csv())
        }
    }

    private func writeVO2Line(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        vo2Handle?.write(data)
    }

    private func writePulseLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        pulseHandle?.write(data)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
