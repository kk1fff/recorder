import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

/// Use AppKit directly to avoid the _AVKit_SwiftUI superclass-metadata crash
/// when SwiftUI's VideoPlayer is first instantiated on affected macOS releases.
struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

final class RecordingPlayback: ObservableObject {
    let player: AVPlayer
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var dimensions = ""
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            self?.position = time.seconds.isFinite ? time.seconds : 0
        }
    }

    @MainActor func loadMetadata() async {
        guard let asset = player.currentItem?.asset else { return }
        if let time = try? await asset.load(.duration), time.seconds.isFinite { duration = time.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            dimensions = "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    func seek(to time: Double) {
        position = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        player.pause()
    }
}

struct RecordingDetailView: View {
    @ObservedObject var engine: CaptureEngine
    let url: URL
    let newRecording: () -> Void
    @StateObject private var playback: RecordingPlayback
    @State private var editing = false
    @State private var draft: [Subtitle] = []
    @State private var notice = ""

    init(engine: CaptureEngine, url: URL, newRecording: @escaping () -> Void) {
        self.engine = engine
        self.url = url
        self.newRecording = newRecording
        _playback = StateObject(wrappedValue: RecordingPlayback(url: url))
    }

    private var transcript: [Subtitle] { editing ? draft : engine.subtitles }
    private var activeIndex: Int? {
        engine.subtitles.indices.last { engine.subtitles[$0].start <= playback.position && playback.position < engine.subtitles[$0].end }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording saved").font(.system(size: 25, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(url.deletingLastPathComponent().lastPathComponent)
                        Text("·")
                        Text(RecordingOutput.timestamp(playback.duration)).monospacedDigit()
                        if !playback.dimensions.isEmpty { Text("·"); Text(playback.dimensions) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Video saved", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }.padding(28)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    RecordingPlayerView(player: playback.player)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Recorded video player")
                    Label(url.deletingLastPathComponent().path, systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
                if engine.lastRecordingNeedsTranscript {
                    Divider()
                    transcriptPanel.frame(width: 336).background(RecorderStyle.panel)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(notice.isEmpty ? engine.status : notice).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(notice.isEmpty ? engine.status : notice)
                Spacer()
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("New recording", systemImage: "plus") {
                    playback.player.pause()
                    newRecording()
                }.disabled(engine.finishing || editing)
            }.padding(.horizontal, 28).padding(.vertical, 18).background(RecorderStyle.panel)
        }
        .task { await playback.loadMetadata() }
        .onDisappear { playback.player.pause() }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    Text(engine.transcribing ? "Transcribing…" : engine.transcriptionFailed ? "Needs attention" : "Ready")
                        .font(.caption).foregroundStyle(engine.transcriptionFailed ? Color.orange : Color.secondary)
                }
                Text(editing ? "Edit the text, then save your changes." : "Click a timestamp to jump")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    if editing {
                        Button("Save") {
                            if engine.saveTranscript(draft) { editing = false; notice = "Transcript changes saved." }
                        }.buttonStyle(.borderedProminent)
                        Button("Cancel") { editing = false; draft = [] }
                    } else {
                        Button("Edit", systemImage: "pencil") { draft = engine.subtitles; editing = true }
                            .disabled(!engine.transcriptReady || engine.subtitles.isEmpty)
                    }
                    Button { copyTranscript() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(!engine.transcriptReady)
                    Button { exportTranscript() } label: { Label("Export .txt", systemImage: "square.and.arrow.down") }
                        .disabled(!engine.transcriptReady || editing)
                }.controlSize(.small)
            }.padding(20)
            Divider()
            if engine.transcribing {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.secondary)
                    Text("Turning speech into text…").font(.headline)
                    Text("Your recording is saved and ready to watch.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("Transcribing audio")
                        Spacer()
                        Text("\(Int(engine.transcriptionProgress * 100))%").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    ProgressView(value: engine.transcriptionProgress).tint(.green)
                    Spacer()
                }.padding(24)
            } else if engine.transcriptionFailed {
                ContentUnavailableView {
                    Label("Transcription failed", systemImage: "exclamationmark.bubble")
                } description: {
                    Text("Your video is safe. Try generating the transcript again.")
                } actions: {
                    Button("Retry transcription") { engine.transcribeLastRecording() }
                }
            } else if engine.transcriptReady && engine.subtitles.isEmpty {
                ContentUnavailableView("No speech detected", systemImage: "waveform", description: Text("No spoken words were found in the recorded microphone audio."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(transcript.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 12) {
                                Button(RecordingOutput.timestamp(transcript[index].start)) {
                                    playback.seek(to: transcript[index].start)
                                }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading).padding(.top, 3)
                                    .accessibilityLabel("Jump to \(RecordingOutput.timestamp(transcript[index].start))")
                                if editing {
                                    TextField("Transcript text", text: $draft[index].text, axis: .vertical)
                                        .textFieldStyle(.roundedBorder).lineLimit(2...12)
                                } else {
                                    Text(transcript[index].text.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .font(.callout).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(12)
                                .background(activeIndex == index ? RecorderStyle.subtle : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(10)
                }
            }
            Divider()
            Text(engine.transcribing ? "You can watch the recording while we work." : "Generated transcript · Review for accuracy")
                .font(.caption2).foregroundStyle(.secondary).padding(16)
        }.frame(maxHeight: .infinity)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RecordingOutput.transcript(transcript), forType: .string)
        notice = "Transcript copied."
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.txt"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try RecordingOutput.transcript(transcript).write(to: destination, atomically: true, encoding: .utf8)
            notice = "Transcript exported."
        } catch { engine.error = "Could not export transcript: \(error.localizedDescription)" }
    }
}
