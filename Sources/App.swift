import SwiftUI
import AppKit

// MARK: - Theme

let brandGradient = LinearGradient(
    colors: [Color(red: 1.00, green: 0.56, blue: 0.36),
             Color(red: 1.00, green: 0.28, blue: 0.50),
             Color(red: 0.50, green: 0.36, blue: 1.00)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
let brandAccent = Color(red: 1.00, green: 0.30, blue: 0.50)
let appSymbol = "arrow.triangle.2.circlepath"
let springy = Animation.spring(response: 0.42, dampingFraction: 0.86)

// MARK: - Root

struct ContentView: View {
    @ObservedObject var converter = Converter.shared
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            Header()
            DropZone(isTargeted: isTargeted, compact: !converter.items.isEmpty) {
                converter.presentOpenPanel()
            }
            SettingsCard(converter: converter)
            if !converter.items.isEmpty {
                FileList(converter: converter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Footer(converter: converter)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(minWidth: 580, idealWidth: 600, minHeight: 680, idealHeight: 760)
        .tint(brandAccent)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { converter.add(urls) }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            converter.refreshTools()
        }
        .animation(springy, value: converter.items.isEmpty)
    }
}

struct Header: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(brandGradient)
                Image(systemName: appSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: brandAccent.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Morph")
                    .font(.system(size: 17, weight: .semibold))
                Text("Convert images, PDFs, documents, video and audio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    let isTargeted: Bool
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(hovering ? 0.06 : 0.035))
            shape.fill(brandGradient).opacity(isTargeted ? 0.16 : 0)
            shape.strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
                .opacity(isTargeted ? 0 : 1)
            shape.strokeBorder(brandGradient, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
            if compact { compactContent } else { fullContent }
        }
        .frame(height: compact ? 92 : nil)
        .frame(maxHeight: compact ? 92 : .infinity)
        .scaleEffect(isTargeted ? 1.015 : 1)
        .shadow(color: brandAccent.opacity(isTargeted ? 0.28 : 0), radius: 26)
        .contentShape(shape)
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Drop files or folders, or click to browse")
    }

    private var icon: some View {
        Image(systemName: isTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square")
            .foregroundStyle(brandGradient)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: isTargeted)
    }

    private var fullContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(brandGradient).opacity(0.13).frame(width: 96, height: 96)
                icon.font(.system(size: 38, weight: .medium))
            }
            .padding(.bottom, 4)
            Text(isTargeted ? "Release to add" : "Drop anything here")
                .font(.system(size: 20, weight: .semibold))
            Text("or click to browse — folders work too")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(MediaKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(brandGradient).opacity(0.13).frame(width: 50, height: 50)
                icon.font(.system(size: 21, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isTargeted ? "Release to add" : "Drop more files")
                    .font(.system(size: 15, weight: .semibold))
                Text("or click to browse")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Format picking

struct FormatPicker: View {
    let title: String
    let options: [Format]
    let selected: Format?
    let isUsable: (Format) -> Bool
    let onPick: (Format) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(options) { format in
                FormatOptionRow(format: format, selected: format == selected, usable: isUsable(format)) {
                    onPick(format)
                }
            }
        }
        .padding(6)
        .frame(width: 280)
    }
}

struct FormatOptionRow: View {
    let format: Format
    let selected: Bool
    let usable: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(format.ext.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(usable ? AnyShapeStyle(brandGradient) : AnyShapeStyle(Color.gray.opacity(0.5))))
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.name).font(.system(size: 13, weight: .medium))
                    Text(usable ? format.detail : "Needs ffmpeg — brew install ffmpeg")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(brandAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering && usable ? 0.08 : 0)))
            .contentShape(Rectangle())
            .opacity(usable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .onHover { hovering = $0 }
    }
}

/// Capsule that opens a format popover.
struct FormatPill<Content: View>: View {
    let title: String
    let options: [Format]
    let selected: Format?
    let isUsable: (Format) -> Bool
    let onPick: (Format) -> Void
    var prominent = true
    @ViewBuilder var content: Content
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                content
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? brandAccent.opacity(hovering ? 0.22 : 0.14)
                                                 : Color.primary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FormatPicker(title: title, options: options, selected: selected, isUsable: isUsable) {
                onPick($0)
                showing = false
            }
        }
    }
}

// MARK: - Settings

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > maxWidth {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct SettingsCard: View {
    @ObservedObject var converter: Converter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                row("Convert") {
                    if converter.readyKinds.isEmpty {
                        Text("Drop files, then choose what to turn them into")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(converter.readyKinds) { kindChip($0) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                row("Quality") {
                    Slider(value: $converter.quality, in: 0.4...1.0)
                        .controlSize(.small)
                    Text("\(Int((converter.quality * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .opacity(converter.qualityMatters ? 1 : 0.4)
                .help("Compression for JPEG, HEIC and AVIF output")
                row("Save to") {
                    Menu {
                        Button("Same folder as original") { converter.destination = nil }
                        Button("Choose Folder…") { converter.chooseDestination() }
                        if let dest = converter.destination {
                            Divider()
                            Button("Show “\(dest.lastPathComponent)” in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([dest])
                            }
                        }
                    } label: {
                        Label(converter.destination?.lastPathComponent ?? "Same folder as original",
                              systemImage: converter.destination == nil ? "arrow.turn.down.right" : "folder")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                    Toggle("Keep metadata", isOn: $converter.keepMetadata)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help("Keep photo date, camera details and location")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .animation(springy, value: converter.readyKinds)
    }

    private func kindChip(_ kind: MediaKind) -> some View {
        let current = converter.chipFormat(for: kind)
        return FormatPill(title: "Convert all \(kind.title.lowercased()) to",
                          options: Catalog.outputs(for: kind), selected: current,
                          isUsable: converter.isUsable,
                          onPick: { converter.setDefault($0, for: kind) },
                          prominent: false) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
                Text(kind.title).foregroundStyle(.primary)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Text(current.name).fontWeight(.semibold).foregroundStyle(brandAccent)
            }
            .font(.system(size: 12))
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
        .frame(minHeight: 22)
    }
}

// MARK: - File list

struct FileList: View {
    @ObservedObject var converter: Converter

    var body: some View {
        Card {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(converter.items) { item in
                        FileRow(item: item, converter: converter)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(6)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct FileRow: View {
    @ObservedObject var item: ConversionItem
    let converter: Converter
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.source.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.055 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if let out = item.outputs.first { NSWorkspace.shared.open(out) } }
        .contextMenu {
            if let out = item.outputs.first {
                Button("Open") { NSWorkspace.shared.open(out) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) }
            }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
            if !item.status.isPending {
                Divider()
                Button("Remove from List") { converter.remove(item) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: item.status)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07))
            if let t = item.thumbnail {
                if item.thumbnailIsIcon {
                    Image(nsImage: t).resizable().scaledToFit().padding(3)
                } else {
                    Image(nsImage: t).resizable().scaledToFill()
                }
            } else {
                Image(systemName: item.kind.symbol).font(.system(size: 14)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: item.thumbnail != nil)
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    @ViewBuilder private var subtitle: some View {
        let style = Font.system(size: 11)
        switch item.status {
        case .ready:
            Text("\(item.kind.singular) · \(bytes(item.inputSize))").font(style).foregroundStyle(.secondary)
        case .queued:
            Text("Waiting…").font(style).foregroundStyle(.secondary)
        case .working:
            if let p = item.progress, p > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: p).progressViewStyle(.linear).controlSize(.mini).frame(width: 140)
                    Text("\(Int(p * 100))%").font(style.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text("Converting to \(item.target?.name ?? "")…").font(style).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(style).foregroundStyle(.orange).lineLimit(2)
        case .done:
            let name = item.outputs.first?.lastPathComponent ?? ""
            let parts = ["→ \(name)", "\(bytes(item.inputSize)) → \(bytes(item.outputSize ?? 0))", item.note]
            Text(parts.compactMap { $0 }.joined(separator: "  ·  "))
                .font(style).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .ready:
            if hovering {
                Button { converter.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
                .transition(.opacity)
            }
            FormatPill(title: "Convert “\(item.source.lastPathComponent)” to",
                       options: item.options, selected: item.target,
                       isUsable: converter.isUsable,
                       onPick: { converter.setTarget($0, for: item) }) {
                Text(item.target?.name ?? "Choose")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(brandAccent)
            }
        case .queued:
            Image(systemName: "clock").foregroundStyle(.tertiary).font(.system(size: 13)).frame(width: 20)
        case .working:
            ProgressView().controlSize(.small).frame(width: 20)
        case .done:
            if hovering {
                Button { NSWorkspace.shared.activateFileViewerSelecting(item.outputs) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .transition(.opacity)
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.white, .green)
                .frame(width: 20)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .frame(width: 20)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var converter: Converter

    var body: some View {
        let ready = converter.readyItems.count
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if converter.isWorking {
                    ProgressView(value: Double(converter.finishedCount), total: Double(max(converter.startedCount, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 170)
                }
            }
            Spacer()
            Button("Clear") { converter.clearFinished() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .disabled(converter.items.allSatisfy { $0.status.isPending })
                .help("Remove everything that isn't converting")
            if ready > 0 {
                Button { converter.convertAll() } label: {
                    Label("Convert \(ready) file\(ready == 1 ? "" : "s")", systemImage: appSymbol)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button { converter.revealOutputs() } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(converter.doneItems.isEmpty)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: converter.isWorking)
        .animation(.easeInOut(duration: 0.2), value: ready)
    }

    private var summary: String {
        let ready = converter.readyItems.count
        if converter.isWorking {
            return "Converting \(min(converter.finishedCount + 1, converter.startedCount)) of \(converter.startedCount)…"
        }
        var parts: [String] = []
        if ready > 0 { parts.append("\(ready) ready") }
        if !converter.doneItems.isEmpty { parts.append("\(converter.doneItems.count) converted") }
        if converter.failedCount > 0 { parts.append("\(converter.failedCount) failed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Converter.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MorphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Morph", id: "main") {
            ContentView()
                .containerBackground(.regularMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 600, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { Converter.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Convert") { Converter.shared.convertAll() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}
