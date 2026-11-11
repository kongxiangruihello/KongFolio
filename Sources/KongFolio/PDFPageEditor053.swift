import SwiftUI

struct PDFPageEditor053:View {
    @ObservedObject var workspace:Workspace
    @State private var deleteConfirmation=false
    @State private var imageWidth = ""
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("共 \(workspace.count) 页 · 已选 \(workspace.effectivePages.count) 页").font(.callout)
            if workspace.readingLocked {
                Text("当前处于阅读模式。切换后可以增删和排列页面。").font(.caption).foregroundStyle(.secondary)
                Button("切换为编辑模式") { workspace.toggleReadingLock() }
            }
            Group {
                Menu {
                    Button("放到当前页面…") { workspace.choosePageImage() }
                    Button("插入为新页面…") { workspace.open(insert:true,imagesOnly:true) }
                } label: { Label("导入图片",systemImage:"photo.badge.plus") }
                Menu("增加页面") {
                    Button("在当前页后增加空白页") { workspace.insertBlankPage() }
                    Button("在当前页前增加空白页") { workspace.insertBlankPage(before:true) }
                    Button("从 PDF 或图片插入…") { workspace.open(insert:true) }
                }
                HStack { Button("前移") { workspace.move(-1) };Button("后移") { workspace.move(1) } }
                HStack { Button("复制页") { workspace.duplicatePages() };Button("旋转") { workspace.rotate() } }
                Button("删除所选页面…",role:.destructive) { deleteConfirmation=true }.disabled(workspace.effectivePages.count>=workspace.count)
            }.disabled(workspace.readingLocked || workspace.busy || workspace.placingSignature != nil)
            if workspace.placingSignature?.isPageImage == true {
                Text("拖动图片或拖角等比缩放。").font(.caption).foregroundStyle(.secondary)
                HStack(spacing:6) {
                    Text("宽度")
                    TextField("毫米",text:$imageWidth).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("图片宽度（毫米）").onSubmit(applyImageWidth)
                    Text("毫米").font(.caption)
                    Button("应用",action:applyImageWidth).disabled(imageWidthMillimetres == nil)
                }
                HStack {
                    Button("放置图片") { workspace.confirmSignaturePlacement() }.buttonStyle(.borderedProminent)
                    Button("取消") { workspace.cancelSignaturePlacement() }
                }
            }
            Text("按住 ⌘ 可选择多页。页面修改会自动保存，可用撤销恢复。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(0..<workspace.count,id:\.self) { i in
                    Button {
                        if NSEvent.modifierFlags.contains(.command) {
                            if workspace.selectedPages.contains(i) { workspace.selectedPages.remove(i) } else { workspace.selectedPages.insert(i) }
                            if workspace.selectedPages.isEmpty { workspace.selectedPages=[i] }
                        } else { workspace.selectPage(i);workspace.selectedPages=[i] }
                    } label:{ HStack { Image(systemName:workspace.selectedPages.contains(i) ? "checkmark.circle.fill":"circle");Text("第 \(i+1) 页");Spacer();if i==workspace.selection { Image(systemName:"eye") } } }.buttonStyle(.plain)
                }
            }.disabled(workspace.placingSignature?.isPageImage == true)
        }.padding(10)
        .onChange(of:workspace.pageImageWidthPoints,initial:true) { _,width in
            updateWidthText(width)
        }
        .confirmationDialog("删除 \(workspace.effectivePages.count) 页？",isPresented:$deleteConfirmation) { Button("删除页面",role:.destructive) { workspace.remove() } }
    }

    private var imageWidthMillimetres: Double? {
        guard let value = try? Double(imageWidth,format:.number), value.isFinite, value > 0 else { return nil }
        return value
    }

    private func applyImageWidth() {
        guard let width = imageWidthMillimetres else { return }
        workspace.setPageImageWidth(width*72/25.4)
        updateWidthText(workspace.pageImageWidthPoints)
    }

    private func updateWidthText(_ width:Double?) {
        imageWidth = width.map { ($0*25.4/72).formatted(.number.precision(.fractionLength(2))) } ?? ""
    }
}
