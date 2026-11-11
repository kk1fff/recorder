import AVFoundation

/// Capture audio and compositor frames must use the same clock, including after
/// the capture session restarts. Preserve every timing entry and sample duration.
enum RecordingAudioTiming {
    static func isEligible(_ buffer: CMSampleBuffer, startingAt start: CMTime) -> Bool {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        return timestamp.isNumeric && timestamp >= start
    }

    static func convert(_ buffer: CMSampleBuffer, from source: CMClock, to destination: CMClock) throws -> CMSampleBuffer {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else {
            throw RecorderError.message("Cannot read microphone sample timing.")
        }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
            throw RecorderError.message("Cannot read microphone sample timing.")
        }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMSyncConvertTime(timing[index].presentationTimeStamp, from: source, to: destination)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMSyncConvertTime(timing[index].decodeTimeStamp, from: source, to: destination)
            }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &result) == noErr, let result else {
            throw RecorderError.message("Cannot synchronize microphone audio.")
        }
        return result
    }
}

/// Self-contained PCM chime; no external sound files or speech service required.
enum RecordingStartChime {
    static func waveData() -> Data {
        let rate = 24000
        let frames = rate / 4
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); number(UInt32(36 + frames * 2)); ascii("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(rate)); number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16))
        ascii("data"); number(UInt32(frames * 2))
        for frame in 0..<frames {
            let t = Double(frame) / Double(rate)
            let envelope = min(1, t / 0.01) * pow(1 - Double(frame) / Double(frames), 2)
            number(Int16(sin(2 * .pi * 880 * t) * envelope * 8000))
        }
        return data
    }

    @MainActor static func play() async throws {
        let player = try AVAudioPlayer(data: waveData())
        defer { player.stop() }
        guard player.play() else { throw RecorderError.message("Could not play the recording start sound.") }
        while player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
        // Let speaker reverberation decay; the writer does not exist yet.
        try await Task.sleep(for: .milliseconds(350))
    }
}
