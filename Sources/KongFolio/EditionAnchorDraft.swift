import AppKit
import PDFKit

@MainActor final class EditionAnchorDraft: ObservableObject {
    var generation = UUID()
    @Published var name = "版本对应"
    @Published var rightPath = ""
    @Published var leftPDF: PDFDocument?
    @Published var rightPDF: PDFDocument?
    @Published var left = 0
    @Published var right = 0
    @Published var pairs: [EditionCorrespondence.Pair] = []
    @Published var editingID: UUID?
}
extension ResearchController {
    func loadEditionLeft(_ draft:EditionAnchorDraft,workspace:Workspace) {
        guard !busy else { return }
        let token = UUID(), path = workspace.displayPath; draft.generation = token
        perform {
            let archive = try await workspace.snapshotForBackgroundSave()
            guard draft.generation == token, workspace.displayPath == path else { throw FolioError(message:"已切换书籍，旧版本预览未套用") }
            draft.leftPDF = PDFDocument(data:archive.pdf)
            return "当前版本已载入，请选择右侧版本"
        }
    }
    func loadEditionRight(_ draft:EditionAnchorDraft,file:URL) {
        let token = draft.generation
        perform {
            try await CloudFilePreparation.prepare([file]) { _ in }
            let bytes = try await self.background { try Data(contentsOf:file) }
            guard let doc = PDFDocument(data:bytes), !doc.isLocked, doc.pageCount > 0 else { throw FolioError(message:"对照版本无法读取或需要密码") }
            guard draft.generation == token else { throw FolioError(message:"已切换书籍，请重新选择对照版本") }
            draft.rightPath = file.path; draft.rightPDF = doc; draft.right = min(draft.right,max(0,doc.pageCount-1))
            return "对照版本已载入，可翻页建立对应"
        }
    }
}
