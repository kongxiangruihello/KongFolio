import SwiftUI
import PDFKit

actor ThumbnailRenderer {
    static let shared = ThumbnailRenderer()
    func render(_ data: Data) throws -> CGImage {
        try Task.checkCancellation()
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { throw FolioError(message: "缩略图读取失败") }
        return try DocumentServices.render(page, maxDimension: 310)
    }
}
@MainActor final class ThumbnailState: ObservableObject { @Published var image: NSImage? }
struct ThumbnailView: View {
    @ObservedObject var workspace: Workspace
    let index: Int
    @StateObject private var state = ThumbnailState()
    var body: some View {
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.quaternary).overlay(Image(systemName: "doc").foregroundStyle(.secondary)) }
        }.frame(height: 140).shadow(color: .black.opacity(0.1), radius: 3)
        .task(id: "\(workspace.revision)-\(index)") {
            let key = "\(workspace.revision)-\(index)"
            if let cached = workspace.thumbnails.image(for: key) { state.image = cached; return }
            state.image = nil
            guard let data = DocumentServices.subset(workspace.document, indexes: [index]).dataRepresentation() else { return }
            do {
                let cg = try await ThumbnailRenderer.shared.render(data); try Task.checkCancellation()
                let image = NSImage(cgImage: cg, size: .zero)
                workspace.thumbnails.put(image, key: key, cost: cg.width * cg.height * 4); state.image = image
            } catch { }
        }
    }
}
