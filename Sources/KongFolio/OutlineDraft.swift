import Foundation

/// The notes outline while the reader is arranging it: entries can be moved up and down or to another chapter, tagged,
/// merged when they quote the same words, or left out. Export reads the result.
struct OutlineDraft {
    var sections: [NotesSection]

    init(sections: [NotesSection]) { self.sections = sections }

    var count: Int { sections.reduce(0) { $0 + $1.notes.count } }

    private func locate(_ id: String) -> (section: Int, index: Int)? {
        for (s, section) in sections.enumerated() {
            if let i = section.notes.firstIndex(where: { $0.id == id }) { return (s, i) }
        }
        return nil
    }

    /// Moves an entry one place up (negative) or down inside its chapter.
    mutating func move(_ id: String, by step: Int) {
        guard let (s, i) = locate(id) else { return }
        let target = i + step
        guard sections[s].notes.indices.contains(target) else { return }
        sections[s].notes.swapAt(i, target)
    }

    /// Puts an entry at the end of another chapter.
    mutating func move(_ id: String, toSection destination: Int) {
        guard let (s, i) = locate(id), sections.indices.contains(destination), destination != s else { return }
        let note = sections[s].notes.remove(at: i)
        sections[destination].notes.append(note)
    }

    mutating func remove(_ id: String) {
        guard let (s, i) = locate(id) else { return }
        sections[s].notes.remove(at: i)
    }

    mutating func setTags(_ id: String, _ tags: [String]) {
        guard let (s, i) = locate(id) else { return }
        sections[s].notes[i].tags = tags
    }

    /// "重点, 待查" → ["重点", "待查"] (commas of both kinds and spaces separate; empty ones and repeats go).
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n ")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func key(_ note: AnnotationNote) -> String {
        var cache: [String: String] = [:]
        let quote = FoldedText(note.quote, simplify: true, cache: &cache).text as String
        return quote
    }

    /// Entries that quote the same words (ignoring 繁简, spacing and case) become one: the first stays, the others'
    /// notes and tags are added to it. Returns how many entries went.
    @discardableResult mutating func mergeDuplicates() -> Int {
        var first: [String: (section: Int, index: Int)] = [:]
        var removed = 0
        for s in sections.indices {
            var i = 0
            while i < sections[s].notes.count {
                let note = sections[s].notes[i]
                let key = Self.key(note)
                guard !key.isEmpty else { i += 1; continue }
                if let home = first[key] {
                    var target = sections[home.section].notes[home.index]
                    if !note.note.isEmpty && !target.note.contains(note.note) { target.note += (target.note.isEmpty ? "" : "\n") + note.note }
                    for tag in note.tags where !target.tags.contains(tag) { target.tags.append(tag) }
                    sections[home.section].notes[home.index] = target
                    sections[s].notes.remove(at: i)
                    removed += 1
                } else {
                    first[key] = (s, i)
                    i += 1
                }
            }
        }
        return removed
    }

    /// Chapters left with nothing in them are dropped from the export.
    var exportSections: [NotesSection] { sections.filter { !$0.notes.isEmpty } }
}
