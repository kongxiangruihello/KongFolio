import SwiftUI
import PDFKit

struct SaveConflictBanner: View {
    var copy: () -> Void
    var reload: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原文件在外部发生变化，已暂停覆盖。当前修改已保留。").font(.callout)
            PanelRow { Button("另存我的修改…", action: copy); Button("保留备份并重新载入", action: reload) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))
    }
}
