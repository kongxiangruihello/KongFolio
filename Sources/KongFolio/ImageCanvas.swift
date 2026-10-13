import SwiftUI

@MainActor private final class CropDrag: ObservableObject {
    @Published var box: CGRect?
    var interactionBox: CGRect?
}
struct ImageCanvas: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var drag = CropDrag()
    private var image: NSImage? {
        if workspace.showOriginal { return workspace.originalPreview }
        return workspace.preview ?? workspace.pageDisplayImage(maxDimension: 1800)
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(workspace.cropMode ? "拖出选区 · 拖边角调整 · 框内拖动位置" : "图片编辑 · 项目保留原始页面").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("原图", isOn: $workspace.showOriginal).toggleStyle(.switch).onChange(of: workspace.showOriginal) { _, show in if show { workspace.cropMode = false; workspace.updatePreview(markDirty: false) } }
            }.padding(12)
            GeometryReader { geometry in
                if let image {
                    let available = CGSize(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 48))
                    let scale = min(available.width / max(1, image.size.width), available.height / max(1, image.size.height))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("cropCanvas")).onChanged { value in
                                guard workspace.cropMode, !workspace.showOriginal else { return }
                                drag.box = CropGeometry.selection(from: value.startLocation, to: value.location, size: size)
                            }.onEnded { _ in if let box = drag.box, box.width < 0.02 || box.height < 0.02 { drag.box = nil } })
                        if workspace.cropMode, let box = drag.box {
                            let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
                            Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect) }.fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                            Rectangle().fill(Brand.accent.opacity(0.08)).overlay(Rectangle().stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [6])))
                                .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                                .gesture(DragGesture(coordinateSpace: .named("cropCanvas")).onChanged { value in
                                    if drag.interactionBox == nil { drag.interactionBox = box }
                                    drag.box = CropGeometry.move(drag.interactionBox!, dx: value.translation.width / size.width, dy: value.translation.height / size.height)
                                }.onEnded { _ in drag.interactionBox = nil })
                            ForEach(0..<8, id: \.self) { index in handle(index, box: box, size: size) }
                        }
                    }.frame(width: size.width, height: size.height).coordinateSpace(name: "cropCanvas")
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            if workspace.cropMode {
                HStack {
                    if let box = drag.box, let image { Text("预览选区：\(Int(image.size.width * box.width)) × \(Int(image.size.height * box.height)) px").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("取消裁剪") { workspace.cropMode = false }
                    Button("确认裁剪") { if let box = drag.box { workspace.setCrop(CropGeometry.imageCoordinates(box)) } }.buttonStyle(.borderedProminent).disabled(drag.box == nil)
                }.padding(12)
            }
        }.background(Color.black.opacity(0.04))
        .onChange(of: workspace.cropMode) { _, _ in drag.box = nil; drag.interactionBox = nil }
        .onChange(of: workspace.selection) { _, _ in drag.box = nil; drag.interactionBox = nil }
    }
    private func handle(_ index: Int, box: CGRect, size: CGSize) -> some View {
        let anchors = [(-1,-1),(0,-1),(1,-1),(1,0),(1,1),(0,1),(-1,1),(-1,0)]
        let (x,y) = anchors[index]
        let point = CGPoint(x: (x < 0 ? box.minX : x > 0 ? box.maxX : box.midX) * size.width, y: (y < 0 ? box.minY : y > 0 ? box.maxY : box.midY) * size.height)
        return Circle().fill(.white).overlay(Circle().stroke(Brand.accent, lineWidth: 2)).frame(width: 15, height: 15).padding(6).contentShape(Rectangle()).position(point)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas")).onChanged { value in
                if drag.interactionBox == nil { drag.interactionBox = box }
                drag.box = CropGeometry.resize(drag.interactionBox!, anchorX: x, anchorY: y, dx: value.translation.width / size.width, dy: value.translation.height / size.height)
            }.onEnded { _ in drag.interactionBox = nil })
    }
}
