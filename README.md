# Recorder

Native macOS 14+ screen and webcam recorder.

Build with `./scripts/build.sh`, then launch `open dist/Recorder.app`.
Requires Xcode command-line tools with Swift 5.10 or later (Xcode 16+ recommended).

Enable a camera, a screen/window, or both. Enable the microphone to record
voice. Select the screen resolution cap before enabling screen capture.
Choose a destination folder before recording; Recorder remembers it across launches.
Stop saves an H.264/AAC `recording.mp4` and then generates `recording.srt`
inside a new `recording_YYYYMMDD_HHMMSS` folder under that destination.
Folder names use local recording start time; existing folders are never overwritten.

On first launch Recorder downloads multilingual Whisper Large v3 Turbo (compressed)
and its tokenizer into Application Support. Wait for setup before recording;
failed setup can be retried. Later launches work offline with the cached model.
Transcription runs locally on Apple Silicon, detects the spoken language, and
uses microphone audio only. A progress bar shows completed audio processing.
No speech produces an empty SRT.

Closing the window or quitting during transcription asks whether to keep
transcribing or quit without subtitles. Confirming quit preserves the finalized
MP4 and does not save an SRT. Closing during recording finalizes the video first,
then asks about transcription. Failed transcription can be retried in the app.
Force Quit and power loss cannot guarantee a playable file.

Screen and camera panels are adjacent, preserving proportions with black
vertical padding. Choose webcam output of 480p (854×480) or 720p
(1280×720, default) before recording, including while previewing. Camera
capture stays at up to 720p and is scaled to fit the selected output without
cropping. The preview box stays the same size. Screen defaults to 1080p. Video
controls lock during recording; microphone can be toggled. System audio is
not recorded. macOS will request camera, microphone, screen recording, and
Documents access as needed.

Manual acceptance checks: record each source independently and together;
check pointer visibility, microphone toggling and synchronization, static
screens, portrait windows, all resolution presets, permission denial,
source disconnection, and saving on Stop, window close, and Quit.

Webcam resolution checks: camera-only output should be 854×480 or
1280×720. With a 1920×1080 screen, combined output should be 2774×1080
or 3200×1080 respectively. Check switching between recordings and that
the webcam resolution picker locks during recording and saving.

## App icon

The PNG master is `assets/Recorder.png`; the ready-to-use macOS icon is
`assets/Recorder.icns`. `scripts/export-icon.sh` exports standard and Retina
sizes using native macOS tools. The build script exports and bundles the icon
before signing the app.
