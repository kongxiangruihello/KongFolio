import Foundation

enum ReadingMirrorSettings053 {
    struct Settings:Codable { var path:String;var bookmark:Data }
    static func file(_ folder:URL)->URL { folder.appendingPathComponent("ReadableBackup053.json") }
    static func enable(_ directory:URL,folder:URL)throws {
        try ReadingBackupStorage.checked(directory)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let data=try directory.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
        try JSONEncoder().encode(Settings(path:directory.path,bookmark:data)).write(to:file(folder),options:.atomic)
    }
    static func disable(_ folder:URL)throws { let target=file(folder);if FileManager.default.fileExists(atPath:target.path) { try FileManager.default.removeItem(at:target) } }
    static func directory(_ folder:URL)throws->URL? {
        guard FileManager.default.fileExists(atPath:file(folder).path) else { return nil }
        let settings=try JSONDecoder().decode(Settings.self,from:Data(contentsOf:file(folder)))
        var stale=false
        return try URL(resolvingBookmarkData:settings.bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
    }
}
actor ReadingMirrorWriter053 {
    static let shared=ReadingMirrorWriter053()
    private var pending:[String:(ReadingJournalState,URL)]=[:]
    private var task:Task<Void,Never>?
    func schedule(_ state:ReadingJournalState,folder:URL) {
        guard FileManager.default.fileExists(atPath:ReadingMirrorSettings053.file(folder).path) else { return }
        pending[folder.path]=(state,folder)
        if task==nil { task=Task { do { try await Task.sleep(nanoseconds:60_000_000_000) } catch { return };await drain() } }
    }
    func drain() async {
        task?.cancel();task=nil
        let snapshots=pending;pending=[:]
        for (_,value) in snapshots {
            let (state,folder)=value
            do {
                guard let directory=try ReadingMirrorSettings053.directory(folder) else { continue }
                let access=directory.startAccessingSecurityScopedResource();defer { if access { directory.stopAccessingSecurityScopedResource() } }
                _=try ReadingReadable053.write(state,assets:folder.appendingPathComponent("Assets"),to:directory)
                try? Data(ISO8601DateFormatter().string(from:Date()).utf8).write(to:folder.appendingPathComponent("ReadableBackup053.status"),options:.atomic)
            } catch { try? Data(error.localizedDescription.utf8).write(to:folder.appendingPathComponent("ReadableBackup053.status"),options:.atomic) }
        }
    }
}
