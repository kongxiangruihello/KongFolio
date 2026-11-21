import SwiftUI
import AppKit

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
            toolbar
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
            AppIcon("chevron.left")
        }.help("返回 PDF 阅读").accessibilityLabel("返回 PDF 阅读")
    }

    private var pageCount: some View {
        Text("\(workspace.count) 页 · 已选 \(workspace.effectivePages.count) 页")
            .font(.caption).monospacedDigit().fixedSize()
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                closeButton
                pageCount
                Spacer(minLength: 12)
                insertionButtons
                pageButtons
                extractButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    closeButton
                    pageCount
                    Spacer(minLength: 4)
                    extractButton
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        insertionButtons
                        pageButtons
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var insertionButtons: some View {
        HStack(spacing: 6) {
            Button("前插空白") { workspace.insertBlankPage(before: true) }
                .help("在当前页前插入空白页")
                .accessibilityLabel("在当前页前插入空白页")
            Button("后插空白") { workspace.insertBlankPage() }
                .help("在当前页后插入空白页")
                .accessibilityLabel("在当前页后插入空白页")
            Button("插入文件…") { workspace.open(insert: true) }
                .help("从 PDF 或图片插入页面")
                .accessibilityLabel("从 PDF 或图片插入")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!canEdit)
    }

    private var pageButtons: some View {
        HStack(spacing: 6) {
            Button("旋转") { workspace.rotate() }
            Button("复制页") { workspace.duplicatePages() }
            Button("删除…", role: .destructive) { confirmingDeletion = true }
                .disabled(workspace.effectivePages.count >= workspace.count)
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!canEdit)
    }

    private var extractButton: some View {
        Button("提取页面…") { workspace.openExport(scope: .selected, extractingPages: true) }
            .disabled(workspace.busy || workspace.placingSignature != nil || workspace.effectivePages.isEmpty)
            .help("将选中的页面保存为独立 PDF")
    }

    @ViewBuilder private func thumbnail(_ index: Int) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let caption = workspace.printedPageLabel(index)
        let card = Button {
            select(index, modifiers: NSEvent.modifierFlags)
        } label: {
            VStack(spacing: 8) {
                ThumbnailView(workspace: workspace, index: index, height: 156, inPageGrid: true)
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
        .help(canEdit ? "拖动重排 · 双击打开 · ⌘ 多选 · ⇧ 连选" : "双击打开 · ⌘ 多选 · ⇧ 连选")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            open(index)
        })
        .contextMenu {
            Button("打开第 \(index + 1) 页") { open(index) }
            Button("提取选中页面…") { extract(index) }.disabled(workspace.placingSignature != nil)
        }
        if canEdit {
            card
                .overlay {
                    PDFThumbnailPointer(
                        click: { event in
                            if event.clickCount == 2 { open(index) }
                            else { select(index, modifiers: event.modifierFlags) }
                        },
                        drag: {
                            guard canEdit else { return nil }
                            if !workspace.selectedPages.contains(index) { select(index) }
                            return (workspace.pageDrag(index),
                                    workspace.thumbnails.image(for: workspace.thumbnailKey(index)))
                        },
                        propose: { drag in
                            guard canEdit else { return [] }
                            if drag.source != workspace.id { return .copy }
                            return drag.revision == workspace.revision ? .move : []
                        },
                        hover: { after in
                            if let after { dropIndicator = index * 2 + (after ? 1 : 0) }
                            else if dropIndicator == index * 2 || dropIndicator == index * 2 + 1 { dropIndicator = nil }
                        },
                        drop: { payload, after in workspace.receivePageDrag(payload, before: index + (after ? 1 : 0)) },
                        open: { open(index) },
                        extract: { extract(index) }
                    )
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .leading) { insertionLine(index * 2) }
                .overlay(alignment: .trailing) { insertionLine(index * 2 + 1) }
        } else { card }
    }

    private func select(_ index: Int, modifiers: NSEvent.ModifierFlags = []) {
        let rangeStart = modifiers.contains(.shift) ? workspace.selection : index
        workspace.selectPage(index, modifiers: modifiers, rangeAnchor: anchor)
        if !modifiers.contains(.shift) || anchor == nil { anchor = rangeStart }
    }

    private func open(_ index: Int) {
        workspace.selectPage(index)
        workspace.showsPageThumbnails = false
    }

    private func extract(_ index: Int) {
        if !workspace.selectedPages.contains(index) { workspace.selectPage(index) }
        workspace.openExport(scope: .selected, extractingPages: true)
    }

    @ViewBuilder private func insertionLine(_ boundary: Int) -> some View {
        if dropIndicator == boundary {
            Capsule().fill(Color.accentColor).frame(width: 4).allowsHitTesting(false)
        }
    }
}
