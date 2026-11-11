import SwiftUI

struct SignatureManagerSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [SignatureTemplate] = []
    @State private var showImport = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var target: SignatureTemplate?
    @State private var newName = ""
    @State private var message = ""
    @State private var readable = false
    @State private var loaded = false

    private var placementWorkspace: Workspace? {
        guard let workspace = store.commandWorkspace, workspace.count > 0,
              !workspace.readingLocked, !workspace.busy, workspace.pdfView != nil else { return nil }
        return workspace
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("签名管理").font(.title3.bold())
                    if readable { Text("\(templates.count) 枚已保存签名").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("导入图片签名…") { showImport = true }.disabled(!readable)
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.red) }
            if !loaded {
                ProgressView("正在读取签名…").frame(maxWidth:.infinity,minHeight:130)
            } else if readable && templates.isEmpty {
                ContentUnavailableView("还没有保存的签名",systemImage:"signature",
                                       description:Text("可从图片或剪贴板导入。"))
                    .frame(maxWidth:.infinity,minHeight:160)
            } else if readable {
                signatureRows
            }
            HStack {
                Text("签名保存在本机。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .adaptiveSheet(width:600,height:max(310,min(460,180+CGFloat(templates.count)*64)),minimumWidth:400,flexibleHeight:true)
        .task { load() }
        .sheet(isPresented:$showImport) {
            SignatureImportSheet { image,name in
                guard let png = SignatureImage.pngData(image) else { throw FolioError(message:"无法保存这张签名图片。") }
                templates = try store.editManagedSignatures {
                    $0.append(SignatureTemplate(name:name ?? "图片签名",pdf:Data(),image:png))
                }
                message = ""
            }
        }
        .alert("重命名签名",isPresented:$showRename) {
            TextField("签名名称",text:$newName)
            Button("取消",role:.cancel) {}
            Button("保存") {
                guard let target else { return }
                let name = newName.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                edit { values in
                    if let index = values.firstIndex(where:{$0.id == target.id}) { values[index].name = name }
                }
            }.disabled(newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("删除签名？",isPresented:$showDelete,titleVisibility:.visible,presenting:target) { template in
            Button("删除",role:.destructive) { edit { $0.removeAll { $0.id == template.id } } }
            Button("取消",role:.cancel) {}
        } message: { template in
            Text("从本机签名库删除「\(template.name)」。")
        }
    }

    private var signatureRows: some View {
        // The adaptive sheet measures its content without a vertical proposal. Give the scrolling list a viewport.
        ScrollView {
            LazyVStack(spacing:0) {
                ForEach(templates) { template in
                    signatureRow(template)
                    if template.id != templates.last?.id { Divider().padding(.horizontal,10) }
                }
            }.frame(maxWidth:.infinity)
        }
        .frame(height:min(280,CGFloat(templates.count)*64))
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:8))
        .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(.quaternary).allowsHitTesting(false) }
        .accessibilityLabel("已保存签名列表")
    }

    private func signatureRow(_ template: SignatureTemplate) -> some View {
        HStack(spacing:10) {
            SignatureThumbnail(template:template)
            Text(template.name).lineLimit(2).help(template.name)
                .frame(maxWidth:.infinity,alignment:.leading)
            Button("放置") { place(template) }.disabled(placementWorkspace == nil)
                .help(placementWorkspace == nil ? "打开可编辑的 PDF 后即可放置" : "放置到当前 PDF")
                .accessibilityLabel("放置 "+template.name)
            Button("重命名") { target = template; newName = template.name; showRename = true }
                .accessibilityLabel("重命名 "+template.name)
            Button("删除",role:.destructive) { target = template; showDelete = true }
                .accessibilityLabel("删除 "+template.name)
        }
        .font(.system(size:13)).buttonStyle(.borderless)
        .padding(.horizontal,12).frame(minHeight:63)
    }

    private func load() {
        defer { loaded = true }
        do {
            templates = try SignatureLibrary.read(storage:store.storage)
            readable = true
            message = ""
        } catch {
            readable = false
            message = "签名库未能读取："+error.localizedDescription
        }
    }

    private func edit(_ mutation: (inout [SignatureTemplate]) -> Void) {
        do { templates = try store.editManagedSignatures(mutation); message = "" }
        catch { message = "签名未能保存："+error.localizedDescription }
    }

    private func place(_ template: SignatureTemplate) {
        guard let workspace = placementWorkspace else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
            guard store.commandWorkspace === workspace else { return }
            workspace.beginPlacing(template)
        }
    }
}

extension WorkspaceStore {
    func editManagedSignatures(_ edit: (inout [SignatureTemplate]) -> Void) throws -> [SignatureTemplate] {
        let updated = try SignatureLibrary.update(storage:storage,edit)
        for workspace in tabs.compactMap(\.workspace) where workspace.storage.standardizedFileURL == storage.standardizedFileURL {
            workspace.signatures = updated
        }
        return updated
    }
}
