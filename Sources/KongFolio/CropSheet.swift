import SwiftUI
import PDFKit

/// Cuts white (or dark) margins off scanned pages. Settings are fractions of the page, so one setting fits every
/// page; odd and even pages can differ, as the binding side moves from left to right in a book.
struct CropSheet: View {
    @ObservedObject var workspace: Workspace

    private var margins: Binding<CropMargins> {
        Binding(get: { workspace.cropSingle ? workspace.cropPage : (workspace.cropSeparate && !PageCrop.isOddPage(workspace.selection) ? workspace.cropEven : workspace.cropOdd) },
                set: { value in
                    if workspace.cropSingle { workspace.cropPage = value; return }
                    if workspace.cropSeparate && !PageCrop.isOddPage(workspace.selection) { workspace.cropEven = value } else { workspace.cropOdd = value }
                    if !workspace.cropSeparate { workspace.cropEven = value }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.cropAutoPreview ? "清除空白边" : "裁剪页面").font(.title2.bold())
            HStack(alignment: .top, spacing: 18) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("逐页微调", isOn: Binding(get: { workspace.cropSingle }, set: { workspace.setCropSingle($0) }))
                    if workspace.cropSingle {
                        HStack {
                            Button { workspace.stepCropPage(-1) } label: { AppIcon("chevron.left") }.disabled(workspace.selection == 0)
                            Text("第 \(workspace.selection + 1) / \(workspace.count) 页").font(.callout.monospacedDigit())
                            Button { workspace.stepCropPage(1) } label: { AppIcon("chevron.right") }.disabled(workspace.selection >= workspace.count - 1)
                            Spacer()
                            Button("裁这一页") { workspace.applyCropToCurrentPage() }
                        }
                        Text("当前调整只用于本页。点「裁这一页」后，可以接着翻到下一页。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("范围", selection: $workspace.cropScope) { ForEach(CropScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                            .onChange(of: workspace.cropScope) {
                                if workspace.cropAutoPreview { workspace.detectCrop() }
                            }
                        Toggle("奇数页和偶数页分开设置", isOn: $workspace.cropSeparate)
                    }
                    if workspace.cropSeparate && !workspace.cropSingle {
                        Text("当前预览的是第 \(workspace.selection + 1) 页（\(PageCrop.isOddPage(workspace.selection) ? "奇数页" : "偶数页")），当前调整只用于这一组。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    slider("左", \.left)
                    slider("右", \.right)
                    slider("上", \.top)
                    slider("下", \.bottom)
                    HStack {
                        Button(workspace.cropDetecting ? "检测中…" : "自动检测内容边界") { if workspace.cropSingle { workspace.detectCropPage() } else { workspace.detectCrop() } }.disabled(workspace.cropDetecting)
                        if workspace.cropDetecting { ProgressView().controlSize(.small) }
                    }
                    if !workspace.cropMessage.isEmpty { Text(workspace.cropMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(width: 250)
                .disabled(workspace.cropDetecting)
            }
            Text("拖动裁剪框的边或角调整范围，拖动框内可移动选区。")
                .font(.caption).foregroundStyle(.secondary)
            Text("只改变显示的范围，页面内容不会被删掉；可以撤销，也可以用“恢复完整页面”还原。含文字层的页面，文字层保持不变。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !workspace.cropSingle { Button("取消") { workspace.showCrop = false }.keyboardShortcut(.cancelAction) }
                Button(workspace.cropSingle ? "恢复本页完整" : "恢复完整页面") {
                    if workspace.cropSingle { workspace.cropPage = .zero; workspace.applyCropToCurrentPage() } else { workspace.resetCrop() }
                }
                .disabled(workspace.cropDetecting)
                Spacer()
                if workspace.cropSingle {
                    Button("完成") { workspace.showCrop = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Text("将处理 \(workspace.cropTargets.count) 页").font(.callout).foregroundStyle(.secondary)
                    Button("应用裁剪") { workspace.applyCrop() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(workspace.cropDetecting)
                }
            }
        }
        .padding(24)
        .adaptiveSheet(width: 600, height: 600, flexibleHeight: true)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<CropMargins, Double>) -> some View {
        HStack {
            Text(title).frame(width: 18)
            Slider(value: Binding(get: { margins.wrappedValue[keyPath: key] }, set: { value in
                var updated = margins.wrappedValue
                updated[keyPath: key] = value
                margins.wrappedValue = updated.clamped
            }), in: 0...CropMargins.limit)
            Text("\(Int((margins.wrappedValue[keyPath: key] * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
        }
    }

    private var preview: some View {
        ZStack {
            if let page = workspace.document.page(at: workspace.selection) {
                CropPagePreview(page: page, revision: workspace.revision,
                                editing: !workspace.cropDetecting, margins: margins)
                    .id(ObjectIdentifier(page))
            } else {
                Rectangle().fill(Color.secondary.opacity(0.1))
            }
        }
        .frame(width: 280, height: 380)
        .border(Color.secondary.opacity(0.4))
    }
}
