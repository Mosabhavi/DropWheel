# Contributing

Thanks for helping improve DropWheel!

## Setup

```bash
git clone https://github.com/Mosabhavi/DropWheel.git
cd DropWheel
./build-app.sh            # builds DropWheel.app
brew install ffmpeg webp  # optional: MP3/OGG/Opus/MKV/AVI/WMV/WebM/WebP
```

## Where things live

| File | Purpose |
|---|---|
| `DragMonitor.swift` | Detects file drags and the trigger key |
| `Wheel.swift` | Overlay window, drawing, drop target |
| `Catalog.swift` | Which actions appear for which file kind |
| `ImageOps` / `MediaOps` / `DocOps` / `Extras` | Conversion engines |
| `FFmpeg.swift` | Optional ffmpeg backend for formats macOS can't write |
| `Compress.swift` | Quality and exact-size compression |
| `ImageEditors.swift` | Crop, Redact, Annotate, Add Background |
| `AudioPanels.swift` | Bleep and Channels |
| `Panels.swift` / `MorePanels.swift` | Edit Photo, Trim, video panels, PDF Organize, Metadata |

## Checking your change

```bash
swift build -c release
B=.build/release/DropWheel
$B --test convert <files…>                       # every convert action, headless
$B --test tools <files…>                         # every tool that doesn't open a window
$B --test-panels <image> <audio> <video> <pdf>   # every window's save path
$B --render convert <file> wheel.png 2           # draw the wheel
$B --render-panel crop <image> crop.png          # draw a window
```

Please keep everything local — no network calls — and match the existing code style.
