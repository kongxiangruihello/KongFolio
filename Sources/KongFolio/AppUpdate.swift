import Foundation
import CryptoKit

struct AppUpdateVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]
    init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let values = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(values.count), values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }), values.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = values.map { Int($0)! } + Array(repeating: 0, count: 3-values.count)
    }
    var description: String { parts.map(String.init).joined(separator: ".") }
    static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

struct AppUpdateRelease: Equatable {
    static let repository = "kongxiangruihello/KongFolio"
    static let endpoint = URL(string: "https://api.github.com/repos/"+repository+"/releases/latest")!
    let version: AppUpdateVersion
    let notes: String
    let page: URL
    let asset: URL
    let filename: String
    let size: Int64
    let sha256: String
    static let maximumSize: Int64 = 512*1024*1024
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String; let size: Int64; let state: String; let browser_download_url: URL; let digest: String?
        }
        let tag_name: String; let body: String?; let html_url: URL; let draft: Bool; let prerelease: Bool; let assets: [Asset]
    }
    static func decode(_ data: Data, architecture: String = architecture) throws -> Self {
        guard data.count <= 2*1024*1024 else { throw FolioError(message: "更新信息过大，请稍后重试") }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard !value.draft, !value.prerelease, let version = AppUpdateVersion(value.tag_name) else { throw FolioError(message: "尚无可安装的正式版本") }
        guard trusted(value.html_url), value.html_url.path == "/"+repository+"/releases/tag/"+value.tag_name else { throw FolioError(message: "更新页面地址无效") }
        let names = ["KongFolio-\(version)-\(architecture).dmg", "KongFolio-\(version)-universal.dmg"]
        guard let asset = names.compactMap({ name in value.assets.first { $0.name == name && $0.state == "uploaded" } }).first else { throw FolioError(message: "发现 \(version)，但尚无适合此 Mac 的安装包，请稍后重试") }
        guard trusted(asset.browser_download_url), asset.browser_download_url.path == "/"+repository+"/releases/download/"+value.tag_name+"/"+asset.name,
              asset.size > 0, asset.size <= maximumSize else { throw FolioError(message: "更新安装包信息无效") }
        guard let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw FolioError(message: "此版本缺少安装包校验信息，请稍后重试或查看发布页面") }
        return Self(version: version, notes: value.body ?? "此版本未附更新说明。", page: value.html_url, asset: asset.browser_download_url, filename: asset.name, size: asset.size, sha256: String(digest.dropFirst(7)).lowercased())
    }
    private static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }
}

struct AppUpdateProgress: Equatable {
    let received: Int64
    let expected: Int64
    var fraction: Double? { expected > 0 ? min(1, max(0, Double(received)/Double(expected))) : nil }
    var label: String {
        let bytes = ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file)
        guard let fraction else { return bytes+"，正在下载…" }
        return "\(Int(fraction*100))% · "+bytes+" / "+ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
    }
}

protocol AppUpdateTransport {
    func latest() async throws -> AppUpdateRelease
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws
}

struct AppUpdateNetwork: AppUpdateTransport {
    func latest() async throws -> AppUpdateRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: AppUpdateRelease.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KongFolio-Update", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard response.url == AppUpdateRelease.endpoint else { throw FolioError(message: "更新服务地址发生变化，请查看正式发布页面") }
        try Task.checkCancellation()
        return try AppUpdateRelease.decode(data)
    }
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws {
        let transfer = AppUpdateDownload(file: file, size: release.size, progress: progress)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { transfer.start(release.asset, continuation: $0) }
        }, onCancel: { transfer.cancel() })
    }
    static func check(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse else { throw FolioError(message: "更新服务未返回有效响应") }
        if [403, 429].contains(response.statusCode) { throw FolioError(message: "更新服务暂时限制访问，请稍后重试") }
        guard response.statusCode == 200 else { throw FolioError(message: "暂时无法获取更新（\(response.statusCode)），请稍后重试") }
    }
}

final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let file: URL
    private let size: Int64
    private let progress: @Sendable (AppUpdateProgress) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    init(file: URL, size: Int64, progress: @escaping @Sendable (AppUpdateProgress) -> Void) { self.file = file; self.size = size; self.progress = progress }
    func start(_ url: URL, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url); request.setValue("KongFolio-Update", forHTTPHeaderField: "User-Agent"); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request); self.session = session; self.task = task
        lock.unlock(); task.resume()
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let session = session; self.session = nil; task = nil; lock.unlock()
        guard let continuation else { return }
        session?.finishTasksAndInvalidate(); continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > AppUpdateRelease.maximumSize || totalBytesWritten > size { downloadTask.cancel(); finish(.failure(FolioError(message: "安装包大小与版本信息不符，请重新检查更新"))); return }
        progress(AppUpdateProgress(received: totalBytesWritten, expected: size > 0 ? size : totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try AppUpdateNetwork.check(downloadTask.response)
            lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw CancellationError() }
            try FileManager.default.moveItem(at: location, to: file)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        let allowed = request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com"))
        completionHandler(allowed ? request : nil)
    }
}

enum AppUpdateValidation {
    static func verify(_ file: URL, release: AppUpdateRelease) throws {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: 1024*1024), !data.isEmpty {
            try Task.checkCancellation(); size += Int64(data.count)
            guard size <= release.size else { throw FolioError(message: "安装包大小不符，请重新下载") }
            digest.update(data: data)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == release.size, actual == release.sha256 else { throw FolioError(message: "安装包校验未通过，请重新下载") }
    }
}
