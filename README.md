# pocket-viewer

A small native macOS viewer, recorder and gimbal controller for the **DJI Osmo Pocket 3** in webcam (UVC) mode.

> **Only the DJI Osmo Pocket 3 is supported at the moment.** The device is matched by its USB IDs (`2ca3:0023`) and name (`OsmoPocket3`), and the control ranges below are specific to it. Other DJI cameras or UVC webcams may expose different controls and are untested.

## Features

- **Live preview** of the Pocket 3's video, scaled to fill, fit or stretch the window, plus full screen.
- **Gimbal control** over standard UVC camera-terminal controls: pan, tilt, roll and zoom. You can use the arrow keys, drag with the mouse, or scroll the wheel. Zoom glides smoothly between levels instead of jumping.
- **Resolution and frame-rate switching**: 720p, 1080p and 4K, in landscape or portrait, at up to 30 fps.
- **Audio**: record from any input (the Pocket 3 mic, a USB audio interface, BlackHole, …) and monitor it on any output device.
- **Recording** to `.mov` with HEVC, H.264 or ProRes 422 video and AAC or 24-bit PCM audio.
- **Echo cancellation (experimental)**: uses macOS voice processing so that monitoring through speakers doesn't feed back into the mic.
- **Plugins**: external programs in any language receive the video, the audio and the gimbal state over a local socket. They can draw boxes, labels and subtitles over the picture and steer the gimbal. Two examples are included: **face follow** and **live interpretation** (speech-to-subtitles plus translation).
- Every option is available from the **right-click menu** and the menu bar.
- `pocketctl`, a command-line gimbal controller.

## Requirements

- macOS 14 or later (Apple Silicon tested)
- Xcode Command Line Tools (`xcode-select --install`)
- A DJI Osmo Pocket 3 connected over USB in webcam mode

## Build

```sh
make            # builds ./pocket-viewer, ./pocketctl and the example plugins in plugins/bin/
```

On first launch, macOS asks for camera and microphone access. If you run the app from a terminal, the permission is granted to that terminal.

## pocket-viewer

```sh
./pocket-viewer                         # 1080p30, Pocket 3 mic
./pocket-viewer -s 3840x2160 -a AG06    # 4K, record audio from another input
./pocket-viewer -l                      # list resolutions, audio inputs and outputs
./pocket-viewer -t 60 -c h264           # record 60 s with H.264, then quit
```

| Option | |
|---|---|
| `-s WxH` | initial resolution, e.g. `3840x2160` or `1080x1920` (portrait) |
| `-r fps` | initial frame rate |
| `-a name` | audio input (substring of its name) |
| `-o dir` | where recordings go (default `~/Movies`) |
| `-c codec` | `hevc`, `h264` or `prores` |
| `-e` | start with echo cancellation on |
| `-p cmd` | launch a plugin (repeatable) |
| `-t secs` | record immediately for `secs` seconds, then quit |
| `-l` | list formats and audio devices |

| Key / mouse | |
|---|---|
| Arrows / WASD, mouse drag | pan & tilt |
| `[` `]` | smaller / larger step |
| `,` `.` | roll |
| `+` `-`, scroll | zoom |
| `c` | center the gimbal |
| `r` / ⌘R | start / stop recording |
| `m` | toggle audio monitoring |
| `v` | video scaling: fill / fit / stretch |
| `f` | full screen |
| ⌘1…⌘5 | switch resolution |
| right-click | everything else |

Recording settings, audio input and output, and echo cancellation are in the right-click menu and the menu bar.

## Plugins

A plugin is any program that connects to pocket-viewer's Unix socket. It subscribes to frames (BGRA or JPEG, at the size and rate it asks for), audio (16-bit PCM at the rate it asks for) and gimbal state. It sends back `draw` commands, which render as an overlay on the video, and `gimbal` / `zoom` commands. The wire format is in [plugins/PROTOCOL.md](plugins/PROTOCOL.md), with SDKs for [Python](plugins/python/pocketviewer.py) (standard library only) and [Swift](plugins/swift/PocketViewer.swift).

```sh
./pocket-viewer -p "plugins/bin/face-follow"                # keep the largest face framed
./pocket-viewer -p "plugins/bin/interpreter --from zh-CN --to English"
./pocket-viewer -p "python3 plugins/python/hello_overlay.py"
```

Plugins can also be loaded from *Plugins → Load Plugin…*, which also lists running plugins and stops them. A plugin started on its own, while pocket-viewer is running, connects to `$TMPDIR/pocket-viewer.sock`.

```python
import pocketviewer

class Boxes(pocketviewer.Plugin):
    def on_video(self, frame):            # frame.data: BGRA, rows top to bottom
        self.draw("demo", [{"shape": "rect", "x": .4, "y": .4, "w": .2, "h": .2, "label": "hi"}], ttl=1)

Boxes("boxes").run(video={"maxWidth": 320, "fps": 5})
```

- **face-follow** uses Apple Vision to box every face. It turns the gimbal to keep the largest one centered a little above the middle, and moves only once the gimbal has settled, so it converges without oscillating. Pass `--no-follow` to only draw.
- **interpreter** shows live subtitles with one of two engines:
  - `--asr apple` (the default): speech is recognized on-device with Apple Speech, and each phrase is translated with the OpenAI API (`gpt-5.4-mini`) once the speaker pauses. On first run, macOS asks for speech-recognition permission.
  - `--asr openai`: the audio streams to OpenAI's `gpt-realtime-translate`, which transcribes and translates while the speaker is still talking. It is noticeably more accurate, and audio is uploaded continuously and billed per minute.

  Put your key in `$OPENAI_API_KEY` or a `.openai-key` file, which is git-ignored.

## pocketctl

```sh
./pocketctl get              # current pan / tilt / zoom / roll and ranges
./pocketctl set 90 -10       # absolute pan / tilt in degrees
./pocketctl move 15 0        # relative move
./pocketctl zoom 200         # 100 … 400
./pocketctl roll 10          # -30 … 30 degrees
./pocketctl center
./pocketctl                  # interactive: arrow keys, +/-, c, q
```

## How it works / Pocket 3 notes

- **Gimbal control.** In webcam mode the Pocket 3 exposes standard UVC camera-terminal controls: *PanTilt Absolute* (pan −35°…215°, tilt ±90°, 1° steps, in arc-seconds on the wire), *Zoom Absolute* (100…400) and *Roll Absolute* (−30°…30°, in whole degrees). macOS's `UVCAssistant` owns the device, so libusb can't open it. `gimbal.c` sends class requests to the default control pipe through IOKit `DeviceRequest` instead, which needs no root and works while video is streaming.
- **Not supported by the device.** Focus responds but ignores writes. Image controls (brightness, white balance, …) are stubs. A vendor extension unit exists but is undocumented and is left untouched.
- **Video formats.** AVFoundation also lists `2vuy` formats for the Pocket 3, including the only 4K60 mode, but they deliver no frames on macOS. Only the `420v` formats are offered, which caps the frame rate at 4K30.
- **Format locking.** macOS resets the camera format whenever the capture session reconfigures, unless the device stays locked for configuration. pocket-viewer holds that lock while it runs.
- **Plugin direction and field of view.** +pan turns right and +tilt turns up. The field of view is about 95° × 53° at zoom 100 (16:9), measured by panning and cross-correlating frames through the plugin interface.
- **Echo cancellation.** This uses `AVAudioEngine` with voice processing. It only cancels audio the engine itself plays, which is the monitor path, not other apps. Recording in this mode muxes camera frames and processed audio with `AVAssetWriter` on the host clock. See the comments in `echocancel.m` for the macOS voice-processing pitfalls worked around.

## License

MIT, see [LICENSE](LICENSE).

DJI and Osmo are trademarks of SZ DJI Technology Co., Ltd. This project is not affiliated with or endorsed by DJI.
