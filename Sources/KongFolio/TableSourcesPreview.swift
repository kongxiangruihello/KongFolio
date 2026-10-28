import SwiftUI
import PDFKit
struct TableSourcesPreview: View {
    var source: Data
    var regions: [TableSourceRegion]
    @State private var chosen = 0
    @State private var left: CGImage?
    @State private var right: CGImage?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading) {
            Picker("对照来源页", selection: $chosen) { ForEach(regions.indices, id: \.self) { Text("第 \(regions[$0].page + 1) 页").tag($0) } }
            Text("左侧为表格起始页，右侧为所选来源页；蓝框显示实际提取范围。").font(.caption).foregroundStyle(.secondary)
            PanelRow {
                if let left { picture(left, rect: regions.first?.rect ?? .zero) }
                if let right, regions.indices.contains(chosen) { picture(right, rect: regions[chosen].rect) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task(id: chosen) {
            let index = min(chosen, max(0,regions.count-1)), data = source, items = regions
            do {
                let job = Task.detached { () throws -> (CGImage, CGImage) in
                    let document = try PDFDocument(data: data).unwrap("来源页无法读取")
                    let first = try items.first.unwrap("来源范围为空"), other = items[index]
                    try Task.checkCancellation()
                    return (try DocumentServices.render(try document.page(at: first.page).unwrap("来源页不存在"), maxDimension: 1200), try DocumentServices.render(try document.page(at: other.page).unwrap("来源页不存在"), maxDimension: 1200))
                }
                let images = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }); try Task.checkCancellation(); left = images.0; right = images.1
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
    private func picture(_ image: CGImage, rect: CGRect) -> some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).overlay {
            GeometryReader { proxy in Rectangle().stroke(.blue, lineWidth: 1.5).frame(width: proxy.size.width * rect.width, height: proxy.size.height * rect.height).offset(x: proxy.size.width * rect.minX, y: proxy.size.height * rect.minY) }
        }.frame(maxWidth: 330, maxHeight: 300)
    }
}
