import Foundation

actor ReadingEmergencyWriter {
    static let shared = ReadingEmergencyWriter()
    func write(_ state:ReadingJournalState,pending:[String:Data],assets:URL,to file:URL,expected:FileBaseline) throws {
        try state.validate()
        var missing:[String] = [],images:[String:Data] = [:]
        for name in state.assetNames053 {
            if let bytes = pending[name] ?? (try? Data(contentsOf:assets.appendingPathComponent(name))) { images[name] = bytes } else { missing.append(name) }
        }
        let bytes = try JSONEncoder().encode(state)
        try DocumentTaskOutput.write(to:file,expected:expected) { temp in
            let zip = try ZipWriter(url:temp)
            do { try zip.add("ReadingJournal/catalog.json",bytes);for (name,data) in images { try Task.checkCancellation();try zip.add("ReadingJournal/Assets/"+name,data) }
                try zip.add("恢复说明.txt",Data(("这是当前内存中阅读资料的应急副本，原保存位置不变。请先解压此包，在“资料库 → 备份恢复 → 应急目录预览”选择解压后的 ReadingJournal 子目录，核对后恢复所选记录。\n缺失图片：\n"+missing.sorted().joined(separator:"\n")).utf8));try zip.finish()
            } catch { zip.abandon();throw error }
        }
    }
}
