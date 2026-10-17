import SwiftUI
import UniformTypeIdentifiers

/// Chooses what goes into the Word file made from the scanned book.
struct WordExportSheet: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出为 Word（.docx）").font(.title2.bold())
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
            HStack {
                Toggle("应用替换规则（\(ReplacementRules.parse(workspace.replacementText).count) 条）", isOn: $workspace.applyReplacements)
                Button("编辑规则…") { workspace.showReplacementRules = true }
            }
            Toggle("标出页码（“—— 第 N 页 ——”）", isOn: $workspace.wordOptions.pageMarks)
            Text("文字来自页面的文字层，扫描页需要先 OCR；目录条目会成为 Word 的标题，可在导航窗格里跳转。页面图片是当前显示的范围（裁边后的样子）。版式、脚注位置不会还原。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { workspace.showWordExport = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择位置并导出…") { workspace.startWordExport() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

extension Workspace {
    func openWordExport() {
        guard count > 0 else { return }
        showWordExport = true
    }

    func startWordExport() {
        guard count > 0, !busy, checkDraftsForExport(), let data = try? pdfData() else { return }
        let pages = wordScope == .all ? Array(0..<count) : effectivePages
        if wordOptions.content != .imagesOnly {
            let hasText = pages.contains { index in document.page(at: index).map { BackgroundJobs.textCharacterCount($0) > 0 } ?? false }
            if !hasText {
                if wordOptions.content == .textOnly { error = "这些页面没有文字，请先运行 OCR。"; return }
                guard confirm("这些页面没有文字层", "只会导出页面图片。需要文字的话，请先运行 OCR 再导出。", action: "只导出图片") else { return }
            }
        }
        showWordExport = false
        var exportOptions = wordOptions
        exportOptions.replacements = applyReplacements ? ReplacementRules.parse(replacementText) : []
        guard let destination = saveURL(type: UTType(filenameExtension: "docx") ?? .data, suffix: "docx") else { return }
        runJob(JobSpec(operation: .word, source: data, pages: pages, destination: destination, revision: revision, word: exportOptions, outline: outlineEntries,
                         regions: Dictionary(uniqueKeysWithValues: pages.compactMap { index in meta(index).ocrRegions.map { (index, $0) } })))
    }
}
