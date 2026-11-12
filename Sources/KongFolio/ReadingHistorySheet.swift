import SwiftUI

enum ReadingHistoryPage: Int, CaseIterable, Identifiable {
    case bookshelf = 0, history = 2, shortcuts = 1
    var id: Self { self }

    var title: String {
        switch self {
        case .bookshelf: "个人书架"
        case .history: "阅读历史"
        case .shortcuts: "阅读快捷方式"
        }
    }

    var icon: String {
        switch self {
        case .bookshelf: "books.vertical"
        case .history: "clock"
        case .shortcuts: "link"
        }
    }

    var help: String {
        switch self {
        case .bookshelf: "浏览和整理你手动加入书架的文献"
        case .history: "查看最近打开的文献与上次阅读位置"
        case .shortcuts: "管理继续阅读或跳到指定页的快捷方式"
        }
    }
}

extension WorkspaceStore {
    func openReadingHistory(_ page: ReadingHistoryPage) {
        libraryTab = page.rawValue
        showReadingHistory = true
    }
}

struct ReadingHistorySheet: View {
    @ObservedObject var store: WorkspaceStore
    private var page: ReadingHistoryPage { ReadingHistoryPage(rawValue:store.libraryTab) ?? .bookshelf }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("个人书架与阅读记录").font(.headline)
                Spacer()
                Button("完成") { store.showReadingHistory = false }.keyboardShortcut(.cancelAction)
            }
            PanelRow {
                ForEach(ReadingHistoryPage.allCases) { destination in
                    navigationButton(destination)
                }
            }
            Divider()
            pageContent
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.padding(20).adaptiveSheet(width:980,height:680,minimumWidth:360)
            .modifier(ShelfQueueProblemAlert(store:store,inShelf:true))
    }

    private func navigationButton(_ destination:ReadingHistoryPage) -> some View {
        let selected = page == destination
        return Button {
            store.libraryTab = destination.rawValue
        } label: {
            Label(destination.title,systemImage:destination.icon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal,10)
                .frame(minHeight:32)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                            in:RoundedRectangle(cornerRadius:7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(destination.help)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reading-history-page-\(destination.rawValue)")
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .bookshelf:
            BookLibraryView(store:store,library:store.library)
        case .history:
            ReadingHistoryOnlyView(store:store)
        case .shortcuts:
            ShortcutManagerView(store:store,library:store.library)
        }
    }
}
