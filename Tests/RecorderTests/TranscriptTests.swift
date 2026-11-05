import XCTest
@testable import Recorder

final class TranscriptTests: XCTestCase {
    func testPlainTextExportKeepsTimestampsAndEditedUnicodeText() {
        var cues = [Subtitle(start: 8.25, end: 19, text: " original "), Subtitle(start: 3661, end: 3665, text: "你好\nNext line")]
        cues[0].text = " Corrected words "
        XCTAssertEqual(RecordingOutput.transcript(cues), "0:08  Corrected words\n\n1:01:01  你好\nNext line")
        XCTAssertTrue(RecordingOutput.srt(cues).contains("00:00:08,250 --> 00:00:19,000\nCorrected words"))
    }

    func testEmptyTranscriptAndInvalidCues() {
        XCTAssertEqual(RecordingOutput.transcript([]), "")
        XCTAssertEqual(RecordingOutput.transcript([Subtitle(start: 0, end: 1, text: "  "), Subtitle(start: 2, end: 1, text: "invalid")]), "")
        XCTAssertEqual(RecordingOutput.timestamp(.nan), "0:00")
        XCTAssertEqual(RecordingOutput.timestamp(-10), "0:00")
    }

    func testTranscriptionDefaultsOnAndRemembersOptOutAcrossInstances() {
        let name = "RecorderTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let first = CaptureEngine(preferences: preferences)
        XCTAssertTrue(first.transcriptionEnabled)
        first.transcriptionEnabled = false
        let next = CaptureEngine(preferences: preferences)
        XCTAssertFalse(next.transcriptionEnabled)
        XCTAssertFalse(next.modelReady)
        next.start()
        // The model must not block video-only recording: validation reaches the destination check.
        XCTAssertEqual(next.error, "Choose an available, writable destination folder.")
        XCTAssertFalse(next.recording)
    }
}
