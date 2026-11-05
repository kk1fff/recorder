import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage

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
    private var cameraImage: CIImage?
    private var screenImage: CIImage?
    private var useCamera = false
    private var useScreen = false
    private var useAudio = false
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

    func loadSources() async {
        loadingSources = true
        defer { loadingSources = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var result: [CaptureSource] = []
            for display in content.displays {
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                result.append(CaptureSource(id: "d\(display.displayID)", name: "Display \(result.count + 1)", detail: "\(display.width) × \(display.height)", filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), size: CGSize(width: display.width, height: display.height)))
            }
            for window in content.windows where window.frame.width > 100 && window.frame.height > 80 && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier {
                guard let app = window.owningApplication, let title = window.title, !title.isEmpty else { continue }
                result.append(CaptureSource(id: "w\(window.windowID)", name: title, detail: app.applicationName, filter: SCContentFilter(desktopIndependentWindow: window), size: window.frame.size))
            }
            sources = result
            for index in result.indices {
                let config = SCStreamConfiguration()
                config.width = 360; config.height = 220
                config.showsCursor = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: result[index].filter, configuration: config) {
                    sources[index].thumbnail = NSImage(cgImage: image, size: .zero)
                }
            }
        } catch { self.error = "Screen access failed: \(error.localizedDescription). Allow Recorder in System Settings → Privacy & Security → Screen & System Audio Recording." }
    }

    func select(_ source: CaptureSource) async {
        do {
            if let stream { try await stream.stopCapture() }
            let scale = min(1, min(CGFloat(resolution) / source.size.width, CGFloat(resolution * 9 / 16) / source.size.height))
            let size = CGSize(width: max(2, Int(source.size.width * scale) / 2 * 2), height: max(2, Int(source.size.height * scale) / 2 * 2))
            let config = SCStreamConfiguration()
            config.width = Int(size.width); config.height = Int(size.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true; config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let next = SCStream(filter: source.filter, configuration: config, delegate: self)
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync { self.screenImage = nil; self.screenSize = size; self.useScreen = true }
            stream = next
            try await next.startCapture()
            selectedScreenSize = size
            screenEnabled = true; sourceName = source.name
            status = "Screen selected."
        } catch { queue.sync { self.useScreen = false }; screenEnabled = false; self.error = error.localizedDescription }
    }

    func disableScreen() async {
        do { try await stream?.stopCapture() } catch { self.error = error.localizedDescription }
        stream = nil
        queue.sync { self.useScreen = false; self.screenImage = nil }
        screenEnabled = false; screenPreview = nil
    }

    func toggleCamera() async {
        if cameraEnabled {
            queue.sync { cameraSession.stopRunning(); useCamera = false; cameraImage = nil }
            cameraEnabled = false; cameraPreview = nil
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "Allow camera access in System Settings → Privacy & Security → Camera."; return }
        do {
            try queue.sync {
                if cameraSession.inputs.isEmpty {
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

    func toggleAudio() async {
        if audioEnabled {
            queue.sync { useAudio = false; micSession.stopRunning() }
            audioEnabled = false; return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Allow microphone access in System Settings → Privacy & Security → Microphone."; return }
        do {
            try queue.sync {
                if micSession.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderError.message("No microphone is available.") }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard micSession.canAddInput(input) else { throw RecorderError.message("Cannot connect to the microphone.") }
                    micSession.addInput(input)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard micSession.canAddOutput(output) else { throw RecorderError.message("Cannot configure microphone output.") }
                    micSession.addOutput(output)
                }
                micSession.startRunning(); useAudio = true
            }
            audioEnabled = true
        } catch { self.error = error.localizedDescription }
    }

    func start() {
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
            let url = self.writingURL
            self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
            asset.finishWriting {
                DispatchQueue.main.async {
                    self.finishing = false
                    if asset.status == .completed {
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
        } else if useAudio, let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startTime {
            if !audioInput.append(sampleBuffer) { report(writer.error?.localizedDescription ?? "Audio encoding failed.") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), useScreen else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        screenImage = CIImage(cvPixelBuffer: buffer)
        if let screenImage { publishPreview(screenImage, camera: false) }
    }

    private func publishPreview(_ image: CIImage, camera: Bool) {
        let scale = min(1, 640 / image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return }
        let preview = NSImage(cgImage: cg, size: .zero)
        DispatchQueue.main.async { if camera { if self.cameraEnabled { self.cameraPreview = preview } } else if self.screenEnabled { self.screenPreview = preview } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        report("Screen capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { if self.recording { self.stop() }; self.screenEnabled = false }
        queue.async { self.useScreen = false; self.screenImage = nil }
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
