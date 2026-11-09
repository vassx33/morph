# Morph

A small, native macOS app that converts files by drag and drop: images, PDFs, documents, video and audio.

Drop files (or whole folders) onto the window, pick what to turn them into, and press **Convert**. Everything runs locally on your Mac. Morph makes no network requests and collects nothing.

## What it converts

| From | To |
|---|---|
| **Images**: HEIC, JPEG, PNG, WebP, AVIF, TIFF, GIF, BMP, PSD, camera RAW | JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, PDF |
| **PDF** | Word, plain text, RTF, or one image per page (PNG, JPEG, TIFF, HEIC) |
| **Documents**: Word (.docx/.doc), RTF, OpenDocument, TXT, Markdown, HTML | PDF, Word, Word 97, RTF, plain text, HTML, OpenDocument |
| **Video**: MP4, MOV, M4V | MP4 (H.264), MP4 (HEVC), MOV, animated GIF, M4A, WAV |
| **Audio**: MP3, M4A, WAV, AIFF, FLAC, AAC | M4A, WAV, AIFF, FLAC, Apple Lossless |

With [ffmpeg](https://ffmpeg.org) installed, Morph also:

- converts anything with audio to **MP3**
- opens **MKV, WebM, AVI, WMV, FLV, MPEG, OGG, Opus and WMA** files

Morph looks for ffmpeg in the standard Homebrew and MacPorts locations and enables these formats automatically.

```bash
brew install ffmpeg
```

## Features

- Drag and drop files or folders onto the window or the Dock icon, or use **Open With → Morph** in Finder
- Choose one target per file type, or override it for a single file
- Converts in parallel, with progress for long video jobs
- Never overwrites anything: if a name is taken it saves as `photo 2.jpg`
- Photos keep their date, camera and location metadata (optional), and sideways iPhone photos come out upright
- Save next to the original or into a folder you choose

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode or the Xcode Command Line Tools, to build

## Build

```bash
git clone <this-repo-url>
cd morph
./build.sh
```

The app is written to `build/Morph.app`. Drag it into `/Applications` to install.

The build is signed ad hoc, not with an Apple Developer ID. If macOS blocks it the first time, right-click the app and choose **Open**.

## Limitations

- **PDF → Word / text** copies the text and basic formatting, not the page layout. Scanned PDFs have no text layer, so there's nothing to extract.
- **Video → GIF** uses the first 60 seconds at 12 fps, up to 540 px wide.
- **MP3 output** needs ffmpeg, because macOS doesn't include an MP3 encoder.

## How it works

Morph uses only Apple frameworks, with no third-party dependencies:

| Area | Framework |
|---|---|
| Images | ImageIO |
| PDFs | Core Graphics and PDFKit |
| Documents | AppKit's text system (`NSAttributedString`) |
| Audio and video | AVFoundation |
| Thumbnails | QuickLook |
| Interface | SwiftUI |

ffmpeg is optional. When it's installed, Morph runs it as a separate process; it is not bundled or linked into the app.

```
Sources/
  App.swift        SwiftUI interface
  Model.swift      Queue, settings and conversion scheduling
  Formats.swift    Which formats convert to which
  Engine.swift     The converters (image, PDF, document, media, ffmpeg)
scripts/
  make_icon.swift  Renders the app icon
build.sh           Compiles, bundles and signs the app
```

## License

[MIT](LICENSE)
