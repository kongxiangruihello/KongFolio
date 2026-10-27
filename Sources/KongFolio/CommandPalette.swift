import SwiftUI

enum FolioCommand: String, CaseIterable, Identifiable {
    case open, newPDF, newMarkdown, newHTML, newText, save, saveAs, exportPDF, exportWord, printDocument
    case find, searchFiles, rotate, extractPages, removePages, blankPage, annotation, signature, tools
    case table, forms, ocr, scan, compare, history, tasks, switchTabs, undo, redo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "打开文件"
        case .newPDF: return "新建 PDF"
        case .newMarkdown: return "新建 Markdown 笔记"
        case .newHTML: return "新建 HTML 文件"
        case .newText: return "新建文本文件"
        case .save: return "保存当前文件"
        case .saveAs: return "另存当前文件"
        case .exportPDF: return "导出 PDF"
        case .exportWord: return "导出 Word"
        case .printDocument: return "打印当前文件"
        case .find: return "查找当前 PDF 文字"
        case .searchFiles: return "跨文件全文搜索"
        case .rotate: return "旋转选中页面"
        case .extractPages: return "提取选中页面"
        case .removePages: return "删除选中页面"
        case .blankPage: return "插入空白页"
        case .annotation: return "显示或隐藏标注工具"
        case .signature: return "放置图片签名"
        case .tools: return "打开快捷工具"
        case .table: return "提取 PDF 表格"
        case .forms: return "填写 PDF 表单"
        case .ocr: return "识别选中页面文字 OCR"
        case .scan: return "扫描整理与纠偏"
        case .compare: return "文档精细对比"
        case .history: return "查看当前文档保存历史"
        case .tasks: return "任务中心与扫描配方"
        case .switchTabs: return "切换已打开文件"
        case .undo: return "撤销上一步"
        case .redo: return "重做上一步"
        }
    }
    var keywords: String {
        switch self {
        case .open: return "打开 导入 open import"
        case .exportWord: return "转换 导出 docx word"
        case .table: return "提取表格 表格 行列 csv markdown word table"
        case .forms: return "填写表单 表单 输入框 勾选 下拉 填表 form"
        case .signature: return "签字 签名 图片 signature"
        case .ocr: return "识别 扫描 文字 ocr"
        case .scan: return "裁切 切分 纠偏 扫描 deskew"
        default: return rawValue
        }
    }
    static func ranked(query: String, recent: [String]) -> [Self] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return allCases.filter { c in terms.allSatisfy { (c.title + " " + c.keywords).lowercased().contains($0) } }.sorted { a, b in
            let ai = recent.firstIndex(of: a.rawValue) ?? 999, bi = recent.firstIndex(of: b.rawValue) ?? 999
            if ai != bi { return ai < bi }; return allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }
}

extension WorkspaceStore {
    var recentCommands: [String] {
        (try? Data(contentsOf: storage.appendingPathComponent("Commands.json"))).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
    func unavailableReason(_ command: FolioCommand) -> String? {
        let w = commandWorkspace
        switch command {
        case .open, .newPDF, .newMarkdown, .newHTML, .newText, .searchFiles, .compare, .tasks, .switchTabs: return nil
        case .save, .saveAs, .exportPDF, .exportWord, .printDocument:
            if activeWorkspace?.busy == true { return "当前文档正在处理任务" }
            return canSave ? nil : "请先打开或新建文件"
        case .undo: return canUndo ? nil : "没有可以撤销的操作"
        case .redo: return canRedo ? nil : "没有可以重做的操作"
        default:
            guard let w, w.count > 0 else { return "请先打开 PDF 文档" }
            if w.busy { return "请等待当前任务完成" }
            if command == .history, w.historySource == nil { return "请先保存此文档" }
            if command == .signature, w.signatures.isEmpty { return "请先在标注工具中导入图片签名" }
            if command == .removePages, w.effectivePages.count >= w.count { return "文档至少需要保留一页" }
            return nil
        }
    }
    func performCommand(_ command: FolioCommand) {
        guard unavailableReason(command) == nil else { return }
        var recent = recentCommands.filter { $0 != command.rawValue }; recent.insert(command.rawValue, at: 0)
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(recent.prefix(12))).write(to: storage.appendingPathComponent("Commands.json"), options: .atomic)
        } catch { commandWorkspace?.status = "无法记忆最近命令：\(error.localizedDescription)" }
        let w = commandWorkspace
        switch command {
        case .open: open()
        case .newPDF: newPDF()
        case .newMarkdown: newNote()
        case .newHTML: newNote(format: .html)
        case .newText: newNote(format: .plain)
        case .save: saveActive()
        case .saveAs: saveActive(asNew: true)
        case .exportPDF: exportActive()
        case .exportWord: exportWordActive()
        case .printDocument: printActive()
        case .find: w?.sidebarTab = .search; w?.find()
        case .searchFiles: showFolderSearch = true
        case .rotate: w?.rotate()
        case .extractPages: w?.exportPDF(currentOnly: true)
        case .removePages: w?.remove()
        case .blankPage: w?.insertBlankPage()
        case .annotation: w?.showAnnotationBar.toggle()
        case .signature: if let template = w?.signatures.first { w?.beginPlacing(template) }
        case .tools: w?.showTools = true
        case .table: w?.showTableExtraction = true
        case .forms: w?.showPDFForms = true
        case .ocr: w?.ocr(selectedOnly: true)
        case .scan: w?.showScanWorkshop = true
        case .compare: showDocumentComparison = true
        case .history: w?.showVersionHistory = true
        case .tasks: showTaskCenter = true
        case .switchTabs: showSwitcher = true
        case .undo: undoActive()
        case .redo: redoActive()
        }
    }
}

