import XCTest
import SwiftUI
@testable import Recorder

final class MicrophoneActivityTests: XCTestCase {
    @MainActor
    func testIndicatorKeepsLabelPixelsAndRowSizeUnchanged() throws {
        var labelImages: [Data] = []
        var rowImages: [Data] = []
        var sizes: [CGSize] = []
        for (level, visible) in [(nil as Double?, false), (0, false), (0, true), (1, true)] {
            let row = Toggle(isOn: .constant(visible)) {
                Label("Microphone", systemImage: "mic")
            }
            .toggleStyle(SourceToggleStyle(microphoneActivity: level, showsMicrophoneActivity: visible))
            .font(.callout).frame(width: 252, height: 22)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            rowImages.append(try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])))
            sizes.append(CGSize(width: image.width, height: image.height))
            // This region contains the label and icon, excluding meter and switch.
            let label = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 125, height: 22)))
            labelImages.append(try XCTUnwrap(NSBitmapImageRep(cgImage: label).representation(using: .png, properties: [:])))
        }
        XCTAssertEqual(sizes.count, 4)
        XCTAssertNotEqual(rowImages[2], rowImages[3], "Active bars must visibly change while the label stays fixed")
        for image in labelImages { XCTAssertEqual(image, labelImages.first) }
        for size in sizes { XCTAssertEqual(size, CGSize(width: 252, height: 22)) }
    }

    func testPowerNormalizationHandlesSilenceLoudInputAndInvalidValues() {
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(-80), 0)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(-55), 0)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(-30), 0.5)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(-5), 1)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(10), 1)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(-.infinity), 0)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedPower(.nan), 0)
    }

    func testPublicationIsLimitedToFifteenUpdatesPerSecond() {
        var meter = MicrophoneLevelMeter()
        var updates: [Double] = []
        for tick in 0..<1000 {
            let time = Double(tick) / 1000
            if meter.update(power: -10, at: time) != nil { updates.append(time) }
        }
        XCTAssertLessThanOrEqual(updates.count, 15)
        for pair in zip(updates, updates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1 - pair.0, 1.0 / 15)
        }
    }

    func testQuickAttackGentleDecayAndReturnToSilence() throws {
        var meter = MicrophoneLevelMeter()
        let peak = try XCTUnwrap(meter.update(power: 0, at: 0))
        XCTAssertGreaterThan(peak, 0.8)
        let falling = try XCTUnwrap(meter.update(power: -80, at: 0.1))
        XCTAssertGreaterThan(falling, 0)
        XCTAssertLessThan(falling, peak)
        XCTAssertLessThan(peak - falling, peak)
        for tick in 2...30 { _ = meter.update(power: -80, at: Double(tick) / 10) }
        XCTAssertEqual(meter.level, 0)
    }

    func testResetClearsLevelAndThrottleAcrossRepeatedSessions() {
        var meter = MicrophoneLevelMeter()
        for _ in 0..<10 {
            XCTAssertNotNil(meter.update(power: 0, at: 0))
            XCTAssertGreaterThan(meter.level, 0)
            XCTAssertNil(meter.update(power: 0, at: 0.01))
            meter.reset()
            XCTAssertEqual(meter.level, 0)
            XCTAssertEqual(meter.update(power: -80, at: 0.01), 0)
            meter.reset()
        }
    }
}
