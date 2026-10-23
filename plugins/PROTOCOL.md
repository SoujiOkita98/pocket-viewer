# pocket-viewer plugin protocol (v1)

A plugin is any program that connects to pocket-viewer's Unix socket. It can subscribe to the camera's video frames, the audio, and the gimbal state. It can send back drawing commands, shown over the video, and gimbal commands.

- **Socket:** `$POCKET_VIEWER_SOCKET` when pocket-viewer launched the plugin. Otherwise use `$TMPDIR/pocket-viewer.sock`, the per-user temporary directory (Python: `tempfile.gettempdir()`). Only the current user can connect.
- **Launching:** use *Plugins → Load Plugin…* (right-click or the menu bar), or `pocket-viewer -p "command"` (repeatable). The command runs via `/bin/sh -c` with `POCKET_VIEWER_SOCKET` and `POCKET_VIEWER_TOKEN` set. Plugins started any other way connect as *external* clients.
- **SDKs:** [`python/pocketviewer.py`](python/pocketviewer.py) (standard library only) and [`swift/PocketViewer.swift`](swift/PocketViewer.swift).

## Framing

Every message in both directions has the same layout:

```
u32 big-endian   length of the JSON header
JSON object      the header; always has "type"; has "size" when a payload follows
bytes            payload of "size" bytes (frames, audio)
```

pocket-viewer validates everything it receives. Malformed input, unknown types and wrong field types are ignored, or at worst close that connection.

## pocket-viewer → plugin

| type | fields | payload |
|---|---|---|
| `hello` | `protocol` (1), `clientID`, plus the `state` fields below | — |
| `video` | `pts` (host-clock seconds), `width`, `height`, `format` | `bgra`: width×height×4 bytes, rows top to bottom. `jpeg`: a JPEG |
| `audio` | `pts`, `rate`, `channels`, `frames`, `format` (`s16le`) | interleaved signed 16-bit little-endian samples |
| `state` | `pan`, `tilt`, `roll`, `zoom` (commanded); `actualPan`, `actualTilt` (read back from the camera); `panRange`, `tiltRange`, `zoomRange`; `video` {`width`, `height`, `fps`}; `recording` | — |

`state` arrives every 0.2 s while subscribed. All timestamps share the host clock, so video and audio `pts` can be compared directly.

## plugin → pocket-viewer

### `hello`
`{"type": "hello", "name": "face-follow", "token": "$POCKET_VIEWER_TOKEN"}` names the plugin in the Plugins menu. The token ties the connection to the process pocket-viewer launched.

### `subscribe`
```json
{"type": "subscribe",
 "video": {"maxWidth": 640, "fps": 15, "format": "bgra", "quality": 0.7},
 "audio": {"rate": 16000, "channels": 1},
 "state": true}
```
Each part is optional: `null`, `false` or a missing key unsubscribes, and `true` uses the defaults shown. A new `subscribe` replaces the previous one.

- **Video** is scaled down to `maxWidth`, keeping the aspect ratio. `quality` applies to `jpeg` only.
- **Backpressure:** a client still receiving its previous frame skips frames instead of queueing them. Audio is queued up to a limit, then dropped.
- **Audio source:** the selected audio input. With echo cancellation on, it is the echo-cancelled signal.

### `draw`
```json
{"type": "draw", "layer": "faces", "ttl": 0.5, "items": [
  {"shape": "rect", "x": 0.4, "y": 0.3, "w": 0.2, "h": 0.25, "color": "#00ff88", "width": 3, "label": "face"},
  {"shape": "line", "x1": 0.5, "y1": 0.45, "x2": 0.5, "y2": 0.55},
  {"shape": "text", "x": 0.02, "y": 0.02, "text": "hello", "size": 15},
  {"shape": "subtitle", "text": "Hello everyone", "size": 26}
]}
```
- **Coordinates** are normalized to the video frame: 0…1, origin top-left. They follow the window's scaling mode (fill, fit or stretch).
- **Layers:** each `layer` belongs to the sending plugin and is replaced wholesale by the next `draw` to it. With `ttl` > 0, the layer disappears that many seconds after it was drawn, so a crashed plugin can't leave stale boxes behind.
- **Colors** are `#rrggbb` or `#rrggbbaa`. Optional fields: rect `fill` and `label`; text `color` and `background`; subtitle `color`, `background` and `size`.
- **Subtitles** from all plugins stack upward from the bottom of the picture.

### `clear`
`{"type": "clear", "layer": "faces"}` removes one layer. Without `layer`, it removes all of this plugin's layers. They are also removed when the plugin disconnects.

### `gimbal`, `zoom`, `roll`, `center`
```json
{"type": "gimbal", "pan": 120, "tilt": -10}     // absolute degrees
{"type": "gimbal", "dpan": 5, "dtilt": -2}      // relative to the commanded position
{"type": "zoom", "zoom": 200}                   // 100…400, or "dzoom"
{"type": "roll", "roll": 0}                     // −30…30 degrees, or "droll"
{"type": "center"}
```
- **Direction:** +pan turns right and +tilt turns up. Both were measured on a Pocket 3 in landscape.
- **Speed:** the gimbal moves at roughly 8°/s. For closed-loop control, such as following a subject, wait until `actualPan`/`actualTilt` reach `pan`/`tilt` before acting on the next frame. A frame taken mid-move shows an error that is already being corrected, and correcting it again overshoots. [`FaceFollow.swift`](swift/FaceFollow.swift) does this.
- **Field of view:** about 95° × 53° at zoom 100 in 16:9, divided by zoom/100.
- **Zoom** changes glide smoothly to the target.

### `log`
`{"type": "log", "text": "…"}` is written to pocket-viewer's log, prefixed with the plugin name.

## Example plugins

| | |
|---|---|
| [`python/hello_overlay.py`](python/hello_overlay.py) | Minimal example: draws from video, audio and state. |
| [`swift/FaceFollow.swift`](swift/FaceFollow.swift) → `plugins/bin/face-follow` | Detects faces with Apple Vision, boxes them, and keeps the largest one framed. Pass `--no-follow` to only draw, or `--verbose` to log each move. |
| [`swift/Interpreter.swift`](swift/Interpreter.swift) → `plugins/bin/interpreter` | Live subtitles. Speech is recognized locally with Apple Speech, and each phrase is translated with the OpenAI API: `--from zh-CN --to English --model gpt-5.4-mini`. The key comes from `--key-file`, `$OPENAI_API_KEY`, `./.openai-key` or `~/.config/pocket-viewer/openai-key`. Without a key it shows the transcript only. |

`make plugins` builds the Swift examples into `plugins/bin/`.
