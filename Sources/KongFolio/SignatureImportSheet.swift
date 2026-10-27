import SwiftUI
import UniformTypeIdentifiers

/// Turns a photo, scan or screenshot of a signature into a transparent stamp and saves it to the library.
struct SignatureImportSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var source: CGImage?
    @State private var sourceID = UUID()
    @State private var processed: CGImage?
    @State private var options = SignatureOptions()
    @State private var name = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入图片签名").font(.title3.bold())
            PanelRow {
                Button("选择图片…") { choose() }
                Button("从剪贴板粘贴") { paste() }
                Text("支持 PNG、JPEG、HEIC、TIFF；可以是纸上签名的照片或扫描件。").font(.caption).foregroundStyle(.secondary)
            }
            preview
                .frame(height: 170)
            if source != nil {
                Toggle("去除背景（纸张变透明）", isOn: $options.removeBackground)
                if options.removeBackground {
                    Toggle("自动判断去底强度", isOn: $options.automatic)
                    if !options.automatic {
                        PanelRow {
                            Text("去底强度")
                            Slider(value: $options.threshold, in: 0.3...0.97)
                        }
                    }
                    Toggle("校正不均匀的光线（拍照时有阴影）", isOn: $options.evenOutLight)
                }
                Picker("墨迹颜色", selection: $options.tint) {
                    ForEach(InkTint.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("裁掉四周空白", isOn: $options.trim)
                TextField("名称（可留空）", text: $name)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            PanelRow {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存到签名库") { save(place: false) }.disabled(processed == nil)
                Button("保存并放置") { save(place: true) }.disabled(processed == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .adaptiveSheet(width: 520, height: 600, minimumWidth: 360)
        .task(id: SignaturePreviewKey(source: sourceID, options: options)) { await reprocess() }
    }

    private var preview: some View {
        ZStack {
            Checkerboard()
            if let processed {
                Image(decorative: processed, scale: 1).resizable().scaledToFit().padding(8)
            } else if source != nil {
                ProgressView()
            } else {
                Text("尚未选择图片").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = SignatureImage.load(url) else { message = "无法读取这张图片。"; return }
        use(image, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    private func paste() {
        guard let image = SignatureImage.fromClipboard() else { message = "剪贴板中没有图片。"; return }
        use(image, suggestedName: "")
    }

    private func use(_ image: CGImage, suggestedName: String) {
        message = ""
        source = image
        processed = nil
        sourceID = UUID()
        if name.isEmpty { name = suggestedName }
    }

    private func reprocess() async {
        guard let source else { processed = nil; return }
        processed = nil
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        let current = options
        let result = await Task.detached(priority: .userInitiated) { SignatureImage.process(source, options: current) }.value
        if Task.isCancelled { return }
        processed = result
        message = result == nil ? "没有找到墨迹，请降低“去底强度”或换一张更清晰的图片。" : ""
    }

    private func save(place: Bool) {
        guard let processed else { return }
        workspace.addSignatureImage(processed, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name)
        let saved = workspace.signatures.last
        dismiss()
        if place, let saved { workspace.beginPlacing(saved) }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 {
                    let dark = (row + column) % 2 == 0
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(dark ? Color(white: 0.9) : Color(white: 1)))
                }
            }
        }
    }
}

/// Library row: a thumbnail of the signature on a checkerboard.
struct SignatureThumbnail: View {
    let template: SignatureTemplate
    var body: some View {
        ZStack {
            Checkerboard()
            if let data = template.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: "signature").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
    }
}

private struct SignaturePreviewKey: Equatable { var source: UUID; var options: SignatureOptions }
