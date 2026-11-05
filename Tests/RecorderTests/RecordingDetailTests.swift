import XCTest
import SwiftUI
import AVKit
@testable import Recorder

final class RecordingDetailTests: XCTestCase {
    @MainActor
    func testFinalizedRecordingOpensNativePlayer() async throws {
        _ = NSApplication.shared
        let name = "RecorderDetailTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        preferences.set(false, forKey: "transcriptionEnabled")
        defer { preferences.removePersistentDomain(forName: name) }
        let engine = CaptureEngine(preferences: preferences)
        let host = NSHostingView(rootView: ContentView(engine: engine))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        // Publish the same state as finishWriting after Stop. An absent media file
        // is sufficient: the reported crash happens during view creation, before playback.
        engine.lastFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        let view = try XCTUnwrap(findPlayer(in: host))
        XCTAssertNotNil(view.player)
        XCTAssertEqual(view.controlsStyle, .inline)
        XCTAssertEqual(view.videoGravity, .resizeAspect)
        RecordingPlayerView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.player)
    }

    @MainActor
    private func findPlayer(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        return view.subviews.lazy.compactMap { self.findPlayer(in: $0) }.first
    }
}
