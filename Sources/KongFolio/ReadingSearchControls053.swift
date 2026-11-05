import SwiftUI

struct ReadingSearchControls053:View {
    @Binding var options:ReadingLibraryOptions053
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("搜索范围",selection:$options.scope) { ForEach(ReadingLibraryOptions053.Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            Toggle("精确字形与空格",isOn:$options.exact)
            Text("空格表示同时包含；用“或”连接任选词；-词语表示排除；用英文双引号查找词组。").font(.caption).foregroundStyle(.secondary)
            TextField("作者",text:$options.author)
            TextField("书名、篇名或期刊",text:$options.book)
            HStack { TextField("起始 PDF 页",value:$options.firstPage,format:.number);TextField("结束 PDF 页",value:$options.lastPage,format:.number) }
            date("开始日期",value:$options.after)
            date("结束日期",value:$options.before)
            Toggle("日期筛选使用修改时间",isOn:$options.dateIsModified)
            Picker("核对状态",selection:$options.review) { Text("全部").tag(ReadingRecordExtras053.Review?.none);ForEach(ReadingRecordExtras053.Review.allCases,id:\.self) { Text($0.rawValue).tag(Optional($0)) } }
            TextField("颜色含义",text:$options.meaning)
            TextField("章节",text:$options.chapter)
            Toggle("按章节分组排列",isOn:$options.groupChapters)
            Picker("排序",selection:$options.sort) { ForEach(ReadingLibraryOptions053.Sort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            DisclosureGroup("显示列与宽度") {
                Toggle("类型",isOn:$options.showKind);Toggle("出处",isOn:$options.showSource);Toggle("收录时间",isOn:$options.showCreated);Toggle("修改时间",isOn:$options.showModified)
                Text("标题列宽度");Slider(value:$options.titleWidth,in:120...500,step:20)
                Text("出处列宽度");Slider(value:$options.sourceWidth,in:100...500,step:20)
                Toggle("横向列表",isOn:$options.table)
            }
            Button("重置详细筛选") { options=ReadingLibraryOptions053() }
        }.textFieldStyle(.roundedBorder)
    }
    private func date(_ title:String,value:Binding<Date?>)->some View {
        VStack(alignment:.leading) {
            Toggle(title,isOn:Binding(get:{value.wrappedValue != nil},set:{value.wrappedValue=$0 ? Date():nil}))
            if value.wrappedValue != nil { DatePicker(title,selection:Binding(get:{value.wrappedValue ?? Date()},set:{value.wrappedValue=$0}),displayedComponents:.date).labelsHidden() }
        }
    }
}
