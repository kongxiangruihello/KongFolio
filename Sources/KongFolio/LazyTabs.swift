import CoreGraphics
import Foundation

/// Where the reader was in a document, so a tab that is loaded later (or again) opens at the same place.
struct ViewPosition: Codable, Equatable {
    var selection = 0
    var x: Double?
    var y: Double?
    var scale: Double?

    var point: CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// One tab as it is written to `Session.json`.
/// - `recovery`: the tab has unsaved changes; its content is in the recovery folder.
/// - `file` / `project`: the tab is unchanged since it was opened or saved, so only the path and reading position are kept.
///   Restoring costs nothing until the tab is selected, and quitting does not copy the document anywhere.
struct SessionEntry: Codable, Equatable {
    enum Kind: String, Codable { case recovery, file, project }
    var slot: String
    var kind: Kind
    var path: String? = nil
    var position: ViewPosition? = nil
    var layout: ReadingLayout? = nil
}

struct Session: Codable, Equatable {
    var entries: [SessionEntry] = []
    /// Slot of the tab that was in front.
    var selected: String? = nil

    /// Reads the current format, or the first one (a plain list of recovery slots).
    static func decode(_ data: Data) -> Session? {
        if let session = try? JSONDecoder().decode(Session.self, from: data) { return session }
        guard let slots = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Session(entries: slots.map { SessionEntry(slot: $0, kind: .recovery) })
    }
}
