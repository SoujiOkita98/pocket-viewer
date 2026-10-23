#!/usr/bin/env python3
"""Minimal pocket-viewer plugin: shows what a plugin receives.

Draws a box that sweeps across the picture, the frame's average brightness
(computed from the raw BGRA pixels), the audio level, and the gimbal state.

    python3 plugins/python/hello_overlay.py      # with pocket-viewer running
    pocket-viewer -p "python3 plugins/python/hello_overlay.py"
"""

import array
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pocketviewer  # noqa: E402


class HelloOverlay(pocketviewer.Plugin):
    def __init__(self):
        super().__init__("hello-overlay")
        self.frames = 0
        self.started = time.time()
        self.level_db = -90.0

    def on_video(self, frame):
        self.frames += 1
        # Sample every 97th pixel's green channel: cheap enough in pure Python.
        g = frame.data[1::4 * 97]
        brightness = sum(g) / max(len(g), 1) / 255
        x = (time.time() * 0.2) % 0.8
        fps = self.frames / max(time.time() - self.started, 1e-6)
        st = self.state
        self.draw("demo", [
            {"shape": "rect", "x": x, "y": 0.1, "w": 0.2, "h": 0.2, "color": "#ffcc00", "width": 3,
             "label": f"{frame.width}x{frame.height} @ {fps:.1f} fps"},
            {"shape": "text", "x": 0.02, "y": 0.02, "size": 14,
             "text": f"brightness {brightness:.2f}   audio {self.level_db:5.1f} dB   "
                     f"pan {st.get('pan', 0):.1f}°  tilt {st.get('tilt', 0):.1f}°  zoom {st.get('zoom', 0):.0f}"},
        ], ttl=1)

    def on_audio(self, chunk):
        samples = array.array("h", chunk.data)
        peak = max((abs(s) for s in samples), default=0)
        self.level_db = 20 * math.log10(peak / 32768) if peak else -90.0


if __name__ == "__main__":
    HelloOverlay().run(video={"maxWidth": 320, "fps": 10, "format": "bgra"},
                       audio={"rate": 16000, "channels": 1}, state=True)
