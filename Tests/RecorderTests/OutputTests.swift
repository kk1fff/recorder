import XCTest
@testable import Recorder
final class OutputTests: XCTestCase {
    func testSRT() {
        XCTAssertEqual(RecordingOutput.srt([Subtitle(start: 3.125, end: 65.5, text: " hello ")]), "1\n00:00:03,125 --> 00:01:05,500\nhello\n\n")
        XCTAssertEqual(RecordingOutput.srt([]), "")
        XCTAssertEqual(RecordingOutput.srt([Subtitle(start: 0, end: 1, text: " ")]), "")
    }
    func testCollisionPreservesExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let folder = try RecordingOutput.createFolder(in: root, at: date)
        let video = folder.appendingPathComponent("recording.mp4")
        try Data([1, 2, 3]).write(to: video)
        XCTAssertThrowsError(try RecordingOutput.createFolder(in: root, at: date))
        XCTAssertEqual(try Data(contentsOf: video), Data([1, 2, 3]))
    }
    func testInvalidCuesAndLongTimestamps() {
        let cues = [Subtitle(start: 0, end: 0, text: "invalid"), Subtitle(start: 3600, end: 3601.001, text: "你好")]
        XCTAssertEqual(RecordingOutput.srt(cues), "1\n01:00:00,000 --> 01:00:01,001\n你好\n\n")
    }
    func testFolderName() {
        XCTAssertNotNil(RecordingOutput.folderName(Date()).range(of: "^recording_[0-9]{8}_[0-9]{6}$", options: .regularExpression))
    }
}
