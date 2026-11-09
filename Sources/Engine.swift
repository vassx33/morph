import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Job {
    let source: URL
    let kind: MediaKind
    let format: Format
    let quality: Double
    let keepMetadata: Bool
    /// nil = next to the original
    let destination: URL?
}

struct JobResult {
    var outputs: [URL]
    var note: String? = nil
}

enum Engine {
    static func run(_ job: Job, progress: @escaping (Double) -> Void) throws -> JobResult {
        let dir = job.destination ?? job.source.deletingLastPathComponent()
        let base = job.source.deletingPathExtension().lastPathComponent
        let format = job.format

        if format.needsFFmpeg || Catalog.needsFFmpegToRead(job.source) {
            guard FFmpeg.path != nil else {
                let what = format.needsFFmpeg ? "MP3" : job.source.pathExtension.uppercased()
                throw ConversionError("\(what) needs ffmpeg — run: brew install ffmpeg")
            }
            let dst = try reserveFile(in: dir, base: base, ext: format.ext)
            try produce(dst) { try FFmpeg.convert(job.source, to: format, dst: dst, progress: progress) }
            return JobResult(outputs: [dst], note: format.id == "gif" ? "Up to 60 s" : nil)
        }

        switch job.kind {
        case .image:
            let dst = try reserveFile(in: dir, base: base, ext: format.ext)
            try produce(dst) {
                try ImageEngine.convert(job.source, to: format, quality: job.quality,
                                        keepMetadata: job.keepMetadata, dst: dst)
            }
            return JobResult(outputs: [dst])

        case .pdf:
            if ["png", "jpg", "tiff", "heic"].contains(format.id) {
                return try PDFEngine.renderPages(job.source, as: format, quality: job.quality,
                                                 dir: dir, base: base, progress: progress)
            }
            let text = try PDFEngine.extractText(job.source)
            let dst = try reserveFile(in: dir, base: base, ext: format.ext)
            try produce(dst) { try DocEngine.write(text, as: format, to: dst) }
            return JobResult(outputs: [dst], note: "Text only — PDF layout isn't kept")

        case .document:
            let text = try DocEngine.read(job.source)
            let dst = try reserveFile(in: dir, base: base, ext: format.ext)
            try produce(dst) { try DocEngine.write(text, as: format, to: dst) }
            return JobResult(outputs: [dst])

        case .video, .audio:
            let dst = try reserveFile(in: dir, base: base, ext: format.ext)
            var note: String?
            try produce(dst) { note = try MediaEngine.convert(job.source, to: format, dst: dst, progress: progress) }
            return JobResult(outputs: [dst], note: note)
        }
    }

    /// Runs `body`; on failure removes the half-written output.
    static func produce(_ dst: URL, _ body: () throws -> Void) throws {
        do { try body() } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
    }

    private static let reserveLock = NSLock()

    /// Picks a free name ("IMG_1.jpg", "IMG_1 2.jpg", …) and creates an empty placeholder so
    /// parallel conversions never collide and nothing is ever overwritten.
    static func reserveFile(in dir: URL, base: String, ext: String) throws -> URL {
        reserveLock.lock(); defer { reserveLock.unlock() }
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw ConversionError("Can't save to “\(dir.lastPathComponent)” — pick another destination")
        }
        return url
    }

    static func reserveDirectory(in dir: URL, base: String) throws -> URL {
        reserveLock.lock(); defer { reserveLock.unlock() }
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        do { try fm.createDirectory(at: url, withIntermediateDirectories: false) } catch {
            throw ConversionError("Can't save to “\(dir.lastPathComponent)” — pick another destination")
        }
        return url
    }

    static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}

// MARK: - Images

enum ImageEngine {
    static let typeIDs: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "avif": "public.avif",
        "tiff": "public.tiff", "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp",
    ]

    static func convert(_ src: URL, to format: Format, quality: Double, keepMetadata: Bool, dst: URL) throws {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else {
                throw ConversionError("Not a readable image")
            }
            let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard w > 0, h > 0 else { throw ConversionError("Image has no pixels") }

            // Full-resolution decode with EXIF orientation baked in.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ConversionError("Couldn't decode image")
            }

            if format.id == "pdf" {
                let dpi = max(props[kCGImagePropertyDPIWidth] as? Double ?? 72, 72)
                try writePDF(image, dpi: dpi, to: dst)
                return
            }
            var metadata: [CFString: Any] = [:]
            if keepMetadata && ["jpg", "heic", "avif", "tiff", "png"].contains(format.id) {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                            kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                    if let value = props[key] { metadata[key] = value }
                }
                if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    metadata[kCGImagePropertyTIFFDictionary] = tiff
                }
                if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                    exif[kCGImagePropertyExifPixelXDimension] = image.width
                    exif[kCGImagePropertyExifPixelYDimension] = image.height
                    metadata[kCGImagePropertyExifDictionary] = exif
                }
            }
            try write(image, as: format, quality: quality, metadata: metadata, to: dst)
        }
    }

    static func write(_ image: CGImage, as format: Format, quality: Double,
                      metadata: [CFString: Any] = [:], to dst: URL) throws {
        guard let type = typeIDs[format.id] else { throw ConversionError("Unsupported image format") }
        var props = metadata
        props[kCGImagePropertyOrientation] = 1
        if Format.lossyImage.contains(format.id) {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        let output = ["jpg", "bmp"].contains(format.id) ? flattened(image) : image
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type as CFString, 1, nil) else {
            throw ConversionError("Couldn't create output file")
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't write output file") }
    }

    /// Formats without transparency get a white background instead of black.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func writePDF(_ image: CGImage, dpi: Double, to dst: URL) throws {
        let scale = 72.0 / dpi
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, nil) else {
            throw ConversionError("Couldn't create PDF")
        }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

// MARK: - PDF

enum PDFEngine {
    static func open(_ src: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(src as CFURL) else { throw ConversionError("Can't open this PDF") }
        if doc.isEncrypted && !doc.isUnlocked { throw ConversionError("This PDF is password-protected") }
        guard doc.numberOfPages > 0 else { throw ConversionError("This PDF has no pages") }
        return doc
    }

    static func renderPages(_ src: URL, as format: Format, quality: Double, dir: URL, base: String,
                            progress: (Double) -> Void) throws -> JobResult {
        let doc = try open(src)
        let count = doc.numberOfPages
        let outDir = count == 1 ? dir : try Engine.reserveDirectory(in: dir, base: base)
        let digits = String(count).count
        var files: [URL] = []
        do {
            for i in 1...count {
                try autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let image = try render(page, dpi: 150)
                    let number = String(repeating: "0", count: max(0, digits - String(i).count)) + String(i)
                    let name = count == 1 ? base : "\(base) – page \(number)"
                    let dst = try Engine.reserveFile(in: outDir, base: name, ext: format.ext)
                    try Engine.produce(dst) { try ImageEngine.write(image, as: format, quality: quality, to: dst) }
                    files.append(dst)
                }
                progress(Double(i) / Double(count))
            }
        } catch {
            if count > 1 { try? FileManager.default.removeItem(at: outDir) }
            throw error
        }
        if count == 1 { return JobResult(outputs: files) }
        return JobResult(outputs: [outDir], note: "\(count) pages")
    }

    static func render(_ page: CGPDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(dpi / 72, 10_000 / max(size.width, size.height, 1))
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError("Couldn't render page")
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ConversionError("Couldn't render page") }
        return image
    }

    static func extractText(_ src: URL) throws -> NSAttributedString {
        guard let doc = PDFDocument(url: src) else { throw ConversionError("Can't open this PDF") }
        if doc.isLocked { throw ConversionError("This PDF is password-protected") }
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.attributedString else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            out.append(text)
        }
        guard !out.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError("No selectable text — this PDF looks like a scan")
        }
        return out
    }
}

// MARK: - Documents

enum DocEngine {
    static let readTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument,
        "html": .html, "htm": .html, "webarchive": .webArchive,
    ]
    static let writeTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument, "html": .html,
    ]

    static func read(_ src: URL) throws -> NSAttributedString {
        let ext = src.pathExtension.lowercased()
        guard let type = readTypes[ext] else {
            // Plain text / Markdown
            var encoding = String.Encoding.utf8
            guard let string = (try? String(contentsOf: src, usedEncoding: &encoding))
                    ?? (try? String(contentsOf: src, encoding: .isoLatin1)) else {
                throw ConversionError("Can't read this text file")
            }
            return NSAttributedString(string: string, attributes: [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        do {
            return try Engine.onMain {
                try NSAttributedString(url: src, options: [.documentType: type], documentAttributes: nil)
            }
        } catch {
            throw ConversionError("Can't read this \(ext.uppercased()) file")
        }
    }

    static func write(_ text: NSAttributedString, as format: Format, to dst: URL) throws {
        switch format.id {
        case "pdf":
            try Engine.onMain { try renderPDF(text, to: dst) }
        case "txt":
            try text.string.write(to: dst, atomically: true, encoding: .utf8)
        default:
            guard let type = writeTypes[format.id] else { throw ConversionError("Unsupported document format") }
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try Engine.onMain {
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            }
            try data.write(to: dst)
        }
    }

    /// Lays the text out on pages (system default paper size) and saves it as a PDF.
    static func renderPDF(_ text: NSAttributedString, to dst: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: dst])
        info.paperSize = NSPrintInfo.shared.paperSize
        info.jobDisposition = .save
        info.topMargin = 60; info.bottomMargin = 60
        info.leftMargin = 60; info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.setFrameSize(NSSize(width: width, height: max(lm.usedRect(for: tc).height, 20)))
        }

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ConversionError("Couldn't create PDF") }
    }
}

// MARK: - Audio & video

enum MediaEngine {
    /// Returns an optional note for the UI.
    static func convert(_ src: URL, to format: Format, dst: URL, progress: @escaping (Double) -> Void) throws -> String? {
        let asset = AVURLAsset(url: src)
        switch format.id {
        case "mp4":
            try export(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: dst, progress: progress)
        case "mp4-hevc":
            try export(asset, preset: AVAssetExportPresetHEVCHighestQuality, type: .mp4, to: dst, progress: progress)
        case "mov":
            try export(asset, preset: AVAssetExportPresetHighestQuality, type: .mov, to: dst, progress: progress)
        case "m4a":
            guard !asset.tracks(withMediaType: .audio).isEmpty else { throw ConversionError("This file has no sound") }
            try export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: dst, progress: progress)
        case "gif":
            return try makeGIF(asset, to: dst, progress: progress)
        case "wav", "aiff", "flac", "alac":
            try transcodeAudio(asset, to: format, dst: dst, progress: progress)
        default:
            throw ConversionError("Unsupported format")
        }
        return nil
    }

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, to dst: URL,
                       progress: @escaping (Double) -> Void) throws {
        guard asset.isReadable else { throw ConversionError("Can't read this file") }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError("This file can't be converted to that format")
        }
        try? FileManager.default.removeItem(at: dst)  // export refuses to overwrite the placeholder
        session.outputURL = dst
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            progress(Double(session.progress))
        }
        guard session.status == .completed else {
            throw ConversionError(session.error?.localizedDescription ?? "Export failed")
        }
    }

    static func transcodeAudio(_ asset: AVAsset, to format: Format, dst: URL,
                               progress: (Double) -> Void) throws {
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ConversionError("This file has no sound")
        }
        var sourceRate = 44_100.0
        var sourceChannels: UInt32 = 2
        if let desc = track.formatDescriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMAudioFormatDescription)?.pointee {
            if asbd.mSampleRate > 0 { sourceRate = asbd.mSampleRate }
            sourceChannels = asbd.mChannelsPerFrame
        }
        let channels: UInt32 = sourceChannels >= 2 ? 2 : 1
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sourceRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError(reader.error?.localizedDescription ?? "Can't read audio")
        }

        var settings: [String: Any] = [AVSampleRateKey: sourceRate, AVNumberOfChannelsKey: channels]
        switch format.id {
        case "wav", "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format.id == "aiff"
            settings[AVLinearPCMIsNonInterleaved] = false
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                      channels: channels, interleaved: false) else {
            throw ConversionError("Unsupported audio layout")
        }
        let file = try AVAudioFile(forWriting: dst, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let duration = CMTimeGetSeconds(asset.duration)

        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw ConversionError("Couldn't decode audio") }
            try file.write(from: buffer)
            if duration > 0 {
                progress(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration))
            }
        }
        file.close()
        if reader.status == .failed {
            throw ConversionError(reader.error?.localizedDescription ?? "Couldn't decode audio")
        }
    }

    static func makeGIF(_ asset: AVAsset, to dst: URL, progress: (Double) -> Void) throws -> String? {
        guard !asset.tracks(withMediaType: .video).isEmpty else { throw ConversionError("This file has no video") }
        let total = CMTimeGetSeconds(asset.duration)
        let maxSeconds = 60.0, fps = 12.0
        let count = max(1, Int(min(total, maxSeconds) * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 540, height: 540)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw ConversionError("Couldn't create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        var last: CGImage?
        for i in 0..<count {
            try autoreleasepool {
                let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
                if let frame = try? generator.copyCGImage(at: time, actualTime: nil) { last = frame }
                guard let frame = last else { throw ConversionError("Couldn't read video frames") }
                CGImageDestinationAddImage(dest, frame, frameProps)  // repeat previous frame if one fails
            }
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't write GIF") }
        return total > maxSeconds ? "First 60 seconds" : nil
    }
}

// MARK: - ffmpeg (optional: MP3 + MKV/WebM/AVI/OGG…)

enum FFmpeg {
    static var path: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func arguments(for format: Format) -> [String] {
        let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        switch format.id {
        case "mp4": return h264 + ["-movflags", "+faststart"]
        case "mov": return h264
        case "mp4-hevc":
            return ["-c:v", "libx265", "-crf", "26", "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "gif":
            return ["-t", "60", "-an", "-vf",
                    "fps=12,scale='min(540,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "alac": return ["-vn", "-c:a", "alac"]
        default: return []
        }
    }

    static func convert(_ src: URL, to format: Format, dst: URL, progress: @escaping (Double) -> Void) throws {
        guard let path else { throw ConversionError("ffmpeg isn't installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-i", src.path] + arguments(for: format)
            + ["-progress", "pipe:1", "-nostats", dst.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let lock = NSLock()
        var log = ""
        var duration = 0.0
        err.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            log += chunk
            if duration == 0, let r = log.range(of: "Duration: ") {
                let parts = log[r.upperBound...].prefix(11).split(separator: ":")
                if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
                    duration = h * 3600 + m * 60 + s
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                lock.lock(); let total = duration; lock.unlock()
                if total > 0, let us = Double(line.dropFirst("out_time_us=".count)) {
                    progress(min(1, max(0, us / 1_000_000 / total)))
                }
            }
        }
        try process.run()
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        out.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            lock.lock(); let text = log; lock.unlock()
            let lastLine = text.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
            throw ConversionError(lastLine)
        }
    }
}
