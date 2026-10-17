import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where an excerpt came from, so the card can take the reader back to the exact place.
struct SourceRef: Codable, Equatable {
    var path: String
    var fileName: String
    var page: Int
    var pageLabel: String? = nil
    /// The selected lines (or the captured region) in page coordinates.
    var rects: [CGRect] = []

    var pageDescription: String {
        "第 \(page + 1) 页" + (pageLabel.map { $0 == String(page + 1) ? "" : "（印刷页码 \($0)）" } ?? "")
    }
    var position: ViewPosition {
        let top = rects.map(\.maxY).max()
        let left = rects.map(\.minX).min()
        // A little above the excerpt, so some context is visible.
        return ViewPosition(selection: page, x: left.map { Double($0) }, y: top.map { Double($0 + 36) }, scale: nil)
    }
}

enum CardKind: String, Codable { case text, image, note }

enum CardColor: String, Codable, CaseIterable, Identifiable {
    case yellow, blue, green, pink, gray
    var id: String { rawValue }
    var title: String {
        switch self { case .yellow: return "黄"; case .blue: return "蓝"; case .green: return "绿"; case .pink: return "粉"; case .gray: return "灰" }
    }
    var nsColor: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .pink: return .systemPink
        case .gray: return .systemGray
        }
    }
}

/// One card in the workspace: a text excerpt, a captured region of a page, or a free note.
struct BoardCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: CardKind
    /// The quoted text (excerpt) or the note itself.
    var text = ""
    /// The reader's own comment on an excerpt.
    var comment = ""
    var imageData: Data? = nil
    var source: SourceRef? = nil
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var color: CardColor = .yellow
    var z = 0

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct BoardLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

/// The file format of a workspace (`.kongboard`); the same structure is used for the crash backup.
struct BoardFile: Codable {
    var version = 1
    var id: UUID
    var title: String
    var cards: [BoardCard]
    var links: [BoardLink]
}

/// Plain text of an excerpt: Kangxi radical forms folded back, and line breaks removed the way a reader expects
/// (no space between two CJK characters, one space elsewhere).
enum ExcerptText {
    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FDF, 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    static func tidy(_ raw: String) -> String {
        let text = ReadingServices.repairIdeographs(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = ""
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            if let last = result.last, let first = line.first, !(isCJK(last) && isCJK(first)) { result += " " }
            result += line
        }
        return result
    }
}

enum BoardGeometry {
    /// Where the line from the centre of `rect` toward `target` leaves the rectangle.
    static func edgePoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        guard dx != 0 || dy != 0, rect.width > 0, rect.height > 0 else { return center }
        let scale = min(dx == 0 ? .infinity : (rect.width / 2) / abs(dx), dy == 0 ? .infinity : (rect.height / 2) / abs(dy))
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

/// The workspace: free-form cards (excerpts, notes) with links back to their sources and lines between them.
@MainActor final class Board: ObservableObject {
    static let cardWidth = 260.0
    static let minimumWidth = 120.0
    static let minimumHeight = 70.0
    static let fileExtension = "kongboard"

    let id: UUID
    let storage: URL
    @Published var title: String
    @Published private(set) var cards: [BoardCard]
    @Published private(set) var links: [BoardLink]
    @Published var fileURL: URL?
    @Published var dirty = false
    @Published var error: String?
    @Published var status = ""
    private var backupTask: Task<Void, Never>?

    init(id: UUID = UUID(), title: String = "工作区", cards: [BoardCard] = [], links: [BoardLink] = [], fileURL: URL? = nil, dirty: Bool = false, storage: URL? = nil) {
        self.id = id
        self.title = title
        self.cards = cards
        self.links = links
        self.fileURL = fileURL
        self.dirty = dirty
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
    }

    var hasContent: Bool { !cards.isEmpty }
    var displayTitle: String { fileURL?.deletingPathExtension().lastPathComponent ?? title }
    func card(_ id: UUID) -> BoardCard? { cards.first { $0.id == id } }

    /// Size of the scrollable canvas: always a screenful larger than the cards.
    var canvasSize: CGSize {
        CGSize(width: max(1400, (cards.map { $0.x + $0.width }.max() ?? 0) + 500),
               height: max(1000, (cards.map { $0.y + $0.height }.max() ?? 0) + 500))
    }

    // MARK: Cards

    static func estimatedHeight(forText text: String, hasComment: Bool = false) -> Double {
        let perLine = 15.0
        let lines = text.components(separatedBy: "\n").reduce(0.0) { $0 + max(1, ceil(Double($1.count) / perLine)) }
        return min(340, max(110, 62 + lines * 18 + (hasComment ? 0 : 30)))
    }

    /// New cards go below the lowest existing one, so nothing lands on top of something else.
    func nextPosition() -> CGPoint {
        guard let lowest = cards.max(by: { $0.y + $0.height < $1.y + $1.height }) else { return CGPoint(x: 40, y: 40) }
        return CGPoint(x: lowest.x, y: lowest.y + lowest.height + 16)
    }

    private func nextZ() -> Int { (cards.map(\.z).max() ?? 0) + 1 }

    @discardableResult private func append(_ card: BoardCard) -> UUID {
        var card = card
        card.z = nextZ()
        cards.append(card)
        changed()
        return card.id
    }

    @discardableResult func addExcerpt(text: String, source: SourceRef?, color: CardColor = .yellow) -> UUID {
        let position = nextPosition()
        return append(BoardCard(kind: .text, text: text, source: source, x: position.x, y: position.y, width: Board.cardWidth, height: Board.estimatedHeight(forText: text), color: color))
    }

    @discardableResult func addImage(_ data: Data, size: CGSize, source: SourceRef?, color: CardColor = .blue) -> UUID {
        let position = nextPosition()
        let width = Board.cardWidth, aspect = size.width > 0 ? size.height / size.width : 0.6
        return append(BoardCard(kind: .image, imageData: data, source: source, x: position.x, y: position.y, width: width, height: min(420, max(100, (width - 20) * aspect + 70)), color: color))
    }

    @discardableResult func addNote(text: String = "", at point: CGPoint? = nil) -> UUID {
        let position = point ?? nextPosition()
        return append(BoardCard(kind: .note, text: text, x: position.x, y: position.y, width: Board.cardWidth, height: 120, color: .green))
    }

    private func update(_ id: UUID, _ change: (inout BoardCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
        changed()
    }

    func move(_ id: UUID, to point: CGPoint) { update(id) { $0.x = max(0, Double(point.x)); $0.y = max(0, Double(point.y)) } }
    func resize(_ id: UUID, to size: CGSize) {
        update(id) { $0.width = max(Board.minimumWidth, Double(size.width)); $0.height = max(Board.minimumHeight, Double(size.height)) }
    }
    func setText(_ id: UUID, _ text: String) { update(id) { $0.text = text } }
    func setComment(_ id: UUID, _ comment: String) { update(id) { $0.comment = comment } }
    func setColor(_ id: UUID, _ color: CardColor) { update(id) { $0.color = color } }
    func bringToFront(_ id: UUID) {
        guard let card = card(id), card.z < (cards.map(\.z).max() ?? 0) else { return }
        update(id) { $0.z = nextZ() }
    }

    func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
        links.removeAll { $0.from == id || $0.to == id }
        changed()
    }

    // MARK: Links

    /// Joins two cards with a line. A card cannot be linked to itself, and a pair only once (in either direction).
    @discardableResult func connect(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b, card(a) != nil, card(b) != nil,
              !links.contains(where: { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }) else { return false }
        links.append(BoardLink(from: a, to: b))
        changed()
        return true
    }

    func disconnect(_ a: UUID, _ b: UUID) {
        links.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
        changed()
    }

    func neighbours(of id: UUID) -> [BoardCard] {
        links.compactMap { link in link.from == id ? card(link.to) : (link.to == id ? card(link.from) : nil) }
    }

    // MARK: Saving

    private func changed() {
        dirty = true
        scheduleBackup()
    }

    var file: BoardFile { BoardFile(id: id, title: displayTitle, cards: cards, links: links) }

    func write(to url: URL) throws {
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
        fileURL = url
        dirty = false
        removeBackup()
    }

    /// Replaces the content in place (the object stays the same, so every open view keeps following it).
    func load(_ file: BoardFile, from url: URL?) {
        title = file.title
        cards = file.cards
        links = file.links
        fileURL = url
        dirty = false
        removeBackup()
    }

    static func read(_ url: URL) throws -> BoardFile {
        guard let file = try? JSONDecoder().decode(BoardFile.self, from: Data(contentsOf: url)), file.version == 1 else {
            throw FolioError(message: "不是有效的工作区文件，或版本不受支持。")
        }
        return file
    }

    func clear() {
        cards = []; links = []; fileURL = nil; title = "工作区"; dirty = false
        removeBackup()
    }

    @discardableResult func save(asNew: Bool = false) -> Bool {
        var target = fileURL
        if asNew || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: Board.fileExtension) ?? .json]
            panel.nameFieldStringValue = displayTitle + "." + Board.fileExtension
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = chosen
        }
        guard let url = target else { return false }
        do { try write(to: url); status = "工作区已保存"; return true }
        catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }

    /// Asks what to do with an unsaved workspace. Returns false when the user cancels or saving fails.
    func confirmClose() -> Bool {
        guard dirty, hasContent else { removeBackup(); return true }
        let alert = NSAlert()
        alert.messageText = "保存工作区“\(displayTitle)”？"
        alert.informativeText = "工作区里的摘录和连线还没有保存。不保存会丢弃它们。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: removeBackup(); return true
        default: return false
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Board.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirmClose() else { return }
        do { load(try Board.read(url), from: url); status = "已打开工作区" }
        catch { self.error = error.localizedDescription }
    }

    func newBoard() {
        guard confirmClose() else { return }
        clear()
    }

    // MARK: Backup of unsaved work

    var backupURL: URL { storage.appendingPathComponent("Boards", isDirectory: true).appendingPathComponent("\(id.uuidString).json") }

    func writeBackup() throws {
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: backupURL, options: .atomic)
    }

    func removeBackup() {
        backupTask?.cancel()
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func scheduleBackup() {
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.dirty, self.hasContent else { return }
            do { try self.writeBackup() } catch { self.status = "自动备份失败：\(error.localizedDescription)" }
        }
    }

    /// The workspace that was never saved when the app last ended (the newest backup).
    static func restoreBackup(storage: URL) -> Board? {
        let folder = storage.appendingPathComponent("Boards", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "json" }.max {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        guard let newest, let file = try? JSONDecoder().decode(BoardFile.self, from: Data(contentsOf: newest)), !file.cards.isEmpty else { return nil }
        let board = Board(id: file.id, title: file.title, cards: file.cards, links: file.links, dirty: true, storage: storage)
        board.status = "已恢复上次未保存的工作区"
        return board
    }

    // MARK: Export

    /// Markdown with every excerpt quoted and cited, in reading order (top to bottom, then left to right), followed by the links.
    func markdown() -> String {
        let ordered = cards.sorted { ($0.y.rounded() / 40, $0.x) < ($1.y.rounded() / 40, $1.x) }
        var number: [UUID: Int] = [:]
        for (index, card) in ordered.enumerated() { number[card.id] = index + 1 }
        var lines = ["# \(displayTitle)", ""]
        for card in ordered {
            let n = number[card.id] ?? 0
            switch card.kind {
            case .text:
                lines.append("**[\(n)]**")
                lines.append(contentsOf: card.text.components(separatedBy: "\n").map { "> " + $0 })
            case .image:
                lines.append("**[\(n)]** （截取的图片区域）")
            case .note:
                lines.append("**[\(n)]** 笔记")
                lines.append(card.text)
            }
            if let source = card.source { lines.append("> — \(source.fileName)，\(source.pageDescription)") }
            if !card.comment.isEmpty { lines.append(""); lines.append(card.comment) }
            lines.append("")
        }
        if !links.isEmpty {
            lines.append("## 关联")
            lines.append("")
            for link in links { lines.append("- [\(number[link.from] ?? 0)] ↔ [\(number[link.to] ?? 0)]") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = displayTitle + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try markdown().write(to: url, atomically: true, encoding: .utf8); status = "已导出 Markdown" }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
}
