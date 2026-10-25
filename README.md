# Recorder

Recorder is a small native macOS app that records audio from a microphone or any other input device and keeps a list of the recordings. It is one window, written in SwiftUI, and starts like any other app: from Finder, Launchpad or Spotlight.

## What it does

- Record and stop with the big red button or the space bar. Pause and resume while recording (menu Recording, or the Pause button).
- Shows the elapsed time as mm:ss and a live level meter in dBFS. The solid bar is the RMS level, the lighter bar is the peak, the thin line is the peak hold. A CLIP mark appears when a sample reaches full scale.
- Input device picker. "System Default" is the default entry; the choice is remembered.
- Lossless recording: 24-bit WAV at the sample rate of the device (usually 48 kHz). Mono or stereo, matching the device; a device with more than two inputs is recorded as its first two channels. There is no resampling. The other format is M4A, AAC at 256 kbps, also at the device sample rate.
- Saves to `~/Music/Recordings/` by default, as `Recording YYYY-MM-DD HH.mm.ss.wav` (or `.m4a`). The folder is created when needed.
- Below the recorder, a list of the recordings in the folder, newest first, with name, duration and size. Select a row and use the buttons below the list, or use the row's play button, a double click, or the right-click menu:
  - Play and stop (AVAudioPlayer)
  - Reveal in Finder
  - Rename (the extension stays)
  - Move to Trash (uses the Trash; nothing is deleted permanently)
  - Drag a row into Finder or another app to copy the file there.
- Asks for microphone permission the first time you record. If it was denied, the window explains this and has a button that opens System Settings, Privacy & Security, Microphone.
- If the input device is unplugged or the audio setup changes while recording, the recording stops and the file is closed and kept. The window says what happened.
- Quitting or closing the window during a recording stops it first, so the file is complete.

## Choosing the folder

The row "Save to" in the window shows where recordings go. "Choose..." opens a folder picker (it is disabled while recording). The list below shows the files of the chosen folder and updates when the folder changes.

The choice is stored as a plain path in the app's preferences, domain `local.recorder`, key `recordingsFolderPath`. The app is not sandboxed, so no bookmark is needed. If the stored folder no longer exists when the app starts, the app uses `~/Music/Recordings` and says so under the row.

From a shell:

```
defaults write local.recorder recordingsFolderPath /path/to/folder   # set
defaults delete local.recorder recordingsFolderPath                  # back to the default
```

Other stored settings: `inputDeviceUID` (the chosen input device; empty means System Default) and `recordingFormat` (`wav24` or `m4a`).

## Requirements

- macOS 13 or later, Apple Silicon (the build script targets arm64).
- Only the Xcode Command Line Tools are needed (`swiftc`, `codesign`, `iconutil`). There is no Xcode project.

## Build and install

```
bash build.sh             # builds build/Recorder.app
bash build.sh --install   # also copies it to ~/Applications/Recorder.app, replacing an existing copy
```

The script generates the icon (`scripts/make-icon.swift`), compiles `Sources/*.swift` with `swiftc`, assembles the bundle from `Info.plist`, and signs it ad hoc (`codesign --sign -`). After installing, Spotlight and Launchpad find it in `~/Applications`.

Because the signature is ad hoc, macOS treats every rebuild as a new app for privacy purposes and may ask for microphone access again.

## How it is built

- `Sources/RecordingWriter.swift` writes audio buffers to the file on its own serial queue. The recorder copies each buffer and returns at once, so disk or encoder work never blocks the audio thread or the main thread, and no buffers are dropped. The file is created from the first real buffer, so its sample rate and channel count are those of the data that arrives.
- `Sources/AudioCapture.swift` captures with `AVAudioEngine` from the chosen device, measures levels, and watches for device loss.
- `Sources/AudioDevices.swift` lists input devices with CoreAudio.
- `Sources/RecorderModel.swift`, `LibraryModel.swift`, `RecordingFolder.swift` hold the state; the `*View.swift` and `ContentView.swift` files are the interface.

## Self-test

```
~/Applications/Recorder.app/Contents/MacOS/Recorder --self-test <folder>
```

This needs no microphone and shows no window. It pushes a 2 second 1 kHz sine through the same `RecordingWriter` the recorder uses, for WAV and for M4A, in `<folder>`. It then reads the files back and checks the sample rate, channel count, 24-bit format, AAC format, length, level and tone frequency. It also checks, in `<folder>/extra`, a mono 44.1 kHz file and a 4-channel 96 kHz source reduced to two channels, plus the level calculation, file naming, the recordings list, rename rules and the folder setting. It prints PASS or FAIL for each check and exits 0 only if all pass.

```
d=$(mktemp -d) && ~/Applications/Recorder.app/Contents/MacOS/Recorder --self-test "$d"
afinfo "$d"/*.wav    # 24-bit little-endian signed integer, about 2.0 s
afinfo "$d"/*.m4a    # aac, about 2.0 s
```

## Checking the layout from a script

```
open ~/Applications/Recorder.app --args --snapshot /path/to/window.png [--appearance light|dark]
```

The app writes a picture of its own window two seconds after launch and quits. It does not need Screen Recording permission because it only captures its own window.

## Known gaps

- The meter runs only while recording. There is no input monitoring before you press record.
- If the app or the Mac crashes during a recording, the file is not finalized and may be unreadable. A normal stop, a quit, a device loss and a write error all finalize it.
- Recordings from devices with more than two inputs keep only the first two channels.
- Playback has no seek bar.
