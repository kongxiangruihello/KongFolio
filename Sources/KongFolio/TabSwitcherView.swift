import SwiftUI

/// ⌘P: type part of a file name, press Return to go to that tab. Made for dozens of open files.
struct TabSwitcherView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [OpenTab] { store.switcherResults(for: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("输入文件名的一部分，回车切换", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit(choose)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            let list = results
            if list.isEmpty {
                Text("没有匹配的标签页").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { offset, tab in
                                row(tab, selected: offset == min(highlighted, list.count - 1))
                                    .id(offset)
                                    .onTapGesture { open(tab) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 520, height: 360)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ tab: OpenTab, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.switcherIcon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.switcherTitle).lineLimit(1).truncationMode(.middle)
                if let detail = tab.switcherDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if tab.id == store.selectedID { Text("当前").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = min(max(0, min(highlighted, count - 1) + delta), count - 1)
    }

    private func choose() {
        let list = results
        guard !list.isEmpty else { return }
        open(list[min(highlighted, list.count - 1)])
    }

    private func open(_ tab: OpenTab) {
        store.select(tab.id)
        dismiss()
    }
}
