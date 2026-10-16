# KongFolio 0.4

原生 macOS 个人文档工作台。SwiftUI / AppKit + PDFKit + Core Image + Vision + Core Graphics，全程本地处理，无第三方依赖。

## 运行

```sh
./scripts/build.sh
open ../KongFolio.app
```

最低目标 macOS 14。构建产物使用本地 ad-hoc 签名，尚未公证。支持 Command Line Tools 构建，也可以用完整 Xcode 打开 `Package.swift`。版本号只在 `Info.plist` 中维护。

## 0.4 要点

完整清单见 `CHANGELOG.md`。

- **撤销不再拖慢大文档**：标注的新增、移动、缩放、修改和删除只记录被改动的那一个标注；只有页面结构类操作（增删、排序、旋转、OCR、应用图片调整）才保存整本快照。
- **项目格式 4**：二进制容器，PDF 原样存放，不再 Base64。恢复副本按内容寻址，未变的原图只写一次。可读取 0.2 / 0.3 项目；新保存的项目不能在旧版本中打开。
- **OCR**：可选简体、繁体、繁简、日文 + 繁体、英文；按 200 / 300 / 400 DPI 渲染。非空白字符少于 20 个的页面才会识别。另有竖排识别，见下文。
- **压缩保留文字**：使用 PDFKit 的图片重编码选项，文字、矢量内容、链接和目录都保留。也可改用图片型 PDF。
- **引用友好**：显示 PDF 页码标签（通常即印刷页码）。摘录可填书目信息，导出的 Markdown 每条附引用行。
- **搜索**：中文行尾换行处不断词，繁简通查，并把文本层中的"康熙部首"兼容字符（⾃、⽽ 等）折回常用字。
- **有损操作先提示**：含文字的页面转为图片前、OCR 固化标注前，都会先确认。

### 竖排识别

Vision 的 `VNRecognizeTextRequest` 只读横行文字，竖排的一列字往往识别为空（CI 实测如此）。KongFolio 的做法：

1. 按列从右到左切分页面；
2. 把每列切成单字；
3. 每列排成一行交给 Vision 识别；
4. 识别出的字数与切出的字数一致时，逐字放回原位，搜索高亮落在原字上。字数不一致的列，以整列为范围近似定位，识别结果中会标注。

这种方法适合字距清楚的刻本和排印本。双行小注、插图、字距极密或歪斜的版面可能切分不准，请用"检查当前页区域"核对。

另外，PDFKit 按从左到右的顺序提取文本，所以竖排页面的文本层中列序是反的：同一列内的词可以搜索，跨列的词目前搜不到。

## 功能概览

- **打开与合并**：PDF、JPG、PNG、HEIC、TIFF（含多帧），以及 Markdown / 纯文本（排版为 A4 PDF，见 `TextImport.swift`），也可以拖入窗口。多文件可先调整合并顺序；任务进行中打开的文件会排队。
- **页面管理**：⌘ 多选、⇧ 连选，或输入 `1–3, 5, 8–10`。可拖动排序，以及复制、旋转、删除、提取、逐页拆分。文档至少保留一页。
- **阅读**：
  - 连续、单页、双页布局，记住阅读位置；
  - 读取 PDF 目录，可加自定义书签；
  - 跨页搜索最多列出 1000 处匹配；
  - 对照阅读可同步翻页。
- **摘录**：选中文字后可做高亮、下划线或删除线（四种颜色），并附笔记。摘录列表显示原文、笔记和页码，可导出带书目和引用的 Markdown。
- **标注**：批注、文字框、画笔、箭头、手写签名。用"编辑标注"可移动、修改文字或颜色、缩放、删除。签名库只保存在本机，不是证书签名。
- **图片与扫描件**：
  - 鼠标选区裁剪（八个控制点）、±15° 倾斜校正、90° 旋转、翻转；
  - 自动识别纸张并校正透视；
  - 调整亮度、对比度、饱和度、锐化，以及黑白、扫描增强。
  
  拖动滑杆时先显示低分辨率预览，松手后再出全尺寸。项目保留原始页面和参数，可以重新调整或恢复。
- **OCR**：保留原 PDF 页面内容，叠加不可见文本层。"检查当前页区域"可对照识别框、文本和置信度。0.3 及以后识别过的页面，可从 OCR 前的页面重新识别。
- **导出**：
  - PDF（三种类型）、PNG、JPG、TIFF，可选全部、当前或选中页面；
  - 72–600 DPI，可估算体积；
  - TXT 和 Markdown 全文。
- **保存与恢复**：⌘S 保存 `.kongfolio` 项目，⇧⌘S 另存，⌘E 导出 PDF。自动恢复副本与最近文件存放在 `~/Library/Application Support/KongFolio/`。保存时会把被覆盖的上一版项目留在其中的 `Backups/` 文件夹（文件名为"路径摘要-原文件名"，每个项目只保留一版，可手动改名后用 KongFolio 打开）。

## 当前边界

- 导入的扫描件只是图片文件；不连接相机或扫描仪。对照阅读不自动检测差异。
- 应用图片调整会把页面转为图片：文字层和链接不再保留，可重新 OCR。原始页面会保留在项目中。
- 文档序列化、首次快照和图片预览仍在主线程完成。超大文档在页面结构操作时可能短暂等待；自动保存是防抖快照，不保证断电时保留最后几秒的操作。
- 项目文件包含原始页面，可能比导出的 PDF 大；项目未加密。
- 不支持：原 PDF 文字重排、Word/Excel 解析、密码 PDF、证书签名、云同步、AI 问答。
- 界面交互（拖放、滑杆、对话框、同步翻页）只做了代码层面的修改，未在真实窗口中逐项验证。详见 `VALIDATION.md`。

## 架构

| 模块 | 职责 |
| --- | --- |
| KongFolioApp | 应用生命周期、单窗口、菜单、关闭保护（WindowAccessor） |
| Model | 枚举、`PageMeta`、OCR 设置、书目信息、品牌色 |
| Workspace | 工作状态、页面操作、导入、图片配方、确认对话框 |
| UndoHistory | 标注级撤销记录与整本快照的混合历史 |
| ProjectStore | 项目二进制容器、恢复副本的内容寻址存储、页码范围解析 |
| BackgroundJobs | 后台 OCR / 拆分 / 导出任务、进度、取消 |
| DocumentServices / VerticalText | 图像处理、Vision 识别、竖排切分、PDF 文本层 |
| PDFCanvas / AnnotationEditing | PDFKit 画布、标注交互、签名库、对照同步 |
| ContentView / ImageCanvas / CropGeometry | 三栏界面、快捷工具、鼠标裁剪 |
| ReadingServices / ReadingSidebar | 目录、书签、搜索折叠、页码标签、摘录与引用 |
| ExportServices / ExportSheet | 三种 PDF 模式、DPI、范围、估算、后台导出 |
| TextImport | Markdown / 纯文本解码、排版并分页为 A4 PDF |
| ImportServices / ThumbnailView | 后台读取、按页缓存的缩略图 |
| OCRReview | 识别区域、文本与置信度对照 |

## 验证

```sh
swift test          # 需要完整 Xcode
./scripts/test.sh   # 只需 Command Line Tools；自动发现全部测试方法
```

每次推送都会在 GitHub Actions 的 macOS 15 和 macOS 26 机器上编译，并运行这两套测试。验证范围和实测数字见 `VALIDATION.md`。

技术参考：
- [PDFDocumentWriteOption](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption)
- [PDFPage.label](https://developer.apple.com/documentation/pdfkit/pdfpage/label)
- [Vision 竖排讨论（Apple 开发者论坛）](https://developer.apple.com/forums/thread/772972)
- [VNDetectRectanglesRequest](https://developer.apple.com/documentation/vision/vndetectrectanglesrequest)
