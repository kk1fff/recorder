import Foundation
import AVFoundation
import WhisperKit
import Darwin

struct Subtitle: Equatable {
    let start: Double
    let end: Double
    var text: String
}

enum RecordingOutput {
    static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }

    static func transcript(_ cues: [Subtitle]) -> String {
        cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }
            .map { "\(timestamp($0.start))  \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }
    static func folderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "recording_" + formatter.string(from: date)
    }
    static func createFolder(in destination: URL, at date: Date) throws -> URL {
        let folder = destination.appendingPathComponent(folderName(date), isDirectory: true)
        guard mkdir(folder.path, 0o755) == 0 else {
            throw RecorderError.message("Cannot create recording folder (it may already exist): " + String(cString: strerror(errno)))
        }
        return folder
    }
    static func srt(_ cues: [Subtitle]) -> String {
        func timestamp(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }.joined()
    }
}

actor TranscriptionService {
    private var pipe: WhisperKit?
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Recorder/Models")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let saved = base.appendingPathComponent("model-path.txt")
        let folder: URL
        if let path = try? String(contentsOf: saved, encoding: .utf8), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path)
        } else {
            folder = try await WhisperKit.download(variant: "large-v3-v20240930_626MB", downloadBase: base) { value in progress(value.fractionCompleted * 0.9) }
        }
        progress(0.9)
        pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base, verbose: false, prewarm: true, load: true, download: false))
        try folder.path.write(to: saved, atomically: true, encoding: .utf8)
        progress(1)
    }

    func transcribe(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Subtitle] {
        guard let pipe else { throw RecorderError.message("Transcription model is not ready.") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        // Read bounded windows on the movie timeline, preserving delayed microphone starts and mute gaps.
        var cues: [Subtitle] = []
        var offset = 0.0
        while offset < duration {
            try Task.checkCancellation()
            let length = min(30, duration - offset)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 16000), duration: CMTime(seconds: length, preferredTimescale: 16000))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RecorderError.message("Cannot read recorded audio.") }
            var samples = [Float](repeating: 0, count: Int(ceil(length * 16000)))
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                var values = [Float](repeating: 0, count: count)
                let result = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
                guard result == kCMBlockBufferNoErr else { throw RecorderError.message("Cannot decode recorded audio.") }
                let start = Int(((CMSampleBufferGetPresentationTimeStamp(buffer).seconds - offset) * 16000).rounded())
                for i in values.indices where start + i >= 0 && start + i < samples.count { samples[start + i] = values[i] }
            }
            if reader.status == .failed { throw reader.error ?? RecorderError.message("Audio reading failed.") }
            if samples.contains(where: { abs($0) > 0.001 }) {
                let chunkStart = offset
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: DecodingOptions(task: .transcribe, skipSpecialTokens: true, withoutTimestamps: false), segmentCallback: { segments in
                    if let end = segments.map({ Double($0.end) }).max() {
                        progress(min(0.99, (chunkStart + min(length, end)) / duration))
                    }
                })
                for segment in results.flatMap(\.segments) {
                    let start = offset + Double(segment.start)
                    let end = min(offset + length, offset + Double(segment.end))
                    cues.append(Subtitle(start: start, end: end, text: segment.text))
                }
            }
            offset += length
            progress(min(0.99, offset / duration))
        }
        try Task.checkCancellation()
        return cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start }
    }
}
