import Foundation
import SwiftUI

/// State lives on the media queue. Audio channel powers are measured in dBFS.
struct MicrophoneLevelMeter {
    private(set) var level = 0.0
    private var lastUpdate: TimeInterval?

    static func normalizedPower(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 55) / 50))
    }

    mutating func update(power: Double, at time: TimeInterval) -> Double? {
        let elapsed = lastUpdate.map { max(0, time - $0) } ?? (1.0 / 15)
        guard lastUpdate == nil || elapsed >= 1.0 / 15 else { return nil }
        lastUpdate = time
        let target = Self.normalizedPower(power)
        let response = target > level ? 0.04 : 0.25
        level += (target - level) * (1 - exp(-elapsed / response))
        if level < 0.01 { level = 0 }
        return level
    }

    mutating func reset() {
        level = 0
        lastUpdate = nil
    }
}

struct MicrophoneActivityView: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(level > 0.01 ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: 3 + 13 * min(1, max(0, level)) * weights[index])
            }
        }
        .frame(width: 32, height: 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
