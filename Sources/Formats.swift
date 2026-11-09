import Foundation

enum MediaKind: String, CaseIterable, Identifiable {
    case image, pdf, document, video, audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: "Images"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .video: "Videos"
        case .audio: "Audio"
        }
    }
    var singular: String {
        switch self {
        case .image: "Image"
        case .pdf: "PDF"
        case .document: "Document"
        case .video: "Video"
        case .audio: "Audio"
        }
    }
    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

struct Format: Hashable, Identifiable {
    let id: String
    let name: String
    let ext: String
    let detail: String

    var needsFFmpeg: Bool { id == "mp3" }
}

extension Format {
    // Images
    static let jpeg = Format(id: "jpg", name: "JPEG", ext: "jpg", detail: "Small, opens everywhere")
    static let png = Format(id: "png", name: "PNG", ext: "png", detail: "Lossless, keeps transparency")
    static let heic = Format(id: "heic", name: "HEIC", ext: "heic", detail: "Apple's compact photo format")
    static let avif = Format(id: "avif", name: "AVIF", ext: "avif", detail: "Modern and very small")
    static let tiff = Format(id: "tiff", name: "TIFF", ext: "tiff", detail: "Lossless, for print")
    static let gif = Format(id: "gif", name: "GIF", ext: "gif", detail: "Animated, 256 colours")
    static let bmp = Format(id: "bmp", name: "BMP", ext: "bmp", detail: "Uncompressed bitmap")
    // Documents
    static let pdf = Format(id: "pdf", name: "PDF", ext: "pdf", detail: "Print-ready document")
    static let docx = Format(id: "docx", name: "Word", ext: "docx", detail: ".docx document")
    static let doc = Format(id: "doc", name: "Word 97", ext: "doc", detail: "Older .doc format")
    static let rtf = Format(id: "rtf", name: "RTF", ext: "rtf", detail: "Rich text, opens in TextEdit")
    static let odt = Format(id: "odt", name: "OpenDocument", ext: "odt", detail: "LibreOffice / Google Docs")
    static let html = Format(id: "html", name: "HTML", ext: "html", detail: "Web page")
    static let txt = Format(id: "txt", name: "Plain Text", ext: "txt", detail: "Just the words")
    // Video
    static let mp4 = Format(id: "mp4", name: "MP4", ext: "mp4", detail: "H.264, plays everywhere")
    static let hevc = Format(id: "mp4-hevc", name: "MP4 · HEVC", ext: "mp4", detail: "Same quality, smaller file")
    static let mov = Format(id: "mov", name: "MOV", ext: "mov", detail: "QuickTime movie")
    static let videoGIF = Format(id: "gif", name: "GIF", ext: "gif", detail: "Animated, up to 60 s")
    // Audio
    static let mp3 = Format(id: "mp3", name: "MP3", ext: "mp3", detail: "Universal audio")
    static let m4a = Format(id: "m4a", name: "M4A", ext: "m4a", detail: "AAC audio, small")
    static let wav = Format(id: "wav", name: "WAV", ext: "wav", detail: "Uncompressed audio")
    static let aiff = Format(id: "aiff", name: "AIFF", ext: "aiff", detail: "Uncompressed audio")
    static let flac = Format(id: "flac", name: "FLAC", ext: "flac", detail: "Lossless, compressed")
    static let alac = Format(id: "alac", name: "ALAC", ext: "m4a", detail: "Apple Lossless")

    static let lossyImage: Set<String> = ["jpg", "heic", "avif"]
}

enum Catalog {
    static let imageExts: Set<String> = ["heic", "heif", "hif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "bmp",
                                         "webp", "avif", "psd", "ico", "icns", "jp2", "tga", "exr",
                                         "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]
    static let documentExts: Set<String> = ["docx", "doc", "rtf", "odt", "txt", "text", "md", "markdown",
                                            "html", "htm", "webarchive"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "caf"]
    /// Readable only when ffmpeg is installed.
    static let ffmpegVideoExts: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "ogv"]
    static let ffmpegAudioExts: Set<String> = ["ogg", "opus", "wma"]

    static var allExts: Set<String> {
        imageExts.union(documentExts).union(videoExts).union(audioExts)
            .union(ffmpegVideoExts).union(ffmpegAudioExts).union(["pdf"])
    }

    static func needsFFmpegToRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ffmpegVideoExts.contains(ext) || ffmpegAudioExts.contains(ext)
    }

    static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExts.contains(ext) { return .image }
        if documentExts.contains(ext) { return .document }
        if videoExts.contains(ext) || ffmpegVideoExts.contains(ext) { return .video }
        if audioExts.contains(ext) || ffmpegAudioExts.contains(ext) { return .audio }
        return nil
    }

    static func outputs(for kind: MediaKind) -> [Format] {
        switch kind {
        case .image: [.jpeg, .png, .heic, .avif, .tiff, .gif, .bmp, .pdf]
        case .pdf: [.docx, .png, .jpeg, .txt, .rtf, .tiff, .heic]
        case .document: [.pdf, .docx, .rtf, .txt, .html, .odt, .doc]
        case .video: [.mp4, .mov, .hevc, .videoGIF, .mp3, .m4a, .wav]
        case .audio: [.mp3, .m4a, .wav, .aiff, .flac, .alac]
        }
    }

    /// Output choices for a file, minus "convert to the same thing".
    static func outputs(for url: URL, kind: MediaKind) -> [Format] {
        let same = normalized(url.pathExtension)
        return outputs(for: kind).filter { $0.id != same }
    }

    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "aif": "aiff"
        case "htm": "html"
        case "text", "md", "markdown": "txt"
        case "heif", "hif": "heic"
        case let e: e
        }
    }

    static func fallbackDefault(for kind: MediaKind) -> Format {
        switch kind {
        case .image: .jpeg
        case .pdf: .docx
        case .document: .pdf
        case .video: .mp4
        case .audio: .mp3
        }
    }
}
