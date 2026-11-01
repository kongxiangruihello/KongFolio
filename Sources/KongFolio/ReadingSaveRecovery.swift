import SwiftUI
import UniformTypeIdentifiers

struct ReadingSaveRecoveryFooter: View {
    @ObservedObject var journal:ReadingJournal
    @State private var busy = false
    @State private var message = ""
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(journal.saveStatus+(journal.lastVerifiedSave.map{" · "+$0.formatted(date:.omitted,time:.standard)} ?? "")).font(.caption).foregroundStyle(journal.error == nil ? Color.secondary : .red).lineLimit(3)
                if journal.error != nil { Button("重试保存") { Task { do { try await journal.flush() } catch { message = error.localizedDescription } } };Button("另存应急副本…",action:rescue).disabled(busy || journal.unreadable) }
            }
            if busy { ProgressView("正在保存应急副本…").controlSize(.small) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
    }
    private func rescue() {
        let panel = NSSavePanel();panel.allowedContentTypes = [.zip];panel.nameFieldStringValue = "KongFolio-未保存资料-"+String(UUID().uuidString.prefix(8))+".zip"
        guard panel.runModal() == .OK,let file = panel.url else { return }
        do {
            let expected = try FileBaseline.capture(file),state = journal.state,images = journal.pendingImages,assets = journal.folder.appendingPathComponent("Assets")
            busy = true;Task { do { try await ReadingEmergencyWriter.shared.write(state,pending:images,assets:assets,to:file,expected:expected);message = "应急副本已保存；原位置仍需重试保存" } catch { message = error.localizedDescription };busy = false }
        } catch { message = error.localizedDescription }
    }
}
