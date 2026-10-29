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
    @State private var page = 0
    private let pageSize = 25
    private var matchingIndices: [Int] { rows.indices.filter { matches(rows[$0]) } }
    private var lastPage: Int { max(0,(matchingIndices.count-1)/pageSize) }
    private var visibleIndices: [Int] { Array(matchingIndices.dropFirst(min(page,lastPage)*pageSize).prefix(pageSize)) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("批量整理报刊卷期").font(.headline)
            commonFields
            filterControls
            pagination
            table
            Divider()
            annualOverview
        }.task { await load() }.onChange(of:query) { _,_ in page = 0 }
    }
    private var commonFields: some View {
        HStack {
            TextField("统一刊名",text:$journal)
            TextField("统一年份",text:$year)
            TextField("统一卷号",text:$volume)
            Button("套用到勾选项",action:applyCommon)
        }
    }
    private var filterControls: some View {
        HStack {
            TextField("筛选书名、刊名或年份",text:$query)
            Button("全选筛选结果") { for i in rows.indices where matches(rows[i]) { rows[i].selected = true } }
            Button("清空勾选") { for i in rows.indices { rows[i].selected = false } }
            Button("保存勾选卷期",action:save)
        }
    }
    private var pagination: some View {
        HStack {
            Text("共 \(matchingIndices.count) 本 · 已勾选 \(rows.filter(\.selected).count) 本").font(.caption)
            Spacer()
            Button("上一页") { page = max(0,page-1) }.disabled(page == 0)
            Text("第 \(min(page,lastPage)+1) / \(lastPage+1) 页").font(.caption)
            Button("下一页") { page += 1 }.disabled(page >= lastPage)
        }
    }
    private var table: some View {
        ScrollView([.horizontal,.vertical]) {
            VStack(alignment:.leading) {
                HStack {
                    Text("书籍").frame(width:170,alignment:.leading)
                    Text("刊名").frame(width:110)
                    Text("年份").frame(width:70)
                    Text("卷").frame(width:65)
                    Text("期号").frame(width:75)
                    Text("日期 YYYY-MM-DD").frame(width:140)
                    Text("版次").frame(width:90)
                }.font(.caption)
                ForEach(visibleIndices,id:\.self) { index in editRow($rows[index]) }
            }
        }.frame(height:260)
    }
    private func editRow(_ row: Binding<PeriodicalBatchRow>) -> some View {
        HStack {
            Toggle(row.wrappedValue.title,isOn:row.selected).frame(width:170,alignment:.leading).lineLimit(1).help(row.wrappedValue.title)
            TextField("刊名",text:row.record.journal).frame(width:110)
            TextField("年",text:row.record.year).frame(width:70)
            TextField("卷",text:row.record.volume).frame(width:65)
            TextField("期",text:row.record.issue).frame(width:75)
            TextField("日期",text:row.record.date).frame(width:140)
            TextField("版次",text:row.record.edition).frame(width:90)
        }
    }
    private var periods: [PeriodicalRecord] { research.state.periodicals.values.filter { overviewYear.isEmpty || $0.year == overviewYear } }
    private var overviewTitles: [String] { Array(Set(periods.map { $0.journal + " · " + $0.year })).sorted() }
    private var annualOverview: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text("年度卷期总览").font(.headline); TextField("年份，留空显示全部",text:$overviewYear).frame(width:180) }
            ForEach(Array(overviewTitles.prefix(50)),id:\.self) { title in Text(overviewLine(title)).textSelection(.enabled) }
            if overviewTitles.count > 50 { Text("请填写年份缩小总览范围").font(.caption) }
            ForEach(Array(research.periodicalProblems().prefix(50)),id:\.self) { Text($0).foregroundStyle(.orange) }
        }
    }
    private func overviewLine(_ title: String) -> String {
        let list = periods.filter { $0.journal + " · " + $0.year == title }.sorted { ($0.volume,Int($0.issue) ?? 0,$0.issue) < ($1.volume,Int($1.issue) ?? 0,$1.issue) }
        let labels = list.map { record -> String in
            let volume = record.volume.isEmpty ? "" : "卷" + record.volume + " "
            return volume + "第" + record.issue + "期"
        }
        return title + "：" + labels.joined(separator:"、")
    }
    private func matches(_ row:PeriodicalBatchRow) -> Bool { query.isEmpty || (row.title+row.record.citation).localizedCaseInsensitiveContains(query) }
    private func applyCommon() {
        for i in rows.indices where rows[i].selected {
            if !journal.isEmpty { rows[i].record.journal = journal }
            if !year.isEmpty { rows[i].record.year = year }
            if !volume.isEmpty { rows[i].record.volume = volume }
        }
    }
    private func load() async {
        let books = library.books, records = research.state.periodicals
        let loaded = await Task.detached(priority:.utility) { PeriodicalBatchRow.load(books:books,records:records) }.value
        guard !Task.isCancelled else { return }
        rows = loaded; page = 0
    }
    private func save() {
        do {
            let selected = rows.filter(\.selected)
            guard !selected.isEmpty else { throw FolioError(message:"请先勾选书籍") }
            for row in selected { try row.record.validate() }
            try research.update { value in for row in selected { value.periodicals[row.path] = row.record.citation.isEmpty ? nil : row.record } }
            controller.message = "已保存 \(selected.count) 本卷期"
        } catch { controller.message = error.localizedDescription }
    }
}
