import Foundation

enum ReadingSourceImages053 {
    struct Prepared { var snapshot:ReadingExportSnapshot;var assets:URL;var temporary:URL?;var warnings:[String] }
    static func prepare(_ snapshot:ReadingExportSnapshot,assets:URL)throws->Prepared {
        guard snapshot.options?.includeRegionImages==true,snapshot.options?.includeQuote != false else { return Prepared(snapshot:snapshot,assets:assets,warnings:[]) }
        let fm=FileManager.default,directory=fm.temporaryDirectory.appendingPathComponent("KongFolio-source-images-"+UUID().uuidString)
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        var result=snapshot,warnings:[String]=[]
        do {
            for name in snapshot.assetNames053 { try Task.checkCancellation();try fm.copyItem(at:assets.appendingPathComponent(name),to:directory.appendingPathComponent(name)) }
            func render(_ r:inout ReadingRecord)throws {
                guard r.imageAsset==nil,r.extras?.visualAsset==nil else { return }
                var extras=r.extras ?? ReadingRecordExtras053()
                for c in r.citations.prefix(8) where URL(fileURLWithPath:c.source.path).pathExtension.lowercased()=="pdf" {
                    try Task.checkCancellation()
                    do {
                        let bytes=try PDFImportProbe053.region(c.source),name=OCRPageCache.digest(bytes)+".png"
                        let file=directory.appendingPathComponent(name)
                        if !fm.fileExists(atPath:file.path) { try bytes.write(to:file,options:.atomic) }
                        if extras.visualAsset==nil { extras.visualAsset=name } else { extras.regions=(extras.regions ?? [])+[ReadingRegion053(asset:name,citation:c)] }
                    } catch { if FolioCancellation.matches(error) { throw error };warnings.append(c.source.fileName+" · "+c.source.pageDescription+"：来源图片未包含，文字与出处已保留") }
                }
                r.extras=extras
            }
            for i in result.records.indices { try render(&result.records[i]) }
            if var essay=result.essay { for i in essay.blocks.indices { if var r=essay.blocks[i].record { try render(&r);essay.blocks[i].record=r } };result.essay=essay }
            if var essays=result.essays { for i in essays.indices { for j in essays[i].blocks.indices { if var r=essays[i].blocks[j].record { try render(&r);essays[i].blocks[j].record=r } } };result.essays=essays }
            return Prepared(snapshot:result,assets:directory,temporary:directory,warnings:warnings)
        } catch { try? fm.removeItem(at:directory);throw error }
    }
}
