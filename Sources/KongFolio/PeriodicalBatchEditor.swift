import SwiftUI

struct PeriodicalBatchEditor: View {
    @ObservedObject var library: BookLibrary
    @ObservedObject var research: ResearchStore
    @ObservedObject var controller: ResearchController
    @State private var rows: [PeriodicalBatchRow] = []
    @State private var journal = ""
    @State private var year = ""
    @State private var volume = ""
    @State private var query = ""
    @State private var overviewYear = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("批量整理报刊卷期").font(.headline)
            HStack { TextField("统一刊名",text:$journal); TextField("统一年份",text:$year); TextField("统一卷号",text:$volume)
                Button("套用到勾选项") { for i in rows.indices where rows[i].selected { if !journal.isEmpty { rows[i].record.journal = journal }; if !year.isEmpty { rows[i].record.year = year }; if !volume.isEmpty { rows[i].record.volume = volume } } }
            }
            HStack { TextField("筛选书名、刊名或年份",text:$query); Button("全选筛选结果") { for i in rows.indices where matches(rows[i]) { rows[i].selected = true } }; Button("清空勾选") { for i in rows.indices { rows[i].selected = false } }; Button("保存勾选卷期") { save() } }
            ScrollView(.horizontal) {
                VStack(alignment:.leading) {
                    HStack { Text("书籍／刊名").frame(width:250,alignment:.leading); Text("年份").frame(width:70); Text("卷").frame(width:65); Text("期号").frame(width:75); Text("日期 YYYY-MM-DD").frame(width:140); Text("版次").frame(width:90) }.font(.caption)
                    ForEach($rows) { $row in
                        if matches(row) {
                            HStack {
                                Toggle(row.title,isOn:$row.selected).frame(width:170,alignment:.leading).lineLimit(1).help(row.title)
                                TextField("刊名",text:$row.record.journal).frame(width:110)
                                TextField("年",text:$row.record.year).frame(width:70)
                                TextField("卷",text:$row.record.volume).frame(width:65)
                                TextField("期",text:$row.record.issue).frame(width:75)
                                TextField("日期",text:$row.record.date).frame(width:140)
                                TextField("版次",text:$row.record.edition).frame(width:90)
                            }
                        }
                    }
                }
            }.frame(maxHeight:260)
            Divider()
            HStack { Text("年度卷期总览").font(.headline); TextField("年份，留空显示全部",text:$overviewYear).frame(width:180) }
            let periods = research.state.periodicals.values.filter { overviewYear.isEmpty || $0.year == overviewYear }
            ForEach(Array(Set(periods.map { $0.journal + " · " + $0.year })).sorted(),id:\.self) { title in
                let list = periods.filter { $0.journal + " · " + $0.year == title }.sorted { ($0.volume,Int($0.issue) ?? 0,$0.issue) < ($1.volume,Int($1.issue) ?? 0,$1.issue) }
                Text(title + "：" + list.map { ($0.volume.isEmpty ? "" : "卷"+$0.volume+" ") + "第"+$0.issue+"期" }.joined(separator:"、")).textSelection(.enabled)
            }
            ForEach(research.periodicalProblems(),id:\.self) { Text($0).foregroundStyle(.orange) }
        }.onAppear(perform:load)
    }
    private func matches(_ row:PeriodicalBatchRow) -> Bool { query.isEmpty || (row.title+row.record.citation).localizedCaseInsensitiveContains(query) }
    private func load() { rows = library.books.map { PeriodicalBatchRow(path:$0.path,title:$0.title,record:research.periodical(path:$0.path) ?? PeriodicalRecord()) } }
    private func save() {
        do { let selected = rows.filter(\.selected); guard !selected.isEmpty else { throw FolioError(message:"请先勾选书籍") }; for row in selected { try row.record.validate() }
            try research.update { value in for row in selected { value.periodicals[row.path] = row.record.citation.isEmpty ? nil : row.record } }; controller.message = "已保存 \(selected.count) 本卷期"
        } catch { controller.message = error.localizedDescription }
    }
}
