import Foundation

// A renamed QA bundle may use a local signed package to exercise a future-version transaction.
// The production bundle never enters this path; public GitHub remains its only update source.
struct AppUpdateQAFixture: AppUpdateTransport {
    let metadata: URL
    static func configured() -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.kongfolio.qa") == true,
              let storage = environment["KONGFOLIO_STORAGE"], let path = environment["KONGFOLIO_TEST_UPDATE_FIXTURE"] else { return nil }
        let root = URL(fileURLWithPath: storage).appendingPathComponent("UpdateFixture").resolvingSymlinksInPath(), file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path+"/"), file.lastPathComponent == "release.json" else { return nil }
        return Self(metadata: file)
    }
    func latest() async throws -> AppUpdateRelease { try AppUpdateRelease.decode(Data(contentsOf: metadata)) }
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws {
        let input = try FileHandle(forReadingFrom: metadata.deletingLastPathComponent().appendingPathComponent(release.filename)); defer { try? input.close() }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw FolioError(message: "无法创建隔离下载文件") }
        let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
        var count: Int64 = 0
        while let data = try input.read(upToCount: 64*1024), !data.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: data); count += Int64(data.count); progress(AppUpdateProgress(received: count, expected: release.size)); try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
