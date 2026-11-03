import SwiftUI
import AppKit

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView(engine: delegate.engine).frame(minWidth: 820, minHeight: 440) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = CaptureEngine()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private var confirming = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.prepareModel()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirming { return .terminateCancel }
        if engine.transcribing {
            confirming = true
            let alert = NSAlert()
            alert.messageText = "Transcription is still in progress"
            alert.informativeText = "Quit now? Your video is saved, but no subtitle file will be saved."
            alert.addButton(withTitle: "Keep Transcribing")
            alert.addButton(withTitle: "Quit Without Subtitles")
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                if self?.engine.transcribing == false { NSApplication.shared.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = alert.runModal()
            timer.invalidate()
            alert.window.orderOut(nil)
            confirming = false
            if !engine.transcribing { return .terminateNow }
            if response == .alertSecondButtonReturn { engine.cancelTranscription(); return .terminateNow }
            return .terminateCancel
        }
        if engine.recording {
            engine.stop { sender.terminate(nil) }
            return .terminateCancel
        }
        if engine.finishing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sender.terminate(nil) }
            return .terminateCancel
        }
        return .terminateNow
    }

}
struct ContentView: View {
    @ObservedObject var engine: CaptureEngine
    @State private var picker: NSWindow?
    @State private var startedAt = Date()
    @State private var showMicReminder = false
    @State private var changingMicrophone = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("Recorder").font(.largeTitle.bold()); Spacer(); Text(engine.recording ? "● RECORDING" : "READY").foregroundStyle(engine.recording ? .red : .secondary) }
            if showMicReminder && engine.recording && !engine.audioEnabled {
                microphoneReminder
            }
            HStack {
                Text("Destination: " + (engine.destination?.path ?? "Choose a folder"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { engine.setDestination(url) }
                }.disabled(engine.recording || engine.finishing)
            }
            if !engine.modelReady {
                HStack {
                    if engine.modelLoading {
                        ProgressView(value: engine.modelProgress)
                        Text(engine.modelProgress < 0.9 ? "Downloading transcription model…" : "Loading transcription model…")
                    } else { Button("Retry Model Setup") { engine.prepareModel() } }
                }
            }
            if engine.transcribing {
                HStack {
                    ProgressView(value: engine.transcriptionProgress)
                    Text("Transcribing… \(Int(engine.transcriptionProgress * 100))%")
                }
            }
            if engine.transcriptionFailed {
                Button("Retry Transcription") { engine.transcribeLastRecording() }
            }
            HStack(spacing: 16) {
                preview("Camera", image: engine.cameraPreview, symbol: "video")
                preview(engine.sourceName, image: engine.screenPreview, symbol: "display")
            }
            HStack {
                if engine.recording { TimelineView(.periodic(from: startedAt, by: 1)) { context in Text(Duration.seconds(Int(context.date.timeIntervalSince(startedAt))).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit() } }
                Text(engine.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let url = engine.lastFile { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) } }
            }
            Spacer(minLength: 0)
        }.padding(28)
        .background(WindowCloseGuard())
        .onChange(of: engine.recording) { _, active in
            if active { startedAt = Date() }
            showMicReminder = active && !engine.audioEnabled
        }
        .onChange(of: engine.audioEnabled) { _, enabled in
            if enabled { showMicReminder = false }
        }
        .toolbar {
            Button(engine.recording ? "Stop Recording" : "Start Recording", systemImage: engine.recording ? "stop.circle.fill" : "record.circle") { if engine.recording { engine.stop() } else { engine.start() } }.disabled(engine.finishing || (!engine.recording && (!engine.modelReady || engine.destination == nil)))
            Button(engine.audioEnabled ? "Mute Microphone" : "Enable Microphone", systemImage: engine.audioEnabled ? "mic.fill" : "mic.slash") { changeMicrophone() }.disabled(engine.finishing || changingMicrophone)
            Button(engine.cameraEnabled ? "Disable Camera" : "Enable Camera", systemImage: engine.cameraEnabled ? "video.fill" : "video.slash") { Task { await engine.toggleCamera() } }.disabled(engine.recording || engine.finishing)
            Button(engine.screenEnabled ? "Disable Screen" : "Select Screen", systemImage: "display") {
                if engine.screenEnabled { Task { await engine.disableScreen() } } else { openPicker() }
            }.disabled(engine.recording || engine.finishing)
            Picker("Webcam resolution", selection: $engine.webcamResolution) {
                ForEach(WebcamResolution.allCases) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }.frame(width: 180).disabled(engine.recording || engine.finishing)
            Picker("Screen cap", selection: $engine.resolution) { Text("720p").tag(1280); Text("1080p").tag(1920); Text("1440p").tag(2560); Text("2160p").tag(3840) }.frame(width: 110).disabled(engine.screenEnabled || engine.recording || engine.finishing)
        }
        .alert("Recorder", isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) { Button("OK") { engine.error = nil } } message: { Text(engine.error ?? "") }
    }
    private var microphoneReminder: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.slash.fill")
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Microphone is off").font(.headline)
                Text("Your voice isn’t being recorded.").font(.callout)
            }
            Spacer(minLength: 8)
            Button(changingMicrophone ? "Enabling…" : "Enable Microphone") {
                changeMicrophone()
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .foregroundStyle(.white)
            .disabled(changingMicrophone)
            Button { showMicReminder = false } label: {
                Image(systemName: "xmark").font(.body.bold())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Dismiss microphone reminder")
            .help("Dismiss microphone reminder")
        }
        .foregroundStyle(.black)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1, green: 0.77, blue: 0.28), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func changeMicrophone() {
        guard !changingMicrophone else { return }
        changingMicrophone = true
        Task { @MainActor in
            defer { changingMicrophone = false }
            await engine.toggleAudio()
        }
    }

    func preview(_ title: String, image: NSImage?, symbol: String) -> some View {
        VStack(alignment: .leading) {
            ZStack { Color.black; if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.gray) } }.aspectRatio(16/9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title).font(.headline).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
    func openPicker() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Choose a screen or window"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SourcePicker(engine: engine) { source in Task { await engine.select(source); window.close() } })
        picker = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
}
struct SourcePicker: View {
    @ObservedObject var engine: CaptureEngine
    let select: (CaptureSource) -> Void
    var body: some View {
        VStack {
            HStack { Text("Choose what to share").font(.title2.bold()); Spacer(); if engine.loadingSources { ProgressView().controlSize(.small) } }
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 18) {
                ForEach(engine.sources) { source in Button { select(source) } label: {
                    VStack(alignment: .leading) {
                        ZStack { Color.black; if let image = source.thumbnail { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "display") } }.frame(height: 135)
                        Text(source.name).lineLimit(1); Text(source.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(8)
                }.buttonStyle(.plain) }
            } }
        }.padding(24).task { await engine.loadSources() }
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    final class Coordinator: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApplication.shared.terminate(nil)
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
    }
}
