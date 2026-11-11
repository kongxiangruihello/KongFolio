import SwiftUI

struct SignatureToolbarMenu: View {
    @ObservedObject var workspace:Workspace
    var showTitle = false
    var body:some View {
        Menu {
            if let store = workspace.store { Button("签名管理…") { store.showSignatureManager = true } }
            Button("导入图片签名…") { workspace.showSignatureImport = true }
            Divider()
            if workspace.signatures.isEmpty { Text("尚无已保存的签名") }
            else {
                ForEach(workspace.signatures) { template in
                    Button("放置："+template.name) { workspace.beginPlacing(template) }
                        .disabled(workspace.count == 0 || workspace.readingLocked)
                }
            }
            if workspace.readingLocked { Text("放置签名前请切换到编辑模式") }
        } label:{
            if showTitle { Label("图片签名",systemImage:"signature") }
            else { Image(systemName:"signature").frame(width:28,height:28) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("图片签名：导入图片，或放置已保存的签名")
        .accessibilityLabel("图片签名")
    }
}
