import SwiftUI

struct ReadingRulerControls: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("阅读尺与竖向跟读").font(.headline)
            Toggle("显示阅读尺（可在页面上拖动）",isOn:$workspace.readingRuler.enabled)
            Picker("方向",selection:$workspace.readingRuler.direction) { ForEach(ReadingRuler.Direction.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            HStack { Text("位置"); Slider(value:$workspace.readingRuler.position,in:0...1); Button("前移") { workspace.readingRuler.move(-0.04) }; Button("后移") { workspace.readingRuler.move(0.04) } }
            HStack { Text("宽度"); Slider(value:$workspace.readingRuler.thickness,in:0.01...0.3); Text("透明度"); Slider(value:$workspace.readingRuler.opacity,in:0.05...0.8) }
            Text("设置随每本书保存；阅读尺只影响屏幕显示，不写入 PDF 或打印结果。").font(.caption)
        }.onAppear { workspace.loadReadingRulerIfNeeded() }
    }
}
