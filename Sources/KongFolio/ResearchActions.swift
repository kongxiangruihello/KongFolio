import AppKit
import PDFKit

extension ResearchController {
    func savePageRows(_ rows: [PrintedPageRow], workspace: Workspace, research: ResearchStore) {
        perform {
            guard let path = workspace.displayPath else { throw FolioError(message:"请先保存原书") }
            let values = rows.map(\.segment); try PrintedPageSegment.validate(values,count:workspace.count)
            let version = workspace.revision
            let archive = try await workspace.snapshotForBackgroundSave(), digest = workspace.fileBaseline?.digest ?? OCRPageCache.digest(archive.pdf)
            let binding = try await self.background { try ResearchSourceBinding.make(archive.pdf,digest:digest) }
            guard workspace.revision == version, workspace.displayPath == path else { throw FolioError(message:"准备期间原书已变化，请核对后重新保存页码") }
            try research.update { value in value.labels[path] = values; if value.identities == nil { value.identities = [:] }; value.identities?[path] = digest; if value.bindings == nil { value.bindings = [:] }; value.bindings?[path] = binding }
            research.setWarning(path:path,message:nil)
            return "页码对应与来源版本已保存"
        }
    }
    func confirmSource(_ w: Workspace, research: ResearchStore) {
        perform {
            guard let path = w.displayPath else { throw FolioError(message:"请先保存原书") }
            if let source = w.historySource, let baseline = w.fileBaseline { try await self.background { try baseline.verify(source) } }
            let archive = try await w.snapshotForBackgroundSave(), digest = w.fileBaseline?.digest ?? OCRPageCache.digest(archive.pdf)
            let binding = try await self.background { try ResearchSourceBinding.make(archive.pdf,digest:digest) }
            try research.bind(path:path,value:binding)
            return "已按当前核对过的原书更新关联；旧草稿仍保留，请分别核对"
        }
    }
    func insertAcademic(_ kind: AcademicInsertion) {
        let edit = kind.edit(academicText,selection:academicSelection)
        if let view = academicTextView {
            view.insertText(edit.replacement,replacementRange:edit.range); view.setSelectedRange(edit.selection); academicSelection = edit.selection
            academicText = view.string
        } else { academicSelection = edit.selection; academicText = (academicText as NSString).replacingCharacters(in:edit.range,with:edit.replacement) }
    }
    func previewAcademic() {
        let text = academicText, source = academicSource, root = academicStorage ?? FileManager.default.temporaryDirectory
        let digest = OCRPageCache.digest(Data(text.utf8))
        perform {
            self.phase = "生成 Word 排版预览"
            let folder = root.appendingPathComponent("AcademicPreviews").appendingPathComponent(UUID().uuidString)
            let url = folder.appendingPathComponent("学术整理稿预览.docx")
            let base = source.hasPrefix("/") ? URL(fileURLWithPath:source).deletingLastPathComponent() : nil
            try await self.background {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                do { let parsed = try AcademicMarkup.parse(text), document = try RichTextDocument(parsed.text,format:.markdown,baseURL:base); try RichTextWord.write(document,to:url,academic:parsed); try Task.checkCancellation() }
                catch { try? FileManager.default.removeItem(at:folder); throw error }
            }
            guard self.academicSource == source else { throw FolioError(message:"已切换原书，请重新生成当前草稿预览") }
            self.academicPreviewURL = url; self.academicPreviewDigest = digest
            return "已生成 Word 文件预览；修改后可刷新，最终分页由打开 Word 的软件决定。"
        }
    }
    func saveEdition(_ edition: EditionCorrespondence, workspace: Workspace, research: ResearchStore) {
        perform {
            guard workspace.displayPath == edition.leftPath else { throw FolioError(message:"当前书籍与对应表不同，请重新选择") }
            let version = workspace.revision
            let left = try await workspace.snapshotForBackgroundSave(), leftCount = workspace.count
            let url = URL(fileURLWithPath:edition.rightPath)
            try await CloudFilePreparation.prepare([url]) { phase in Task { @MainActor [weak self] in self?.phase = phase } }
            let rightBytes = try await self.background { try Data(contentsOf:url) }
            let digest = workspace.fileBaseline?.digest ?? OCRPageCache.digest(left.pdf)
            let bindings = try await self.background { () throws -> (ResearchSourceBinding,ResearchSourceBinding) in
                let right = try PDFDocument(data:rightBytes).unwrap("对照版本无法读取")
                try edition.validate(leftCount:leftCount,rightCount:right.pageCount)
                return (try ResearchSourceBinding.make(left.pdf,digest:digest),try ResearchSourceBinding.make(rightBytes,digest:OCRPageCache.digest(rightBytes)))
            }
            guard workspace.revision == version, workspace.displayPath == edition.leftPath else { throw FolioError(message:"准备期间原书已变化，请核对后重新建立对应") }
            try research.update { value in
                if let index = value.editions.firstIndex(where: { $0.id == edition.id }) { value.editions[index] = edition } else { value.editions.append(edition) }
                if value.bindings == nil { value.bindings = [:] }; value.bindings?[edition.leftPath] = bindings.0; value.bindings?[edition.rightPath] = bindings.1
            }
            research.setWarning(path:edition.leftPath,message:nil); research.setWarning(path:edition.rightPath,message:nil)
            return "版本对应与来源校验已保存"
        }
    }
    func promoteTrial(_ store: WorkspaceStore) {
        guard let recipe = trialRecipe, trialReport != nil, !store.batchQueue.running else { return }
        let files = NSOpenPanel(); files.allowedContentTypes = [.pdf]; files.allowsMultipleSelection = true; files.message = "选择使用刚才配方正式处理的 PDF；选择后先进入任务中心核对"
        guard files.runModal() == .OK else { return }
        let folder = NSOpenPanel(); folder.canChooseFiles = false; folder.canChooseDirectories = true; folder.canCreateDirectories = true; folder.message = "选择正式输出文件夹"
        guard folder.runModal() == .OK, let destination = folder.url else { return }
        let replacements = store.commandWorkspace.map { $0.applyReplacements ? ReplacementRules.parse($0.replacementText) : [] } ?? []
        store.batchQueue.add(files.urls); store.batchQueue.stage(recipe:recipe,output:destination,replacements:replacements)
        store.showTaskCenter = true; message = "已带入相同配方，请在任务中心核对文件和范围后点击开始。"
    }
    func exportTopic(_ topic: ResearchTopic, store: WorkspaceStore, word: Bool) {
        guard let target = destination(suffix:word ? "docx" : "md",name:topic.name) else { return }
        perform {
            let text = try topic.markdown(template:store.research.state.citation) { path,page in
                let book = store.library.book(path:path)
                return ("",book?.title ?? URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,store.research.periodical(path:path)?.citation ?? "",store.research.displayLabel(path:path,page:page,fallback:String(page+1)))
            }
            let expected = try FileBaseline.capture(target), sources = topic.items.map { URL(fileURLWithPath:$0.annotation.path) }
            try await self.background {
                guard !sources.contains(where: { DocumentTaskOutput.sameFile(target,$0) }) else { throw FolioError(message:"专题稿请另存，不能覆盖原书") }
                try DocumentTaskOutput.write(to:target,expected:expected) { staging in
                    if word { try RichTextWord.write(RichTextDocument(text,format:.markdown),to:staging) } else { try Data(text.utf8).write(to:staging) }
                }
            }
            return "专题稿已导出，保留原文链接"
        }
    }
}
extension BatchQueue {
    func stage(recipe:WorkRecipe,output:URL,replacements:[ReplacementRule]) {
        guard !running else { return }; stagePlan(BatchPlan(recipe:recipe,output:output,replacements:replacements))
    }
}

extension ResearchController {
    func reloadSource(_ w:Workspace) {
        perform {
            guard !w.busy, let file = w.historySource else { throw FolioError(message:"请先结束当前任务") }
            let version = w.revision, archive = try await w.snapshotForBackgroundSave(), root = w.storage
            let result = try await self.background { () throws -> (ImportPayload,PreparedReading?) in
                let folder = root.appendingPathComponent("Conflicts"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try archive.write(folder.appendingPathComponent(UUID().uuidString+".kongfolio"))
                let payload = try ImportServices.read([file])
                if case .documents(let bytes) = payload, file.pathExtension.lowercased() == "pdf" { return (payload,try PreparedReading.read(file,bytes:bytes[0],storage:root)) }
                return (payload,nil)
            }
            guard w.revision == version, !w.busy else { throw FolioError(message:"等待期间又有修改，当前内容已保留；请重新核对后载入") }
            w.clearDocument(keepingSource:false); w.load([file],prepared:result.0,reading:result.1)
            return "原文件已重新载入；此前书签、标注和草稿保留在恢复中心的冲突副本中，请核对关联。"
        }
    }
}
