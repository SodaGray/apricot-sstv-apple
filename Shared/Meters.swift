// SPDX-License-Identifier: GPL-3.0-only
//
//  Meters.swift
//  Shared by the watch and iPhone apps.
//
//  The two bars of the receive screens, drawn alike: the same track, the
//  same tick marks, the same height on a given device, so they read as a
//  pair.
//
//    Tone   1100 … 2400 Hz: a marker at the tone heard; ticks at the tones
//           SSTV uses, 1200 (sync), 1500 (black), 1900 (VIS leader) and
//           2300 Hz (white).
//    Level  −60 … 0 dBFS (RMS): a fill; ticks at −40, −20, −10 and −3 dB;
//           the last stretch, −3 to 0 dB (about to clip), tinted red.
//
//  The iPhone shows the scale under each bar; the watch only the ticks.
//

import SwiftUI

/// The tone heard.
struct ToneMeter: View {
    let toneHz: Int?
    var showsScale = false

    static let ticks = [1200, 1500, 1900, 2300]

    static func position(_ hz: Double) -> Double {
        clamped((hz - 1100) / (2400 - 1100))
    }

    var body: some View {
        MeterTrack(
            ticks: Self.ticks.map { Self.position(Double($0)) },
            labels: showsScale ? Self.ticks.map { "\($0)" } : nil,
            redZone: nil,
            fill: nil,
            marker: toneHz.map { Self.position(Double($0)) }
        )
        .accessibilityHidden(true)
    }
}

/// RMS level.
struct LevelMeter: View {
    let db: Double
    let clipping: Bool
    var showsScale = false

    static let ticks = [-40, -20, -10, -3]

    static func position(_ db: Double) -> Double {
        clamped((db + 60) / 60)
    }

    var body: some View {
        MeterTrack(
            ticks: Self.ticks.map { Self.position(Double($0)) },
            labels: showsScale ? Self.ticks.map { "\u{2212}\(-$0)" } : nil,
            redZone: Self.position(-3)...1,
            fill: (position: Self.position(db), color: color),
            marker: nil
        )
        .accessibilityHidden(true)
    }

    private var color: Color {
        if clipping || db > -3 { return .red }
        if db > -12 { return .yellow }
        return .green
    }
}

private func clamped(_ t: Double) -> Double {
    max(0, min(1, t))
}

// MARK: - Track

private enum MeterStyle {
    #if os(watchOS)
    static let height: CGFloat = 6
    static let markerWidth: CGFloat = 3
    #else
    static let height: CGFloat = 8
    static let markerWidth: CGFloat = 4
    #endif
    static let tickWidth: CGFloat = 1.5
    static let track = Color.primary.opacity(0.12)
    static let tick = Color.primary.opacity(0.35)
    static let redZone = Color.red.opacity(0.35)
}

/// Track, red zone, fill, ticks, marker, back to front; positions 0 … 1.
private struct MeterTrack: View {
    let ticks: [Double]
    let labels: [String]?
    let redZone: ClosedRange<Double>?
    let fill: (position: Double, color: Color)?
    let marker: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(MeterStyle.track)

                    if let redZone {
                        Rectangle()
                            .fill(MeterStyle.redZone)
                            .frame(width: w * (redZone.upperBound - redZone.lowerBound))
                            .offset(x: w * redZone.lowerBound)
                    }

                    if let fill {
                        Rectangle()
                            .fill(fill.color)
                            .frame(width: w * fill.position)
                    }

                    ForEach(ticks, id: \.self) { t in
                        Rectangle()
                            .fill(MeterStyle.tick)
                            .frame(width: MeterStyle.tickWidth)
                            .offset(x: w * t - MeterStyle.tickWidth / 2)
                    }

                    if let marker {
                        Capsule()
                            .fill(.tint)
                            .frame(width: MeterStyle.markerWidth)
                            .offset(x: min(max(0, w * marker - MeterStyle.markerWidth / 2), w - MeterStyle.markerWidth))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: MeterStyle.height)

            if let labels {
                MeterScale(ticks: ticks, labels: labels)
            }
        }
    }
}

/// The numbers under the ticks, kept inside the bar's width.
private struct MeterScale: View {
    let ticks: [Double]
    let labels: [String]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ForEach(Array(zip(ticks, labels).enumerated()), id: \.offset) { _, item in
                Text(verbatim: item.1)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(14, w * item.0), w - 14), y: geo.size.height / 2)
            }
        }
        .frame(height: 14)
    }
}
