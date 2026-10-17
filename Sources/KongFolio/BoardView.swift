import SwiftUI

/// The workspace pane: cards the reader has pulled out of documents, free notes, and the lines between them.
struct BoardView: View {
    @ObservedObject var board: Board
    @ObservedObject var workspace: Workspace
    @State private var connecting = false
    @State private var firstEnd: UUID?
    @AppStorage(LayoutKeys.tintSources) private var tintSources = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .textBackgroundColor)
                        linkLines
                        ForEach(board.cards.sorted { $0.z < $1.z }) { card in
                            CardView(board: board, card: card, store: workspace.store, connecting: connecting, firstEnd: $firstEnd)
                                .id(card.id)
                        }
                        if board.cards.isEmpty {
                            Text("在 PDF 中选中文字，点“摘录选中文字”（⌥⌘E），或用“区域摘录”工具框选图表；摘录会出现在这里，原文会被着色，点卡片或点原文的颜色都能互相跳转。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(width: 280).padding(24)
                        }
                    }
                    .frame(width: board.canvasSize.width, height: board.canvasSize.height, alignment: .topLeading)
                    .coordinateSpace(name: "board")
                }
                .background(Color(nsColor: .textBackgroundColor))
                // A new excerpt, or a click on an excerpt's colour in the document, brings its card into view.
                .onChange(of: board.focusedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if connecting {
                Text(firstEnd == nil ? "连线：点选第一张卡片" : "连线：再点选要连到的卡片（点同一张取消）")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { board.error != nil }, set: { if !$0 { board.error = nil } })) {
            Button("好") { board.error = nil }
        } message: { Text(board.error ?? "") }
        .onChange(of: connecting) { _, on in if !on { firstEnd = nil } }
    }

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(board.displayTitle + (board.dirty && board.hasContent ? " •" : "")).font(.headline).lineLimit(1)
                Divider().frame(height: 16)
                Button { workspace.excerptSelection() } label: { Label("摘录选中文字", systemImage: "text.quote") }
                    .help("把选中的文字放进工作区（⌥⌘E）")
                    .disabled(workspace.count == 0)
                Button { workspace.mode = .document; workspace.tool = .region } label: { Label("区域摘录", systemImage: "viewfinder") }
                    .help("在页面上框选一块区域（图表、表格）放进工作区")
                    .disabled(workspace.count == 0)
                Button { board.addNote() } label: { Label("便签", systemImage: "note.text.badge.plus") }.help("新建一张自由笔记")
                Toggle(isOn: $connecting) { Label("连线", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .toggleStyle(.button).help("在两张卡片之间画线")
                Menu {
                    Button("按原文顺序整理") { board.arrangeBySource() }.disabled(!board.hasContent)
                    Button("撤销整理") { board.undoArrangement() }.disabled(!board.canUndoArrangement)
                    Toggle("摘录后给原文着色", isOn: $tintSources)
                    Divider()
                    Button("导出 Markdown…") { board.exportMarkdown() }.disabled(!board.hasContent)
                    Divider()
                    Button("新建工作区") { board.newBoard() }
                    Button("打开工作区…") { board.openPanel() }
                    Button("保存工作区") { board.save() }.disabled(!board.hasContent)
                    Button("工作区另存为…") { board.save(asNew: true) }.disabled(!board.hasContent)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var linkLines: some View {
        Canvas { context, _ in
            for link in board.links {
                guard let a = board.card(link.from), let b = board.card(link.to) else { continue }
                let start = BoardGeometry.edgePoint(of: a.frame, toward: CGPoint(x: b.frame.midX, y: b.frame.midY))
                let end = BoardGeometry.edgePoint(of: b.frame, toward: CGPoint(x: a.frame.midX, y: a.frame.midY))
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for point in [start, end] {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CardView: View {
    @ObservedObject var board: Board
    let card: BoardCard
    let store: WorkspaceStore?
    let connecting: Bool
    @Binding var firstEnd: UUID?
    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?

    private var tint: Color { Color(nsColor: card.color.nsColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            handle
            content
            if card.kind != .note {
                TextField("批注", text: Binding(get: { board.card(card.id)?.comment ?? "" }, set: { board.setComment(card.id, $0) }), axis: .vertical)
                    .textFieldStyle(.plain).font(.caption).lineLimit(1...4)
            }
            Spacer(minLength: 0)
            if let source = card.source {
                Button { store?.reveal(source) } label: {
                    Label("\(source.fileName) · \(source.pageDescription)", systemImage: "arrow.turn.up.left").font(.caption2).lineLimit(1)
                }
                .buttonStyle(.link).help("回到原文位置")
            }
        }
        .padding(8)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(firstEnd == card.id || board.focusedID == card.id ? Color.accentColor : tint.opacity(0.6), lineWidth: firstEnd == card.id || board.focusedID == card.id ? 3 : 1))
        .shadow(color: board.focusedID == card.id ? Color.accentColor.opacity(0.5) : .clear, radius: 8)
        .animation(.easeInOut(duration: 0.25), value: board.focusedID)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        // Placed with alignment guides (not an offset) so the card's real position is where it appears; that is what
        // lets the pane scroll to it.
        .alignmentGuide(.leading) { _ in -CGFloat(card.x) }
        .alignmentGuide(.top) { _ in -CGFloat(card.y) }
        .onTapGesture(count: 2) { if !connecting, let source = card.source { store?.reveal(source) } }
        .onTapGesture { tapped() }
        .contextMenu {
            Menu("颜色") { ForEach(CardColor.allCases) { color in Button(color.title) { board.setColor(card.id, color) } } }
            let neighbours = board.neighbours(of: card.id)
            if !neighbours.isEmpty {
                Menu("取消连线") {
                    ForEach(neighbours) { other in Button(label(for: other)) { board.disconnect(card.id, other.id) } }
                }
            }
            Divider()
            Button("删除这张卡片", role: .destructive) { board.remove(card.id) }
        }
    }

    private func label(for card: BoardCard) -> String {
        let text = card.kind == .image ? "图片区域" : card.text
        return text.isEmpty ? "空白卡片" : String(text.prefix(18))
    }

    /// The strip at the top of the card: grab it to move the card.
    private var handle: some View {
        HStack(spacing: 6) {
            Image(systemName: card.kind == .image ? "photo" : (card.kind == .note ? "note.text" : "text.quote")).foregroundStyle(tint)
            Spacer(minLength: 0)
            if let source = card.source {
                Button { store?.reveal(source) } label: { Image(systemName: "arrow.turn.up.left") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor).help("回到原文位置（双击卡片也可以）")
            }
            Button { board.remove(card.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).help("删除这张卡片（原文的着色也会取消）")
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("board"))
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = CGPoint(x: card.x, y: card.y); board.bringToFront(card.id) }
                    if let origin = dragOrigin { board.move(card.id, to: CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height)) }
                }
                .onEnded { _ in dragOrigin = nil }
        )
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .text:
            Text(card.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            TextField("笔记", text: Binding(get: { board.card(card.id)?.text ?? "" }, set: { board.setText(card.id, $0) }), axis: .vertical)
                .textFieldStyle(.plain).font(.callout)
        case .image:
            if let data = card.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            }
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.secondary)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
                    .onChanged { value in
                        if resizeOrigin == nil { resizeOrigin = CGSize(width: card.width, height: card.height) }
                        if let origin = resizeOrigin { board.resize(card.id, to: CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)) }
                    }
                    .onEnded { _ in resizeOrigin = nil }
            )
    }

    private func tapped() {
        if connecting {
            if let first = firstEnd {
                if first != card.id { board.connect(first, card.id) }
                firstEnd = nil
            } else {
                firstEnd = card.id
            }
        } else {
            board.bringToFront(card.id)
        }
    }
}
