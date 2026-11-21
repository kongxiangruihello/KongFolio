import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private enum PDFCreationSource: String, CaseIterable, Identifiable {
    case blank = "空白文档", files = "文件合并", clipboard = "剪贴板", web = "网页", scanner = "扫描仪", templates = "模板"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .blank: return "doc"
        case .files: return "doc.on.doc"
        case .clipboard: return "clipboard"
        case .web: return "globe"
        case .scanner: return "scanner"
        case .templates: return "square.grid.2x2"
        }
    }
}

private struct PDFCreationInput: Identifiable {
    let id = UUID()
    var url: URL
}

struct PDFCreationView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: PDFCreationSource
    @State private var options: PDFCreationOptions
    @State private var size: PDFPaperSize
    @State private var unit = PDFCreationUnit.mm
    @State private var title = ""
    @State private var inputs: [PDFCreationInput] = []
    @State private var dragging: UUID?
    @State private var preview: NSImage?
    @State private var clipboard: PDFCreationClipboard?
    @State private var clipboardChange = -1
    @State private var webURL = ""
    @State private var webPaged = true
    @State private var advanced = false
    @State private var presets: [PDFCreationPreset]
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var message = ""
    @State private var busy = false
    @State private var creationTask: Task<Void, Never>?
    @State private var worker: Task<Data, Error>?
    @State private var dropTargeted = false
    @StateObject private var scanner = PDFCreationScanner()
    private let clipboardTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(store: WorkspaceStore) {
        self.store = store
        let options = PDFCreationOptions.load(store.readingDefaults)
        _options = State(initialValue: options)
        _size = State(initialValue: PDFPaperSize.allCases.first { paper in
            guard let points = paper.points else { return false }
            return abs(min(points.width,points.height)-min(options.width,options.height)) < 0.1 && abs(max(points.width,points.height)-max(options.width,options.height)) < 0.1
        } ?? .custom)
        _source = State(initialValue: store.pdfCreationFromClipboard ? .clipboard : .blank)
        _presets = State(initialValue: store.readingDefaults.data(forKey: PDFCreationOptions.presetsKey).flatMap { try? JSONDecoder().decode([PDFCreationPreset].self, from: $0) }?.filter { $0.options.valid } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("新建 PDF", appIcon: "doc.badge.plus").font(.title2.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small); Text("正在创建…").foregroundStyle(.secondary) }
            }.padding(22)
            HStack(spacing: 6) {
                ForEach(PDFCreationSource.allCases) { item in
                    Button { source = item } label: {
                        Label(item.rawValue, appIcon: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 36)
                            .foregroundStyle(source == item ? Color.white : Color.primary)
                            .background(source == item ? Brand.accent : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    .disabled(busy)
                    .overlay(alignment: .topTrailing) {
                        if item == .clipboard, clipboard != nil, source != .clipboard {
                            Circle().fill(Brand.accent).frame(width: 6, height: 6).padding(4)
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 22).padding(.bottom, 18)
            Divider()
            HStack(spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TextField("文档名称（可留空）", text: $title).font(.title3).textFieldStyle(.roundedBorder)
                        sourceSettings
                    }.padding(.vertical, 20)
                }.frame(width: 295)
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.vertical, 20)
            }
            .padding(.horizontal, 22)
            .disabled(busy)
            Divider()
            HStack {
                Text(message.isEmpty && !options.valid && [.blank, .templates, .web].contains(source) ? "请检查尺寸、页数与边距，边距之和需小于纸张尺寸。" : message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 12)
                Button(busy ? "取消创建" : "取消") {
                    if busy { cancelCreation() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("创建 PDF", action: create)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || busy)
            }.padding(18)
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 630, idealHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(busy)
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy else { return false }
            return addFiles(urls, switchSource: true)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .allowsHitTesting(false).padding(4)
            }
        }
        .task(id: previewOptions) { await updatePreview() }
        .onAppear { refreshClipboard(); store.pdfCreationFromClipboard = false; if source == .scanner { scanner.start() } }
        .onReceive(clipboardTimer) { _ in if !busy { refreshClipboard() } }
        .onChange(of: source) { old, value in
            message = ""
            if old == .scanner { scanner.stop() }
            if value == .scanner { scanner.start() }
        }
        .onDisappear { cancelCreation(); scanner.cleanUp() }
    }

    private var canCreate: Bool {
        switch source {
        case .blank, .templates: return options.valid
        case .files, .scanner: return !inputs.isEmpty
        case .clipboard: return clipboard != nil
        case .web: return options.valid && URL(string: webURL.trimmingCharacters(in: .whitespacesAndNewlines)).map { ["http","https"].contains($0.scheme ?? "") && $0.host != nil } == true
        }
    }

    @ViewBuilder private var sourceSettings: some View {
        switch source {
        case .blank, .templates:
            if source == .templates {
                Text("笔记模板").font(.headline)
                Picker("模板", selection: $options.pattern) {
                    ForEach(PDFPaperPattern.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }
            paperSettings
            HStack {
                Text("初始页数")
                Spacer()
                TextField("页数", value: $options.pageCount, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                Stepper("页数", value: $options.pageCount, in: 1...200).labelsHidden()
            }
            if source == .blank {
                Picker("底纹", selection: $options.pattern) { ForEach(PDFPaperPattern.allCases) { Text($0.rawValue).tag($0) } }
            }
            ColorPicker("纸张底色", selection: Binding(get: { Color(nsColor: options.color.nsColor) }, set: { options.color = PDFCreationColor(NSColor($0)) }), supportsOpacity: false)
            HStack(spacing: 10) {
                colorButton("白色", .init())
                colorButton("米黄", .init(red: 0.99, green: 0.96, blue: 0.86))
                colorButton("浅灰", .init(red: 0.94, green: 0.95, blue: 0.96))
                colorButton("深色", .init(red: 0.15, green: 0.17, blue: 0.2))
            }
            advancedSettings
            presetSettings
        case .files:
            Text("按列表顺序合并为一个 PDF").font(.headline)
            Text("支持 PDF、图片、Markdown、HTML 和 TXT，可多选或直接拖入。多页 TIFF 会保留全部页面。").font(.callout).foregroundStyle(.secondary)
            Button("添加文件…", action: chooseFiles)
            if !inputs.isEmpty { Button("清空列表") { inputs = [] } }
            Text("拖动右侧文件调整顺序，也可使用上下箭头。").font(.caption).foregroundStyle(.secondary)
        case .clipboard:
            Text(clipboard?.summary ?? "剪贴板中暂无可创建的内容").font(.headline)
            Text("支持复制的图片、PDF、富文本、HTML 和纯文本。").font(.callout).foregroundStyle(.secondary)
            Button("刷新剪贴板") { clipboardChange = -1; refreshClipboard() }
        case .web:
            Text("网页地址").font(.headline)
            TextField("https://", text: $webURL).textFieldStyle(.roundedBorder)
            Picker("页面形式", selection: $webPaged) {
                Text("纸张分页").tag(true); Text("单页长文档").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            if webPaged { paperSettings; advancedSettings }
            Text("将当前可公开载入的网页保存为 PDF，保留文字与页面排版。").font(.caption).foregroundStyle(.secondary)
        case .scanner:
            Text("扫描仪").font(.headline)
            if !scanner.devices.isEmpty {
                Picker("设备", selection: $scanner.selectedID) {
                    ForEach(scanner.devices, id: \.uuidString) { device in Text(device.name ?? "扫描仪").tag(device.uuidString) }
                }.labelsHidden()
            }
            Text(scanner.message).font(.callout).foregroundStyle(.secondary)
            Text("已扫描 \(inputs.count) 份").font(.headline)
            if !inputs.isEmpty { Button("整理扫描顺序") { source = .files } }
            Button("导入已有扫描文件…", action: chooseFiles)
        }
    }

    private var paperSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("纸张", selection: Binding(get: { size }, set: selectSize)) {
                ForEach(PDFPaperSize.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("方向", selection: Binding(get: { options.width > options.height }, set: { landscape in
                if landscape != (options.width > options.height) { rotatePaper() }
            })) {
                Label("纵向", appIcon: "rectangle.portrait").tag(false)
                Label("横向", appIcon: "rectangle").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                dimensionField("宽", value: $options.width, custom: true)
                Text("×").foregroundStyle(.secondary)
                dimensionField("高", value: $options.height, custom: true)
                Picker("单位", selection: $unit) { ForEach(PDFCreationUnit.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 64)
            }
        }
    }

    private var advancedSettings: some View {
        DisclosureGroup("高级选项", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 12) {
                Text("页边距 · \(unit.rawValue)").font(.caption).foregroundStyle(.secondary)
                HStack { dimensionField("上", value: $options.top); dimensionField("下", value: $options.bottom) }
                HStack { dimensionField("左", value: $options.left); dimensionField("右", value: $options.right) }
                if source != .web { dimensionField("底纹间距", value: $options.spacing) }
                Text("边距限定底纹和网页正文的排版范围。").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }
    }

    private var presetSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !presets.isEmpty {
                Menu("我的预设") {
                    ForEach(presets) { preset in Button(preset.name) { options = preset.options; size = .custom } }
                    Divider()
                    Menu("删除预设") { ForEach(presets) { preset in Button(preset.name) { presets.removeAll { $0.id == preset.id }; savePresets() } } }
                }
            }
            if namingPreset {
                TextField("预设名称", text: $presetName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存预设") {
                        presets.append(PDFCreationPreset(name: presetName.trimmingCharacters(in: .whitespacesAndNewlines), options: options))
                        savePresets(); namingPreset = false; presetName = ""
                    }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !options.valid)
                    Button("取消") { namingPreset = false }
                }
            } else { Button("存为我的预设…") { namingPreset = true } }
        }
    }

    @ViewBuilder private var previewArea: some View {
        switch source {
        case .blank, .templates, .web:
            VStack(spacing: 14) {
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(28).shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                } else { AppIcon("doc").font(.system(size: 64)).foregroundStyle(.secondary) }
                Text("\(options.width * 25.4 / 72, specifier: "%.1f") × \(options.height * 25.4 / 72, specifier: "%.1f") mm\(source == .web ? "" : " · \(options.pageCount) 页")")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 20)
                if source == .web { Text("纸张预览，网页将在创建时载入").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12) }
            }
        case .files:
            if inputs.isEmpty {
                AppEmptyState("拖入文件开始创建", appIcon: "doc.on.doc", description: Text("支持将多份文档或图片合并为一个 PDF"))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(inputs.enumerated()), id: \.element.id) { index, input in
                            HStack(spacing: 10) {
                                AppIcon("line.3.horizontal").foregroundStyle(.secondary)
                                Text("\(index+1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                                Text(input.url.lastPathComponent).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(input.url.path)
                                Button { inputs.swapAt(index, index-1) } label: { AppIcon("chevron.up") }.disabled(index == 0).help("上移")
                                Button { inputs.swapAt(index, index+1) } label: { AppIcon("chevron.down") }.disabled(index == inputs.count-1).help("下移")
                                Button { inputs.removeAll { $0.id == input.id } } label: { AppIcon("xmark") }.help("移除")
                            }
                            .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onDrag { dragging = input.id; return NSItemProvider(object: input.id.uuidString as NSString) }
                            .onDrop(of: [.utf8PlainText], delegate: PDFCreationOrderDrop(target: input.id, inputs: $inputs, dragging: $dragging))
                        }
                    }.padding(16)
                }
            }
        case .clipboard:
            if let clipboard {
                VStack(spacing: 18) {
                    switch clipboard.content {
                    case .image(let data):
                        if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().padding(20) }
                    case .text(let text): Text(String(text.prefix(1200))).font(.system(size: 18)).frame(maxWidth: .infinity, alignment: .topLeading).padding(28)
                    default: AppIcon("doc.on.clipboard").font(.system(size: 64)).foregroundStyle(Brand.accent)
                    }
                    Text(clipboard.summary).foregroundStyle(.secondary).padding(.bottom, 24)
                }
            } else { AppEmptyState("先复制内容", appIcon: "clipboard", description: Text("复制截图、文本或 PDF 后，可在这里创建文档")) }
        case .scanner:
            if let device = scanner.selected {
                PDFScannerView(device: device, directory: scanner.directory, onFile: { url in _ = addFiles([url], switchSource: false) }, onError: { message = $0 })
            } else { AppEmptyState("连接扫描仪", appIcon: "scanner", description: Text("支持 macOS 图像捕捉可识别的扫描设备")) }
        }
    }

    private func dimensionField(_ name: String, value: Binding<Double>, custom: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(name).font(.callout)
            TextField(name, value: Binding(get: { value.wrappedValue / unit.points }, set: { value.wrappedValue = $0 * unit.points; if custom { size = .custom } }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(minWidth: 40)
        }
    }
    private func colorButton(_ name: String, _ color: PDFCreationColor) -> some View {
        Button { options.color = color } label: {
            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 23, height: 23)
                .overlay(Circle().stroke(options.color == color ? Brand.accent : .gray.opacity(0.35), lineWidth: options.color == color ? 2 : 1))
        }.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }
    private func rotatePaper() {
        let width = options.width
        options.width = options.height
        options.height = width
    }
    private func selectSize(_ value: PDFPaperSize) {
        size = value
        guard let points = value.points else { return }
        let landscape = options.width > options.height
        options.width = points.width; options.height = points.height
        if value != .wide, value != .standard, landscape { rotatePaper() }
    }
    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) { store.readingDefaults.set(data, forKey: PDFCreationOptions.presetsKey) }
    }
    private func refreshClipboard() {
        guard clipboardChange != NSPasteboard.general.changeCount else { return }
        clipboardChange = NSPasteboard.general.changeCount; clipboard = PDFCreationClipboard.read()
    }
    private func chooseFiles() {
        guard !DocumentOpenPanel.coordinator.revealExisting() else { return }
        let panel = DocumentOpenPanel.files()
        panel.allowedContentTypes = [.pdf, .image, .plainText, .html] + TextImport.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择用于新建 PDF 的文件，可多选并在导入后调整顺序。"
        DocumentOpenPanel.coordinator.present(panel, presentation: .separate) { response, urls in
            if response == .OK { _ = addFiles(urls, switchSource: true) }
        }
    }
    @discardableResult private func addFiles(_ urls: [URL], switchSource: Bool) -> Bool {
        let supported = urls.filter { $0.isFileURL && ($0.pathExtension.lowercased() == "pdf" || ImageImport.handles($0) || TextImport.handles($0)) }
        guard !supported.isEmpty else { message = "请选择 PDF、图片、Markdown、HTML 或 TXT 文件"; return false }
        inputs += supported.map { PDFCreationInput(url: $0) }
        if switchSource { source = .files }
        message = supported.count == urls.count ? "" : "已添加支持的文件，其余文件请先转为 PDF。"
        return true
    }
    private var previewOptions: PDFCreationOptions {
        var value = options
        value.pageCount = 1
        if source == .web { value.pattern = .blank; value.color = PDFCreationColor() }
        return value
    }
    private func updatePreview() async {
        let value = previewOptions
        guard value.valid else { preview = nil; return }
        do {
            try await Task.sleep(nanoseconds: 100_000_000)
            let task = Task.detached(priority: .utility) { () throws -> NSImage? in
                let data = try PDFCreationService.blank(value)
                let document = PDFDocument(data: data)
                return withExtendedLifetime(document) {
                    document?.page(at: 0)?.thumbnail(of: CGSize(width: 600, height: 720), for: .mediaBox)
                }
            }
            let image = try await task.value
            if !Task.isCancelled { preview = image }
        } catch { if !Task.isCancelled { preview = nil } }
    }
    private func create() {
        guard canCreate, !busy else { return }
        refreshClipboard()
        let source = source, options = options, urls = inputs.map(\.url), clipboard = clipboard, name = title, url = URL(string: webURL.trimmingCharacters(in: .whitespacesAndNewlines)), paged = webPaged
        busy = true; message = source == .files || source == .scanner ? "正在准备和转换文件，可取消。" : ""
        let job: Task<Data, Error>
        if source == .web, let url {
            job = Task { @MainActor in try await PDFWebCreator().create(url: url, options: options, paged: paged) }
        } else {
            job = Task.detached(priority: .userInitiated) {
                switch source {
                case .blank, .templates: return try PDFCreationService.blank(options)
                case .files, .scanner: return try await PDFCreationService.combine(urls)
                case .clipboard:
                    guard let clipboard else { throw FolioError(message: "剪贴板内容已改变，请重新复制后重试") }
                    return try clipboard.pdf()
                case .web: throw FolioError(message: "请输入网页地址")
                }
            }
        }
        worker = job
        creationTask = Task { @MainActor in
            defer { busy = false; worker = nil; creationTask = nil }
            do {
                let data = try await job.value
                try Task.checkCancellation()
                try store.adoptCreatedPDF(data, title: name, emptyPaper: source == .blank || source == .templates)
                if source == .blank || source == .templates { options.save(store.readingDefaults) }
                dismiss()
            } catch { message = FolioCancellation.matches(error) ? "已取消创建" : error.localizedDescription }
        }
    }
    private func cancelCreation() { worker?.cancel(); creationTask?.cancel() }
}

private struct PDFCreationOrderDrop: DropDelegate {
    let target: UUID
    @Binding var inputs: [PDFCreationInput]
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, let from = inputs.firstIndex(where: { $0.id == dragging }), let to = inputs.firstIndex(where: { $0.id == target }) else { return }
        let item = inputs.remove(at: from); inputs.insert(item, at: to)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
