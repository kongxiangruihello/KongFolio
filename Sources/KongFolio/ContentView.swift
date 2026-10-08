import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    private let tools = ["Merge PDFs", "Compress PDF", "OCR PDF", "Images → PDF", "PDF → Images", "Scan Document", "Sign PDF", "Compare PDFs"]
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 150, idealWidth: 180, maxWidth: 230)
                canvas.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(minWidth: 260, idealWidth: 280, maxWidth: 330)
            }
            Divider()
            HStack {
                Circle().fill(workspace.busy ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(workspace.status)
                Spacer()
                if workspace.count > 0 { Text("\(workspace.selection + 1) / \(workspace.count) 页") }
                Text(workspace.recoveryStatus).foregroundStyle(.secondary)
                if workspace.canRetry { Button("重试任务") { workspace.retryJob() } }
                Text("KongFolio 0.3").foregroundStyle(.tertiary)
            }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(workspace.busy)
        .overlay { if workspace.busy {
            VStack(spacing: 16) { ProgressView(workspace.taskLabel, value: workspace.progress, total: 1).frame(width: 260)
                if workspace.activeJob != nil || workspace.cancelAuxiliary != nil { Button("取消任务") { workspace.cancelJob() } }
            }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } }
        .alert("无法完成操作", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) { Button("好") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
        .sheet(isPresented: $workspace.showExport) { ExportSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showOCRReview) { OCRReview(workspace: workspace) }
        .sheet(isPresented: $workspace.showTools) { quickTools }
        .sheet(isPresented: $workspace.showImportOrder) { importOrder }
        .sheet(isPresented: Binding(get: { workspace.comparison != nil }, set: { if !$0 { workspace.comparison = nil } })) {
            VStack {
                HStack { Text("Compare PDFs · 双栏阅读比对").font(.headline); Spacer(); Button("完成") { workspace.comparison = nil } }.padding()
                HSplitView { ComparisonCanvas(document: workspace.document); if let other = workspace.comparison { ComparisonCanvas(document: other) } }
            }.frame(width: 1040, height: 720)
        }
        .onChange(of: workspace.mode) { _, _ in workspace.resetImage(); workspace.scheduleRecovery() }
    }
    private var topBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("KongFolio").font(.headline)
                Text(workspace.title + (workspace.dirty ? " •" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 175, alignment: .leading)
            Picker("模式", selection: $workspace.mode) { Text("Document").tag("Document"); Text("Image").tag("Image") }.pickerStyle(.segmented).frame(width: 210)
            Spacer()
            Button { workspace.showTools = true } label: { Label("Quick Tools", systemImage: "square.grid.2x2") }
            Menu {
                Button("打开文档或项目…") { workspace.open() }
                if !workspace.recentFiles.isEmpty { Divider(); ForEach(workspace.recentFiles, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { workspace.load([URL(fileURLWithPath: path)]) }.help(path) } }
            } label: { Label("打开", systemImage: "folder") }
            Button("保存") { workspace.saveProject() }.disabled(workspace.count == 0).help("保存 KongFolio 项目（⌘S）")
            Menu {
                Button("PDF · 全部页面") { workspace.exportPDF() }
                Button("PDF · 提取选中页") { workspace.exportPDF(currentOnly: true) }
                Divider()
                Button("JPG · 当前页") { workspace.exportImage(.jpeg, suffix: "jpg") }
                Button("PNG · 当前页") { workspace.exportImage(.png, suffix: "png") }
                Button("TIFF · 当前页") { workspace.exportImage(.tiff, suffix: "tiff") }
                Button("PNG · 全部页面") { workspace.exportBatch(split: false) }
                Divider()
                Button("TXT") { workspace.exportText(markdown: false) }
                Button("Markdown · 全文") { workspace.exportText(markdown: true) }
                Button("Markdown · 摘录与笔记") { workspace.exportNotes() }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(workspace.count == 0)
        }.padding(16)
    }
    private var sidebar: some View {
        VStack(spacing: 8) {
            Picker("导航", selection: $workspace.sidebarTab) { ForEach(["页面", "目录", "书签", "搜索", "摘录"], id: \.self) { Text($0) } }.labelsHidden().padding(.horizontal, 12).padding(.top, 12)
            if workspace.sidebarTab == "页面" { pagesSidebar } else { ReadingSidebar(workspace: workspace) }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var pagesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("页面").font(.headline); Spacer(); Text("\(workspace.count)").foregroundStyle(.secondary) }.padding(.horizontal, 14).padding(.top, 16)
            Text("⌘ 多选 · ⇧ 连选 · 拖动排序").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<workspace.count, id: \.self) { index in
                        Button { workspace.selectPage(index, modifiers: NSEvent.modifierFlags) } label: {
                            VStack(spacing: 6) {
                                ThumbnailView(workspace: workspace, index: index)
                                Text("\(index + 1)").font(.caption).monospacedDigit()
                            }.padding(10).frame(maxWidth: .infinity).background(workspace.selectedPages.contains(index) ? Color.teal.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        .draggable("KongFolio:\(index)")
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, value.hasPrefix("KongFolio:"), let source = Int(value.dropFirst(10)) else { return false }
                            workspace.movePages(before: index, dragged: source); return true
                        }
                    }
                }.padding(.horizontal, 12)
            }
            HStack { Button { workspace.move(-1) } label: { Image(systemName: "arrow.up") }.disabled(workspace.effectivePages.first == 0); Button { workspace.move(1) } label: { Image(systemName: "arrow.down") }.disabled(workspace.effectivePages.last == workspace.count - 1); Spacer(); Button { workspace.open(insert: true) } label: { Image(systemName: "plus") } }.padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var canvas: some View {
        if workspace.count == 0 {
            VStack(spacing: 20) {
                Image(systemName: "doc.richtext").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.teal)
                Text("每一页，都井井有条。").font(.system(size: 28, weight: .medium))
                Text("PDF、图片与扫描文档的个人工作台").foregroundStyle(.secondary)
                Button("打开文档或图片…") { workspace.open() }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                Text("PDF · JPG · PNG · HEIC · TIFF").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.mode == "Image" {
            ImageCanvas(workspace: workspace)
        } else { PDFCanvas(workspace: workspace) }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(workspace.mode == "Image" ? "图片属性" : "文档属性").font(.headline)
                HStack { Button { workspace.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.disabled(!workspace.canUndo); Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!workspace.canRedo) }
                if workspace.mode == "Document" { documentControls } else { imageControls }
                Divider()
                Text("文本识别").font(.subheadline.bold())
                Text("中英文 · 本地 Vision OCR").font(.caption).foregroundStyle(.secondary)
                HStack { Button("识别全部") { workspace.ocr() }; Button("识别选中页") { workspace.ocr(selectedOnly: true) } }.disabled(workspace.count == 0)
                Text("跳过已有文本的页面。保留页面原始内容并加入可搜索文本层；原有标注会固化。").font(.caption).foregroundStyle(.secondary)
                HStack { Button("检查当前页区域") { workspace.inspectOCR() }; if workspace.ocrRegions[workspace.selection] != nil { Button("查看") { workspace.reviewSelection = -1; workspace.showOCRReview = true } } }
                Button("重新识别选中页") { workspace.ocr(selectedOnly: true, force: true) }.disabled(!workspace.effectivePages.allSatisfy { workspace.ocrOriginals[$0] != nil })
                if !workspace.recognizedText.isEmpty { TextEditor(text: .constant(workspace.recognizedText)).font(.system(size: 11)).frame(height: 180) }
            }.padding(18)
        }.background(Color(nsColor: .controlBackgroundColor)).disabled(workspace.count == 0)
    }
    private var documentControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("阅读布局", selection: $workspace.readingLayout) { ForEach(["连续", "单页", "双页"], id: \.self) { Text($0) } }.pickerStyle(.segmented).onChange(of: workspace.readingLayout) { _, _ in workspace.scheduleRecovery() }
            HStack { Button("上一页") { workspace.selectPage(workspace.selection - 1) }.disabled(workspace.selection == 0); Button("下一页") { workspace.selectPage(workspace.selection + 1) }.disabled(workspace.selection >= workspace.count - 1); Button { workspace.addBookmark() } label: { Image(systemName: "bookmark") } }
            HStack { TextField("搜索文本", text: $workspace.search).onSubmit { workspace.find() }; Button { workspace.find() } label: { Image(systemName: "magnifyingglass") } }
            Divider()
            Text("页面管理 · 选中 \(workspace.effectivePages.count) 页").font(.subheadline.bold())
            HStack { TextField("页码：1–3, 5", text: $workspace.rangeText).onSubmit { workspace.selectRange() }; Button("选取") { workspace.selectRange() } }
            HStack { Button("全选") { workspace.selectedPages = Set(0..<workspace.count) }; Button("复制选中页") { workspace.duplicatePages() } }
            HStack { Button("旋转 90°") { workspace.rotate() }; Button("删除页面", role: .destructive) { workspace.remove() }.disabled(workspace.effectivePages.count >= workspace.count) }
            Button("插入 PDF / 图片…") { workspace.open(insert: true) }
            HStack { Button("提取选中页") { workspace.exportPDF(currentOnly: true) }; Button("拆分选中页") { workspace.exportBatch(split: true, selectedOnly: true) } }
            Divider()
            Text("标注工具").font(.subheadline.bold())
            Picker("工具", selection: $workspace.tool) { ForEach(["选择", "编辑标注", "批注", "文字框", "画笔", "箭头", "签名"], id: \.self) { Text($0) } }.labelsHidden()
            TextField("批注 / 文字框内容", text: $workspace.note, axis: .vertical).lineLimit(3...5)
            ColorPicker("标注颜色", selection: $workspace.annotationColor, supportsOpacity: false)
            if workspace.selectedAnnotation != nil {
                HStack { Button("更新标注") { workspace.updateAnnotation() }; Button("删除标注") { workspace.deleteAnnotation() } }
                HStack { Button("缩小") { workspace.resizeAnnotation(0.85) }; Button("放大") { workspace.resizeAnnotation(1.15) } }
            }
            if !workspace.currentAnnotations.isEmpty {
                DisclosureGroup("当前页标注（\(workspace.currentAnnotations.count)）") {
                    ForEach(Array(workspace.currentAnnotations.enumerated()), id: \.offset) { index, annotation in
                        Button { workspace.tool = "编辑标注"; workspace.selectAnnotation(annotation) } label: {
                            HStack { Image(systemName: workspace.selectedAnnotation === annotation ? "checkmark.circle.fill" : "circle"); Text("\(index + 1). \(annotation.contents?.prefix(24) ?? Substring(annotation.type ?? "标注"))").lineLimit(1); Spacer() }
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
            }
            DisclosureGroup("本地签名库") {
                Button("保存本页手写签名") { workspace.saveSignature() }
                ForEach(workspace.signatures) { template in HStack { Button(template.name) { workspace.insertSignature(template) }; Spacer(); Button { workspace.removeSignature(template.id) } label: { Image(systemName: "trash") } } }
            }
            Button("高亮选中文字并附加笔记") { workspace.highlight() }
            Text("点击放置标注，拖动绘制；使用“编辑标注”选中并拖动位置，也可在列表中选择。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("−") { workspace.pdfView?.zoomOut(nil); workspace.captureReadingPosition() }; Button("适合页面") { workspace.pdfView?.autoScales = true; workspace.readingScale = nil; workspace.captureReadingPosition() }; Button("+") { workspace.pdfView?.zoomIn(nil); workspace.captureReadingPosition() } }
        }
    }
    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("旋转") { workspace.adjustments.rotation += 1; workspace.updatePreview() }; Button("水平翻转") { workspace.adjustments.flip.toggle(); workspace.updatePreview() } }
            slider("亮度", value: $workspace.adjustments.brightness, range: -0.5...0.5)
            slider("对比度", value: $workspace.adjustments.contrast, range: 0.5...2)
            slider("饱和度", value: $workspace.adjustments.saturation, range: 0...2)
            slider("锐化", value: $workspace.adjustments.sharpness, range: 0...2)
            slider("倾斜校正（度）", value: $workspace.adjustments.straighten, range: -15...15)
            HStack { Button(workspace.cropMode ? "取消框选" : "鼠标选区裁剪") { workspace.showOriginal = false; if workspace.preview == nil { workspace.updatePreview(markDirty: false) }; workspace.cropMode.toggle() }; Button("清除裁剪") { workspace.adjustments.cropRect = nil; workspace.adjustments.crop = 0; workspace.updatePreview() } }
            Button("自动识别纸张与透视校正") { workspace.detectPaper() }
            Toggle("扫描增强", isOn: $workspace.adjustments.scan).onChange(of: workspace.adjustments.scan) { _, _ in workspace.updatePreview() }
            Button("黑白") { workspace.adjustments.saturation = 0; workspace.updatePreview() }
            Divider()
            Text("项目保留原始页面和调整参数。重新应用会替换当前页；导出前请先应用。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("重置参数") { workspace.resetAdjustments() }; Button("应用到页面") { workspace.applyImage() }.buttonStyle(.borderedProminent).tint(.teal).disabled(workspace.preview == nil) }
            if workspace.recipes[workspace.selection] != nil { Button("恢复原始页面") { workspace.restoreOriginalPage() } }
        }
    }
    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) { HStack { Text(name); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }.font(.caption); Slider(value: value, in: range).onChange(of: value.wrappedValue) { _, _ in workspace.updatePreview() } }
    }
    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Quick Tools").font(.title2.bold()); Spacer(); Button("关闭") { workspace.showTools = false } }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(tools, id: \.self) { tool in
                    Button { workspace.quick(tool) } label: { VStack(alignment: .leading, spacing: 8) { Text(tool).font(.headline); Text(toolDetail(tool)).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).padding(12) }.buttonStyle(.bordered)
                        .disabled(workspace.count == 0 && !["Merge PDFs", "Images → PDF", "Scan Document"].contains(tool))
                }
            }
        }.padding(24).frame(width: 650)
    }
    private var importOrder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认合并顺序").font(.title2.bold())
            Text("使用上下按钮排列文件；每个文件内部保持原页序。").foregroundStyle(.secondary)
            List {
                ForEach(Array(workspace.pendingImports.enumerated()), id: \.offset) { index, url in
                    HStack {
                        Text("\(index + 1). \(url.lastPathComponent)"); Spacer()
                        Button("↑") { workspace.pendingImports.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("↓") { workspace.pendingImports.swapAt(index, index + 1) }.disabled(index == workspace.pendingImports.count - 1)
                    }
                }
            }.frame(height: 240)
            HStack { Button("取消") { workspace.showImportOrder = false; workspace.pendingImports = [] }; Spacer(); Button("开始合并") { workspace.finishImport() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 600)
    }
    private func toolDetail(_ tool: String) -> String {
        switch tool {
        case "Merge PDFs": return "多选文件，按选择顺序插入页面"
        case "Compress PDF": return "有损图片副本；文本与标注固化"
        case "OCR PDF": return "中英文识别与可搜索文本层"
        case "Images → PDF": return "打开图片后导出为 PDF"
        case "PDF → Images": return "全部页面导出为 PNG"
        case "Scan Document": return "导入扫描图片，调整与增强"
        case "Sign PDF": return "在画布上手写签名"
        default: return "双栏独立滚动，人工阅读比对"
        }
    }
}
