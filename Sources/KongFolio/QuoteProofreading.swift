import Foundation

struct QuoteProofreading: Equatable, Sendable {
    struct Change: Identifiable, Equatable, Sendable {
        let id: Int
        let originalRange: NSRange
        let revisedRange: NSRange
        let original: String
        let revised: String
    }

    let original: String
    let revised: String
    let changes: [Change]
    let coarse: Bool

    init(original: String, revised: String) throws {
        self.original = original
        self.revised = revised
        let result = try DetailedDifference.text(original,revised,budget:3000)
        var delta = 0
        changes = result.chunks.map { chunk in
            let before = chunk.before ?? NSRange(location:(chunk.after?.location ?? delta)-delta,length:0)
            let after = chunk.after ?? NSRange(location:before.location+delta,length:0)
            delta += after.length-before.length
            return Change(id:chunk.id,originalRange:before,revisedRange:after,original:chunk.old,revised:chunk.new)
        }
        coarse = result.coarse
    }

    func applying(_ selected: Set<Int>) -> String {
        let result = NSMutableString(string:original)
        for change in changes.reversed() where selected.contains(change.id) {
            result.replaceCharacters(in:change.originalRange,with:change.revised)
        }
        return result as String
    }
}
