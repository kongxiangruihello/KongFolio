import SwiftUI

struct EditorImagePane: View {
    @ObservedObject var note:MarkdownNote
    let source:String;let selection:NSRange
    @Environment(\.dismiss) private var dismiss
    @State private var selected:Int?
    @State private var data:Data?
    @State private var transform = EditorImageTransform()
    @State private var caption = ""
    @State private var message = ""
    @State private var previewData:Data?
    private var images:[EditorImage] { EditorImage.list(source,format:note.format) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("选择图片后设置裁剪区域与输出宽度，再预览。处理生成新图片，原图随文件资源保留。宽度单位为排版点，超出页面时会自动缩小。").font(.caption)
            Picker("图片",selection:$selected) { Text("选择正文图片").tag(nil as Int?);ForEach(Array(images.enumerated()),id:\.element.id) { i,image in Text("\(i+1). "+String(image.reference.suffix(70))).tag(image.id as Int?) } }
            HSplitView {
                VStack(alignment:.leading,spacing:10) {
                    Text("裁剪区域：0～1 的比例，横向从左、纵向从上计算").font(.caption)
                    HStack { field("左",$transform.x);field("上",$transform.y) }
                    HStack { field("宽",$transform.width);field("高",$transform.height) }
                    TextField("输出宽度（16～2000）",value:$transform.outputWidth,format:.number)
                    TextField("图题（可留空）",text:$caption)
                    Button("替换成另一张图片…") { let p = NSOpenPanel();p.allowedContentTypes = [.image];if p.runModal() == .OK,let u = p.url { do { data = try TextMedia.read(u.absoluteString,baseURL:nil);previewData = nil;message = "已选择替换图片，请预览" } catch { message = error.localizedDescription } } }
                    Button("预览处理效果") { render() }
                    Text(message).font(.caption).foregroundStyle(.orange)
                }.frame(minWidth:230)
                Group { if let bytes = previewData ?? data,let image = NSImage(data:bytes) { Image(nsImage:image).resizable().scaledToFit() } else { Text("暂无图片") } }.frame(minWidth:200,minHeight:250,maxHeight:400)
            }
            HStack { Spacer();Button("采用图片修改") { apply() }.disabled(note.readOnly || data == nil || selected == nil) }
        }.onAppear { selected = images.first(where:{NSLocationInRange(selection.location,$0.range)})?.id ?? images.first?.id;load() }.onChange(of:selected) { _,_ in load() }
    }
    private func field(_ title:String,_ value:Binding<Double>)->some View { TextField(title,value:value,format:.number.precision(.fractionLength(0...3))).textFieldStyle(.roundedBorder).help(title) }
    private func load() { previewData = nil;transform = EditorImageTransform();caption = "";data = nil;guard let image = images.first(where:{$0.id == selected}) else { message = "请先在正文中插入本地图片";return };caption = image.caption;do { data = try TextMedia.read(image.reference,baseURL:note.fileURL?.deletingLastPathComponent() ?? note.recoveryBaseURL);message = "" } catch { message = error.localizedDescription } }
    private func render() { do { if let data { previewData = try transform.png(data);message = "处理效果已更新；原图保留" } } catch { message = error.localizedDescription } }
    private func apply() { guard let image = images.first(where:{$0.id == selected}),let data else { return };do { try note.editImage(image,source:source,data:data,transform:transform,caption:caption);dismiss() } catch { message = error.localizedDescription } }
}
