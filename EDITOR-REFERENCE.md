# 编辑器参考与本版实现

本次阅读了以下开源仓库的实际源码，参考编辑状态与模型回传分离、原生文字存储和组词处理的设计；没有引入外部编辑器依赖或复制其实现。

- [CodeEditTextView 的 SwiftUI 示例](https://github.com/CodeEditApp/CodeEditTextView/blob/main/Example/CodeEditTextViewExample/CodeEditTextViewExample/Views/SwiftUITextView.swift)：文字存储与控件配置更新分离。读取的文件 blob 为 `693826a39b8fd41e753c09634baa6bd6472fb7cd`。
- [CodeEditTextView 的输入处理](https://github.com/CodeEditApp/CodeEditTextView/blob/main/Sources/CodeEditTextView/TextView/TextView%2BNSTextInput.swift)：区分组词、提交与选区。读取 blob 为 `d64a5a0b38fe0b0916f19c7ef080ee134c144d22`。
- [STTextView 的 SwiftUI 桥接](https://github.com/krzyzanowskim/STTextView/blob/main/Sources/STTextViewSwiftUIAppKit/TextView.swift)：区分用户编辑与外部更新，避免模型回传被当成新的全文替换。读取 blob 为 `8d8236dca2af5e11979dd2ad1c09e4b7c50a2741`。
- [Apple NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient)：marked text 为组词状态，提交后才同步正文。

本版使用系统 NSTextView/NSTextField、明确的提交回调和模型回传去重，并测试组词过程、UTF-16 选区、首行连续编辑及资料库删除恢复。

## 0.50 界面参考

- [MarkText 官方仓库](https://github.com/marktext/marktext)：参考清晰的写作区域和显示模式分组。
- [Zettlr 官方编辑显示说明](https://docs.zettlr.com/en/editor/appearance.html)：参考编辑区字体和显示模式可配置、编辑显示与导出排版分别设置的设计。

本版保留原生 NSTextView 输入组件，不复制上述项目代码；字号、行宽、间距仅作用于屏幕，正文模型与导出版式独立保存。右侧面板入口明确面板位置，其他命令标注窗口类型。
