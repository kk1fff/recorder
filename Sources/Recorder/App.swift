import SwiftUI
import AppKit

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView(engine: delegate.engine).frame(width: 1000, height: 640) }
            .defaultSize(width: 1000, height: 640)
            .windowResizability(.contentSize)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = CaptureEngine()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private var confirming = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if engine.transcriptionEnabled { engine.prepareModel() }
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
        engine.suspendPreview()
        return .terminateNow
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
