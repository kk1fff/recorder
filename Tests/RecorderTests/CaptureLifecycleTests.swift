import XCTest
import AVFoundation
@testable import Recorder

final class CaptureLifecycleTests: XCTestCase {
    @MainActor func testSuspensionPreservesChoicesAndClearsCameraPreview() {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(false, forKey: "transcriptionEnabled")
        let engine = CaptureEngine(preferences: preferences)
        engine.cameraEnabled = true
        engine.audioEnabled = true
        engine.cameraPreview = NSImage(size: NSSize(width: 2, height: 2))
        engine.suspendPreview()
        engine.suspendPreview()
        XCTAssertTrue(engine.cameraEnabled)
        XCTAssertTrue(engine.audioEnabled)
        XCTAssertNil(engine.cameraPreview)
        XCTAssertEqual(engine.microphoneLevel, 0)
        engine.start()
        XCTAssertFalse(engine.starting)
        XCTAssertFalse(engine.recording)
    }

    @MainActor func testSuspensionDoesNotInterruptActiveRecording() {
        let engine = CaptureEngine(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        engine.recording = true
        engine.cameraPreview = NSImage(size: NSSize(width: 2, height: 2))
        engine.suspendPreview()
        XCTAssertTrue(engine.recording)
        XCTAssertNotNil(engine.cameraPreview)
    }

    func testChimeIsDecodableAndShort() throws {
        let player = try AVAudioPlayer(data: RecordingStartChime.waveData())
        XCTAssertEqual(player.duration, 0.25, accuracy: 0.001)
        XCTAssertEqual(player.numberOfChannels, 1)
    }

    func testAudioClockConversionPreservesSamplesAcrossTakes() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let clock = CMClockGetHostTimeClock()
        for seconds in [10, 30, 100] {
            var block: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 1920, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 1920, flags: 0, blockBufferOut: &block), noErr)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: Double(seconds), preferredTimescale: 48000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            var size = 4
            XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription, sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
            let original = try XCTUnwrap(sample)
            let converted = try RecordingAudioTiming.convert(original, from: clock, to: clock)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(converted), timing.presentationTimeStamp)
            XCTAssertEqual(CMSampleBufferGetDuration(converted), CMSampleBufferGetDuration(original))
            XCTAssertEqual(CMSampleBufferGetNumSamples(converted), 480)
            XCTAssertTrue(RecordingAudioTiming.isEligible(converted, startingAt: timing.presentationTimeStamp))
            XCTAssertFalse(RecordingAudioTiming.isEligible(converted, startingAt: CMTimeAdd(timing.presentationTimeStamp, CMTime(seconds: 0.1, preferredTimescale: 48000))))
            XCTAssertTrue(CMSampleBufferGetDataBuffer(converted) === CMSampleBufferGetDataBuffer(original))
        }
    }
    func testConsecutiveFilesContainDecodableAudioWithoutPreStartSamples() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let clock = CMClockGetHostTimeClock()
        for take in 0..<2 {
            let url = folder.appendingPathComponent("take-\(take).mp4")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
            writer.add(input)
            XCTAssertTrue(writer.startWriting())
            let start = CMTime(value: Int64(10 + take * 10), timescale: 1)
            writer.startSession(atSourceTime: start)
            var accepted = 0
            for index in -1..<20 {
                var block: CMBlockBuffer?
                XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 1920, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 1920, flags: 0, blockBufferOut: &block), noErr)
                let data = try XCTUnwrap(block)
                let values = (0..<480).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.5) }
                XCTAssertEqual(values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count) }, noErr)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTimeAdd(start, CMTime(value: Int64(index * 480), timescale: 48000)), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                var size = 4
                XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format.formatDescription, sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
                let converted = try RecordingAudioTiming.convert(XCTUnwrap(sample), from: clock, to: clock)
                guard RecordingAudioTiming.isEligible(converted, startingAt: start) else { continue }
                let deadline = Date().addingTimeInterval(2)
                while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertTrue(input.append(converted), writer.error?.localizedDescription ?? "Audio append failed")
                accepted += 1
            }
            XCTAssertEqual(accepted, 20)
            input.markAsFinished()
            await writer.finishWriting()
            XCTAssertEqual(writer.status, .completed)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var decodedSamples = 0
            while let sample = output.copyNextSampleBuffer() { decodedSamples += CMSampleBufferGetNumSamples(sample) }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThanOrEqual(decodedSamples, 9000)
        }
    }

}
