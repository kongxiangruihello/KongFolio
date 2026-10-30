import AppKit
#if canImport(KongFolioUpdateKit)
import KongFolioUpdateKit
#endif

enum AppUpdateInstaller {
    // AppKit's terminateLater runs a nested event loop. Start it outside a Swift task,
    // so the delegate's asynchronous save task can acquire the main actor.
    @MainActor static func deferTermination(_ action: @escaping @MainActor () -> Void) { DispatchQueue.main.async { action() } }
    static func prepare(_ file: URL, release: AppUpdateRelease, target: URL, expectedIdentifier: String, resultURL: URL, parentLaunchDate: Date?) throws -> UpdateInstallJob {
        try UpdateInstallCore.writableTarget(target)
        try AppUpdateValidation.verify(file, release: release); try Task.checkCancellation()
        let work = file.deletingLastPathComponent().appendingPathComponent("Install-"+UUID().uuidString, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let mount = work.appendingPathComponent("mount", isDirectory: true), source = work.appendingPathComponent("KongFolio.app", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attached = false
        defer { if attached { try? run("/usr/bin/hdiutil", ["detach", mount.path]) } }
        do {
            try run("/usr/bin/hdiutil", ["attach", file.path, "-readonly", "-nobrowse", "-mountpoint", mount.path]); attached = true
            try Task.checkCancellation()
            let mounted = mount.appendingPathComponent("KongFolio.app")
            _ = try UpdateInstallCore.inspect(mounted)
            try FileManager.default.copyItem(at: mounted, to: source); try Task.checkCancellation()
            let job = try UpdateInstallCore.prepare(source: source, target: target, requestedVersion: release.version.description, expectedIdentifier: expectedIdentifier, work: work, resultURL: resultURL, parentLaunchDate: parentLaunchDate)
            try job.write(); return job
        } catch { try? FileManager.default.removeItem(at: source); throw error }
    }
    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments; process.standardOutput = output; process.standardError = output
        try process.run(); _ = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallFailure("无法准备安装包，可重新下载或使用手动安装") }
    }
    @MainActor static func launchHelper(_ job: UpdateInstallJob) async throws {
        let original = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KongFolioUpdater"), runner = job.work.appendingPathComponent("KongFolioUpdater")
        if !FileManager.default.fileExists(atPath: runner.path) { try FileManager.default.copyItem(at: original, to: runner) }
        try UpdateInstallCore.verifySignature(runner)
        let process = Process(); process.executableURL = runner; process.arguments = ["--job", job.file.path]
        let log = job.work.appendingPathComponent("helper.log"); _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]); let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output; try process.run(); try? output.close()
        for _ in 0..<40 {
            if job.signalled(job.readyFile) { return }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        try? job.signal(job.work.appendingPathComponent("abort"))
        throw UpdateInstallFailure("安装组件未能启动，已保留原程序，可使用手动安装")
    }
    static func acknowledgeLaunch() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--kongfolio-update-job"), index+1 < arguments.count,
              let job = try? UpdateInstallJob.load(URL(fileURLWithPath: arguments[index+1])),
              Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath() == job.target.standardizedFileURL.resolvingSymlinksInPath(),
              Bundle.main.bundleIdentifier == job.incoming.identifier,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == job.incoming.version else { return }
        try? job.signal(job.startedFile)
    }
}
