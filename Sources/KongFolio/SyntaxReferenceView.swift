import SwiftUI
import AppKit

struct SyntaxReferenceView: View {
    let format: TextDocumentFormat
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    private struct Example: Identifiable {
        let id: String
        let code: String

        init(_ title: String, _ code: String) {
            id = title
            self.code = code
        }
    }

    private var examples: [Example] {
        switch format {
        case .markdown:
            return [
                Example("标题与段落", "# 文献笔记\n\n## 阅读心得\n\n另起一段前留一个空行。"),
                Example("粗体与斜体", "**重点** 和 *强调*"),
                Example("无序与有序列表", "- 原文\n- 笔记\n\n1. 阅读\n2. 核对"),
                Example("引用", "> 这里填写摘录原文。"),
                Example("链接与图片", "[资料来源](https://example.org)\n\n![封面说明](images/cover.png)"),
                Example("行内代码与代码块", "`文件名`\n\n```text\n一段原样显示的文字\n```"),
                Example("表格（Markdown 扩展）", "| 篇名 | 页码 |\n| --- | --- |\n| 前言 | 12 |")
            ]
        case .html:
            return [
                Example("文档结构", """
                <!doctype html>
                <html lang="zh-Hans">
                <head>
                  <meta charset="utf-8">
                  <title>文献笔记</title>
                </head>
                <body>
                  <h1>阅读心得</h1>
                  <p>这里填写正文。</p>
                </body>
                </html>
                """),
                Example("标题与段落", "<h1>文献笔记</h1>\n<h2>阅读心得</h2>\n<p>这里填写正文。</p>"),
                Example("重点与强调", "<strong>重点</strong> 和 <em>强调</em>"),
                Example("无序与有序列表", "<ul>\n  <li>原文</li>\n</ul>\n<ol>\n  <li>核对出处</li>\n</ol>"),
                Example("引用", "<blockquote>\n  <p>这里填写摘录原文。</p>\n</blockquote>"),
                Example("链接与图片", "<a href=\"https://example.org\">资料来源</a>\n<img src=\"images/cover.png\" alt=\"封面说明\">"),
                Example("代码与转义", "<code>&lt;h1&gt;</code>\n<pre><code>一段原样显示的文字</code></pre>"),
                Example("表格", "<table>\n  <tr><th scope=\"col\">篇名</th><th scope=\"col\">页码</th></tr>\n  <tr><td>前言</td><td>12</td></tr>\n</table>")
            ]
        case .plain:
            return []
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label(format.rawValue + " 语法手册",systemImage:"book").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(examples) { example in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Text(example.id).font(.headline)
                                Spacer()
                                Button(copied == example.id ? "已复制" : "复制示例") {
                                    NSPasteboard.general.clearContents()
                                    if NSPasteboard.general.setString(example.code,forType:.string) { copied = example.id }
                                }
                                .accessibilityLabel((copied == example.id ? "已复制 " : "复制 ") + example.id)
                            }
                            Text(verbatim:example.code)
                                .font(.system(.body,design:.monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading)
                                .padding(10)
                                .background(.quaternary,in:RoundedRectangle(cornerRadius:6))
                        }
                    }
                }.padding(.trailing,8)
            }
        }.padding(20).adaptiveSheet(width:640,height:580,minimumWidth:360)
    }
}
