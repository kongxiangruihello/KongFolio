import Foundation

enum ReadingUpgradeReceipt053 {
    struct Receipt:Codable { var version="0.53.0";var date=Date();var previousDigest:String;var backup:String? }
    static func ensure(_ folder:URL)throws {
        let file=folder.appendingPathComponent("Upgrade-0.53.0.json")
        guard !FileManager.default.fileExists(atPath:file.path) else { return }
        let state=try ReadingDeltaStorage.read(folder).state
        let previous=try ReadingBackupStorage.bytes(state)
        let backup=state.records.isEmpty && state.essays.isEmpty ? nil:try ReadingBackupStorage.capture(state,folder:folder,kind:.beforeRestore).id
        try JSONEncoder().encode(Receipt(previousDigest:OCRPageCache.digest(previous),backup:backup)).write(to:file,options:.atomic)
    }
}
