# Recorder

Native macOS 14+ screen and webcam recorder.

Build with `./scripts/build.sh`, then launch `open dist/Recorder.app`.
Requires Xcode command-line tools with Swift 5.10 or later (Xcode 16+ recommended).

Enable a camera, a screen/window, or both. Enable the microphone to record
voice. Select the screen resolution cap before enabling screen capture.
When the microphone is on, a five-bar activity meter responds to input sound even
before recording. It fades to gray in silence and hides when muted without moving
the microphone label or switch. It indicates sound level, not speech recognition.
Choose a destination folder before recording; Recorder remembers it across launches.
Start plays a short chime before the recording timeline begins, followed by a
brief pause to let speaker sound decay. The button shows “Starting…” during this
period; begin speaking when it changes to “Stop recording.” Microphone samples
from before the recording starts are discarded. If the enabled microphone is not
delivering fresh audio, starting fails with an explanation instead of silently
recording without it.

Camera and microphone capture stop on the saved-recording screen, including
while transcription runs. New recording restores the previous source choices
and reconnects the devices. Switching to another app during recording does not
interrupt capture.

Stop saves an H.264/AAC `recording.mp4` and, when transcription is enabled, generates `recording.srt`
inside a new `recording_YYYYMMDD_HHMMSS` folder under that destination.
Folder names use local recording start time; existing folders are never overwritten.

The Studio setup screen groups microphone, camera, and output controls beside a
large screen preview. “Transcribe recording” defaults on and remembers your
choice across launches. With transcription enabled, Recorder downloads multilingual
Whisper Large v3 Turbo (compressed) and its tokenizer into Application Support.
Wait for setup before recording with transcription, or turn it off to record video
without waiting for a model. Failed setup can be retried. Later launches work offline with the cached model.
Transcription runs locally on Apple Silicon, detects the spoken language, and
uses microphone audio only. A progress bar shows completed audio processing.
No speech produces an empty SRT.

After Stop, the recording detail screen opens with a native video player. When
requested, the transcript panel shows processing progress, retry on failure, or
timestamped text. Click a timestamp to seek the video. Edit and Save update the
recording’s SRT; Copy and Export .txt include timestamps. An empty transcript shows
“No speech detected.” Video-only recordings hide the transcript panel. Use New
recording after processing completes to return to setup, or Show in Finder to
reveal the MP4. Save or cancel transcript edits before starting another recording.

Closing the window or quitting during transcription asks whether to keep
transcribing or quit without subtitles. Confirming quit preserves the finalized
MP4 and does not save an SRT. Closing during recording finalizes the video first,
then asks about transcription. Failed transcription can be retried in the app.
Force Quit and power loss cannot guarantee a playable file.

Screen and camera panels are adjacent, preserving proportions with black
vertical padding. Camera output defaults to Auto (10% of video width): when
recording both sources, the camera width is one ninth of the captured screen
width, making it roughly 10% of the combined video width. Dimensions round to
even pixels. Auto uses 1280×720 for camera-only recordings. You can also choose
fixed camera output of 480p (854×480) or 720p (1280×720) before recording,
including while previewing. The labeled Screen resolution cap control limits
screen capture size; Camera output controls the recorded camera panel size. Camera
capture stays at up to 720p and is scaled to fit the selected output without
cropping. The preview box stays the same size. Screen defaults to 1080p. Video
controls lock during recording; microphone can be toggled. System audio is
not recorded. macOS will request camera, microphone, screen recording, and
Documents access as needed.

Manual acceptance checks: record each source independently and together;
check pointer visibility, microphone toggling and synchronization, static
screens, portrait windows, all resolution presets, permission denial,
source disconnection, and saving on Stop, window close, and Quit.

Webcam resolution checks: Auto with a 1920×1080 screen should produce a
2134×1080 video with a 214×120 camera panel. Auto camera-only output should
be 1280×720. Check the visible control labels at the minimum window size.
With fixed presets, camera-only output should be 854×480 or
1280×720. With a 1920×1080 screen, combined output should be 2774×1080
or 3200×1080 respectively. Check switching between recordings and that
the webcam resolution picker locks during recording and saving.

## App icon

The PNG master is `assets/Recorder.png`; the ready-to-use macOS icon is
`assets/Recorder.icns`. `scripts/export-icon.sh` exports standard and Retina
sizes using native macOS tools. The build script exports and bundles the icon
before signing the app.

Capture lifecycle checks: make at least three consecutive recordings using New
recording, with transcription both on and off. Speak distinct phrases in each
and check the saved audio and synchronization. Confirm camera/mic privacy
indicators disappear on the detail screen and return on setup. Test View last
recording and rapid navigation while sources connect, plus quitting during
Starting. Verify the start chime is absent from recordings using built-in
speakers and headphones. Test disconnecting/reconnecting the microphone and
muting/unmuting mid-recording. Capture diagnostics are available in Console
under subsystem local.recorder.app, category capture.
