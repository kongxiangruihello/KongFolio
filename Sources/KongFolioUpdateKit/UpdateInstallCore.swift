import Foundation
import CryptoKit
import Darwin

public struct UpdateInstallFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct UpdateBundleIdentity: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let infoHash: String
    public let executableHash: String
}

public struct UpdateInstallJob: Codable, Sendable {
    public let id: UUID
    public let source: URL
    public let target: URL
    public let incoming: UpdateBundleIdentity
    public let original: UpdateBundleIdentity
    public let parentPID: Int32
    public let parentLaunchDate: Date?
    public let work: URL
    public let resultURL: URL
    public var file: URL { work.appendingPathComponent("job.json") }
    public var readyFile: URL { work.appendingPathComponent("helper-ready.json") }
    public var startedFile: URL { work.appendingPathComponent("application-started.json") }
    public func write() throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func load(_ file: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard file.lastPathComponent == "job.json", attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 128*1024 else { throw UpdateInstallFailure("更新任务文件无效") }
        let job = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard job.file.standardizedFileURL == file.standardizedFileURL, job.work.resolvingSymlinksInPath() == file.deletingLastPathComponent().resolvingSymlinksInPath(),
              job.source.resolvingSymlinksInPath().path.hasPrefix(job.work.resolvingSymlinksInPath().path+"/"),
              job.parentPID > 1, job.resultURL.lastPathComponent == "last-install.json", job.resultURL.deletingLastPathComponent().lastPathComponent == "Updates" else { throw UpdateInstallFailure("更新任务位置无效") }
        return job
    }
    public func signal(_ file: URL) throws {
        guard file.deletingLastPathComponent().resolvingSymlinksInPath() == work.resolvingSymlinksInPath(), ["helper-ready.json", "application-started.json", "abort"].contains(file.lastPathComponent), (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw UpdateInstallFailure("更新确认位置无效") }
        try Data(id.uuidString.utf8).write(to: file, options: [.atomic])
    }
    public func signalled(_ file: URL) -> Bool { (try? String(contentsOf: file, encoding: .utf8)) == id.uuidString }
}

public struct UpdateInstalledTransaction: Sendable {
    public let job: UpdateInstallJob
    public let backup: URL
    public let lock: URL
}

public struct UpdateInstallResult: Codable, Sendable {
    public let version: String
    public let previousVersion: String
    public let backup: URL?
    public let status: String
    public let message: String
    public let date: Date
    public init(job: UpdateInstallJob, backup: URL?, status: String, message: String) { version = job.incoming.version; previousVersion = job.original.version; self.backup = backup; self.status = status; self.message = message; date = Date() }
    public func write(to file: URL) throws {
        guard file.lastPathComponent == "last-install.json", file.deletingLastPathComponent().lastPathComponent == "Updates", (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw UpdateInstallFailure("更新结果位置无效") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

public enum UpdateInstallCore {
    public static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024*1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func inspect(_ app: URL) throws -> UpdateBundleIdentity {
        guard app.pathExtension == "app", app.standardizedFileURL.path == app.standardizedFileURL.resolvingSymlinksInPath().path,
              (try app.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw UpdateInstallFailure("应用位置无效，不能自动替换") }
        let infoFile = app.appendingPathComponent("Contents/Info.plist"), infoData = try Data(contentsOf: infoFile)
        guard infoData.count < 1024*1024, (try? infoFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, identifier == "com.kongfolio.mac" || identifier.hasPrefix("com.kongfolio.qa"),
              let version = info["CFBundleShortVersionString"] as? String, components(version) != nil,
              info["CFBundleExecutable"] as? String == "KongFolio" else { throw UpdateInstallFailure("安装包不是有效的 KongFolio 应用") }
        if let minimum = info["LSMinimumSystemVersion"] as? String, let required = components(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard ![os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(required) else { throw UpdateInstallFailure("此版本需要更新的 macOS，请先检查系统版本") }
        }
        let executable = app.appendingPathComponent("Contents/MacOS/KongFolio")
        guard (try? executable.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true, try supportsCurrentArchitecture(executable) else { throw UpdateInstallFailure("安装包不适合这台 Mac 的处理器") }
        try verifySignature(app)
        return UpdateBundleIdentity(identifier: identifier, version: version, infoHash: SHA256.hash(data: infoData).map { String(format: "%02x", $0) }.joined(), executableHash: try digest(executable))
    }
    public static func prepare(source: URL, target: URL, requestedVersion: String, expectedIdentifier: String, work: URL, resultURL: URL, parentLaunchDate: Date?) throws -> UpdateInstallJob {
        let source = source.standardizedFileURL.resolvingSymlinksInPath(), target = target.standardizedFileURL
        try writableTarget(target)
        guard source != target, source.path.hasPrefix(work.standardizedFileURL.resolvingSymlinksInPath().path+"/"), !source.path.hasPrefix(target.path+"/") else { throw UpdateInstallFailure("新版与当前应用的位置不能重叠") }
        let incoming = try inspect(source), original = try inspect(target)
        guard incoming.identifier == expectedIdentifier, original.identifier == expectedIdentifier, incoming.version == requestedVersion,
              let next = components(incoming.version), let old = components(original.version), old.lexicographicallyPrecedes(next) else { throw UpdateInstallFailure("新版标识或版本号不匹配，已停止安装") }
        return UpdateInstallJob(id: UUID(), source: source, target: target, incoming: incoming, original: original, parentPID: getpid(), parentLaunchDate: parentLaunchDate, work: work.standardizedFileURL.resolvingSymlinksInPath(), resultURL: resultURL)
    }
    public static func writableTarget(_ target: URL) throws {
        let fm = FileManager.default, parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target.standardizedFileURL.path == target.standardizedFileURL.resolvingSymlinksInPath().path,
              (try target.resourceValues(forKeys: [.volumeIsReadOnlyKey])).volumeIsReadOnly != true,
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path),
              (try parent.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey])).volumeSupportsSwapRenaming == true else { throw UpdateInstallFailure("当前应用所在位置不支持自动替换，请将应用放到可写位置，或使用手动安装") }
    }
    public static func install(_ job: UpdateInstallJob, progress: (Int, String) -> Void = { _,_ in }) throws -> UpdateInstalledTransaction {
        try writableTarget(job.target)
        guard try inspect(job.target) == job.original, try inspect(job.source) == job.incoming else { throw UpdateInstallFailure("应用在准备期间已变化，已停止安装，请重新检查更新") }
        let parent = job.target.deletingLastPathComponent(), lock = parent.appendingPathComponent("."+job.target.lastPathComponent+".update-lock")
        do { try Data(job.id.uuidString.utf8).write(to: lock, options: .withoutOverwriting) } catch { throw UpdateInstallFailure("此应用已有更新任务，请等待完成后再试") }
        let backup = parent.appendingPathComponent(".KongFolio-previous-"+job.original.version+"-"+job.id.uuidString+".app")
        do {
            progress(1, "已核对新旧版本，正在准备安装…")
            try Task.checkCancellation(); try FileManager.default.copyItem(at: job.source, to: backup)
            guard try inspect(backup) == job.incoming, try inspect(job.target) == job.original else { throw UpdateInstallFailure("应用内容已变化，已停止替换") }
            try Task.checkCancellation(); progress(2, "新版已准备，正在安全替换…")
            // Both directories are siblings on the same filesystem. Swapping keeps a valid app at the original path.
            try swap(backup, job.target)
            let result = UpdateInstalledTransaction(job: job, backup: backup, lock: lock)
            progress(3, "已安装新版本，正在重新打开…")
            return result
        } catch {
            // Before the swap, this is only our new-version copy. The installed application is untouched.
            if (try? inspect(job.target)) == job.original { try? FileManager.default.removeItem(at: backup) }
            release(lock, id: job.id)
            throw error
        }
    }
    public static func rollback(_ transaction: UpdateInstalledTransaction) throws {
        let job = transaction.job
        guard owns(transaction.lock, id: job.id), try inspect(job.target) == job.incoming, try inspect(transaction.backup) == job.original else { throw UpdateInstallFailure("应用已发生其他变化，不能自动还原；上一版本仍保留在备份位置") }
        try swap(job.target, transaction.backup)
    }
    public static func finish(_ transaction: UpdateInstalledTransaction) { release(transaction.lock, id: transaction.job.id) }
    public static func verifySignature(_ app: URL) throws {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = ["--verify", "--deep", "--strict", app.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = output; try process.run(); _ = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallFailure("应用签名校验未通过，已停止安装") }
    }
    private static func components(_ value: String) -> [Int]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && Int($0) != nil }) else { return nil }
        return pieces.map { Int($0)! } + Array(repeating: 0, count: 3-pieces.count)
    }
    private static func swap(_ a: URL, _ b: URL) throws {
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateInstallFailure("系统未能安全替换应用，原版本与备份均保留，可改用手动安装") }
    }
    private static func owns(_ file: URL, id: UUID) -> Bool { (try? String(contentsOf: file, encoding: .utf8)) == id.uuidString }
    private static func release(_ file: URL, id: UUID) { if owns(file, id: id) { try? FileManager.default.removeItem(at: file) } }
    private static func supportsCurrentArchitecture(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }; let data = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, little: Bool) -> UInt32? {
            guard offset >= 0, offset+4 <= data.count else { return nil }
            let bytes = Array(data[offset..<offset+4]); return little ? UInt32(bytes[0]) | UInt32(bytes[1])<<8 | UInt32(bytes[2])<<16 | UInt32(bytes[3])<<24 : UInt32(bytes[3]) | UInt32(bytes[2])<<8 | UInt32(bytes[1])<<16 | UInt32(bytes[0])<<24
        }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        if word(0, little: true) == 0xfeedfacf { return word(4, little: true) == cpu }
        let magic = word(0, little: false)
        guard magic == 0xcafebabe || magic == 0xcafebabf, let count = word(4, little: false), count <= 32 else { return false }
        let stride = magic == 0xcafebabf ? 32 : 20
        return (0..<Int(count)).contains { word(8+$0*stride, little: false) == cpu }
    }
}
