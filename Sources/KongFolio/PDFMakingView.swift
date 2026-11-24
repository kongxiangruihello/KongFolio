import SwiftUI
import PDFKit

struct PDFMakingToolbar: View {
    @ObservedObject var workspace: Workspace

    private var canEdit: Bool {
        !workspace.busy && !workspace.readingLocked && workspace.placingSignature == nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 9) {
            if workspace.previewsCreatedPDF {
                Button { workspace.previewsCreatedPDF = false } label: {
                    Label("返回制作", appIcon: "chevron.left")
                }
            } else {
                Button { workspace.beginMakingText() } label: {
                    control("添加文字", symbol: "textformat", compact: compact)
                        .foregroundStyle(workspace.tool == .textBox ? Brand.accent : Color.primary)
                }
                .help("添加文字").disabled(!canEdit)
                Button { workspace.choosePageImage() } label: {
                    control("添加图片", symbol: "photo.badge.plus", compact: compact)
                }
                .help("添加图片到当前页").disabled(!canEdit)
                Menu {
                    Button("在当前页后插入空白页") { workspace.insertBlankPage() }
                    Button("在当前页前插入空白页") { workspace.insertBlankPage(before: true) }
                    Divider()
                    Button("图片各占一页…") { workspace.open(insert: true, imagesOnly: true) }
                    Button("从文件插入页面…") { workspace.open(insert: true) }
                } label: {
                    control("插入页面", symbol: "doc.badge.plus", compact: compact)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("插入空白页、PDF 或图片")
                .disabled(!canEdit)

                if workspace.selectedAnnotation?.type == "FreeText" {
                    textStyle(compact: compact).disabled(!canEdit)
                }
                Divider().frame(height: 17)
                Button { workspace.undo() } label: { AppIcon("arrow.uturn.backward") }
                    .help("撤销").accessibilityLabel("撤销").disabled(!canEdit || workspace.history.isEmpty)
                Button { workspace.redo() } label: { AppIcon("arrow.uturn.forward") }
                    .help("重做").accessibilityLabel("重做").disabled(!canEdit || workspace.future.isEmpty)
            }

            Spacer(minLength: 4)
            Button {
                workspace.store?.saveActive()
            } label: {
                Label(workspace.historySource == nil ? "保存 PDF…" : "保存 PDF", appIcon: "square.and.arrow.down")
                    .labelStyle(.titleOnly)
            }
            .buttonStyle(.borderedProminent)
            .disabled(workspace.busy || workspace.saving)
            more
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(.borderless)
    }

    private func control(_ title: String, symbol: String, compact: Bool) -> some View {
        HStack(spacing: 5) {
            AppIcon(symbol).accessibilityHidden(true)
            if !compact { Text(title) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(title)
    }

    private func textStyle(compact: Bool) -> some View {
        Menu {
            Menu("字号") {
                ForEach(AnnotationTextStyle.sizes, id: \.self) { size in
                    Button("\(Int(size)) 磅") { workspace.styleTextBoxes(size: size) }
                }
            }
            Menu("文字颜色") {
                Button("黑色") { workspace.styleTextBoxes(ink: .black) }
                Button("深蓝") { workspace.styleTextBoxes(ink: .systemBlue) }
                Button("深红") { workspace.styleTextBoxes(ink: .systemRed) }
            }
        } label: { control("文字样式", symbol: "textformat.size", compact: compact) }
        .menuStyle(.borderlessButton).fixedSize()
        .help("文字样式")
    }

    private var more: some View {
        Menu {
            if !workspace.previewsCreatedPDF {
                Button("预览 PDF") {
                    workspace.tool = .select
                    workspace.selectAnnotation(nil)
                    workspace.previewsCreatedPDF = true
                }.disabled(!canEdit)
                SignatureToolbarMenu(workspace: workspace, showTitle: true).disabled(!canEdit)
                Button("识别扫描文字（OCR）") { workspace.ocr() }.disabled(!canEdit)
            }
            Button("导出 PDF 副本…") { workspace.exportPDF() }.disabled(workspace.busy)
            Button("导出 Word…") { workspace.showWordExport = true }.disabled(workspace.busy)
            Button("打印…") { workspace.store?.printActive() }.disabled(workspace.busy)
            Divider()
            Button("切换到阅读界面") {
                workspace.previewsCreatedPDF = false
                workspace.isMakingPDF = false
                workspace.tool = .select
            }.disabled(!canEdit)
        } label: { AppIcon("ellipsis.circle").frame(width: 21) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多").accessibilityLabel("更多")
    }
}

struct PDFMakingContent: View {
    @ObservedObject var workspace: Workspace
    @State private var showsPages = true
    @State private var dropTargeted = false

    private var canInsert: Bool {
        !workspace.previewsCreatedPDF && !workspace.busy && !workspace.readingLocked &&
            workspace.placingSignature == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showsPages && !workspace.previewsCreatedPDF {
                    VStack(spacing: 0) {
                        HStack {
                            Text("页面").font(.headline)
                            Spacer()
                            SidePanelCloseButton(title: "关闭左侧页面栏") { showsPages = false }
                        }.padding(10)
                        Divider()
                        PDFThumbnailGrid(workspace: workspace, inSidebar: true)
                        if canInsert { insertionDropZone }
                    }
                    .frame(minWidth: 126, idealWidth: 150, maxWidth: 230)
                }
                ZStack {
                    PDFCanvas(workspace: workspace)
                    if showsBlankActions {
                        HStack(spacing: 8) {
                            Button("添加文字") { workspace.beginMakingText() }
                            Button("添加图片") { workspace.choosePageImage() }
                        }
                        .buttonStyle(.bordered)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            }
            if workspace.placingSignature?.isPageImage == true {
                Divider()
                PDFPageImagePlacementControls(workspace: workspace)
                    .padding(10).frame(maxWidth: .infinity).background(.bar)
            } else if workspace.placingSignature != nil {
                HStack {
                    Button("放置签名") { workspace.confirmSignaturePlacement() }.buttonStyle(.borderedProminent)
                    Button("取消") { workspace.cancelSignaturePlacement() }
                }.padding(8)
            }
            Divider()
            HStack(spacing: 8) {
                if !workspace.previewsCreatedPDF {
                    Button { showsPages.toggle() } label: { AppIcon("sidebar.left") }
                        .help(showsPages ? "隐藏页面栏" : "显示页面栏").accessibilityLabel("显示或隐藏页面栏")
                }
                PDFReaderPageControls(workspace: workspace)
                    .disabled(workspace.placingSignature != nil)
                Menu("缩放") { PDFReaderZoomActions(workspace: workspace) }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 4)
                Text(saveStatus).foregroundStyle(.secondary).lineLimit(1)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 10).frame(height: 34)
            .background(.bar)
        }
        .onAppear { workspace.showsPageThumbnails = false }
        .onChange(of: workspace.showsPageThumbnails) { _, value in
            if value { showsPages = true; workspace.showsPageThumbnails = false }
        }
    }

    private var insertionDropZone: some View {
        Label("拖入文件插页", appIcon: "arrow.down.doc")
            .font(.caption)
            .foregroundStyle(dropTargeted ? Brand.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(dropTargeted ? Brand.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(dropTargeted ? Brand.accent : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard canInsert else { return false }
                let files = urls.filter {
                    $0.isFileURL && ($0.pathExtension.lowercased() == "pdf" || ImageImport.handles($0))
                }
                guard !files.isEmpty else { return false }
                workspace.openSelected(files, insert: true)
                return true
            } isTargeted: { dropTargeted = $0 }
            .padding(8)
            .help("把 PDF 或图片拖到这里，作为页面插到当前页之后")
    }

    private var showsBlankActions: Bool {
        !workspace.previewsCreatedPDF && workspace.selection == 0 && workspace.tool == .select &&
            !workspace.readingLocked && workspace.emptyCreationPDF != nil && workspace.canDiscardEmptyCreation
    }

    private var saveStatus: String {
        if workspace.saving { return "正在保存…" }
        if workspace.historySource == nil { return "尚未保存" }
        return workspace.dirty ? "有未保存修改" : "已保存"
    }
}

extension Workspace {
    func beginMakingText() {
        guard isMakingPDF, !previewsCreatedPDF, !readingLocked, !busy, placingSignature == nil else { return }
        if tool == .textBox {
            tool = .select
            status = "已退出添加文字"
        } else {
            note = ""
            tool = .textBox
            status = "点击纸面，输入文字"
        }
    }
}
