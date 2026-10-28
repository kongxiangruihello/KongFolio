import SwiftUI
import PDFKit

struct FormTemplateSheet: View {
    @ObservedObject var workspace: Workspace
    @State private var template = FormTemplate(name: "我的表单", pageSize: CGSize(width: 595, height: 842))
    @State private var saved: [FormTemplate] = []
    @State private var chosen: UUID?
    @State private var selected: UUID?
    @State private var kind = FormTemplateField.Kind.text
    @State private var fieldName = "字段1"
    @State private var image: CGImage?
    @State private var message = ""
    @State private var working = false
    @State private var page = 0
    @State private var sourceRevision = UUID()
    @State private var targetPages = ""
    @State private var aligned = Set<UUID>()
    @State private var candidates: [FormFieldCandidate] = []
    @State private var selectedCandidates = Set<UUID>()
    @State private var worker: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描表单模板 · 第 \(page + 1) 页").font(.title2.bold())
            Text("在扫描表格上框选输入框或勾选框，拖动字段移动，拖动右下角缩放；空白处框选新增。模板不记录填写值。").font(.caption).foregroundStyle(.secondary)
            Picker("已保存模板", selection: $chosen) {
                Text("新建模板").tag(nil as UUID?)
                ForEach(saved) { Text($0.name).tag($0.id as UUID?) }
            }.onChange(of: chosen) { _, value in if let next = saved.first(where: { $0.id == value }) { template = next; selected = nil } }
            TextField("模板名称", text: $template.name).textFieldStyle(.roundedBorder)
            PanelRow {
                Picker("字段类型", selection: $kind) { ForEach(FormTemplateField.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                TextField("下一个字段名称", text: $fieldName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("添加字段") { addField(CGRect(x: 0.15, y: 0.3, width: kind == .text ? 0.4 : 0.06, height: 0.06)) }
                Button("自动检测候选框") { detect() }.disabled(working || image == nil)
                Button("删除选中字段") { template.fields.removeAll { $0.id == selected }; selected = nil }.disabled(selected == nil)
            }
            if working { ProgressView("正在后台读取页面…"); Button("取消读取") { worker?.cancel(); working = false } }
            if let image {
                FormTemplateCanvas(image: image, fields: template.fields, candidates: candidates.filter { selectedCandidates.contains($0.id) }, selected: $selected, change: { id, rect in updateField(id) { $0.rect = rect } }, add: addField).frame(height: 350)
            }
            if !candidates.isEmpty {
                DisclosureGroup("检测到 \(candidates.count) 个候选框，请核对后添加") {
                    ScrollView { ForEach(candidates) { item in Toggle("\(item.kind.rawValue) · 左 \(Int(item.rect.minX*100))% / 上 \(Int(item.rect.minY*100))%", isOn: Binding(get: { selectedCandidates.contains(item.id) }, set: { on in if on { selectedCandidates.insert(item.id) } else { selectedCandidates.remove(item.id) } })) } }.frame(height: 100)
                    Button("添加选中的候选框") { addCandidates() }
                    Text("候选框基于本地形状与空白线检测，可能漏检或把表格边框当作字段；添加后仍可调整位置。").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("多字段对齐") {
                ScrollView { ForEach(template.fields) { field in Toggle(field.name, isOn: Binding(get: { aligned.contains(field.id) }, set: { on in if on { aligned.insert(field.id) } else { aligned.remove(field.id) } })) } }.frame(height: 90)
                PanelRow { ForEach(FormTemplateTools.Alignment.allCases, id: \.self) { mode in Button(mode.rawValue) { do { try FormTemplateTools.align(&template, ids: aligned, mode: mode) } catch { message = error.localizedDescription } }.disabled(aligned.count < 2) } }
            }
            if let field = template.fields.first(where: { $0.id == selected }) {
                TextField("选中字段名称", text: Binding(get: { template.fields.first(where: { $0.id == field.id })?.name ?? "" }, set: { value in updateField(field.id) { $0.name = value } })).textFieldStyle(.roundedBorder)
                PanelRow {
                    rectField("左", value: field.rect.minX) { value in updateField(field.id) { $0.rect.origin.x = value } }
                    rectField("上", value: field.rect.minY) { value in updateField(field.id) { $0.rect.origin.y = value } }
                    rectField("宽", value: field.rect.width) { value in updateField(field.id) { $0.rect.size.width = value } }
                    rectField("高", value: field.rect.height) { value in updateField(field.id) { $0.rect.size.height = value } }
                }
            }
            TextField("应用页码：留空为当前页，例如 1-3, 5", text: $targetPages).textFieldStyle(.roundedBorder)
            Text("已添加 \(template.fields.count) 个字段。点击蓝框选中，可调整名称和百分比位置。").font(.caption)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            PanelRow {
                Button("关闭") { worker?.cancel(); workspace.showFormTemplate = false }.keyboardShortcut(.cancelAction)
                Button("另存为新模板") { template.id = UUID(); chosen = nil; save() }.disabled(working)
                Button("保存模板") { save() }.disabled(working)
                Button("应用到当前页并填写") { apply() }.disabled(working || template.fields.isEmpty)
            }
        }.padding(24).adaptiveSheet(width: 760, height: 820, minimumWidth: 360, flexibleHeight: true).onAppear(perform: load).onDisappear { worker?.cancel() }
    }
    private func addField(_ rect: CGRect) {
        guard template.fields.count < 200 else { message = "最多支持 200 个字段"; return }
        let field = FormTemplateField(name: fieldName.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, rect: rect)
        template.fields.append(field); selected = field.id; fieldName = "字段\(template.fields.count + 1)"
    }
    private func updateField(_ id: UUID, change: (inout FormTemplateField) -> Void) { if let i = template.fields.firstIndex(where: { $0.id == id }) { change(&template.fields[i]) } }
    private func rectField(_ label: String, value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack { Text(label); TextField("%", value: Binding(get: { Double(value) * 100 }, set: { set(CGFloat($0 / 100)) }), format: .number.precision(.fractionLength(1))).frame(width: 58); Text("%") }
    }
    private func load() {
        page = workspace.selection; sourceRevision = workspace.revision
        do {
            saved = try FormTemplateStore.list(storage: workspace.storage)
            let data = try workspace.pdfData(), index = page; working = true
            worker = Task {
                let job = Task.detached { () throws -> (CGImage, CGSize) in
                    let document = try PDFDocument(data: data).unwrap("无法读取 PDF"), p = try document.page(at: index).unwrap("页面不存在")
                    try Task.checkCancellation(); let image = try DocumentServices.render(p, maxDimension: 1800); try Task.checkCancellation(); return (image, FormTemplate.displaySize(p))
                }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation()
                    image = result.0; template.pageSize = result.1
                } catch is CancellationError {} catch { message = error.localizedDescription }
                working = false
            }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        do { try FormTemplateStore.save(template, storage: workspace.storage); saved = try FormTemplateStore.list(storage: workspace.storage); message = "模板已保存，只包含字段名称、位置和类型" }
        catch { message = error.localizedDescription }
    }
    private func detect() {
        guard let image else { return }; working = true; message = "正在本地检测输入框和勾选框…"
        worker = Task {
            let job = Task.detached { try FormTemplateTools.detect(image) }
            do {
                let values = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation()
                candidates = values; selectedCandidates = Set(values.map(\.id)); message = values.isEmpty ? "没有检测到候选框，可手动添加" : "候选框尚未应用，请展开列表核对后添加"
            } catch is CancellationError {} catch { message = error.localizedDescription }
            working = false
        }
    }
    private func addCandidates() {
        for candidate in candidates where selectedCandidates.contains(candidate.id) && template.fields.count < 200 {
            if !template.fields.contains(where: { $0.rect.intersection(candidate.rect).width * $0.rect.intersection(candidate.rect).height > candidate.rect.width * candidate.rect.height * 0.75 }) {
                var number = template.fields.count + 1
                while template.fields.contains(where: { $0.name == "识别字段\(number)" }) { number += 1 }
                template.fields.append(FormTemplateField(name: "识别字段\(number)", kind: candidate.kind, rect: candidate.rect))
            }
        }
        candidates = []; selectedCandidates = []; message = "已加入候选字段，可拖动、缩放并保存模板"
    }
    private func apply() {
        do {
            let pages: [Int]
            if targetPages.trimmingCharacters(in: .whitespaces).isEmpty { pages = [page] }
            else { pages = try PageSpan.parse(targetPages, pageCount: workspace.count).unwrap("应用页码无效") }
            try workspace.applyFormTemplate(template, pages: pages, from: sourceRevision)
            workspace.showFormTemplate = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { workspace.showPDFForms = true }
        } catch { message = error.localizedDescription }
    }
}
private struct FormTemplateCanvas: View {
    var image: CGImage
    var fields: [FormTemplateField]
    var candidates: [FormFieldCandidate] = []
    @Binding var selected: UUID?
    var change: (UUID, CGRect) -> Void
    var add: (CGRect) -> Void
    @State private var moving: CGRect?
    @State private var resizing: CGRect?
    @State private var rubber: CGRect?
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height)), w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                ForEach(candidates) { candidate in
                    Rectangle().stroke(.orange,style:StrokeStyle(lineWidth:1.5,dash:[5])).frame(width:candidate.rect.width*w,height:candidate.rect.height*h).offset(x:candidate.rect.minX*w,y:candidate.rect.minY*h).allowsHitTesting(false)
                }
                ForEach(fields) { field in
                    Rectangle().fill(.blue.opacity(selected == field.id ? 0.25 : 0.1)).overlay(Rectangle().stroke(.blue, lineWidth: selected == field.id ? 2 : 1))
                        .overlay(alignment: .topLeading) { Text(field.name).font(.system(size: 10)).lineLimit(1) }
                        .frame(width: field.rect.width * w, height: field.rect.height * h).offset(x: field.rect.minX * w, y: field.rect.minY * h)
                        .onTapGesture { selected = field.id }
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            if moving == nil { moving = field.rect }; selected = field.id
                            change(field.id, FormTemplateTools.moved(moving ?? field.rect, dx: value.translation.width/w, dy: value.translation.height/h))
                        }.onEnded { _ in moving = nil })
                    if selected == field.id {
                        Rectangle().fill(.blue).frame(width: 12,height: 12).offset(x: field.rect.maxX*w-6,y:field.rect.maxY*h-6)
                            .gesture(DragGesture(minimumDistance:1).onChanged { value in
                                if resizing == nil { resizing = field.rect }
                                change(field.id, FormTemplateTools.resized(resizing ?? field.rect,dw:value.translation.width/w,dh:value.translation.height/h))
                            }.onEnded { _ in resizing = nil }).help("拖动缩放字段")
                    }
                }
                if let rubber { Rectangle().stroke(.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4])).frame(width: rubber.width * w, height: rubber.height * h).offset(x: rubber.minX * w, y: rubber.minY * h).allowsHitTesting(false) }
            }.frame(width: w, height: h).contentShape(Rectangle()).simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in if !fields.contains(where: { $0.rect.contains(CGPoint(x:value.startLocation.x/w,y:value.startLocation.y/h)) }) { rubber = rect(value, w: w, h: h) } }.onEnded { value in let wasDrawing = rubber != nil; let next = rect(value, w: w, h: h); rubber = nil; if wasDrawing && TableGrid.validRect(next) { add(next) } }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.gray.opacity(0.1))
    }
    private func rect(_ value: DragGesture.Value, w: CGFloat, h: CGFloat) -> CGRect {
        let a = CGPoint(x: min(1, max(0, value.startLocation.x / w)), y: min(1, max(0, value.startLocation.y / h))), b = CGPoint(x: min(1, max(0, value.location.x / w)), y: min(1, max(0, value.location.y / h)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
