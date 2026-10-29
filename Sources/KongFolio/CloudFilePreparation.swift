import Foundation

/// Download preparation is cancellable and never waits on the UI thread. File parsing remains on a worker.
enum CloudFilePreparation {
    static func prepare(_ urls: [URL], progress: @escaping @Sendable (String) -> Void) async throws {
        for original in urls {
            var url = original
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values.isUbiquitousItem == true else { continue }
            if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded { continue }
            progress("等待 iCloud 下载")
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(300)
            while true {
                try Task.checkCancellation(); url.removeAllCachedResourceValues()
                let state = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
                if let error = state.ubiquitousItemDownloadingError { throw error }
                if state.ubiquitousItemDownloadingStatus == .current || state.ubiquitousItemDownloadingStatus == .downloaded { break }
                guard Date() < deadline else { throw FolioError(message: "云文件尚未下载完成，可先阅读其他文件后重试") }
                progress("正在下载 iCloud 文件")
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}
