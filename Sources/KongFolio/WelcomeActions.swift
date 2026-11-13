import SwiftUI

struct WelcomeActions: View {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered: FileToolbarAction?
    @FocusState private var focused: FileToolbarAction?

    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:12) { buttons(compact:false) }
                .fixedSize(horizontal:true,vertical:false)
            HStack(spacing:8) { buttons(compact:true) }
                .fixedSize(horizontal:true,vertical:false)
            VStack(spacing:8) { buttons(compact:false) }
        }
        .onDisappear { hovered = nil }
    }

    @ViewBuilder private func buttons(compact: Bool) -> some View {
        if let store = workspace.store {
            action(.books,title:"个人书架",compact:compact) { store.openReadingHistory(.bookshelf) }
        }
        action(.open,title:FileToolbarAction.open.title,compact:compact) { workspace.open() }
        if let store = workspace.store {
            action(.library,title:FileToolbarAction.library.title,compact:compact) {
                store.openReadingDesk(.search,window:true)
            }
        }
    }

    private func action(_ item:FileToolbarAction,title:String,compact:Bool,perform:@escaping () -> Void) -> some View {
        let highlighted = isEnabled && hovered == item
        let keyboardFocused = isEnabled && focused == item
        return Button(action:perform) {
            Group {
                if compact {
                    VStack(spacing:3) {
                        Image(systemName:item.symbol)
                        Text(title)
                    }
                    .frame(minWidth:58)
                } else {
                    Label(title,systemImage:item.symbol).labelStyle(.titleAndIcon)
                }
            }
                .accessibilityLabel(title)
                .font(.system(size:compact ? 12 : 14,weight:.medium))
                .foregroundStyle(highlighted ? .white : Color.primary)
                .padding(.horizontal,compact ? 7 : 14)
                .frame(minHeight:compact ? 42 : 36)
                .background {
                    RoundedRectangle(cornerRadius:9)
                        .fill(highlighted ? Brand.accent : Color.primary.opacity(0.07))
                }
                .overlay {
                    RoundedRectangle(cornerRadius:9)
                        .strokeBorder(keyboardFocused ? Brand.accent : .clear,lineWidth:2)
                }
                .contentShape(RoundedRectangle(cornerRadius:9))
        }
        .buttonStyle(.plain)
        .focused($focused,equals:item)
        .onHover { inside in
            if inside { hovered = item }
            else if hovered == item { hovered = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:highlighted)
    }
}
