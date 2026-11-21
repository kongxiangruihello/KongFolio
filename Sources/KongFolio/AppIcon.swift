import SwiftUI

/// Applies the same color to a feature wherever its symbol appears.
struct AppIcon: View {
    let symbol: String
    let tone: Color?

    init(_ symbol: String, tone: Color? = nil) {
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        let primary = tone ?? Self.color(for: symbol)
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(primary, primary.opacity(0.75), primary.opacity(0.58))
    }

    static let onAccent = Color(red: 0.76, green: 0.93, blue: 1)

    private static func color(for symbol: String) -> Color {
        switch symbol {
        case "text.viewfinder", "doc.text.magnifyingglass", "plus.magnifyingglass", "minus.magnifyingglass":
            return Color(nsColor: .systemTeal)
        case "square.and.arrow.down", "square.and.arrow.up", "square.stack.3d.up.fill":
            return Color(nsColor: .systemBlue)
        default:
            break
        }
        let family = symbol.split(separator: ".", maxSplits: 1).first ?? ""
        switch family {
        case "trash", "exclamationmark", "minus", "minusmark":
            return Color(nsColor: .systemRed)
        case "highlighter", "star", "bookmark", "folder", "flag", "clock", "sun", "sparkles":
            return Color(nsColor: .systemOrange)
        case "checkmark", "plus", "play", "forward", "tray":
            return Color(nsColor: .systemGreen)
        case "text", "textformat", "pencil", "square", "note", "signature", "bold", "italic", "underline",
             "strikethrough", "curlybraces", "list", "eraser", "line", "lineweight":
            return Color(nsColor: .systemPurple)
        case "photo", "camera", "scanner", "tablecells", "magnifyingglass", "scope", "eye", "viewfinder":
            return Color(nsColor: .systemTeal)
        case "book", "books", "bookshelf", "briefcase", "newspaper", "archivebox":
            return Color(nsColor: .systemIndigo)
        default:
            return Color(nsColor: .systemBlue)
        }
    }
}

extension Label where Title == Text, Icon == AppIcon {
    init(_ title: LocalizedStringKey, appIcon symbol: String, tone: Color? = nil) {
        self.init(title: { Text(title) }, icon: { AppIcon(symbol, tone: tone) })
    }

    init<S: StringProtocol>(_ title: S, appIcon symbol: String, tone: Color? = nil) {
        self.init(title: { Text(title) }, icon: { AppIcon(symbol, tone: tone) })
    }
}

struct AppEmptyState: View {
    let title: LocalizedStringKey
    let symbol: String
    let explanation: Text?

    init(_ title: LocalizedStringKey, appIcon symbol: String, description: Text? = nil) {
        self.title = title
        self.symbol = symbol
        explanation = description
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, appIcon: symbol)
        } description: {
            if let explanation { explanation }
        }
    }
}
