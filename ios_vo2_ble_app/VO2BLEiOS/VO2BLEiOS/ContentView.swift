import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showSettings = false

    var body: some View {
        GeometryReader { proxy in
            TabView {
                NavigationStack {
                    LiveDashboardView(model: model, showSettings: $showSettings)
                }
                .toolbarColorScheme(.dark, for: .navigationBar)
                .tabItem {
                    Label("Live", systemImage: "speedometer")
                }

                NavigationStack {
                    SessionSummaryView(model: model, showSettings: $showSettings)
                }
                .toolbarColorScheme(.dark, for: .navigationBar)
                .tabItem {
                    Label("Session", systemImage: "figure.run")
                }

                NavigationStack {
                    ChartsHubView(model: model, showSettings: $showSettings)
                }
                .toolbarColorScheme(.dark, for: .navigationBar)
                .tabItem {
                    Label("Charts", systemImage: "waveform.path.ecg")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }
}

private struct LiveDashboardView: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool

    private var currentVO2: Double? {
        model.vo2Roll ?? model.vo2.last?.v
    }

    private var zone: LactateZone {
        LactateZone.from(
            current: currentVO2,
            peak: model.vo2Max,
            vtStatus: model.vtStatus
        )
    }

    private var windowText: String {
        String(format: "%.0f", model.settings.vo2WindowSec)
    }

    var body: some View {
        ZStack {
            AppGradientBackground()
            ScrollView {
                VStack(spacing: 14) {
                    heroZoneCard
                    quickMetricsRow
                    controlsCard
                }
                .padding()
                .padding(.bottom, 20)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings") { showSettings = true }
            }
        }
    }

    private var heroZoneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Training Zone")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(zone.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(zone.color.opacity(0.22))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    zoneGauge(size: 112)
                    metricsColumn
                }
                VStack(spacing: 14) {
                    zoneGauge(size: 108)
                    metricsColumn
                }
            }

            Text(zone.guidanceText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardStyle()
    }

    private var metricsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            majorMetric(title: "Current VO2", value: formatVO2(currentVO2), unit: "ml/kg/min")
            majorMetric(title: "Session Peak VO2max", value: formatVO2(model.vo2Max), unit: "ml/kg/min")
            Text("Peak uses \(windowText)s rolling average")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))

            Button("Reset Session Peak") {
                model.resetSessionPeakVO2Max()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zoneGauge(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0.0, to: zone.gaugeFill)
                .stroke(zone.color.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(zone.shortLabel)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(zone.percentText)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Live zone")
        .accessibilityValue(zone.label)
    }

    private var quickMetricsRow: some View {
        HStack(spacing: 10) {
            statPill(
                title: "VE",
                value: model.veLatest.map { String(format: "%.1f L/min", $0) } ?? "--"
            )
            statPill(
                title: "Battery",
                value: model.batteryPercent.map { "\($0)%" } ?? "--"
            )
            statPill(
                title: "Calories",
                value: String(format: "%.1f", model.kcalTotal)
            )
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                model.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .green)

            Text("Device connections are managed in Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            if model.isRecording {
                Text("VO2 CSV: \(model.vo2RecordingPath)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Pulse CSV: \(model.pulseRecordingPath)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .cardStyle()
    }

    private func majorMetric(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Text("\(value) \(unit)")
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.white)
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private func formatVO2(_ value: Double?) -> String {
        guard let value, value > 0 else { return "--" }
        return String(format: "%.1f", value)
    }
}

private struct SessionSummaryView: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool

    private var currentVO2: Double? {
        model.vo2Roll ?? model.vo2.last?.v
    }

    private var windowText: String {
        String(format: "%.0f", model.settings.vo2WindowSec)
    }

    private var ltLabel: String {
        LactateZone.from(current: currentVO2, peak: model.vo2Max, vtStatus: model.vtStatus).label
    }

    var body: some View {
        ZStack {
            AppGradientBackground()
            ScrollView {
                VStack(spacing: 14) {
                    sessionMetricsCard
                    recordingCard
                    diagnosticsCard
                }
                .padding()
                .padding(.bottom, 20)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .navigationTitle("Session")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings") { showSettings = true }
            }
        }
    }

    private var sessionMetricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Metrics")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            sessionMetricRow(
                title: "Current VO2",
                value: currentVO2.map { String(format: "%.1f ml/kg/min", $0) } ?? "--"
            )
            sessionMetricRow(
                title: "Peak VO2max (\(windowText)s avg)",
                value: String(format: "%.1f ml/kg/min", model.vo2Max)
            )
            sessionMetricRow(
                title: "Current LT Zone",
                value: ltLabel
            )
            sessionMetricRow(
                title: "VE",
                value: model.veLatest.map { String(format: "%.1f L/min", $0) } ?? "--"
            )
            sessionMetricRow(
                title: "Calories",
                value: String(format: "%.2f kcal", model.kcalTotal)
            )

            Button("Reset Session Peak") {
                model.resetSessionPeakVO2Max()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .foregroundStyle(.white)
        }
        .padding(16)
        .cardStyle()
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                model.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .green)

            if model.isRecording {
                Text("VO2 CSV: \(model.vo2RecordingPath)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Pulse CSV: \(model.pulseRecordingPath)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            sessionMetricRow(
                title: "Ventilatory Status",
                value: model.vtStatus ?? "Calculating..."
            )
            sessionMetricRow(
                title: "Pulse Gaps",
                value: model.pulseGapSummary.isEmpty ? "No drops detected" : model.pulseGapSummary
            )
            sessionMetricRow(
                title: "Battery",
                value: model.batteryPercent.map { "\($0)%" } ?? "--"
            )
        }
        .padding(16)
        .cardStyle()
    }

    private func sessionMetricRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
            Spacer(minLength: 10)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
        }
    }
}

private struct ChartsHubView: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool
    @State private var showAdvancedCharts = false

    var body: some View {
        ZStack {
            AppGradientBackground()
            ScrollView {
                VStack(spacing: 14) {
                    chartPanel {
                        SingleSeriesChart(title: "VO2 (ml/kg/min)", points: model.vo2, color: .yellow)
                    }
                    chartPanel {
                        SingleSeriesChart(title: "VE (L/min)", points: model.ve, color: .mint)
                    }
                    chartPanel {
                        DualSeriesChart(
                            title: "O2 / CO2 (%)",
                            aName: "O2", aPoints: model.o2, aColor: .green,
                            bName: "CO2", bPoints: model.co2, bColor: .red
                        )
                    }

                    DisclosureGroup(isExpanded: $showAdvancedCharts) {
                        VStack(spacing: 12) {
                            chartPanel {
                                SingleSeriesChart(title: "Pressure (Pa)", points: model.pressure, color: .cyan)
                            }
                            chartPanel {
                                SingleSeriesChart(title: "Breath Volume (L)", points: model.breathVolume, color: .orange)
                            }
                            chartPanel {
                                SingleSeriesChart(title: "Heart ADC (ch1)", points: model.ecgHeart, color: .teal)
                            }
                            chartPanel {
                                SingleSeriesChart(title: "Breath ADC (ch0)", points: model.ecgBreath, color: .orange)
                            }
                            chartPanel {
                                TripleSeriesChart(
                                    title: "IMU Accel (g)",
                                    xName: "ax", xPoints: model.accelX, xColor: .blue,
                                    yName: "ay", yPoints: model.accelY, yColor: .green,
                                    zName: "az", zPoints: model.accelZ, zColor: .orange
                                )
                            }
                            chartPanel {
                                TripleSeriesChart(
                                    title: "IMU Gyro (dps)",
                                    xName: "gx", xPoints: model.gyroX, xColor: .purple,
                                    yName: "gy", yPoints: model.gyroY, yColor: .cyan,
                                    zName: "gz", zPoints: model.gyroZ, zColor: .red
                                )
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("See all charts (advanced)")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(16)
                    .cardStyle()
                }
                .padding()
                .padding(.bottom, 20)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .navigationTitle("Charts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings") { showSettings = true }
            }
        }
    }

    private func chartPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .cardStyle()
    }
}

private struct AppGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.11, blue: 0.18),
                Color(red: 0.08, green: 0.29, blue: 0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct LactateZone {
    let label: String
    let shortLabel: String
    let guidanceText: String
    let color: Color
    let gaugeFill: CGFloat
    let percentText: String

    static func from(current: Double?, peak: Double, vtStatus: String?) -> LactateZone {
        let hasVO2 = (current ?? 0) > 0 && peak > 0
        let intensity = hasVO2 ? max(0.0, min((current ?? 0) / peak, 1.0)) : 0.0
        let percentText = hasVO2 ? "\(Int((intensity * 100.0).rounded()))% of peak" : "--"
        let gaugeFill = hasVO2 ? max(0.02, CGFloat(intensity)) : 0.02

        guard hasVO2 else {
            return LactateZone(
                label: "Waiting for data",
                shortLabel: "--",
                guidanceText: "Once breaths are detected, your LT zone appears here.",
                color: .gray,
                gaugeFill: gaugeFill,
                percentText: percentText
            )
        }

        switch vtStatus {
        case "Below VT1":
            return LactateZone(
                label: "Below LT1",
                shortLabel: "<LT1",
                guidanceText: "Low to moderate aerobic effort.",
                color: .green,
                gaugeFill: gaugeFill,
                percentText: percentText
            )
        case "Between VT1 and VT2":
            return LactateZone(
                label: "Between LT1 and LT2",
                shortLabel: "LT1-LT2",
                guidanceText: "Tempo effort between first and second threshold.",
                color: .orange,
                gaugeFill: gaugeFill,
                percentText: percentText
            )
        case "Above VT2":
            return LactateZone(
                label: "Above LT2",
                shortLabel: ">LT2",
                guidanceText: "High-intensity effort above second threshold.",
                color: .red,
                gaugeFill: gaugeFill,
                percentText: percentText
            )
        default:
            return LactateZone(
                label: "Estimating LT zone",
                shortLabel: "...",
                guidanceText: "Collecting more data to classify LT1/LT2 zone.",
                color: .teal,
                gaugeFill: gaugeFill,
                percentText: percentText
            )
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}
