import SwiftUI
import PDFKit

/// Cuts white (or dark) margins off scanned pages. Settings are fractions of the page, so one setting fits every
/// page; odd and even pages can differ, as the binding side moves from left to right in a book.
struct CropSheet: View {
    @ObservedObject var workspace: Workspace

    private var margins: Binding<CropMargins> {
        Binding(get: { workspace.cropSeparate && !PageCrop.isOddPage(workspace.selection) ? workspace.cropEven : workspace.cropOdd },
                set: { value in
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
                    Picker("范围", selection: $workspace.cropScope) { ForEach(CropScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Toggle("奇数页和偶数页分开设置", isOn: $workspace.cropSeparate)
                    if workspace.cropSeparate {
                        Text("当前预览的是第 \(workspace.selection + 1) 页（\(PageCrop.isOddPage(workspace.selection) ? "奇数页" : "偶数页")），拖动滑杆只改这一组。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    slider("左", \.left)
                    slider("右", \.right)
                    slider("上", \.top)
                    slider("下", \.bottom)
                    HStack {
                        Button(workspace.cropDetecting ? "检测中…" : "自动检测内容边界") { workspace.detectCrop() }.disabled(workspace.cropDetecting)
                        if workspace.cropDetecting { ProgressView().controlSize(.small) }
                    }
                    if !workspace.cropMessage.isEmpty { Text(workspace.cropMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(width: 250)
            }
            Text("只改变显示的范围，页面内容不会被删掉；可以撤销，也可以用“恢复完整页面”还原。含文字层的页面，文字层保持不变。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { workspace.showCrop = false }.keyboardShortcut(.cancelAction)
                Button("恢复完整页面") { workspace.resetCrop() }
                Spacer()
                Text("将处理 \(workspace.cropTargets.count) 页").font(.callout).foregroundStyle(.secondary)
                Button("应用裁边") { workspace.applyCrop() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
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
                        let w = proxy.size.width, h = proxy.size.height
                        Path { path in
                            path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                            path.addRect(CGRect(x: m.left * w, y: m.top * h, width: w * (1 - m.left - m.right), height: h * (1 - m.top - m.bottom)))
                        }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                            .frame(width: w * (1 - m.left - m.right), height: h * (1 - m.top - m.bottom))
                            .position(x: m.left * w + w * (1 - m.left - m.right) / 2, y: m.top * h + h * (1 - m.top - m.bottom) / 2)
                    })
            } else {
                Rectangle().fill(Color.secondary.opacity(0.1))
            }
        }
        .frame(width: 280, height: 380)
        .border(Color.secondary.opacity(0.4))
    }
}
