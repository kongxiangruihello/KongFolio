import AppKit
import PDFKit
import Combine

struct TableSourceRegion: Codable, Equatable { var page: Int; var rect: CGRect }
struct TableGrid: Codable, Equatable {
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    var x: [Double] = [0, 1]
    var y: [Double] = [0, 1]
    static func validRect(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0.005 && rect.height > 0.005 && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1.000001 && rect.maxY <= 1.000001
    }
    func validate() throws {
        guard Self.validRect(region), x.count >= 2, y.count >= 2, x.count <= 100, y.count <= 100,
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite),
              zip(x, x.dropFirst()).allSatisfy({ $1 - $0 > 0.001 }), zip(y, y.dropFirst()).allSatisfy({ $1 - $0 > 0.001 }),
              abs(x[0] - region.minX) < 0.00001, abs(x.last! - region.maxX) < 0.00001,
              abs(y[0] - region.minY) < 0.00001, abs(y.last! - region.maxY) < 0.00001 else { throw FolioError(message: "表格范围或分隔线无效") }
    }
    mutating func move(vertical: Bool, index: Int, value: Double) throws {
        guard value.isFinite else { throw FolioError(message: "分隔位置无效") }
        var axis = vertical ? x : y
        guard index > 0, index < axis.count - 1 else { throw FolioError(message: "只能拖动内部行列分隔线") }
        axis[index] = min(axis[index + 1] - 0.002, max(axis[index - 1] + 0.002, value))
        if vertical { x = axis } else { y = axis }; try validate()
    }
}
struct TableDraftRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var identity: String
    var sourcePath: String?
    var sourceTitle: String
    var sourceDigest: String
    var page: Int
    var grid = TableGrid()
    var rows: [[String]] = []
    var sourceRegions: [TableSourceRegion] = []
    var needsRegeneration = false
    var includeInWord = false
    var modified = Date()
    var columns: Int { rows.first?.count ?? 0 }
    func validate() throws {
        try grid.validate()
        guard page >= 0, sourceDigest.count == 64, !identity.isEmpty, rows.count <= 2000,
              columns <= 100, rows.count * columns <= 2000,
              rows.allSatisfy({ $0.count == columns }), rows.isEmpty || columns > 0,
              rows.joined().reduce(0, { $0 + $1.utf8.count }) <= 4_000_000,
              sourceRegions.count <= 100, sourceRegions.allSatisfy({ $0.page >= 0 && TableGrid.validRect($0.rect) }) else { throw FolioError(message: "表格草稿无效或过大") }
    }
    var regions: [TableSourceRegion] { sourceRegions.isEmpty ? [TableSourceRegion(page: page, rect: grid.region)] : sourceRegions }
}
enum TableDraftStore {
    static func folder(_ storage: URL) -> URL { storage.appendingPathComponent("TableDrafts", isDirectory: true) }
    static func url(_ id: UUID, storage: URL) -> URL { folder(storage).appendingPathComponent(id.uuidString + ".json") }
    static func write(_ draft: TableDraftRecord, storage: URL) throws {
        try draft.validate(); try FileManager.default.createDirectory(at: folder(storage), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url(draft.id, storage: storage), options: .atomic)
    }
    static func read(_ url: URL) throws -> TableDraftRecord {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw FolioError(message: "草稿过大，已保留原稿") }
        let result = try JSONDecoder().decode(TableDraftRecord.self, from: Data(contentsOf: url)); try result.validate(); return result
    }
    static func list(storage: URL) throws -> [TableDraftRecord] {
        let directory = folder(storage)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map(read).sorted { $0.modified > $1.modified }
    }
}

enum TableCellEdit {
    case insertRow(Int), deleteRow(Int), insertColumn(Int), deleteColumn(Int)
    func applying(to rows: [[String]]) throws -> [[String]] {
        guard let first = rows.first, !first.isEmpty else { throw FolioError(message: "请先生成单元格") }
        var result = rows
        switch self {
        case .insertRow(let i): guard (0...rows.count).contains(i) else { throw FolioError(message: "行位置无效") }; result.insert(Array(repeating: "", count: first.count), at: i)
        case .deleteRow(let i): guard rows.count > 1, rows.indices.contains(i) else { throw FolioError(message: "至少保留一行") }; result.remove(at: i)
        case .insertColumn(let i): guard (0...first.count).contains(i) else { throw FolioError(message: "列位置无效") }; for r in result.indices { result[r].insert("", at: i) }
        case .deleteColumn(let i): guard first.count > 1, first.indices.contains(i) else { throw FolioError(message: "至少保留一列") }; for r in result.indices { result[r].remove(at: i) }
        }
        guard result.count * result[0].count <= 2000 else { throw FolioError(message: "最多支持 2000 个单元格") }; return result
    }
}

@MainActor final class TableEditorModel: ObservableObject {
    @Published private(set) var draft: TableDraftRecord?
    @Published private(set) var image: CGImage?
    @Published private(set) var working = false
    @Published private(set) var progress = 0.0
    @Published var message = ""
    @Published private(set) var undoStates: [TableDraftRecord] = []
    @Published private(set) var redoStates: [TableDraftRecord] = []
    private var pieces: [TablePiece] = []
    private var source = Data()
    private var diskBaseline: FileBaseline?
    private var worker: Task<Void, Never>?
    private var token = UUID()
    let storage: URL
    var changed: ((TableDraftRecord) -> Void)?
    init(storage: URL) { self.storage = storage }
    var stale = false
    func cancel() { token = UUID(); worker?.cancel(); working = false; message = "已取消；已有草稿保留" }
    func open(data: Data, page: Int, identity: String, sourcePath: String?, title: String, saved: TableDraftRecord?) {
        cancel(); source = data; working = true; progress = 0; message = "正在后台读取页面…"; let key = UUID(); token = key
        worker = Task {
            let job = Task.detached(priority: .userInitiated) { () throws -> (CGImage, [TablePiece], String, TableDraftRecord?, FileBaseline?) in
                try Task.checkCancellation()
                let document = try PDFDocument(data: data).unwrap("无法读取 PDF"), p = try document.page(at: page).unwrap("页面不存在")
                let pieces = TableExtraction.pieces(p); try Task.checkCancellation()
                var restored = saved, baseline: FileBaseline?
                if let saved {
                    let file = TableDraftStore.url(saved.id, storage: self.storage)
                    if FileManager.default.fileExists(atPath: file.path) {
                        let bytes = try Data(contentsOf: file)
                        restored = try JSONDecoder().decode(TableDraftRecord.self, from: bytes); try restored?.validate()
                        baseline = try FileBaseline.capture(file, data: bytes)
                    } else { baseline = try FileBaseline.capture(file) }
                }
                return (try DocumentServices.render(p, maxDimension: 1800), pieces, OCRPageCache.digest(data), restored, baseline)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation()
                guard key == token else { return }
                image = result.0; pieces = result.1
                if let saved = result.3 { draft = saved; stale = saved.sourceDigest != result.2 }
                else { draft = TableDraftRecord(identity: identity, sourcePath: sourcePath, sourceTitle: title, sourceDigest: result.2, page: page); stale = false }
                diskBaseline = result.4
                if diskBaseline == nil, let draft { diskBaseline = try FileBaseline.capture(TableDraftStore.url(draft.id, storage: storage)) }
                undoStates = []; redoStates = []; progress = 1
                message = stale ? "原文已变化，旧草稿保留供核对。可单独导出；重新提取前请另存旧稿。" : "已读取 \(pieces.count) 个字符。框选范围、拖动蓝色分隔线，生成后修改单元格；草稿自动保留。"
            } catch is CancellationError {} catch { if key == token { message = error.localizedDescription } }
            if key == token { working = false }
        }
    }
    func edit(_ transform: (inout TableDraftRecord) throws -> Void) {
        guard !working, var next = draft else { return }
        do {
            try transform(&next); try next.validate(); guard next != draft else { return }; next.modified = Date()
            try save(next)
            if let draft { undoStates.append(draft); if undoStates.count > 40 { undoStates.removeFirst() } }
            redoStates = []; draft = next; changed?(next)
        } catch { message = error.localizedDescription }
    }
    private func save(_ value: TableDraftRecord) throws {
        try FileManager.default.createDirectory(at: TableDraftStore.folder(storage), withIntermediateDirectories: true)
        let file = TableDraftStore.url(value.id, storage: storage), expected = try diskBaseline ?? FileBaseline.capture(file)
        do { diskBaseline = try expected.writing(file) { _ in try TableDraftStore.write(value, storage: storage) } }
        catch is FileConflict { throw FolioError(message: "草稿已在其他窗口修改，未覆盖。请关闭后重新打开，或到恢复中心核对。") }
    }
    func undo() { restoreHistory(undo: true) }
    func redo() { restoreHistory(undo: false) }
    private func restoreHistory(undo: Bool) {
        guard !working, let current = draft, let next = undo ? undoStates.last : redoStates.last else { return }
        do {
            try save(next)
            if undo { undoStates.removeLast(); redoStates.append(current) } else { redoStates.removeLast(); undoStates.append(current) }
            draft = next; changed?(next)
        } catch { message = error.localizedDescription }
    }
    func setCell(row: Int, column: Int, text: String) {
        edit { guard $0.rows.indices.contains(row), $0.rows[row].indices.contains(column) else { return }; $0.rows[row][column] = text }
    }
    func changeGrid(_ grid: TableGrid) { guard !stale else { return }; edit { $0.grid = grid; $0.needsRegeneration = !$0.rows.isEmpty; $0.includeInWord = false } }
    func suggest() {
        guard !stale, let image, let current = draft, !working else { return }
        run("正在后台识别行列…") { [pieces] in
            let result = try TableExtraction.suggest(pieces, image: image, region: current.grid.region)
            var grid = current.grid; grid.x = [grid.region.minX] + result.x + [grid.region.maxX]; grid.y = [grid.region.minY] + result.y + [grid.region.maxY]; return grid
        } apply: { [weak self] grid in self?.changeGrid(grid); self?.message = "已建议分隔线，可直接拖动调整后生成单元格" }
    }
    func recognize(languages: [String]) {
        guard !stale, let image, !working else { return }
        run("正在后台识别扫描文字…") { try TableExtraction.recognize(image, languages: languages) } apply: { [weak self] pieces in self?.pieces = pieces; self?.message = "已识别 \(pieces.count) 个字符，原 PDF 保留" }
    }
    private func run<T>(_ title: String, operation: @escaping @Sendable () throws -> T, apply: @escaping (T) -> Void) {
        working = true; message = title; progress = 0; let key = UUID(); token = key
        worker = Task {
            let job = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); let result = try operation(); try Task.checkCancellation(); return result }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation()
                guard key == token else { return }; working = false; progress = 1; apply(result)
            } catch is CancellationError {} catch { if key == token { message = error.localizedDescription } }
            if key == token { working = false }
        }
    }
    func generate() {
        guard !stale, let current = draft else { return }
        run("正在生成单元格…") { [pieces] in try TableExtraction.extract(pieces, x: current.grid.x, y: current.grid.y).rows } apply: { [weak self] rows in
            self?.edit { $0.rows = rows; $0.needsRegeneration = false; $0.sourceRegions = [TableSourceRegion(page: $0.page, rect: $0.grid.region)]; $0.includeInWord = false }
            self?.message = "单元格已生成并自动保存，可修改、插入或删除行列"
        }
    }
    func merge(pages: [Int], removeHeaders: Bool, languages: [String]) {
        guard !stale, let current = draft, !current.rows.isEmpty, !current.needsRegeneration else { message = "请先生成并核对当前页表格"; return }
        let data = source
        run("正在后台提取连续页面…") {
            try TableMerge.extract(data: data, current: current, pages: pages, removeHeaders: removeHeaders, languages: languages)
        } apply: { [weak self] result in self?.edit { $0.rows = result.rows; $0.sourceRegions = result.regions; $0.includeInWord = false }; self?.message = "已合并 \(result.regions.count) 页。请核对行列、表头及跨页断行，再加入 Word 正文。" }
    }
}
struct TableMergeResult { var rows: [[String]]; var regions: [TableSourceRegion] }
enum TableMerge {
    static func joined(_ fragments: [[[String]]], removeHeaders: Bool) throws -> [[String]] {
        guard let first = fragments.first, let header = first.first, !header.isEmpty else { throw FolioError(message: "表格为空") }
        var rows = first
        func key(_ row: [String]) -> [String] { row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) } }
        for fragment in fragments.dropFirst() {
            guard fragment.allSatisfy({ $0.count == header.count }) else { throw FolioError(message: "跨页表格列数不同，请先调整为相同列数") }
            rows += removeHeaders && fragment.first.map(key) == key(header) ? Array(fragment.dropFirst()) : fragment
        }
        guard rows.count * header.count <= 2000 else { throw FolioError(message: "合并后超过 2000 个单元格，请分段整理") }; return rows
    }
    static func extract(data: Data, current: TableDraftRecord, pages: [Int], removeHeaders: Bool, languages: [String], progress: (Double) -> Void = { _ in }) throws -> TableMergeResult {
        let sorted = pages.sorted()
        guard sorted.count >= 2, sorted.count <= 100, sorted.first == current.page, Set(sorted).count == sorted.count,
              zip(sorted, sorted.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { throw FolioError(message: "请选择从当前页开始的连续页面，最多 100 页") }
        let document = try PDFDocument(data: data).unwrap("无法读取文档")
        let existing = current.regions
        guard existing.map(\.page) == Array(sorted.prefix(existing.count)) else { throw FolioError(message: "所选范围须包含已经合并的全部来源页；缩小范围请先重新生成当前页表格") }
        var fragments = [current.rows], regions = existing
        let remaining = Array(sorted.dropFirst(existing.count))
        for (offset, index) in remaining.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let page = try document.page(at: index).unwrap("合并页码超出文档范围")
                let image = try DocumentServices.render(page, maxDimension: 1800)
                var pieces = TableExtraction.pieces(page)
                if pieces.isEmpty { pieces = try TableExtraction.recognize(image, languages: languages) }
                let guides = try TableExtraction.suggest(pieces, image: image, region: current.grid.region)
                let ys = [current.grid.region.minY] + guides.y + [current.grid.region.maxY]
                var extracted = try TableExtraction.extract(pieces, x: current.grid.x, y: ys).rows
                while extracted.first?.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true { extracted.removeFirst() }
                while extracted.last?.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true { extracted.removeLast() }
                guard !extracted.isEmpty else { throw FolioError(message: "第 \(index + 1) 页框选范围没有可提取内容，请调整范围或单独识别") }
                fragments.append(extracted)
                regions.append(TableSourceRegion(page: index, rect: current.grid.region))
            }
            progress(Double(offset + 1) / Double(max(1, remaining.count)))
        }
        return TableMergeResult(rows: try joined(fragments, removeHeaders: removeHeaders), regions: regions)
    }
}

extension Workspace {
    var tableIdentity: String { (projectURL ?? sourceURL)?.standardizedFileURL.path ?? "unsaved-\(id.uuidString)" }
    func loadTableDrafts() {
        do { tableDrafts = try TableDraftStore.list(storage: storage).filter { $0.identity == tableIdentity } }
        catch { status = "部分表格草稿无法读取，原稿保留：\(error.localizedDescription)" }
    }
    func updateTableDraft(_ draft: TableDraftRecord) { tableDrafts.removeAll { $0.id == draft.id }; tableDrafts.append(draft); scheduleRecovery() }
    func persistTableDrafts() throws {
        for i in tableDrafts.indices {
            var value = tableDrafts[i]
            let oldURL = TableDraftStore.url(value.id, storage: storage)
            var expected: FileBaseline?
            if FileManager.default.fileExists(atPath: oldURL.path) {
                let bytes = try Data(contentsOf: oldURL), stored = try JSONDecoder().decode(TableDraftRecord.self, from: bytes)
                expected = try FileBaseline.capture(oldURL, data: bytes)
                if stored.identity == tableIdentity, stored.modified > value.modified { tableDrafts[i] = stored; continue }
                if stored.identity != tableIdentity { value.id = UUID(); expected = nil }
            }
            value.identity = tableIdentity; value.sourcePath = (projectURL ?? sourceURL)?.path; value.sourceTitle = displayName
            try FileManager.default.createDirectory(at: TableDraftStore.folder(storage), withIntermediateDirectories: true)
            let destination = TableDraftStore.url(value.id, storage: storage), baseline = try expected ?? FileBaseline.capture(destination)
            try baseline.writing(destination) { _ in try TableDraftStore.write(value, storage: storage) }
            tableDrafts[i] = value
        }
    }
}

extension Workspace {
    func startTableMerge(_ draft: TableDraftRecord, pages: [Int], removeHeaders: Bool, queue: DocumentTaskQueue) throws {
        let data = try pdfData(), languages = ocrSettings.languages
        guard OCRPageCache.digest(data) == draft.sourceDigest, !draft.needsRegeneration else { throw FolioError(message: "原文或分隔线已变化，请先重新核对表格") }
        let destination = TableDraftStore.url(draft.id, storage: storage)
        let expected: FileBaseline
        if FileManager.default.fileExists(atPath: destination.path) {
            let bytes = try Data(contentsOf: destination), stored = try JSONDecoder().decode(TableDraftRecord.self, from: bytes)
            guard stored == draft else { throw FolioError(message: "草稿已在其他窗口修改，请重新打开后合并") }
            expected = try FileBaseline.capture(destination, data: bytes)
        } else {
            try FileManager.default.createDirectory(at: TableDraftStore.folder(storage), withIntermediateDirectories: true)
            let absent = try FileBaseline.capture(destination)
            expected = try absent.writing(destination) { _ in try TableDraftStore.write(draft, storage: storage) }
        }
        try queue.start("跨页表格合并 · \(displayName)", completion: { [weak self] _ in
            if let self, let updated = try? TableDraftStore.read(destination) { self.updateTableDraft(updated) }
        }) { progress in
            let result = try TableMerge.extract(data: data, current: draft, pages: pages, removeHeaders: removeHeaders, languages: languages, progress: progress)
            var updated = draft; updated.rows = result.rows; updated.sourceRegions = result.regions; updated.includeInWord = false; updated.modified = Date(); try updated.validate()
            try DocumentTaskOutput.write(to: destination, expected: expected) { try JSONEncoder().encode(updated).write(to: $0) }
            return DocumentTaskResult(message: "已合并 \(result.regions.count) 页，请打开草稿核对后加入 Word", file: destination)
        }
    }
}
