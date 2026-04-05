//
//  EqualizerView.swift
//  Spotifly
//
//  6-band graphic EQ UI. Persists state via @AppStorage.
//  Pushes gain/enabled changes to sharedEqualizer (DSP engine in AudioRenderer).
//

import SwiftUI


struct EqualizerView: View {
    // MARK: - Persisted State

    @AppStorage("eq.enabled") private var isEnabled: Bool = false
    @AppStorage("eq.band0") private var band0: Double = 0
    @AppStorage("eq.band1") private var band1: Double = 0
    @AppStorage("eq.band2") private var band2: Double = 0
    @AppStorage("eq.band3") private var band3: Double = 0
    @AppStorage("eq.band4") private var band4: Double = 0
    @AppStorage("eq.band5") private var band5: Double = 0

    private var gains: [Double] { [band0, band1, band2, band3, band4, band5] }

    private let bandLabels = ["60", "150", "400", "1K", "2.4K", "15K"]
    private let maxGain: Double = 12
    private let minGain: Double = -12

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("eq.title")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Toggle("eq.enabled", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: isEnabled) { _, val in
                        sharedEqualizer.setEnabled(val)
                    }
            }
            .padding()

            Divider()

            // EQ curve + sliders
            VStack(spacing: 24) {
                // Frequency response curve
                FrequencyResponseCurve(gains: gains, isEnabled: isEnabled)
                    .frame(height: 120)
                    .padding(.horizontal)

                // Band sliders
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0 ..< Equalizer.bandCount, id: \.self) { index in
                        BandSlider(
                            label: bandLabels[index],
                            gain: bindingForBand(index),
                            isEnabled: isEnabled,
                        )
                    }
                }
                .padding(.horizontal, 8)

                // dB labels
                HStack {
                    Text("+12dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("0dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("-12dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                // Reset button
                Button("eq.reset") {
                    resetAllBands()
                }
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
            }
            .padding(.vertical, 24)
            .opacity(isEnabled ? 1 : 0.5)

            Spacer()
        }
        .onAppear {
            // Push persisted state into DSP engine on view appear
            sharedEqualizer.setEnabled(isEnabled)
            for i in 0 ..< Equalizer.bandCount {
                sharedEqualizer.setGain(Float(gains[i]), forBand: i)
            }
        }
    }

    // MARK: - Helpers

    private func bindingForBand(_ index: Int) -> Binding<Double> {
        Binding(
            get: { gains[index] },
            set: { newValue in
                switch index {
                case 0: band0 = newValue
                case 1: band1 = newValue
                case 2: band2 = newValue
                case 3: band3 = newValue
                case 4: band4 = newValue
                case 5: band5 = newValue
                default: break
                }
                sharedEqualizer.setGain(Float(newValue), forBand: index)
            }
        )
    }

    private func resetAllBands() {
        band0 = 0; band1 = 0; band2 = 0
        band3 = 0; band4 = 0; band5 = 0
        sharedEqualizer.reset()
    }
}

// MARK: - Band Slider

private struct BandSlider: View {
    let label: String
    @Binding var gain: Double
    let isEnabled: Bool

    @State private var isDragging = false
    @State private var dragStartGain: Double = 0
    @State private var trackHeight: CGFloat = 160

    private let sliderHeight: CGFloat = 160
    private let dotSize: CGFloat = 18
    private let maxGain: Double = 12

    var body: some View {
        VStack(spacing: 8) {
            // dB value label
            Text(gainLabel)
                .font(.caption2)
                .foregroundStyle(isDragging ? Color.green : .secondary)
                .frame(height: 14)

            // Slider track + dot
            GeometryReader { geo in
                let h = geo.size.height
                let dotY = gainToY(gain, in: h)

                ZStack {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)

                    // Center line (0dB)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 3, height: 1)

                    // Fill from center to dot
                    let centerY = h / 2
                    let fillTop = min(dotY, centerY)
                    let fillHeight = abs(dotY - centerY)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isEnabled ? Color.green.opacity(0.6) : Color.secondary.opacity(0.3))
                        .frame(width: 3, height: fillHeight)
                        .offset(y: fillTop - centerY + fillHeight / 2)

                    // Draggable dot
                    Circle()
                        .fill(isEnabled ? Color.green : Color.secondary)
                        .frame(width: dotSize, height: dotSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(y: dotY - h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDragging {
                                        isDragging = true
                                        dragStartGain = gain
                                    }
                                    // Compute from fixed drag-start baseline — avoids compounding drift
                                    let startY = gainToY(dragStartGain, in: trackHeight)
                                    let newY = (startY + value.translation.height)
                                        .clamped(to: 0 ... trackHeight)
                                    gain = yToGain(newY, in: trackHeight)
                                }
                                .onEnded { _ in isDragging = false }
                        )
                        .disabled(!isEnabled)
                }
                .frame(maxWidth: .infinity)
                .onAppear { trackHeight = h }
                .onChange(of: h) { _, new in trackHeight = new }
            }
            .frame(height: sliderHeight)

            // Frequency label
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var gainLabel: String {
        let rounded = (gain * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(rounded)dB"
    }

    private func gainToY(_ gain: Double, in height: CGFloat) -> CGFloat {
        let normalized = (maxGain - gain) / (maxGain * 2)
        return CGFloat(normalized) * height
    }

    private func yToGain(_ y: CGFloat, in height: CGFloat) -> Double {
        let normalized = Double(y / height)
        return ((1 - normalized) * maxGain * 2 - maxGain)
            .clamped(to: -maxGain ... maxGain)
    }
}

// MARK: - Frequency Response Curve

private struct FrequencyResponseCurve: View {
    let gains: [Double]
    let isEnabled: Bool

    var body: some View {
        Canvas { context, size in
            let path = curvePath(in: size)

            // Filled gradient below curve
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [
                        (isEnabled ? Color.green : Color.secondary).opacity(0.25),
                        (isEnabled ? Color.green : Color.secondary).opacity(0.02),
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height),
                ),
            )

            // Curve stroke
            context.stroke(
                path,
                with: .color(isEnabled ? Color.green : .secondary),
                lineWidth: 2,
            )

            // 0dB baseline
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                baseline,
                with: .color(.secondary.opacity(0.2)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4]),
            )
        }
    }

    private func curvePath(in size: CGSize) -> Path {
        let count = gains.count
        guard count > 0 else { return Path() }

        let points: [CGPoint] = (0 ..< count).map { i in
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            let normalizedGain = gains[i] / 12.0 // -1...1
            let y = size.height / 2 - CGFloat(normalizedGain) * (size.height / 2 - 4)
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: points[0])

        // Catmull-Rom spline through control points
        for i in 0 ..< points.count - 1 {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6,
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6,
            )

            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }

        return path
    }
}

// MARK: - Comparable clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
