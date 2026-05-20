import SwiftUI
import Charts

struct SingleSeriesChart: View {
    let title: String
    let points: [ChartPoint]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Chart(points) { p in
                LineMark(
                    x: .value("t", p.t),
                    y: .value("v", p.v)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis { chartAxisMarks() }
            .chartYAxis { chartAxisMarks() }
            .frame(height: 170)
        }
    }
}

struct DualSeriesChart: View {
    let title: String
    let aName: String
    let aPoints: [ChartPoint]
    let aColor: Color
    let bName: String
    let bPoints: [ChartPoint]
    let bColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Chart {
                ForEach(aPoints) { p in
                    LineMark(x: .value("t", p.t), y: .value(aName, p.v))
                        .foregroundStyle(aColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(bPoints) { p in
                    LineMark(x: .value("t", p.t), y: .value(bName, p.v))
                        .foregroundStyle(bColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXAxis { chartAxisMarks() }
            .chartYAxis { chartAxisMarks() }
            .frame(height: 170)
        }
    }
}

struct TripleSeriesChart: View {
    let title: String
    let xName: String
    let xPoints: [ChartPoint]
    let xColor: Color
    let yName: String
    let yPoints: [ChartPoint]
    let yColor: Color
    let zName: String
    let zPoints: [ChartPoint]
    let zColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Chart {
                ForEach(xPoints) { p in
                    LineMark(x: .value("t", p.t), y: .value(xName, p.v))
                        .foregroundStyle(xColor)
                }
                ForEach(yPoints) { p in
                    LineMark(x: .value("t", p.t), y: .value(yName, p.v))
                        .foregroundStyle(yColor)
                }
                ForEach(zPoints) { p in
                    LineMark(x: .value("t", p.t), y: .value(zName, p.v))
                        .foregroundStyle(zColor)
                }
            }
            .chartXAxis { chartAxisMarks() }
            .chartYAxis { chartAxisMarks() }
            .frame(height: 170)
        }
    }
}

private func chartAxisMarks() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) {
        AxisGridLine().foregroundStyle(.white.opacity(0.16))
        AxisTick().foregroundStyle(.white.opacity(0.55))
        AxisValueLabel().foregroundStyle(.white.opacity(0.65))
    }
}
