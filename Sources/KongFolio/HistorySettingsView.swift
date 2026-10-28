import SwiftUI

struct HistorySettingsView: View {
    let storage: URL
    @Environment(\.dismiss) private var dismiss
    @State private var policy = HistoryPolicy()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("历史版本与备份空间").font(.headline)
            Stepper("每个文件最多 \(policy.maximumEntries) 个版本", value: $policy.maximumEntries, in: 2...100)
            Picker("每个文件容量", selection: $policy.perFileMB) { ForEach([16, 64, 128, 256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0) MB").tag($0) } }
            Picker("全部历史容量", selection: $policy.totalMB) { ForEach([256, 512, 1024, 2048, 4096, 8192, 16384], id: \.self) { Text("\($0) MB").tag($0) } }
            Text("按最早版本清理，每个文件至少保留最近 2 个版本，因此大文件可能超过容量目标。清理仅涉及历史版本，未保存的恢复副本、冲突副本和原件保留。").font(.caption).foregroundStyle(.secondary)
            Text(message).font(.caption).textSelection(.enabled)
            PanelRow {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存并整理历史") {
                    do { try policy.save(storage: storage); try HistoryRetention.apply(storage: storage); refresh() }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).adaptiveSheet(width: 560, height: 360, minimumWidth: 360)
        .onAppear { policy = HistoryPolicy.load(storage: storage); refresh() }
    }
    private func refresh() {
        do { let usage = try HistoryRetention.usage(storage: storage); message = "共 \(usage.files) 个文件、\(usage.versions) 个历史版本，约 " + ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file) }
        catch { message = error.localizedDescription }
    }
}
