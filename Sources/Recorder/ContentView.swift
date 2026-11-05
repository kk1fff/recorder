import SwiftUI
import AppKit

enum RecorderStyle {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color.primary.opacity(0.045)
    static let line = Color.primary.opacity(0.09)
    static let record = Color(red: 0.89, green: 0.30, blue: 0.31)
}

/// Draw the thumb explicitly: the small macOS switch can lose it in its enabled state.
struct SourceToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.14))
                    .frame(width: 36, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16).padding(3)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct ContentView: View {
    @ObservedObject var engine: CaptureEngine
    @State private var picker: NSWindow?
    @State private var startedAt = Date()
    @State private var showMicReminder = false
    @State private var changingMicrophone = false
    @State private var changingCamera = false
    @State private var showDetail = false

    private var locked: Bool { engine.recording || engine.finishing }
    private var showingModelLaunch: Bool {
        engine.transcriptionEnabled && !engine.modelReady && !showDetail && !engine.recording && !engine.finishing
    }
    private var canRecord: Bool {
        !engine.recording && !engine.finishing && !changingCamera && !changingMicrophone
            && engine.destination != nil && (engine.screenEnabled || engine.cameraEnabled)
            && (!engine.screenEnabled || engine.screenPreview != nil)
            && (!engine.cameraEnabled || engine.cameraPreview != nil)
            && (!engine.transcriptionEnabled || engine.modelReady)
    }

    private var setupStatus: String {
        if engine.transcribing { return "Transcribing…" }
        if engine.finishing { return "Saving recording…" }
        if changingCamera || changingMicrophone { return "Connecting sources…" }
        if !engine.screenEnabled && !engine.cameraEnabled { return "Choose a screen or camera" }
        if engine.destination == nil { return "Choose a save folder" }
        if engine.transcriptionEnabled && !engine.modelReady {
            return engine.modelLoading ? "Preparing transcription…" : "Transcription setup needed"
        }
        return canRecord ? "Ready to record" : "Waiting for preview…"
    }

    var body: some View {
        Group {
            if showDetail, let url = engine.lastFile {
                RecordingDetailView(engine: engine, url: url) { showDetail = false }
                    .id(url)
            } else {
                setup
            }
        }
        .disabled(showingModelLaunch)
        .accessibilityHidden(showingModelLaunch)
        .background(RecorderStyle.background)
        .overlay {
            if showingModelLaunch { modelLaunchOverlay }
        }
        .background(WindowCloseGuard())
        .onChange(of: engine.lastFile) { _, file in if file != nil { showDetail = true } }
        .onChange(of: engine.recording) { _, active in
            if active { startedAt = Date() }
            showMicReminder = active && !engine.audioEnabled
        }
        .onChange(of: engine.audioEnabled) { _, enabled in if enabled { showMicReminder = false } }
        .alert("Recorder", isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) {
            Button("OK") { engine.error = nil }
        } message: { Text(engine.error ?? "") }
    }

    private var setup: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
              ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .center) {
                            Text(engine.recording ? "Recording" : "New recording").font(.system(size: 25, weight: .semibold))
                            Spacer()
                            if engine.recording {
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Label(RecordingOutput.timestamp(context.date.timeIntervalSince(startedAt)), systemImage: "record.circle.fill")
                                        .monospacedDigit().foregroundStyle(RecorderStyle.record)
                                }
                            } else {
                                Text(setupStatus)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        capturePreview
                            .frame(height: max(220, min((geometry.size.width - 336) * 0.625, geometry.size.height - 160)))
                        HStack {
                            Text(engine.screenEnabled ? engine.sourceName : engine.cameraEnabled ? "Camera only" : "No screen selected")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if engine.screenEnabled {
                                Button("Change…") { openPicker() }.disabled(locked)
                                Button { Task { await engine.disableScreen() } } label: { Image(systemName: "xmark") }
                                    .help("Remove screen").accessibilityLabel("Remove screen").disabled(locked)
                            } else {
                                Button("Choose screen", systemImage: "display") { openPicker() }.disabled(locked)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if showMicReminder && engine.recording && !engine.audioEnabled { microphoneReminder }
                        if let _ = engine.lastFile {
                            Button("View last recording", systemImage: "play.rectangle") { showDetail = true }
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    settings.frame(width: 252)
                }.padding(28)
              }
            }
            Divider()
            HStack(spacing: 16) {
                Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save recording to").font(.caption).foregroundStyle(.secondary)
                    Text(engine.destination.map { $0.deletingLastPathComponent().lastPathComponent + " / " + $0.lastPathComponent } ?? "Choose a folder")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                        .help(engine.destination?.path ?? "Select a destination folder")
                }
                Button { chooseDestination() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Change save folder").disabled(locked)
                Spacer()
                Button {
                    if engine.recording { engine.stop() } else { engine.start() }
                } label: {
                    Label(engine.recording ? "Stop recording" : engine.finishing ? "Saving recording…" : "Start recording",
                          systemImage: engine.recording ? "stop.fill" : "circle.fill")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).tint(RecorderStyle.record)
                .disabled(!engine.recording && !canRecord)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }.padding(.horizontal, 28).padding(.vertical, 20).background(RecorderStyle.panel)
        }
    }

    private var capturePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(RecorderStyle.subtle)
            if engine.screenEnabled && engine.cameraEnabled {
                GeometryReader { geometry in
                    let screen = engine.selectedScreenSize
                    let camera = engine.webcamResolution.size(screenSize: screen)
                    let scale = min(geometry.size.width / (screen.width + camera.width), geometry.size.height / max(screen.height, camera.height))
                    HStack(spacing: 0) {
                        sourceImage(engine.screenPreview, symbol: "display")
                            .frame(width: screen.width * scale, height: screen.height * scale)
                        sourceImage(engine.cameraPreview, symbol: "video")
                            .frame(width: camera.width * scale, height: camera.height * scale)
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else if let image = engine.screenEnabled ? engine.screenPreview : engine.cameraPreview {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text("What would you like to capture?").font(.system(size: 16, weight: .medium))
                    Text("Choose a screen or window to get started.").font(.callout).foregroundStyle(.secondary)
                    Button("Choose screen", systemImage: "plus") { openPicker() }.padding(.top, 8).disabled(locked)
                }.frame(maxWidth: .infinity)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecorderStyle.line))
    }

    @ViewBuilder
    private func sourceImage(_ image: NSImage?, symbol: String) -> some View {
        if let image { Image(nsImage: image).resizable().scaledToFit() }
        else { Image(systemName: symbol).foregroundStyle(.secondary) }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Sources")
            Toggle(isOn: Binding(get: { engine.audioEnabled }, set: { _ in changeMicrophone() })) {
                Label("Microphone", systemImage: "mic")
            }.toggleStyle(SourceToggleStyle()).disabled(engine.finishing || changingMicrophone)
            Text(engine.audioEnabled ? "System default microphone" : "Off · No microphone audio")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { engine.cameraEnabled }, set: { _ in
                changingCamera = true
                Task { @MainActor in await engine.toggleCamera(); changingCamera = false }
            })) { Label("Camera", systemImage: "video") }
                .toggleStyle(SourceToggleStyle()).disabled(locked || changingCamera)
            if engine.cameraEnabled {
                Text(engine.screenEnabled ? "Recorded beside your screen" : "Camera only").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Off · Screen only").font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            sectionTitle("Output")
            VStack(alignment: .leading, spacing: 7) {
                Text("Screen resolution").font(.caption)
                Picker("Screen resolution", selection: $engine.resolution) {
                    Text("720p").tag(1280); Text("1080p").tag(1920)
                    Text("1440p").tag(2560); Text("2160p").tag(3840)
                }.labelsHidden().disabled(engine.screenEnabled || locked)
                if engine.screenEnabled { Text("Remove the screen to change resolution.").font(.caption2).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Camera size").font(.caption)
                Picker("Camera size", selection: $engine.webcamResolution) {
                    ForEach(WebcamResolution.allCases) { value in Text(value.label).tag(value) }
                }.labelsHidden().disabled(locked)
            }
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Transcribe recording", isOn: $engine.transcriptionEnabled).toggleStyle(.checkbox).disabled(locked)
                Text("Remembered for your next recording.").font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
            }
        }.font(.callout)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
    }

    private var modelLaunchOverlay: some View {
        ZStack {
            RecorderStyle.background.opacity(0.96)
            VStack(spacing: 20) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(engine.modelLoading ? "Preparing Recorder" : "Transcription setup needed")
                        .font(.system(size: 23, weight: .semibold))
                    Text(engine.modelLoading
                         ? (engine.modelProgress < 0.9 ? "Downloading the transcription model…" : "Loading the transcription model…")
                         : "The transcription model couldn’t be loaded. Try again or continue without transcription.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if engine.modelLoading {
                    ProgressView(value: engine.modelProgress).frame(width: 280)
                        .accessibilityLabel("Transcription model setup")
                } else {
                    Button("Retry setup") { engine.prepareModel() }.buttonStyle(.borderedProminent)
                }
                Button("Continue without transcription") { engine.transcriptionEnabled = false }
                    .controlSize(.large)
                Text("Transcription can be enabled later in Output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(36).frame(width: 430)
            .background(RecorderStyle.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RecorderStyle.line))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var microphoneReminder: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone is off").fontWeight(.medium)
                Text("Your voice isn’t being recorded.").font(.caption)
            }
            Spacer()
            Button(changingMicrophone ? "Enabling…" : "Enable microphone") { changeMicrophone() }.disabled(changingMicrophone)
            Button { showMicReminder = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss microphone reminder")
        }.padding(14).background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func changeMicrophone() {
        guard !changingMicrophone else { return }
        changingMicrophone = true
        Task { @MainActor in
            defer { changingMicrophone = false }
            await engine.toggleAudio()
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { engine.setDestination(url) }
    }

    private func openPicker() {
        if let picker, picker.isVisible { picker.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Choose a screen or window"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SourcePicker(engine: engine) { source in
            Task { await engine.select(source); window.close() }
        })
        picker = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
}
