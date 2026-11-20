import SwiftUI
import UniformTypeIdentifiers

struct PDFThumbnailGrid: View {
    @ObservedObject var workspace: Workspace
    @State private var anchor: Int?
    @State private var dropIndicator: Int?
    @State private var confirmingDeletion = false

    private let cardWidth: CGFloat = 144
    private var canEdit: Bool {
        !workspace.readingLocked && !workspace.busy && workspace.placingSignature == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    closeButton
                    pageCount
                    Spacer(minLength: 12)
                    editActions
                    extractButton
                }
                HStack {
                    closeButton
                    pageCount
                    Spacer(minLength: 0)
                    Menu {
                        editActions
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("页面操作") }
                    extractButton
                }
            }
            .padding(10)
            .background(.bar)
            Divider()
            if workspace.readingLocked {
                Button("切换为编辑模式以排列页面") { workspace.toggleReadingLock() }
                    .buttonStyle(.link)
                    .padding(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth, maximum: 185), spacing: 16)],
                              spacing: 18) {
                        ForEach(0..<workspace.count, id: \.self) { index in
                            thumbnail(index).id(index)
                        }
                    }
                    .padding(18)
                }
                .task {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(workspace.selection, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: workspace.layoutRevision) { _, _ in anchor = nil; dropIndicator = nil }
        .confirmationDialog("删除 \(workspace.effectivePages.count) 页？", isPresented: $confirmingDeletion) {
            Button("删除页面", role: .destructive) { if canEdit { workspace.remove() } }
        }
    }

    private var closeButton: some View {
        Button { workspace.showsPageThumbnails = false } label: {
            Image(systemName: "chevron.left")
        }.help("返回 PDF 阅读").accessibilityLabel("返回 PDF 阅读")
    }

    private var pageCount: some View {
        Text("\(workspace.count) 页 · 已选 \(workspace.effectivePages.count) 页")
            .font(.caption).monospacedDigit().fixedSize()
    }

    @ViewBuilder private var editActions: some View {
        Menu("插入页") {
            Button("在当前页前插入空白页") { workspace.insertBlankPage(before: true) }
            Button("在当前页后插入空白页") { workspace.insertBlankPage() }
            Button("从 PDF 或图片插入…") { workspace.open(insert: true) }
        }.disabled(!canEdit)
        Button("旋转") { workspace.rotate() }.disabled(!canEdit)
        Button("复制页") { workspace.duplicatePages() }.disabled(!canEdit)
        Button("删除…", role: .destructive) { confirmingDeletion = true }
            .disabled(!canEdit || workspace.effectivePages.count >= workspace.count)
    }

    private var extractButton: some View {
        Button("提取页面…") { workspace.openExport(scope: .selected, extractingPages: true) }
            .disabled(workspace.busy || workspace.placingSignature != nil || workspace.effectivePages.isEmpty)
            .help("将选中的页面保存为独立 PDF")
    }

    private func thumbnail(_ index: Int) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let caption = workspace.printedPageLabel(index)
        let card = Button {
            let modifiers = NSEvent.modifierFlags
            let rangeStart = modifiers.contains(.shift) ? workspace.selection : index
            workspace.selectPage(index, modifiers: modifiers, rangeAnchor: anchor)
            if !modifiers.contains(.shift) || anchor == nil { anchor = rangeStart }
        } label: {
            VStack(spacing: 8) {
                ThumbnailView(workspace: workspace, index: index, height: 156)
                Text(caption.map { "\(index + 1) · p.\($0)" } ?? "\(index + 1)")
                    .font(.caption.monospacedDigit()).lineLimit(1)
            }
            .padding(8)
            .frame(width: cardWidth)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(selected ? 1 : 0), lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index + 1) 页")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("双击打开原页 · ⌘ 多选 · ⇧ 连选")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            workspace.selectPage(index)
            workspace.showsPageThumbnails = false
        })
        .contextMenu {
            Button("打开第 \(index + 1) 页") {
                workspace.selectPage(index)
                workspace.showsPageThumbnails = false
            }
            Button("提取选中页面…") {
                if !selected { workspace.selectPage(index) }
                workspace.openExport(scope: .selected, extractingPages: true)
            }.disabled(workspace.placingSignature != nil)
        }
        if canEdit {
            card
                .onDrag { NSItemProvider(object: workspace.pageDrag(index) as NSString) }
                .onDrop(of: [.utf8PlainText], delegate: PageDropDelegate(
                    workspace: workspace, insertion: index,
                    horizontalMidpoint: cardWidth / 2,
                    insertionChanged: { boundary in dropIndicator = boundary }
                ))
                .overlay(alignment: .leading) { insertionLine(index * 2) }
                .overlay(alignment: .trailing) { insertionLine(index * 2 + 1) }
        } else { card }
    }

    @ViewBuilder private func insertionLine(_ boundary: Int) -> some View {
        if dropIndicator == boundary {
            Capsule().fill(Color.accentColor).frame(width: 4).allowsHitTesting(false)
        }
    }
}
