import SwiftUI
import PDFKit
import AppKit

struct ShelfBookEditor: View {
    @ObservedObject var library:BookLibrary
    let book:LibraryBook
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var topics = ""
    @State private var author = ""
    @State private var periodical = ""
    @State private var year = ""
    @State private var tags = ""
    @State private var reflection = ""
    @State private var favorite = false
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("编辑书架记录").font(.headline)
            TextField("书名",text:$title)
            HStack { TextField("作者",text:$author);TextField("刊名",text:$periodical);TextField("年代",text:$year) }
            TextField("专题，用逗号分隔",text:$topics)
            TextField("标签，用逗号分隔",text:$tags)
            Toggle("收藏",isOn:$favorite)
            Text("整本书的心得").font(.caption); LibraryWritingEditor(text:$reflection,label:"整本书的心得",identity:"shelf-reflection:"+book.id.uuidString).frame(height:330)
            Text(book.path).font(.caption).textSelection(.enabled)
            Text(message).foregroundStyle(.red)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(20).adaptiveSheet(width:700,height:665,minimumWidth:360)
        .onAppear {
            title = book.title;reflection = book.reflection;favorite = book.favorite
            topics = book.shelfTopics.joined(separator:"，")
            author = book.shelfAuthor ?? "";periodical = book.shelfPeriodical ?? "";year = book.shelfYear ?? ""
            tags = (book.shelfTags ?? []).joined(separator:"，")
        }
    }
    private func save() {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { message = "请填写书名"; return }
        do {
            try library.editShelfBooks([book.id],name:"编辑书目信息") { value in
                value.title = title.trimmingCharacters(in:.whitespacesAndNewlines)
                value.topics = ReadingRecordDetail.tags(topics);value.category = ""
                value.shelfAuthor = author;value.shelfPeriodical = periodical;value.shelfYear = year
                value.shelfTags = ReadingRecordDetail.tags(tags)
                value.reflection = reflection;value.favorite = favorite
            }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct PendingLibraryBooksView: View {
    @ObservedObject var library:BookLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var query = ""
    @State private var page = 0
    @State private var message = ""
    private var matches:[LibraryBook] { (library.catalog.pendingBooks ?? []).filter { query.isEmpty || ($0.title+$0.category).localizedCaseInsensitiveContains(query) } }
    private var lastPage:Int { max(0,(matches.count-1)/25) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("旧版与已移出的书架记录").font(.headline)
            Text("这些记录仍保留分类、收藏和心得。只有你选择添加后，才会出现在书架中。").font(.caption)
            TextField("筛选待添加书名",text:$query)
            HStack { Button("全选筛选结果") { selected.formUnion(matches.map(\.id)) }; Button("清空勾选") { selected = [] }; Text("已选 \(selected.count) 本") }
            List(Array(matches.dropFirst(min(page,lastPage)*25).prefix(25))) { book in
                Toggle(isOn:Binding(get:{selected.contains(book.id)},set:{ if $0 { selected.insert(book.id) } else { selected.remove(book.id) } })) { Text(book.title).lineLimit(1).help(book.title+"\n"+book.path) }
            }
            HStack { Text("第 \(min(page,lastPage)+1) / \(lastPage+1) 页"); Button("上一页") { page = max(0,page-1) }.disabled(page == 0); Button("下一页") { page += 1 }.disabled(page >= lastPage) }
            Text(message).foregroundStyle(.red)
            HStack { Button("关闭") { dismiss() }; Spacer(); Button("添加所选书籍") { do { try library.acceptPending(selected); dismiss() } catch { message = error.localizedDescription } }.disabled(selected.isEmpty) }
        }.padding(20).adaptiveSheet(width:720,height:560,minimumWidth:360).onChange(of:query) { _,_ in page = 0 }
    }
}

struct LibraryCover: View {
    let path:String
    @State private var cover:NSImage?
    var body:some View {
        Group {
            if let cover { Image(nsImage:cover).resizable().scaledToFit() }
            else { Image(systemName:"book.closed").font(.largeTitle).foregroundStyle(.blue).frame(maxWidth:.infinity,maxHeight:.infinity).background(.quaternary,in:RoundedRectangle(cornerRadius:5)) }
        }.task(id:path) { do { let data = try await LibraryCoverLoader.shared.load(URL(fileURLWithPath:path)); try Task.checkCancellation(); cover = data.flatMap(NSImage.init(data:)) } catch { cover = nil } }
    }
}
