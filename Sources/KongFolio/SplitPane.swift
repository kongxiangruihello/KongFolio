import SwiftUI

/// The second document of side-by-side reading: its own header and a full reading canvas (scrolling, selecting,
/// marking and excerpting all work as in a tab of its own).
struct SplitPane: View {
    @ObservedObject var primary: Workspace
    @ObservedObject var partner: Workspace
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if partner.count > 0 {
                PDFCanvas(workspace: partner)
            } else if partner.needsLoad {
                VStack(spacing: 10) {
                    Text("这个文件还没有读取").foregroundStyle(.secondary)
                    Button("读取这个文件") { partner.ensureLoaded() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(partner.busy ? "正在读取…" : "没有可显示的内容").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: primary.selection) { _, page in
            if primary.synchronizedSelection == page { primary.synchronizedSelection = nil; return }
            guard primary.splitSync, partner.count > 0, primary.store?.research.warning(path:primary.displayPath ?? "") == nil, primary.store?.research.warning(path:partner.displayPath ?? "") == nil else { return }
            let target = min(max(0, primary.activeEdition?.mapped(page, fromLeft: primary.activeEdition?.isLeft(primary.displayPath) == true) ?? (page + primary.splitOffset)), partner.count - 1)
            if target != partner.selection { partner.synchronizedSelection = target; partner.selectPage(target) }
        }
        .onChange(of: partner.selection) { _, page in
            if partner.synchronizedSelection == page { partner.synchronizedSelection = nil; return }
            guard primary.splitSync, primary.count > 0, primary.store?.research.warning(path:primary.displayPath ?? "") == nil, primary.store?.research.warning(path:partner.displayPath ?? "") == nil else { return }
            let target = min(max(0, primary.activeEdition?.mapped(page, fromLeft: primary.activeEdition?.isLeft(primary.displayPath) != true) ?? (page - primary.splitOffset)), primary.count - 1)
            if target != primary.selection { primary.synchronizedSelection = target; primary.selectPage(target) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            Text(partner.displayName).font(.caption.bold()).lineLimit(1).truncationMode(.middle)
                .help(partner.displayPath ?? "")
            if partner.count > 0 { Text("\(partner.selection + 1) / \(partner.count) 页").font(.caption).foregroundStyle(.secondary).fixedSize() }
            Spacer(minLength: 4)
            Toggle("同步翻页", isOn: Binding(get: { primary.splitSync }, set: { enable in
                primary.splitSync = enable
                // The two documents rarely have the same page numbers: syncing keeps the gap they had when it was switched on.
                if enable { primary.splitOffset = partner.selection - primary.selection }
            }))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("开启后，翻其中一份文档时另一份跟着翻，保持开启时的页码差")
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("关闭并排阅读")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
