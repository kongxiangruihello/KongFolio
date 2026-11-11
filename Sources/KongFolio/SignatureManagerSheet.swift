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

    private var placementWorkspace: Workspace? {
        guard let workspace = store.commandWorkspace, workspace.count > 0,
              !workspace.readingLocked, !workspace.busy, workspace.pdfView != nil else { return nil }
        return workspace
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("签名管理").font(.title3.bold())
                Spacer()
                Button("导入图片签名…") { showImport = true }.disabled(!readable)
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.red) }
            if readable && templates.isEmpty {
                ContentUnavailableView("还没有保存的签名",systemImage:"signature",
                                       description:Text("可从图片或剪贴板导入。"))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if readable {
                List(templates) { template in
                    HStack(spacing:12) {
                        SignatureThumbnail(template:template)
                        Text(template.name).lineLimit(2).help(template.name)
                        Spacer(minLength:0)
                        if placementWorkspace != nil {
                            Button("放置到当前 PDF") { place(template) }.buttonStyle(.borderless)
                        }
                        Menu {
                            Button("重命名…") { target = template; newName = template.name; showRename = true }
                            Button("删除签名…",role:.destructive) { target = template; showDelete = true }
                        } label: { Image(systemName:"ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .help("管理 "+template.name).accessibilityLabel("管理 "+template.name)
                    }.padding(.vertical,5)
                }.listStyle(.inset)
            }
            HStack {
                Text("签名保存在本机。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .adaptiveSheet(width:580,height:460,minimumWidth:400,flexibleHeight:true)
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

    private func load() {
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
