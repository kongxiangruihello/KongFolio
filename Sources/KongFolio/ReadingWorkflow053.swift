import Foundation

enum ReadingWorkflow053 {
    static func items(_ state:ReadingJournalState,ids:Set<ReadingLibraryID> = [])->[ReadingLibraryItem] {
        ReadingLibraryItem.results(state,kind:"全部",removed:false).filter{ids.isEmpty || ids.contains($0.id)}
    }
    static func duplicateGroups(_ state:ReadingJournalState)->[[ReadingRecord]] {
        let entries=state.records.filter{$0.removed==nil && $0.hasContent && $0.kind != .note}
        var groups:[String:[ReadingRecord]]=[:]
        for record in entries {
            var locations:[String]=[]
            for citation in record.citations {
                let fields:[String]=[ReadingBookIdentity.key(citation.source.path),String(citation.source.page),String(describing:citation.source.rects)]
                locations.append(fields.joined(separator:":"))
            }
            let fields:[String]=[ReadingSearchExpression053.normalized(record.quote),record.imageAsset ?? "",record.pdfOrigin?.annotationID ?? "",locations.sorted().joined(separator:"|")]
            groups[fields.joined(separator:"|"),default:[]].append(record)
        }
        var result:[[ReadingRecord]]=[]
        for values in groups.values where values.count>1 { result.append(values.sorted{$0.created<$1.created}) }
        return result.sorted{$0[0].created<$1[0].created}
    }
    static func frozen(_ item:ReadingLibraryItem)->ReadingQuotation053 {
        var q=ReadingQuotation053(recordID:item.id.uuid053,title:item.title,text:item.text053,citations:item.citations053,kind:item.kind,originalCreated:item.created,originalModified:item.modified053)
        switch item {case .record(let r):q.assets=r.assetNames053;q.pdfOrigin=r.pdfOrigin;q.targetKind="record";case .essay(let e):q.assets=e.blocks.compactMap(\.record).flatMap(\.assetNames053)+(e.extras?.assets ?? []);q.targetKind="essay"};return q
    }
    static func bibliography(_ items:[ReadingLibraryItem])->[String] {
        var seen=Set<String>()
        return items.flatMap(\.citations053).compactMap { c in
            let key=[c.author,c.title,c.edition ?? "",c.publication?.summary ?? ""].joined(separator:"|")
            guard seen.insert(key).inserted else { return nil }
            return [c.author.isEmpty ? "作者未详":c.author,"《"+c.title+"》",c.edition ?? "",c.publication?.summary ?? ""].filter{!$0.isEmpty}.joined(separator:"，")
        }
    }
}
extension ReadingLibraryID {
    var uuid053:UUID { switch self { case .record(let id),.essay(let id):return id } }
    var filename053:String { switch self { case .record(let id):return "record-"+id.uuidString.lowercased()+".md";case .essay(let id):return "essay-"+id.uuidString.lowercased()+".md" } }
}
extension ReadingJournal {
    func mergeDuplicates053(_ ids:[UUID]) throws {
        guard !unreadable,ids.count>1,Set(ids).count==ids.count else { throw FolioError(message:"请选择两条以上可合并的资料") }
        let values=ids.compactMap{record($0)}
        guard values.count==ids.count,values.allSatisfy({$0.removed==nil}),var keeper=values.first else { throw FolioError(message:"资料已变化，请重新比较") }
        let before=state
        var citations=keeper.citations,tags=keeper.tags
        var extras=keeper.extras ?? ReadingRecordExtras053()
        for value in values.dropFirst() {
            for c in value.citations where !citations.contains(c) { citations.append(c) }
            for tag in value.tags where !tags.contains(tag) { tags.append(tag) }
            if !value.note.isEmpty { keeper.note += (keeper.note.isEmpty ? "":"\n\n---\n\n")+value.note }
            extras.quotations=(extras.quotations ?? [])+[ReadingWorkflow053.frozen(.record(value))]
            for region in value.extras?.regions ?? [] where !(extras.regions ?? []).contains(where:{$0.id==region.id}) { extras.regions=(extras.regions ?? [])+[region] }
        }
        keeper.citations=citations;keeper.tags=tags;keeper.extras=extras;keeper.modified=Date()
        change { s in
            for i in s.records.indices { if s.records[i].id==keeper.id { s.records[i]=keeper } else if ids.contains(s.records[i].id) { s.records[i].removed=Date() } }
        }
        finishBulk(before,"合并重复资料")
    }
    func quote053(_ source:ReadingLibraryItem,in destination:ReadingLibraryID) throws {
        guard source.id != destination,let target=libraryItem053(destination),target.kind=="笔记" else { throw FolioError(message:"请选择另一条笔记作为目标") }
        let quote=ReadingWorkflow053.frozen(source)
        updateExtras053([destination]) { value in value.quotations=(value.quotations ?? [])+[quote] }
    }
    func refreshQuotation053(_ id:ReadingLibraryID,quotation:UUID,expected:ReadingQuotation053)throws {
        guard let target=libraryItem053(id),let q=target.extras053.quotations?.first(where:{$0.id==quotation}),q==expected else { throw FolioError(message:"引用已变化，请重新比较") }
        let source=ReadingWorkflow053.items(state).first{$0.id.uuid053==q.recordID && (q.targetKind==nil || $0.id.isEssay053==(q.targetKind=="essay"))}
        guard let source else { throw FolioError(message:"原记录已移除，已保留引用副本") }
        updateExtras053([id]) { extras in
            guard let i=extras.quotations?.firstIndex(where:{$0.id==quotation}) else { return }
            var new=ReadingWorkflow053.frozen(source);new.id=q.id;extras.quotations?[i]=new
        }
    }
    func updateBookMetadata053(path:String,publication:ReadingPublication053,author:String,title:String,expected:ReadingJournalState)throws {
        guard !unreadable,state==expected else { throw FolioError(message:"资料已变化，请重新预览修改范围") }
        let before=state
        change { s in
            func update(_ r:inout ReadingRecord) {
                var changed=false
                for i in r.citations.indices where ReadingBookIdentity.key(r.citations[i].source.path)==ReadingBookIdentity.key(path) {
                    r.citations[i].publication=publication;r.citations[i].author=author;r.citations[i].title=title;changed=true
                }
                if changed { r.modified=Date() }
            }
            for i in s.records.indices { update(&s.records[i]) }
            // A quoted record is a frozen source. Book-wide edits concern the live records;
            // updating an existing quotation is a separate, explicit comparison action.
        }
        finishBulk(before,"整本文献的书目信息")
    }
}

enum ReadingCatalog053 {
    enum Column:String,CaseIterable { case kind="类型",title="标题",quote="原文",note="我的笔记",source="出处",author="作者",page="PDF 页码",created="收录时间",modified="修改时间",review="核对状态",meaning="颜色含义",link="记录链接" }
    static func values(_ item:ReadingLibraryItem,columns:[Column])->[String] {
        let iso=ISO8601DateFormatter()
        return columns.map { column in switch column {
        case .kind:return item.kind;case .title:return item.title
        case .quote:switch item {case .record(let r):return r.quote;case .essay(let e):return e.blocks.compactMap{$0.record?.quote}.joined(separator:"\n\n")}
        case .note:switch item {case .record(let r):return r.note;case .essay(let e):return e.blocks.map(\.text).joined(separator:"\n\n")}
        case .source:return item.citations053.map{ReadingExportOrdering.citation($0)}.joined(separator:"\n")
        case .author:return item.citations053.map(\.author).joined(separator:"；")
        case .page:return item.citations053.map{String($0.source.page+1)}.joined(separator:"；")
        case .created:return iso.string(from:item.created);case .modified:return iso.string(from:item.modified053)
        case .review:return item.extras053.review?.rawValue ?? "待核对";case .meaning:return item.extras053.colorMeaning ?? ""
        case .link:return ReadingRecordLink053.url(item.id).absoluteString
        } }
    }
    static func csv(_ items:[ReadingLibraryItem],columns:[Column])->String {
        func row(_ values:[String])->String { values.map{"\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\""}.joined(separator:",") }
        return "\u{FEFF}"+([row(columns.map(\.rawValue))]+items.map{row(values($0,columns:columns))}).joined(separator:"\r\n")+"\r\n"
    }
    static func xlsx(_ items:[ReadingLibraryItem],columns:[Column],to file:URL)throws {
        let zip=try ZipWriter(url:file)
        do {
            try zip.add("[Content_Types].xml",Data((WordExport.header+"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>").utf8))
            try zip.add("_rels/.rels",Data((WordExport.header+"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>").utf8))
            try zip.add("xl/workbook.xml",Data((WordExport.header+"<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"阅读资料\" sheetId=\"1\" r:id=\"s1\"/></sheets></workbook>").utf8))
            try zip.add("xl/_rels/workbook.xml.rels",Data((WordExport.header+"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"s1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>").utf8))
            let rows=[columns.map(\.rawValue)]+items.map{values($0,columns:columns)}
            let xml=rows.enumerated().map{ i,row in "<row r=\"\(i+1)\">"+row.map{"<c t=\"inlineStr\"><is><t xml:space=\"preserve\">"+WordExport.escape($0)+"</t></is></c>"}.joined()+"</row>" }.joined()
            try zip.add("xl/worksheets/sheet1.xml",Data((WordExport.header+"<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"+xml+"</sheetData></worksheet>").utf8));try zip.finish()
        } catch { zip.abandon();throw error }
    }
}

enum ReadingReadable053 {
    struct Manifest:Codable { var version=1;var date=Date();var files:[String:String] }
    static func write(_ state:ReadingJournalState,assets:URL,to parent:URL)throws->URL {
        try state.validate()
        let fm=FileManager.default,target=parent.appendingPathComponent("KongFolio-阅读资料",isDirectory:true)
        let stage=parent.appendingPathComponent(".KongFolio-readable-"+UUID().uuidString)
        try fm.createDirectory(at:stage.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:stage) }
        let items=ReadingWorkflow053.items(state)
        let previous=(try? Data(contentsOf:target.appendingPathComponent("manifest.json"))).flatMap{try? JSONDecoder().decode(Manifest.self,from:$0)}
        var files:[String:String]=[:],index=["# 阅读资料索引",""]
        func write(_ data:Data,_ name:String)throws {
            let hash=OCRPageCache.digest(data),output=stage.appendingPathComponent(name),old=target.appendingPathComponent(name)
            if previous?.files[name]==hash,(try? Data(contentsOf:old))==data,(try? fm.linkItem(at:old,to:output)) != nil { files[name]=hash;return }
            try data.write(to:output,options:.atomic);files[name]=hash
        }
        for item in items {
            try Task.checkCancellation()
            let snapshot:ReadingExportSnapshot
            switch item {case .record(let r):snapshot=ReadingExportSnapshot(title:r.displayTitle,records:[r]);case .essay(let e):snapshot=ReadingExportSnapshot(title:e.title,essay:e)}
            var text=ReadingRecordExport.markdown(snapshot,imageFolder:"Assets")
            text += "\n记录链接："+ReadingRecordLink053.url(item.id).absoluteString+"\n"
            for q in item.extras053.quotations ?? [] {
                let linked=items.first{$0.id.uuid053==q.recordID && (q.targetKind==nil || $0.id.isEssay053==(q.targetKind=="essay"))}
                if let linked { text += "[原记录](<"+linked.id.filename053+">)\n" }
            }
            try write(Data(text.utf8),item.id.filename053)
            index.append("- ["+item.title.replacingOccurrences(of:"]",with:"\\]")+" ](<"+item.id.filename053+">)")
        }
        for name in state.assetNames053 { try write(Data(contentsOf:assets.appendingPathComponent(name)),"Assets/"+name) }
        try write(Data(index.joined(separator:"\n").utf8),"index.md")
        try write(Data(ReadingCatalog053.csv(items,columns:ReadingCatalog053.Column.allCases).utf8),"catalog.csv")
        try JSONEncoder().encode(Manifest(files:files)).write(to:stage.appendingPathComponent("manifest.json"),options:.atomic)
        try ReadingBackupStorage.checked(target)
        if fm.fileExists(atPath:target.path) {
            guard let previousData=try? Data(contentsOf:target.appendingPathComponent("manifest.json")),let previous=try? JSONDecoder().decode(Manifest.self,from:previousData),previous.version==1 else { throw FolioError(message:"目标目录已有同名资料，请选择另一个位置") }
            let backup=parent.appendingPathComponent("KongFolio-阅读资料.previous")
            if fm.fileExists(atPath:backup.path) {
                try ReadingBackupStorage.checked(backup)
                guard let old=try? Data(contentsOf:backup.appendingPathComponent("manifest.json")),(try? JSONDecoder().decode(Manifest.self,from:old))?.version==1 else { throw FolioError(message:"上一份可读备份目录无法确认，现有文件保持不变") }
                try fm.removeItem(at:backup)
            }
            _=try fm.replaceItemAt(target,withItemAt:stage,backupItemName:"KongFolio-阅读资料.previous",options:.withoutDeletingBackupItem)
        } else { try fm.moveItem(at:stage,to:target) }
        return target
    }
}
