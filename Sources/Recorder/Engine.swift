import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage
import OSLog

enum WebcamResolution: String, CaseIterable, Identifiable {
    case auto, p480, p720

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (10% of video width)"
        case .p480: return "480p (854×480)"
        case .p720: return "720p (1280×720)"
        }
    }
    func size(screenSize: CGSize?) -> CGSize {
        switch self {
        case .auto:
            guard let screenSize else { return CGSize(width: 1280, height: 720) }
            let width = max(2, (screenSize.width / 9 / 2).rounded() * 2)
            let height = max(2, (width * 9 / 16 / 2).rounded() * 2)
            return CGSize(width: width, height: height)
        case .p480: return CGSize(width: 854, height: 480)
        case .p720: return CGSize(width: 1280, height: 720)
        }
    }
}

struct CaptureSource: Identifiable {
    let id: String
    let name: String
    let detail: String
    let filter: SCContentFilter
    let size: CGSize
    var thumbnail: NSImage?
}

final class CaptureEngine: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var cameraPreview: NSImage?
    @Published var screenPreview: NSImage?
    @Published private(set) var selectedScreenSize = CGSize(width: 1920, height: 1080)
    @Published var cameraEnabled = false
    @Published var screenEnabled = false
    @Published var audioEnabled = false
    @Published private(set) var microphoneLevel = 0.0
    // UI generation rejects updates queued by a previous microphone session.
    private var microphoneGeneration = UUID()
    private var microphoneSilenceReset: DispatchWorkItem?
    @Published private(set) var starting = false
    @Published private(set) var restoringSources = false
    private var previewActive = true
    private var lifecycleID = UUID()
    private var startTask: Task<Void, Never>?
    @Published var recording = false
    @Published var finishing = false
    @Published var status = "Choose your sources to get started."
    @Published var sourceName = "No screen selected"
    @Published var sources: [CaptureSource] = []
    @Published var loadingSources = false
    @Published var error: String?
    @Published var lastFile: URL?
    @Published var resolution = 1920
    @Published var webcamResolution: WebcamResolution = .auto
    @Published var destination: URL?
    @Published var modelReady = false
    @Published var modelLoading = false
    @Published var modelProgress = 0.0
    @Published var transcribing = false
    @Published var transcriptionProgress = 0.0
    @Published var transcriptionFailed = false
    @Published var transcriptionEnabled: Bool {
        didSet {
            preferences.set(transcriptionEnabled, forKey: "transcriptionEnabled")
            if transcriptionEnabled { prepareModel() }
        }
    }
    @Published private(set) var lastRecordingNeedsTranscript = false
    @Published private(set) var subtitles: [Subtitle] = []
    @Published private(set) var transcriptReady = false
    private let transcriptionService = TranscriptionService()
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID = UUID()
    private var destinationScoped = false
    private let preferences: UserDefaults

    override convenience init() {
        self.init(preferences: .standard)
    }

    init(preferences: UserDefaults) {
        self.preferences = preferences
        self.transcriptionEnabled = preferences.object(forKey: "transcriptionEnabled") as? Bool ?? true
        super.init()
        if let data = preferences.data(forKey: "destinationBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                setDestination(url)
            }
        }
    }

    func setDestination(_ url: URL) {
        if destinationScoped, let destination { destination.stopAccessingSecurityScopedResource() }
        destinationScoped = url.startAccessingSecurityScopedResource()
        destination = url
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            preferences.set(data, forKey: "destinationBookmark")
        }
    }

    func prepareModel() {
        guard !modelReady, !modelLoading else { return }
        modelLoading = true; modelProgress = 0
        Task { @MainActor in
            do {
                try await transcriptionService.prepare { value in
                    Task { @MainActor in self.modelProgress = value }
                }
                modelReady = true
            } catch { self.error = "Model setup failed: \(error.localizedDescription)" }
            modelLoading = false
        }
    }

    func transcribeLastRecording() {
        guard let url = lastFile, !transcribing else { return }
        transcribing = true; finishing = true; transcriptionFailed = false
        transcriptionProgress = 0; status = "Transcribing…"
        let id = UUID(); transcriptionID = id
        transcriptionTask = Task { @MainActor in
            do {
                let cues = try await transcriptionService.transcribe(url) { value in
                    Task { @MainActor in
                        if self.transcriptionID == id { self.transcriptionProgress = max(self.transcriptionProgress, value) }
                    }
                }
                try Task.checkCancellation()
                guard transcriptionID == id else { return }
                try RecordingOutput.srt(cues).write(to: url.deletingLastPathComponent().appendingPathComponent("recording.srt"), atomically: true, encoding: .utf8)
                subtitles = cues
                transcriptReady = true
                transcriptionProgress = 1
                status = cues.isEmpty ? "Saved. No speech detected." : "Video and subtitles saved."
            } catch {
                guard transcriptionID == id else { return }
                transcriptionFailed = true
                self.error = "Video saved; transcription failed: \(error.localizedDescription)"
                status = "Video saved; transcription failed."
            }
            transcribing = false; finishing = false
        }
    }

    func cancelTranscription() {
        transcriptionID = UUID()
        transcriptionTask?.cancel()
        transcribing = false; finishing = false
    }

    @discardableResult
    func saveTranscript(_ cues: [Subtitle]) -> Bool {
        guard let lastFile, transcriptReady, !transcribing else { return false }
        do {
            try RecordingOutput.srt(cues).write(to: lastFile.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            subtitles = cues
            return true
        } catch {
            self.error = "Could not save transcript edits: \(error.localizedDescription)"
            return false
        }
    }

    private let queue = DispatchQueue(label: "recorder.media")
    private let context = CIContext()
    private let cameraSession = AVCaptureSession()
    private let micSession = AVCaptureSession()
    private var stream: SCStream?
    private var mediaStream: SCStream? // Access only on the media queue.
    private var screenRequestID = UUID()
    private var selectedSourceID: String?
    private var cameraImage: CIImage?
    private var screenImage: CIImage?
    private var useCamera = false
    private var useScreen = false
    private var useAudio = false
    private var lastAudioArrival: Double?
    private let mediaLog = Logger(subsystem: "local.recorder.app", category: "capture")
    private var receivedAudioBuffers = 0
    private var rejectedAudioBuffers = 0
    private var reportedAudioStall = false
    private var appendedAudioBuffers = 0
    private var expectedAudio = false
    private var microphoneMeter = MicrophoneLevelMeter()
    private var meterGeneration = UUID()
    private var screenSize = CGSize(width: 1920, height: 1080)
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var startTime = CMTime.zero
    private var outputSize = CGSize.zero
    private var leftSize = CGSize.zero
    private var rightSize = CGSize.zero
    private var frameCount: Int64 = 0
    private var previewCount = 0
    private var writingURL: URL?

    private func report(_ message: String) { DispatchQueue.main.async { self.error = message } }

    @MainActor private func availableSources() async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return Self.captureSources(from: content)
    }

    private static func captureSources(from content: SCShareableContent) -> [CaptureSource] {
        var result: [CaptureSource] = []
        for display in content.displays {
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            result.append(CaptureSource(id: "d\(display.displayID)", name: "Display \(result.count + 1)", detail: "\(display.width) × \(display.height)", filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), size: CGSize(width: display.width, height: display.height)))
        }
        for window in content.windows where window.frame.width > 100 && window.frame.height > 80 && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier {
            guard let app = window.owningApplication, let title = window.title, !title.isEmpty else { continue }
            result.append(CaptureSource(id: "w\(window.windowID)", name: title, detail: app.applicationName, filter: SCContentFilter(desktopIndependentWindow: window), size: window.frame.size))
        }
        return result
    }

    @MainActor func loadSources() async {
        loadingSources = true
        defer { loadingSources = false }
        do {
            let result = try await availableSources()
            sources = result
            for index in result.indices {
                let config = SCStreamConfiguration()
                config.width = 360; config.height = 220
                config.showsCursor = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: result[index].filter, configuration: config) {
                    if let current = sources.firstIndex(where: { $0.id == result[index].id }) {
                        sources[current].thumbnail = NSImage(cgImage: image, size: .zero)
                    }
                }
            }
        } catch { self.error = "Screen access failed: \(error.localizedDescription). Allow Recorder in System Settings → Privacy & Security → Screen & System Audio Recording." }
    }

    @MainActor func select(_ source: CaptureSource) async {
        await selectSource(id: source.id)
    }

    @MainActor private func selectSource(id: String) async {
        guard previewActive, !recording, !starting, !finishing else { return }
        screenRequestID = UUID()
        let requestID = screenRequestID
        let previous = detachScreenStream()
        selectedSourceID = id
        screenEnabled = false
        do {
            if let previous { try? await previous.stopCapture() }
            guard requestID == screenRequestID, previewActive else { return }
            // Picker filters may refer to a window that closed or a disconnected display.
            let currentSources = try await availableSources()
            guard requestID == screenRequestID, previewActive else { return }
            guard let source = currentSources.first(where: { $0.id == id }) else {
                throw RecorderError.message("The selected screen or window is no longer available. Reconnect the display or reopen the window, then choose it again.")
            }
            let scale = min(1, min(CGFloat(resolution) / source.size.width, CGFloat(resolution * 9 / 16) / source.size.height))
            let size = CGSize(width: max(2, Int(source.size.width * scale) / 2 * 2), height: max(2, Int(source.size.height * scale) / 2 * 2))
            let config = SCStreamConfiguration()
            config.width = Int(size.width); config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true; config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let next = SCStream(filter: source.filter, configuration: config, delegate: self)
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync { self.screenImage = nil; self.screenSize = size; self.useScreen = true; self.mediaStream = next }
            stream = next
            try await next.startCapture()
            guard requestID == screenRequestID, previewActive, stream === next else {
                try? await next.stopCapture()
                return
            }
            selectedSourceID = id
            selectedScreenSize = size
            screenEnabled = true; sourceName = source.name
            status = "Screen selected."
        } catch {
            guard requestID == screenRequestID else { return }
            let failed = detachScreenStream()
            if let failed { try? await failed.stopCapture() }
            guard requestID == screenRequestID else { return }
            screenEnabled = false
            selectedSourceID = nil
            sourceName = "No screen selected"
            self.error = "Could not start screen capture: \(error.localizedDescription)"
        }
    }

    // Invalidate callbacks before asking ScreenCaptureKit to stop asynchronously.
    @discardableResult private func detachScreenStream() -> SCStream? {
        let previous = stream
        stream = nil
        queue.sync { self.mediaStream = nil; self.useScreen = false; self.screenImage = nil }
        screenPreview = nil
        return previous
    }

    @MainActor func disableScreen() async {
        screenRequestID = UUID()
        let previous = detachScreenStream()
        selectedSourceID = nil
        screenEnabled = false
        sourceName = "No screen selected"
        if let previous { try? await previous.stopCapture() }
    }

    func toggleCamera() async { await setCameraEnabled(!cameraEnabled) }

    private func setCameraEnabled(_ enabled: Bool) async {
        if !enabled {
            queue.sync { cameraSession.stopRunning(); useCamera = false; cameraImage = nil }
            cameraEnabled = false; cameraPreview = nil
            return
        }
        let requestID = lifecycleID
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "Allow camera access in System Settings → Privacy & Security → Camera."; return }
        guard previewActive, requestID == lifecycleID else { return }
        do {
            try queue.sync {
                if cameraSession.inputs.isEmpty || cameraSession.outputs.isEmpty {
                    cameraSession.inputs.forEach { cameraSession.removeInput($0) }
                    cameraSession.outputs.forEach { cameraSession.removeOutput($0) }
                    guard let device = AVCaptureDevice.default(for: .video) else { throw RecorderError.message("No camera is available.") }
                    cameraSession.beginConfiguration()
                    defer { cameraSession.commitConfiguration() }
                    cameraSession.sessionPreset = .hd1280x720
                    let input = try AVCaptureDeviceInput(device: device)
                    guard cameraSession.canAddInput(input) else { throw RecorderError.message("Cannot connect to the camera.") }
                    cameraSession.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard cameraSession.canAddOutput(output) else { throw RecorderError.message("Cannot configure camera output.") }
                    cameraSession.addOutput(output)
                }
                cameraSession.startRunning(); useCamera = true
            }
            cameraEnabled = true; status = "Camera enabled."
        } catch { self.error = error.localizedDescription }
    }

    func toggleAudio() async { await setAudioEnabled(!audioEnabled) }

    private func setAudioEnabled(_ enabled: Bool) async {
        if !enabled {
            microphoneGeneration = UUID()
            microphoneSilenceReset?.cancel()
            microphoneLevel = 0
            queue.sync { useAudio = false; lastAudioArrival = nil; microphoneMeter.reset(); micSession.stopRunning() }
            audioEnabled = false; return
        }
        let requestID = lifecycleID
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Allow microphone access in System Settings → Privacy & Security → Microphone."; return }
        guard previewActive, requestID == lifecycleID else { return }
        do {
            let generation = UUID()
            microphoneGeneration = generation
            microphoneLevel = 0
            try queue.sync {
                if micSession.inputs.isEmpty || micSession.outputs.isEmpty {
                    micSession.inputs.forEach { micSession.removeInput($0) }
                    micSession.outputs.forEach { micSession.removeOutput($0) }
                    guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.message("No microphone is available.") }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard micSession.canAddInput(input) else { throw RecorderError.message("Cannot connect to the microphone.") }
                    micSession.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard micSession.canAddOutput(output) else { throw RecorderError.message("Cannot configure microphone output.") }
                    micSession.addOutput(output)
                }
                microphoneMeter.reset(); meterGeneration = generation
                micSession.startRunning(); useAudio = true
                if writer != nil { expectedAudio = true }
            }
            audioEnabled = true
        } catch { self.error = error.localizedDescription }
    }

    // Choices survive suspension, but hardware and queued UI updates do not.
    func suspendPreview() {
        guard !recording else { return }
        previewActive = false
        screenRequestID = UUID()
        if let previous = detachScreenStream() {
            Task { try? await previous.stopCapture() }
        }
        lifecycleID = UUID()
        startTask?.cancel(); startTask = nil; starting = false; restoringSources = false
        microphoneGeneration = UUID()
        microphoneSilenceReset?.cancel(); microphoneLevel = 0
        queue.sync {
            useCamera = false; useAudio = false
            cameraSession.stopRunning(); micSession.stopRunning()
            cameraImage = nil; lastAudioArrival = nil; microphoneMeter.reset()
        }
        cameraPreview = nil
    }

    @MainActor func resumePreview() async {
        guard !recording else { return }
        previewActive = true
        lifecycleID = UUID()
        let id = lifecycleID
        restoringSources = true
        defer { if lifecycleID == id { restoringSources = false } }
        if cameraEnabled { await setCameraEnabled(true) }
        guard previewActive, lifecycleID == id else { return }
        if audioEnabled { await setAudioEnabled(true) }
        guard previewActive, lifecycleID == id else { return }
        if let selectedSourceID { await selectSource(id: selectedSourceID) }
    }

    func start() {
        guard !starting, !recording, !finishing, !restoringSources, previewActive else { return }
        guard !transcriptionEnabled || modelReady else { return }
        guard let destination, FileManager.default.isWritableFile(atPath: destination.path) else {
            error = "Choose an available, writable destination folder."; return
        }
        guard queue.sync(execute: { (useScreen || useCamera) && (!useScreen || screenImage != nil) && (!useCamera || cameraImage != nil) }) else {
            error = "Wait for your selected sources to connect before recording."; return
        }
        let id = lifecycleID
        starting = true
        startTask = Task { @MainActor in
            defer { if self.lifecycleID == id { self.starting = false; self.startTask = nil } }
            do {
                // A silent microphone still delivers buffers. Never infer readiness from volume.
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while self.audioEnabled && !self.queue.sync(execute: {
                    self.useAudio && self.micSession.isRunning &&
                    self.lastAudioArrival.map { ProcessInfo.processInfo.systemUptime - $0 < 0.5 } == true
                }) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw RecorderError.message("The microphone is not delivering audio. Turn it off and on or reconnect it before recording.")
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                try await RecordingStartChime.play()
                try Task.checkCancellation()
                guard self.previewActive else { return }
                self.beginRecording()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func beginRecording() {
        guard (!transcriptionEnabled || modelReady), !recording, !finishing else { return }
        guard let destination, FileManager.default.isWritableFile(atPath: destination.path) else {
            error = "Choose an available, writable destination folder."; return
        }
        var createdFolder: URL?
        let selectedWebcamResolution = webcamResolution
        do {
            try queue.sync {
                guard useScreen || useCamera else { throw RecorderError.message("Enable a screen or camera before recording.") }
                guard !useScreen || screenImage != nil, !useCamera || cameraImage != nil else { throw RecorderError.message("Waiting for the first preview frame. Try again in a moment.") }
                guard !audioEnabled || (useAudio && micSession.isRunning && lastAudioArrival.map { ProcessInfo.processInfo.systemUptime - $0 < 0.5 } == true) else {
                    throw RecorderError.message("The microphone stopped delivering audio. Reconnect it before recording.")
                }
                let folder = try RecordingOutput.createFolder(in: destination, at: Date())
                createdFolder = folder
                let url = folder.appendingPathComponent("recording.mp4")
                leftSize = useScreen ? screenSize : .zero
                rightSize = useCamera ? selectedWebcamResolution.size(screenSize: useScreen ? screenSize : nil) : .zero
                outputSize = CGSize(width: leftSize.width + rightSize.width, height: max(leftSize.height, rightSize.height))
                let asset = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
                video.expectsMediaDataInRealTime = true
                guard asset.canAdd(video) else { throw RecorderError.message("Unsupported recording dimensions.") }
                asset.add(video)
                let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(outputSize.width), kCVPixelBufferHeightKey as String: Int(outputSize.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                var audio: AVAssetWriterInput?
                do {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
                    input.expectsMediaDataInRealTime = true
                    guard asset.canAdd(input) else { throw RecorderError.message("Cannot configure audio encoding.") }
                    asset.add(input); audio = input
                }
                guard asset.startWriting() else { throw asset.error ?? RecorderError.message("Cannot start MP4 writer.") }
                startTime = CMClockGetTime(CMClockGetHostTimeClock())
                asset.startSession(atSourceTime: startTime)
                appendedAudioBuffers = 0; receivedAudioBuffers = 0; rejectedAudioBuffers = 0; reportedAudioStall = false; expectedAudio = useAudio
                writer = asset; videoInput = video; audioInput = audio; adaptor = pixels; writingURL = url; frameCount = 0
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak self] in self?.writeFrame() }
                self.timer = timer; timer.resume()
            }
            lastRecordingNeedsTranscript = transcriptionEnabled
            subtitles = []; transcriptReady = false
            recording = true; lastFile = nil; transcriptionFailed = false; status = "Recording…"
        } catch {
            if let createdFolder { try? FileManager.default.removeItem(at: createdFolder) }
            self.error = error.localizedDescription
        }
    }

    private func fitted(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        let factor = min(rect.width / extent.width, rect.height / extent.height)
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - extent.width * factor) / 2, y: rect.minY + (rect.height - extent.height * factor) / 2))
    }

    private func writeFrame() {
        if writer != nil, useAudio, !reportedAudioStall,
           lastAudioArrival.map({ ProcessInfo.processInfo.systemUptime - $0 > 2 }) != false {
            reportedAudioStall = true
            report("Microphone audio stopped arriving. Check the microphone connection; video recording is continuing.")
        }
        guard let writer, writer.status == .writing, let videoInput, videoInput.isReadyForMoreMediaData, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        var image = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
        if useScreen, let screenImage, leftSize.width > 0 {
            image = fitted(screenImage, in: CGRect(x: 0, y: (outputSize.height - leftSize.height) / 2, width: leftSize.width, height: leftSize.height)).composited(over: image)
        }
        if useCamera, let cameraImage, rightSize.width > 0 {
            image = fitted(cameraImage, in: CGRect(x: leftSize.width, y: (outputSize.height - rightSize.height) / 2, width: rightSize.width, height: rightSize.height)).composited(over: image)
        }
        context.render(image, to: buffer)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if !adaptor.append(buffer, withPresentationTime: now) { report(writer.error?.localizedDescription ?? "Video encoding failed.") }
        frameCount += 1
    }

    func stop(completion: (() -> Void)? = nil) {
        recording = false; finishing = true; status = "Finishing MP4…"
        queue.async {
            self.timer?.cancel(); self.timer = nil
            guard let asset = self.writer else { DispatchQueue.main.async { self.finishing = false; completion?() }; return }
            self.writeFrame()
            asset.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
            self.mediaLog.info("Recording audio: received=\(self.receivedAudioBuffers), appended=\(self.appendedAudioBuffers), rejected=\(self.rejectedAudioBuffers)")
            let missingAudio = self.expectedAudio && self.appendedAudioBuffers == 0
            let url = self.writingURL
            self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
            asset.finishWriting {
                DispatchQueue.main.async {
                    self.finishing = false
                    self.suspendPreview()
                    if asset.status == .completed {
                        if missingAudio { self.error = "Video saved, but no microphone audio was received. Check your microphone before the next recording." }
                        self.lastFile = url
                        if self.lastRecordingNeedsTranscript { self.transcribeLastRecording() }
                        else { self.status = "Video saved." }
                    }
                    else { self.error = asset.error?.localizedDescription ?? "Unable to finish the recording."; self.status = "Recording failed." }
                    completion?()
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), useCamera {
            cameraImage = CIImage(cvPixelBuffer: buffer)
            previewCount += 1
            if previewCount % 3 == 0, let cameraImage { publishPreview(cameraImage, camera: true) }
        } else if output is AVCaptureAudioDataOutput, useAudio {
            lastAudioArrival = ProcessInfo.processInfo.systemUptime
            reportedAudioStall = false
            if writer != nil { receivedAudioBuffers += 1 }
            // Meter even when no writer exists; never modify the captured audio.
            let power = connection.audioChannels.map { Double($0.averagePowerLevel) }.max() ?? -.infinity
            if let level = microphoneMeter.update(power: power, at: ProcessInfo.processInfo.systemUptime) {
                publishMicrophoneLevel(level, generation: meterGeneration)
            }
            if let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData,
               let clock = micSession.synchronizationClock {
                do {
                    let sample = try RecordingAudioTiming.convert(sampleBuffer, from: clock, to: CMClockGetHostTimeClock())
                    guard RecordingAudioTiming.isEligible(sample, startingAt: startTime) else { rejectedAudioBuffers += 1; return }
                    if audioInput.append(sample) { appendedAudioBuffers += 1 }
                    else { report(writer.error?.localizedDescription ?? "Audio encoding failed.") }
                } catch { report(error.localizedDescription) }
            }
        }
    }

    private func publishMicrophoneLevel(_ level: Double, generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.audioEnabled, self.microphoneGeneration == generation else { return }
            self.microphoneLevel = level
            self.microphoneSilenceReset?.cancel()
            let reset = DispatchWorkItem { [weak self] in
                guard let self, self.microphoneGeneration == generation else { return }
                self.microphoneLevel = 0
            }
            self.microphoneSilenceReset = reset
            // A disconnected/stalled input must not leave a frozen green meter.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reset)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard mediaStream === stream, type == .screen, sampleBuffer.isValid, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), useScreen else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        screenImage = CIImage(cvPixelBuffer: buffer)
        if let screenImage { publishPreview(screenImage, camera: false, screenStream: stream) }
    }

    private func publishPreview(_ image: CIImage, camera: Bool, screenStream: SCStream? = nil) {
        let scale = min(1, 640 / image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return }
        let preview = NSImage(cgImage: cg, size: .zero)
        DispatchQueue.main.async { if camera { if self.cameraEnabled && self.previewActive { self.cameraPreview = preview } } else if self.screenEnabled && self.previewActive && self.stream === screenStream { self.screenPreview = preview } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let failure = error as NSError
        mediaLog.error("Screen stream stopped: domain=\(failure.domain, privacy: .public), code=\(failure.code), description=\(failure.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.screenRequestID = UUID()
            // Finalize an active recording instead of continuing with frozen frames.
            if self.recording { self.stop() }
            self.detachScreenStream()
            self.screenEnabled = false
            self.selectedSourceID = nil
            self.sourceName = "No screen selected"
            self.error = "Screen capture stopped: \(error.localizedDescription). The selected display or window may have become unavailable. Choose the screen or window again to reconnect."
        }
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
