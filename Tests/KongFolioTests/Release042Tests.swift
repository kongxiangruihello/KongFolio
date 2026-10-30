import XCTest
import Foundation
import CryptoKit
@testable import KongFolio

final class Release042Tests: XCTestCase {
    func folder() throws -> URL { try Release027Tests().folder() }
    func bytes() -> Data { Data(repeating: 42, count: 512*1024) }
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func release(_ data: Data? = nil, version: String = "0.43.0", asset: URL? = nil) -> AppUpdateRelease {
        let data = data ?? bytes()
        return AppUpdateRelease(version: AppUpdateVersion(version)!, notes: "阅读和更新验证", page: URL(string: "https://github.com/kongxiangruihello/KongFolio/releases/tag/v"+version)!, asset: asset ?? URL(string: "https://github.com/kongxiangruihello/KongFolio/releases/download/v\(version)/KongFolio-\(version)-arm64.dmg")!, filename: "KongFolio-\(version)-arm64.dmg", size: Int64(data.count), sha256: hash(data))
    }
    func payload() -> [String: Any] {
        ["tag_name": "v0.43.0", "body": "更新说明", "html_url": "https://github.com/kongxiangruihello/KongFolio/releases/tag/v0.43.0", "draft": false, "prerelease": false, "assets": [["name": "KongFolio-0.43.0-arm64.dmg", "size": 100, "state": "uploaded", "digest": "sha256:"+String(repeating: "a", count: 64), "browser_download_url": "https://github.com/kongxiangruihello/KongFolio/releases/download/v0.43.0/KongFolio-0.43.0-arm64.dmg"]]]
    }
    func decode(_ payload: [String: Any], architecture: String = "arm64") throws -> AppUpdateRelease { try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: payload), architecture: architecture) }
    func testVersionsUseNumericComponentsAndRejectAmbiguousTags() {
        XCTAssertTrue(AppUpdateVersion("0.10.0")! > AppUpdateVersion("0.9.99")!)
        XCTAssertTrue(AppUpdateVersion("1.0")! > AppUpdateVersion("0.99.99")!)
        XCTAssertEqual(AppUpdateVersion("v0.42.0"), AppUpdateVersion("0.42"))
        for invalid in ["", "1", "1..2", "1.2.3.4", "1.2-beta", "1.2.3+build", "-1.2.3", "１.２.３", String(repeating: "9", count: 100)+".1"] { XCTAssertNil(AppUpdateVersion(invalid)) }
    }
    func testOnlyPublishedStableReleaseAndMatchingDMGIsSelected() throws {
        XCTAssertEqual(try decode(payload()).version, AppUpdateVersion("0.43.0"))
        for key in ["draft", "prerelease"] { var value = payload(); value[key] = true; XCTAssertThrowsError(try decode(value)) }
        for name in ["KongFolio-0.43.0-source.zip", "KongFolio-0.43.0-macOS.zip", "KongFolio-0.42.0-arm64.dmg"] {
            var value = payload(), assets = value["assets"] as! [[String: Any]]; assets[0]["name"] = name; value["assets"] = assets; XCTAssertThrowsError(try decode(value))
        }
    }
    func testArchitectureDoesNotOfferARMInstallerToIntelMac() throws {
        XCTAssertThrowsError(try decode(payload(), architecture: "x86_64"))
        var value = payload(), assets = value["assets"] as! [[String: Any]]
        assets[0]["name"] = "KongFolio-0.43.0-universal.dmg"; assets[0]["browser_download_url"] = "https://github.com/kongxiangruihello/KongFolio/releases/download/v0.43.0/KongFolio-0.43.0-universal.dmg"; value["assets"] = assets
        XCTAssertEqual(try decode(value, architecture: "x86_64").filename, "KongFolio-0.43.0-universal.dmg")
    }
    func testReleaseRejectsForeignOrInsecureURLs() {
        for url in ["http://github.com/kongxiangruihello/KongFolio/releases/tag/v0.43.0", "https://github.com/other/repo/releases/tag/v0.43.0", "https://github.com.evil.example/kongxiangruihello/KongFolio/releases/tag/v0.43.0", "https://user:password@github.com/kongxiangruihello/KongFolio/releases/tag/v0.43.0"] {
            var value = payload(); value["html_url"] = url; XCTAssertThrowsError(try decode(value))
        }
        var value = payload(), assets = value["assets"] as! [[String: Any]]; assets[0]["browser_download_url"] = "https://github.com/other/repo/releases/download/v0.43.0/KongFolio-0.43.0-arm64.dmg"; value["assets"] = assets; XCTAssertThrowsError(try decode(value))
    }
    func testReleaseRequiresAValidSizeAndSHA256() {
        for digest: Any in [NSNull(), "md5:"+String(repeating: "a", count: 64), "sha256:bad", "sha256:"+String(repeating: "z", count: 64)] {
            var value = payload(), assets = value["assets"] as! [[String: Any]]; assets[0]["digest"] = digest; value["assets"] = assets; XCTAssertThrowsError(try decode(value))
        }
        for size in [0, -1, AppUpdateRelease.maximumSize+1] {
            var value = payload(), assets = value["assets"] as! [[String: Any]]; assets[0]["size"] = size; value["assets"] = assets; XCTAssertThrowsError(try decode(value))
        }
    }
    func testProgressHandlesMissingLengthAndClampsValues() {
        XCTAssertEqual(AppUpdateProgress(received: 50, expected: 100).fraction, 0.5)
        XCTAssertEqual(AppUpdateProgress(received: 150, expected: 100).fraction, 1)
        XCTAssertEqual(AppUpdateProgress(received: -1, expected: 100).fraction, 0)
        XCTAssertNil(AppUpdateProgress(received: 10, expected: -1).fraction)
        XCTAssertTrue(AppUpdateProgress(received: 50, expected: 100).label.contains("50%"))
    }
    func testHTTPFailuresNeverBecomeSuccessfulDownloads() throws {
        let url = AppUpdateRelease.endpoint
        for status in [206, 301, 403, 404, 429, 500] { XCTAssertThrowsError(try AppUpdateNetwork.check(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))) }
        try AppUpdateNetwork.check(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
    func testChecksumAndLengthAreBothRequiredBeforeInstallation() throws {
        let file = try folder().appendingPathComponent("update.dmg"), data = bytes(); try data.write(to: file)
        try AppUpdateValidation.verify(file, release: release(data))
        try Data(data.dropLast()).write(to: file); XCTAssertThrowsError(try AppUpdateValidation.verify(file, release: release(data)))
        try Data(repeating: 12, count: data.count).write(to: file); XCTAssertThrowsError(try AppUpdateValidation.verify(file, release: release(data)))
    }
    @MainActor func wait(_ controller: AppUpdateController) async throws {
        for _ in 0..<600 { if !controller.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw FolioError(message: "测试更新任务未及时完成")
    }
    @MainActor func testCurrentVersionDoesNotOfferADowngrade() async throws {
        let model = AppUpdateController(current: AppUpdateVersion("0.44.0")!, folder: try folder(), transport: Update042Fixture(release: release(), data: bytes()))
        model.check(); try await wait(model); XCTAssertEqual(model.phase, .current); XCTAssertFalse(model.canDownload)
    }
    @MainActor func testTerminationHandoffRunsOutsideTheCallingSwiftTask() async throws {
        var invoked = false, insideTask = true
        AppUpdateInstaller.deferTermination { withUnsafeCurrentTask { insideTask = $0 != nil }; invoked = true }
        XCTAssertFalse(invoked)
        for _ in 0..<200 { if invoked { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(invoked); XCTAssertFalse(insideTask, "AppKit terminateLater must not hold a Swift task's main actor while waiting for the save task")
    }
    @MainActor func testOfflineCheckCanBeRetriedWithoutAnApplicationErrorDialog() async throws {
        let model = AppUpdateController(current: AppUpdateVersion("0.42.0")!, folder: try folder(), transport: Update042OfflineCheck(release: release()))
        model.check(); try await wait(model); XCTAssertEqual(model.phase, .failed); XCTAssertNil(model.file)
        model.check(); try await wait(model); XCTAssertEqual(model.phase, .available); XCTAssertTrue(model.canDownload)
    }
    @MainActor func testDownloadReportsBytesAndFinishesOnlyAfterVerification() async throws {
        let model = AppUpdateController(current: AppUpdateVersion("0.42.0")!, folder: try folder(), transport: Update042Fixture(release: release(), data: bytes()))
        model.check(); try await wait(model); XCTAssertTrue(model.canDownload); model.download(); try await wait(model)
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.file)), bytes()); XCTAssertEqual(model.progress.fraction, 1); XCTAssertFalse(model.canDownload)
    }
    @MainActor func testDamagedDownloadIsRemovedAndCanBeRetried() async throws {
        let root = try folder(), model = AppUpdateController(current: AppUpdateVersion("0.42.0")!, folder: root, transport: Update042Fixture(release: release(), data: Data(repeating: 0, count: bytes().count)))
        model.check(); try await wait(model); model.download(); try await wait(model)
        XCTAssertEqual(model.phase, .failed); XCTAssertNil(model.file); XCTAssertTrue(model.canDownload); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testCancelledDownloadAndLateCallbacksDoNotOverwriteNewState() async throws {
        let root = try folder(), model = AppUpdateController(current: AppUpdateVersion("0.42.0")!, folder: root, transport: Update042Fixture(release: release(), data: bytes(), slow: true))
        model.check(); try await wait(model); model.download(); try await Task.sleep(nanoseconds: 15_000_000); model.cancel(); XCTAssertEqual(model.phase, .cancelled)
        model.check(); try await wait(model); try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.phase, .available); XCTAssertNil(model.file); XCTAssertTrue(model.canDownload); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testCancelledOldCheckCannotReplaceTheNewRelease() async throws {
        let transport = Update042SlowCheck(first: release(version: "0.43.0"), second: release(version: "0.44.0")), model = AppUpdateController(current: AppUpdateVersion("0.42.0")!, folder: try folder(), transport: transport)
        model.check(); while await transport.calls == 0 { await Task.yield() }; model.cancel(); model.check(); try await wait(model); try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(model.release?.version, AppUpdateVersion("0.44.0")); XCTAssertEqual(model.phase, .available)
    }
    func testRealDownloadDelegateReportsProgressAndRejectsHTTPError() async throws {
        let server = try Update042HTTPServer(folder: folder(), data: bytes()); defer { server.stop() }
        let probe = Update042ProgressProbe(), file = server.folder.appendingPathComponent("download.dmg"), value = release(asset: server.url("ok"))
        try await AppUpdateNetwork().download(value, to: file) { probe.add($0) }; try AppUpdateValidation.verify(file, release: value)
        XCTAssertTrue(probe.count > 0); XCTAssertTrue(probe.received > 0); XCTAssertEqual(try Data(contentsOf: file), bytes())
        do { try await AppUpdateNetwork().download(release(asset: server.url("missing")), to: server.folder.appendingPathComponent("missing.dmg")) { _ in }; XCTAssertTrue(false, "HTTP 404 must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.folder.appendingPathComponent("missing.dmg").path))
    }
    func testRealDownloadCancellationDoesNotLeaveAnInstaller() async throws {
        let data = Data(repeating: 7, count: 4*1024*1024), server = try Update042HTTPServer(folder: folder(), data: data); defer { server.stop() }
        let probe = Update042ProgressProbe(), file = server.folder.appendingPathComponent("cancelled.dmg"), value = release(data, asset: server.url("slow"))
        let task = Task { try await AppUpdateNetwork().download(value, to: file) { probe.add($0) } }
        for _ in 0..<400 { if probe.count > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(probe.count > 0); task.cancel()
        do { try await task.value; XCTAssertTrue(false, "Cancelled transfer must fail") } catch { XCTAssertTrue(FolioCancellation.matches(error)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

struct Update042Fixture: AppUpdateTransport {
    let release: AppUpdateRelease; let data: Data; var slow = false
    func latest() async throws -> AppUpdateRelease { release }
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws {
        progress(AppUpdateProgress(received: release.size/2, expected: release.size))
        do { try await Task.sleep(nanoseconds: slow ? 60_000_000 : 5_000_000) } catch { progress(AppUpdateProgress(received: release.size, expected: release.size)); throw error }
        try data.write(to: file); progress(AppUpdateProgress(received: release.size, expected: release.size))
    }
}
actor Update042SlowCheck: AppUpdateTransport {
    let first: AppUpdateRelease; let second: AppUpdateRelease; private(set) var calls = 0
    init(first: AppUpdateRelease, second: AppUpdateRelease) { self.first = first; self.second = second }
    func latest() async throws -> AppUpdateRelease { calls += 1; if calls == 1 { try? await Task.sleep(nanoseconds: 120_000_000); return first }; return second }
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws { throw CancellationError() }
}
actor Update042OfflineCheck: AppUpdateTransport {
    let release: AppUpdateRelease; private var calls = 0
    init(release: AppUpdateRelease) { self.release = release }
    func latest() async throws -> AppUpdateRelease { calls += 1; if calls == 1 { throw URLError(.notConnectedToInternet) }; return release }
    func download(_ release: AppUpdateRelease, to file: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void) async throws { throw CancellationError() }
}
final class Update042ProgressProbe: @unchecked Sendable {
    private let lock = NSLock(); private var values: [AppUpdateProgress] = []
    func add(_ value: AppUpdateProgress) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var received: Int64 { lock.lock(); defer { lock.unlock() }; return values.last?.received ?? 0 }
}
final class Update042HTTPServer {
    let folder: URL; let port: Int; private let process: Process
    init(folder: URL, data: Data) throws {
        self.folder = folder; let bytes = folder.appendingPathComponent("source.dmg"), script = folder.appendingPathComponent("server.py")
        try data.write(to: bytes)
        try #"""
import http.server,sys,time
data=open(sys.argv[1],'rb').read()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  missing=self.path=='/missing'
  body=b'missing' if missing else data
  self.send_response(404 if missing else 200)
  self.send_header('Content-Length',str(len(body)));self.end_headers()
  try:
   for i in range(0,len(body),16384):
    self.wfile.write(body[i:i+16384]);self.wfile.flush()
    if self.path=='/slow':time.sleep(.01)
  except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()
"""#.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, bytes.path]; process.standardOutput = output; process.standardError = FileHandle.nullDevice; try process.run(); self.process = process
        var line = Data()
        while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty { if next[0] == 10 { break }; line.append(next) }
        guard let port = Int(String(data: line, encoding: .utf8) ?? "") else { process.terminate(); throw FolioError(message: "无法启动更新下载测试服务") }; self.port = port
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/"+path)! }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}
