import SwiftUI
import PDFKit

actor ThumbnailRenderer {
    static let shared = ThumbnailRenderer()
    func render(_ data: Data, maxDimension: CGFloat = 310) throws -> CGImage {
        try Task.checkCancellation()
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { throw FolioError(message: "缩略图读取失败") }
        let image=try autoreleasepool { try DocumentServices.render(page, maxDimension: maxDimension) }
        try Task.checkCancellation()
        return image
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
        .task(id: workspace.thumbnailKey(index)) {
            // Keyed per page: an annotation edit re-renders only its own page's thumbnail.
            let key = workspace.thumbnailKey(index)
            if let cached = workspace.thumbnails.image(for: key) { state.image = cached; return }
            state.image = nil
            do {
                // Let fast scrolling settle before serializing a page on the main actor.
                try await Task.sleep(nanoseconds:45_000_000)
                try Task.checkCancellation()
                guard let data=autoreleasepool(invoking:{ DocumentServices.subset(workspace.document,indexes:[index]).dataRepresentation() }) else { return }
                let cg = try await ThumbnailRenderer.shared.render(data,maxDimension:workspace.store?.constrainedMemory == true ? 180 : 310); try Task.checkCancellation()
                guard key==workspace.thumbnailKey(index) else { return }
                let image = NSImage(cgImage: cg, size: .zero)
                workspace.thumbnails.put(image, key: key, cost: cg.width * cg.height * 4); state.image = image
            } catch { }
        }
        .onDisappear { state.image=nil }
    }
}
