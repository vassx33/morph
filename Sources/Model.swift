import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ItemStatus: Equatable {
    case ready, queued, working, done, failed(String)
    var isPending: Bool { self == .queued || self == .working }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

final class ConversionItem: ObservableObject, Identifiable {
    let id = UUID()
    let source: URL
    let kind: MediaKind
    let inputSize: Int64
    let options: [Format]
    @Published var target: Format?
    @Published var status: ItemStatus = .ready
    @Published var progress: Double?
    @Published var outputs: [URL] = []
    @Published var outputSize: Int64?
    @Published var note: String?
    @Published var thumbnail: NSImage?
    @Published var thumbnailIsIcon = true

    init(source: URL, kind: MediaKind) {
        self.source = source
        self.kind = kind
        self.options = Catalog.outputs(for: source, kind: kind)
        self.inputSize = Self.size(of: source)
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

final class Converter: ObservableObject {
    static let shared = Converter()

    @Published var items: [ConversionItem] = []
    @Published var quality: Double { didSet { UserDefaults.standard.set(quality, forKey: "quality") } }
    @Published var keepMetadata: Bool { didSet { UserDefaults.standard.set(keepMetadata, forKey: "keepMetadata") } }
    @Published var destination: URL? { didSet { UserDefaults.standard.set(destination?.path, forKey: "destination") } }
    @Published private var kindDefaults: [String: String] {
        didSet { UserDefaults.standard.set(kindDefaults, forKey: "kindDefaults") }
    }
    @Published private(set) var hasFFmpeg = FFmpeg.path != nil

    private let fastQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .userInitiated
        return q
    }()
    private let mediaQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    init() {
        let d = UserDefaults.standard
        quality = d.object(forKey: "quality") as? Double ?? 0.9
        keepMetadata = d.object(forKey: "keepMetadata") as? Bool ?? true
        kindDefaults = d.dictionary(forKey: "kindDefaults") as? [String: String] ?? [:]
        if let path = d.string(forKey: "destination"), FileManager.default.fileExists(atPath: path) {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = nil
        }
    }

    // MARK: Derived state

    var readyItems: [ConversionItem] { items.filter { $0.status == .ready } }
    var readyKinds: [MediaKind] {
        let present = Set(readyItems.map(\.kind))
        return MediaKind.allCases.filter(present.contains)
    }
    var isWorking: Bool { items.contains { $0.status.isPending } }
    var doneItems: [ConversionItem] { items.filter { $0.status == .done } }
    var failedCount: Int { items.filter { $0.status.isFailed }.count }
    var startedCount: Int { items.filter { $0.status != .ready }.count }
    var finishedCount: Int { items.filter { $0.status == .done || $0.status.isFailed }.count }
    var qualityMatters: Bool { readyItems.contains { Format.lossyImage.contains($0.target?.id ?? "") } }

    func refreshTools() {
        let found = FFmpeg.path != nil
        if found != hasFFmpeg { hasFFmpeg = found }
    }

    func isUsable(_ format: Format) -> Bool { !format.needsFFmpeg || hasFFmpeg }

    func defaultFormat(for kind: MediaKind) -> Format {
        let all = Catalog.outputs(for: kind)
        let saved = all.first { $0.id == kindDefaults[kind.rawValue] }
        let preferred = saved ?? Catalog.fallbackDefault(for: kind)
        return isUsable(preferred) ? preferred : (all.first(where: isUsable) ?? preferred)
    }

    /// The format shown on a kind's chip: what most of its ready files are set to.
    func chipFormat(for kind: MediaKind) -> Format {
        let targets = readyItems.filter { $0.kind == kind }.compactMap(\.target)
        let counts = Dictionary(grouping: targets, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? defaultFormat(for: kind)
    }

    func setDefault(_ format: Format, for kind: MediaKind) {
        kindDefaults[kind.rawValue] = format.id
        for item in items where item.kind == kind && item.status == .ready && item.options.contains(format) {
            item.target = format
        }
        objectWillChange.send()
    }

    func setTarget(_ format: Format, for item: ConversionItem) {
        item.target = format
        objectWillChange.send()
    }

    private func initialTarget(for item: ConversionItem) -> Format? {
        let preferred = defaultFormat(for: item.kind)
        if item.options.contains(preferred) { return preferred }
        return item.options.first(where: isUsable)
    }

    // MARK: Actions

    func add(_ urls: [URL]) {
        refreshTools()
        let files = expand(urls)
        guard !files.isEmpty else { NSSound.beep(); return }
        let new = files.compactMap { url -> ConversionItem? in
            guard let kind = Catalog.kind(of: url) else { return nil }
            let item = ConversionItem(source: url, kind: kind)
            if Catalog.needsFFmpegToRead(url) && !hasFFmpeg {
                item.status = .failed("\(url.pathExtension.uppercased()) files need ffmpeg — run: brew install ffmpeg")
            } else {
                item.target = initialTarget(for: item)
            }
            return item
        }
        withAnimation(springy) { items.insert(contentsOf: new, at: 0) }
        for item in new { loadThumbnail(item) }
    }

    func convertAll() {
        let quality = quality, keepMetadata = keepMetadata, destination = destination
        for item in items where item.status == .ready {
            guard let format = item.target else { continue }
            item.status = .queued
            item.progress = nil
            let job = Job(source: item.source, kind: item.kind, format: format, quality: quality,
                          keepMetadata: keepMetadata, destination: destination)
            let queue = (item.kind == .video || item.kind == .audio) ? mediaQueue : fastQueue
            queue.addOperation { [weak self] in
                DispatchQueue.main.async { item.status = .working; self?.objectWillChange.send() }
                var lastSent = Date.distantPast
                do {
                    let result = try Engine.run(job) { p in
                        guard Date().timeIntervalSince(lastSent) > 0.1 || p >= 1 else { return }
                        lastSent = Date()
                        DispatchQueue.main.async { item.progress = p }
                    }
                    let size = result.outputs.reduce(Int64(0)) { $0 + ConversionItem.size(of: $1) }
                    DispatchQueue.main.async {
                        item.outputs = result.outputs
                        item.outputSize = size
                        item.note = result.note
                        item.status = .done
                        self?.itemFinished()
                    }
                } catch {
                    DispatchQueue.main.async {
                        item.status = .failed(error.localizedDescription)
                        self?.itemFinished()
                    }
                }
            }
        }
        objectWillChange.send()
    }

    private func itemFinished() {
        objectWillChange.send()
        if !isWorking && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func remove(_ item: ConversionItem) {
        withAnimation(springy) { items.removeAll { $0.id == item.id } }
    }

    func clearFinished() {
        withAnimation(springy) { items.removeAll { !$0.status.isPending } }
    }

    func revealOutputs() {
        let outputs = doneItems.flatMap(\.outputs)
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func loadThumbnail(_ item: ConversionItem) {
        let request = QLThumbnailGenerator.Request(fileAt: item.source, size: CGSize(width: 48, height: 48),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                item.thumbnail = rep.nsImage
                item.thumbnailIsIcon = rep.type == .icon
            }
        }
    }

    private func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if Catalog.kind(of: f) != nil { result.append(f) }
                }
            } else if Catalog.kind(of: url) != nil {
                result.append(url)
            }
        }
        return result.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Catalog.allExts.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose files or folders to convert"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Converted files will be saved in this folder"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
