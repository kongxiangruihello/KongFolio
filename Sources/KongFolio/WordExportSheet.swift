import SwiftUI
import UniformTypeIdentifiers
import PDFKit

/// Chooses what goes into the Word file made from the scanned book.
struct WordExportSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var preview: [WordPreparedPage] = []
    @State private var candidates: [WordMarginCandidate] = []
    @State private var previewIndex = 0
    @State private var editText = false
    @State private var previewRevision: UUID?
    @State private var preparing = false
    @State private var previewMessage = ""
    @State private var worker: Task<Void, Never>?
    private var cleanup: Binding<Bool> { Binding(get: { workspace.wordOptions.removeRunningMargins ?? false }, set: { workspace.wordOptions.removeRunningMargins = $0 }) }
    private var headings: Binding<Bool> { Binding(get: { workspace.wordOptions.recognizeHeadings ?? true }, set: { workspace.wordOptions.recognizeHeadings = $0 }) }
    private var printed: Binding<Bool> { Binding(get: { workspace.wordOptions.printedPageLabels ?? false }, set: { workspace.wordOptions.printedPageLabels = $0 }) }

    private var shownParagraphs: [WordPreparedParagraph] {
        guard preview.indices.contains(previewIndex) else { return [] }
        let page = preview[previewIndex]
        if let edited = workspace.wordOptions.editedText?[page.index] { return WordCleanup.editedParagraphs(edited, headings: workspace.wordOptions.recognizeHeadings != false) }
        return page.paragraphs
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出为 Word（.docx）").font(.title2.bold())
            if workspace.wordOptions.hasDraft {
                Text(workspace.wordOptions.editedFromRevision == workspace.revision ? "修改草稿已自动保留，重新打开可继续。" : "原文已变化，草稿已保留。请先拷贝核对，再清除旧稿并更新预览。").font(.caption).foregroundStyle(.secondary)
                PanelRow {
                    Button("拷贝全部修改草稿") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(workspace.wordDraftText, forType: .string) }
                    Button("清除当前页修改") { workspace.clearWordDraft(page: workspace.selection); inspect() }.disabled(!workspace.wordOptions.draftPages.contains(workspace.selection))
                    Button("清除修改草稿") { workspace.clearWordDraft(); inspect() }
                }
            }
            Picker("范围", selection: $workspace.wordScope) { ForEach(CropScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("内容", selection: $workspace.wordOptions.content) { ForEach(WordExportOptions.Content.allCases) { Text($0.rawValue).tag($0) } }
            if workspace.wordOptions.content != .textOnly {
                Picker("页面图片", selection: $workspace.wordOptions.imageSize) { ForEach(WordExportOptions.ImageSize.allCases) { Text($0.rawValue).tag($0) } }
            }
            if workspace.wordOptions.content != .imagesOnly {
                Toggle("把同一句的断行合并成段落", isOn: $workspace.wordOptions.mergeLines)
            }
            if workspace.wordOptions.content != .imagesOnly {
                Toggle("竖排页面：保持原书的列（每列一行）", isOn: $workspace.wordOptions.keepColumns)
                Text("做过竖排 OCR 的页面按“列从右到左、字从上到下”排成横排文字，繁体字原样保留；关闭时整页连成一段。没有识别记录的页面按文字层顺序。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            PanelRow {
                Toggle("应用替换规则（\(ReplacementRules.parse(workspace.replacementText).count) 条）", isOn: $workspace.applyReplacements)
                Button("编辑规则…") { workspace.showReplacementRules = true }
            }
            if workspace.tableDrafts.contains(where: \.includeInWord) {
                Toggle("正文插入已核对的表格草稿（\(workspace.tableDrafts.filter(\.includeInWord).count) 份）", isOn: Binding(get: { workspace.wordOptions.includeTables != false }, set: { workspace.wordOptions.includeTables = $0 }))
            }
            Toggle("清除重复页眉页脚（仅导出文字）", isOn: cleanup)
            Toggle("将章、节标题设为 Word 标题", isOn: headings)
            Toggle("页码标记附上原书印刷页码", isOn: printed)
            PanelRow {
                Button(preparing ? "正在整理…" : "更新导出预览") { inspect() }.disabled(preparing)
                if preparing { ProgressView().controlSize(.small) }
                Spacer()
                if !preview.isEmpty { Button("上一页") { previewIndex = max(0, previewIndex - 1) }; Button("下一页") { previewIndex = min(preview.count - 1, previewIndex + 1) } }
            }
            if !candidates.isEmpty {
                Text("疑似页眉页脚（只检查至少 3 页；请核对后选择）").font(.caption)
                ForEach(candidates) { candidate in
                    Toggle("\(candidate.id.hasPrefix("上") ? "页眉" : "页脚")：\(candidate.example) · \(candidate.pages) 页", isOn: Binding(get: { workspace.wordOptions.removedMarginKeys?.contains(candidate.id) ?? true }, set: { value in
                        var keys = Set(workspace.wordOptions.removedMarginKeys ?? candidates.map(\.id)); if value { keys.insert(candidate.id) } else { keys.remove(candidate.id) }; workspace.wordOptions.removedMarginKeys = keys.sorted()
                    })).font(.caption).disabled(!cleanup.wrappedValue)
                }
            }
            if preview.indices.contains(previewIndex) {
                Text("文字整理预览 · 第 \(preview[previewIndex].index + 1) 页").font(.caption.bold())
                Toggle("导出前修改本页正文和表格", isOn: $editText).disabled(preparing || workspace.wordOptions.content == .imagesOnly)
                if editText, let base = preview[previewIndex].blocks {
                    let index = preview[previewIndex].index
                    WordMixedEditor(blocks: workspace.wordOptions.editedBlocks?[index] ?? base) { block, row, column, text in
                        do {
                            guard previewRevision == workspace.revision else { throw FolioError(message: "PDF 已变化，请重新更新预览") }
                            let changed = try WordMixedDraft.replacing(workspace.wordOptions.editedBlocks?[index] ?? base, block: block, row: row, column: column, text: text)
                            try workspace.setWordBlocks(changed, base: base, page: index)
                        } catch { previewMessage = error.localizedDescription }
                    }.frame(height: 240).border(.secondary.opacity(0.3))
                    Text("正文和单元格修改自动保留，仅影响 Word 导出。表格结构调整请回到表格工具。").font(.caption).foregroundStyle(.secondary)
                } else if editText {
                    TextEditor(text: Binding(get: {
                        let page = preview[previewIndex]
                        return workspace.wordOptions.editedText?[page.index] ?? page.paragraphs.map(\.text).joined(separator: "\n\n")
                    }, set: { text in
                        do {
                            guard previewRevision == workspace.revision else { throw FolioError(message: "PDF 已变化，请重新更新预览后再修改正文") }
                            try workspace.setWordDraft(text, page: preview[previewIndex].index) }
                        catch { previewMessage = error.localizedDescription }
                    })).font(.body).frame(height: 200).border(.secondary.opacity(0.3))
                    Text("仅修改 Word 导出的文字，草稿自动保留，原 PDF 保留。段落之间留空行；已修改页采用手动文字，其他页继续应用整理规则。").font(.caption).foregroundStyle(.secondary)
                } else {
                    WordBlocksPreview(blocks: workspace.wordOptions.editedBlocks?[preview[previewIndex].index] ?? preview[previewIndex].blocks ?? shownParagraphs.map(WordPreparedBlock.paragraph)).frame(height: 220).border(.secondary.opacity(0.3))
                }
                if workspace.wordOptions.hasDraft {
                    PanelRow {
                        Text("已修改 \(workspace.wordOptions.draftPages.count) 页").font(.caption)
                        Button("恢复本页整理结果") { workspace.clearWordDraft(page: preview[previewIndex].index); inspect() }
                        Button("清除本次文字修改") { workspace.clearWordDraft(); inspect() }
                    }
                }
            }
            if !previewMessage.isEmpty { Text(previewMessage).font(.caption).foregroundStyle(.secondary) }
            Toggle("标出页码（“—— 第 N 页 ——”）", isOn: $workspace.wordOptions.pageMarks)
            Text("文字来自页面的文字层，扫描页需要先 OCR；目录条目会成为 Word 的标题，可在导航窗格里跳转。页面图片是当前显示的范围（裁边后的样子）。版式、脚注位置不会还原。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PanelRow {
                Button("取消") { workspace.showWordExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择位置并导出…") { workspace.startWordExport() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .adaptiveSheet(width: 620, height: 820, minimumWidth: 360, flexibleHeight: true)
        .onAppear { inspect() }
        .onDisappear { worker?.cancel() }
    }
    private func inspect() {
        do { try workspace.validateWordDraft() } catch { previewMessage = error.localizedDescription; return }
        guard let data = try? workspace.pdfData() else { previewMessage = "无法读取当前文档"; return }
        let sourceRevision = workspace.revision
        let baseOptions: WordExportOptions
        do { baseOptions = try workspace.wordOptionsWithTables() } catch { previewMessage = error.localizedDescription; return }
        var options = baseOptions
        options.replacements = workspace.applyReplacements ? ReplacementRules.parse(workspace.replacementText) : []
        let pages = workspace.wordScope == .all ? Array(0..<workspace.count) : workspace.effectivePages
        let regions = Dictionary(uniqueKeysWithValues: pages.compactMap { i in workspace.meta(i).ocrRegions.map { (i, $0) } })
        preparing = true; previewMessage = ""
        worker = Task {
            let job = Task.detached(priority: .userInitiated) {
                try WordCleanup.inspect(try PDFDocument(data: data).unwrap("无法读取文档"), pages: pages, options: options, regions: regions, sourceDigest: OCRPageCache.digest(data))
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation()
                guard sourceRevision == workspace.revision else { preparing = false; previewMessage = "PDF 已变化，请重新更新预览"; return }
                previewRevision = sourceRevision; preview = result.pages; candidates = result.candidates; previewIndex = result.pages.firstIndex(where: { $0.index == workspace.pendingWordPreviewPage }) ?? 0; workspace.pendingWordPreviewPage = nil
                previewMessage = "预览与导出使用同一套整理规则。修改选项后请更新预览；原 PDF 不变。"
            } catch is CancellationError {} catch { previewMessage = error.localizedDescription }
            preparing = false
        }
    }

}
