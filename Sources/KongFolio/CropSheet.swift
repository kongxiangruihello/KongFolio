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
            Text("裁边").font(.title2.bold())
            HStack(alignment: .top, spacing: 18) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("逐页微调", isOn: Binding(get: { workspace.cropSingle }, set: { workspace.setCropSingle($0) }))
                    if workspace.cropSingle {
                        HStack {
                            Button { workspace.stepCropPage(-1) } label: { Image(systemName: "chevron.left") }.disabled(workspace.selection == 0)
                            Text("第 \(workspace.selection + 1) / \(workspace.count) 页").font(.callout.monospacedDigit())
                            Button { workspace.stepCropPage(1) } label: { Image(systemName: "chevron.right") }.disabled(workspace.selection >= workspace.count - 1)
                            Spacer()
                            Button("裁这一页") { workspace.applyCropToCurrentPage() }
                        }
                        Text("滑杆只改当前页；点“裁这一页”后窗口保持打开，可以接着翻到下一页。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("范围", selection: $workspace.cropScope) { ForEach(CropScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        Toggle("奇数页和偶数页分开设置", isOn: $workspace.cropSeparate)
                    }
                    if workspace.cropSeparate && !workspace.cropSingle {
                        Text("当前预览的是第 \(workspace.selection + 1) 页（\(PageCrop.isOddPage(workspace.selection) ? "奇数页" : "偶数页")），拖动滑杆只改这一组。")
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
            }
            Text("只改变显示的范围，页面内容不会被删掉；可以撤销，也可以用“恢复完整页面”还原。含文字层的页面，文字层保持不变。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !workspace.cropSingle { Button("取消") { workspace.showCrop = false }.keyboardShortcut(.cancelAction) }
                Button(workspace.cropSingle ? "恢复本页完整" : "恢复完整页面") {
                    if workspace.cropSingle { workspace.cropPage = .zero; workspace.applyCropToCurrentPage() } else { workspace.resetCrop() }
                }
                Spacer()
                if workspace.cropSingle {
                    Button("完成") { workspace.showCrop = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Text("将处理 \(workspace.cropTargets.count) 页").font(.callout).foregroundStyle(.secondary)
                    Button("应用裁边") { workspace.applyCrop() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .adaptiveSheet(width: 600, height: 600, flexibleHeight: true)
    }

    /// The part of a preview of the given size that stays after the cut (the top-left origin of SwiftUI).
    private static func keptArea(_ margins: CropMargins, in size: CGSize) -> CGRect {
        let left = CGFloat(margins.left) * size.width, right = CGFloat(margins.right) * size.width
        let top = CGFloat(margins.top) * size.height, bottom = CGFloat(margins.bottom) * size.height
        return CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
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

    /// The whole page with the part that will be cut shaded.
    private var preview: some View {
        let page = workspace.document.page(at: workspace.selection)
        let image = page?.thumbnail(of: CGSize(width: 300, height: 400), for: .mediaBox)
        let m = margins.wrappedValue.clamped
        return ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .overlay(GeometryReader { proxy in
                        let kept = Self.keptArea(m, in: proxy.size)
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: proxy.size))
                            path.addRect(kept)
                        }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                            .frame(width: kept.width, height: kept.height)
                            .position(x: kept.midX, y: kept.midY)
                    })
            } else {
                Rectangle().fill(Color.secondary.opacity(0.1))
            }
        }
        .frame(width: 280, height: 380)
        .border(Color.secondary.opacity(0.4))
    }
}
