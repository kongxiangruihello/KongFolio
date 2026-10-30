import XCTest
import Foundation
#if canImport(KongFolioUpdateKit)
import KongFolioUpdateKit
#endif
@testable import KongFolio

final class OnlineInstall042Tests: XCTestCase {
    let identifier = "com.kongfolio.qa.installtests"
    func root() throws -> URL { try Release027Tests().folder().resolvingSymlinksInPath() }
    func bundle(_ url: URL, version: String, identifier custom: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents"), mac = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": custom ?? identifier, "CFBundleExecutable": "KongFolio", "CFBundlePackageType": "APPL", "CFBundleName": "KongFolio", "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: mac.appendingPathComponent("KongFolio"))
        let resources = contents.appendingPathComponent("Resources"); try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(("fixture "+version).utf8).write(to: resources.appendingPathComponent("resource.txt")); try sign(url)
    }
    func sign(_ url: URL) throws {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = ["--force", "--sign", "-", url.path]; process.standardOutput = output; process.standardError = output; try process.run(); let diagnostic = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallFailure("无法签署隔离测试应用："+(String(data: diagnostic, encoding: .utf8) ?? "")) }
    }
    func pair() throws -> (URL, URL, URL) {
        let root = try root(), source = root.appendingPathComponent("Job/KongFolio.app", isDirectory: true), target = root.appendingPathComponent("Applications/KongFolio.app", isDirectory: true)
        try bundle(source, version: "3.0.0"); try bundle(target, version: "2.0.0"); return (root, source, target)
    }
    func job(_ root: URL, _ source: URL, _ target: URL, requested: String = "3.0.0") throws -> UpdateInstallJob {
        try UpdateInstallCore.prepare(source: source, target: target, requestedVersion: requested, expectedIdentifier: identifier, work: root.appendingPathComponent("Job", isDirectory: true), resultURL: root.appendingPathComponent("Storage/Updates/last-install.json"), parentLaunchDate: nil)
    }
    func changeBuild(_ app: URL) throws {
        let file = app.appendingPathComponent("Contents/Info.plist"); var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]; info["CFBundleVersion"] = "999"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file); try sign(app)
    }
    func testAtomicInstallPreservesPreviousApplicationAndSource() throws {
        let (root, source, target) = try pair(), job = try job(root, source, target), transaction = try UpdateInstallCore.install(job)
        defer { UpdateInstallCore.finish(transaction) }
        XCTAssertEqual(try UpdateInstallCore.inspect(target), job.incoming); XCTAssertEqual(try UpdateInstallCore.inspect(transaction.backup), job.original); XCTAssertEqual(try UpdateInstallCore.inspect(source), job.incoming)
    }
    func testLaunchFailureCanRollbackWithoutChangingReaderData() throws {
        let (root, source, target) = try pair(), note = root.appendingPathComponent("my-reading-notes.json"), bytes = Data("我的摘录和札记".utf8); try bytes.write(to: note)
        let job = try job(root, source, target), transaction = try UpdateInstallCore.install(job); defer { UpdateInstallCore.finish(transaction) }
        try UpdateInstallCore.rollback(transaction)
        XCTAssertEqual(try UpdateInstallCore.inspect(target), job.original); XCTAssertEqual(try Data(contentsOf: note), bytes); XCTAssertEqual(try UpdateInstallCore.inspect(transaction.backup), job.incoming)
    }
    func testInvalidSourceSignatureStopsBeforeReplacingTheInstalledApp() throws {
        let (root, source, target) = try pair(), before = try UpdateInstallCore.inspect(target)
        try Data("damaged".utf8).write(to: source.appendingPathComponent("Contents/Resources/resource.txt"))
        XCTAssertThrowsError(try job(root, source, target)); XCTAssertEqual(try UpdateInstallCore.inspect(target), before)
    }
    func testInstalledApplicationChangingAfterPreparationIsNotOverwritten() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target); try changeBuild(target)
        let changed = try UpdateInstallCore.inspect(target); XCTAssertThrowsError(try UpdateInstallCore.install(prepared)); XCTAssertEqual(try UpdateInstallCore.inspect(target), changed)
    }
    func testPreparedSourceChangingIsNotInstalled() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target); try changeBuild(source)
        XCTAssertThrowsError(try UpdateInstallCore.install(prepared)); XCTAssertEqual(try UpdateInstallCore.inspect(target), prepared.original)
    }
    func testRollbackDoesNotOverwriteAnotherInstalledVersion() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target), transaction = try UpdateInstallCore.install(prepared); defer { UpdateInstallCore.finish(transaction) }
        let previous = root.appendingPathComponent("intervening-copy.app"); try FileManager.default.moveItem(at: target, to: previous); try bundle(target, version: "4.0.0")
        XCTAssertThrowsError(try UpdateInstallCore.rollback(transaction)); XCTAssertEqual(try UpdateInstallCore.inspect(target).version, "4.0.0"); XCTAssertEqual(try UpdateInstallCore.inspect(transaction.backup), prepared.original)
    }
    func testExistingUpdateLockPreventsASecondInstaller() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target), lock = target.deletingLastPathComponent().appendingPathComponent("."+target.lastPathComponent+".update-lock")
        try Data("another-installer".utf8).write(to: lock)
        XCTAssertThrowsError(try UpdateInstallCore.install(prepared)); XCTAssertEqual(try UpdateInstallCore.inspect(target), prepared.original); XCTAssertEqual(try String(contentsOf: lock), "another-installer")
    }
    func testDowngradeWrongVersionAndWrongIdentifierAreRejected() throws {
        let (root, source, target) = try pair(); XCTAssertThrowsError(try job(root, source, target, requested: "9.0.0"))
        try FileManager.default.removeItem(at: source); try bundle(source, version: "1.0.0"); XCTAssertThrowsError(try job(root, source, target, requested: "1.0.0"))
        try FileManager.default.removeItem(at: source); try bundle(source, version: "3.0.0", identifier: "com.kongfolio.qa.another"); XCTAssertThrowsError(try job(root, source, target))
    }
    func testSymlinkTargetIsRejected() throws {
        let (root, source, target) = try pair(), alias = target.deletingLastPathComponent().appendingPathComponent("alias.app"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try job(root, source, alias))
    }
    func testJobFileAndLaunchReceiptAreBoundToTheSameJob() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target); try prepared.write()
        XCTAssertEqual(try UpdateInstallJob.load(prepared.file).id, prepared.id); try prepared.signal(prepared.startedFile); XCTAssertTrue(prepared.signalled(prepared.startedFile))
        let next = try job(root, source, target); XCTAssertFalse(next.signalled(next.startedFile))
        let other = root.appendingPathComponent("other/job.json"); try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: other, withDestinationURL: prepared.file)
        XCTAssertThrowsError(try UpdateInstallJob.load(other))
    }
    func testLaunchReceiptCannotWriteOutsideThePrivateJobDirectory() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target), note = root.appendingPathComponent("notes.json"), bytes = Data("保留".utf8); try bytes.write(to: note)
        XCTAssertThrowsError(try prepared.signal(note)); XCTAssertEqual(try Data(contentsOf: note), bytes)
    }
    func testResultIsStoredSeparatelyAndKeepsBackupLocation() throws {
        let (root, source, target) = try pair(), prepared = try job(root, source, target), transaction = try UpdateInstallCore.install(prepared); defer { UpdateInstallCore.finish(transaction) }
        let value = UpdateInstallResult(job: prepared, backup: transaction.backup, status: "installed", message: "安装完成"); try value.write(to: prepared.resultURL)
        let read = try JSONDecoder().decode(UpdateInstallResult.self, from: Data(contentsOf: prepared.resultURL)); XCTAssertEqual(read.version, "3.0.0"); XCTAssertEqual(read.previousVersion, "2.0.0"); XCTAssertEqual(read.backup, transaction.backup)
        XCTAssertThrowsError(try value.write(to: root.appendingPathComponent("notes.json")))
    }
}
