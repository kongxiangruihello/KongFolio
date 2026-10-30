#!/bin/bash
# Optional live integration probe: downloads the latest public release without installing it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kongfolio-update-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Probe.swift" <<'SWIFT'
import Foundation
struct FolioError: LocalizedError { let message: String; var errorDescription: String? { message } }
final class ProgressProbe: @unchecked Sendable {
    let lock = NSLock(); var ticks = 0; var received: Int64 = 0
    func update(_ progress: AppUpdateProgress) { lock.lock(); ticks += 1; received = max(received, progress.received); lock.unlock() }
}
@main struct Probe {
    static func main() async throws {
        let release = try await AppUpdateNetwork().latest(), probe = ProgressProbe()
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), file = folder.appendingPathComponent(release.filename)
        try await AppUpdateNetwork().download(release, to: file) { probe.update($0) }
        try AppUpdateValidation.verify(file, release: release)
        let report: [String: Any] = ["version": release.version.description, "filename": release.filename, "bytes": release.size, "progressCallbacks": probe.ticks, "receivedBytes": probe.received, "sha256": release.sha256, "verified": true, "installed": false]
        guard probe.ticks > 0, probe.received > 0 else { throw FolioError(message: "No real download progress callbacks") }
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/KongFolio/AppUpdate.swift" "$WORK/Probe.swift" -o "$WORK/probe"
"$WORK/probe" "$WORK"
