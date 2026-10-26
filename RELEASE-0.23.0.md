# KongFolio 0.23.0 预发布

本版聚焦页面整理和数据安全。界面入口为阅读侧栏的“选择页面”“整理页序”，以及菜单栏“编辑页面”。

## 使用方法

- 奇偶页按照 PDF 物理页码计算，第 1 页属于奇数页。
- 反转选中页顺序只交换选中的页面位置，其他页面保持原位。
- 双面扫描还原处理整个文档，要求输入是全部正面在前、背面倒序在后；例如 1、3、5、6、4、2。执行前显示确认，可撤销。
- 不符合该扫描顺序的文件请使用手动页面编排。

## 验证

- 基于 GitHub main：2b0f6e093db16887aa0c7445cf28e0a6adb3d959。
- 构建环境：macOS 27.0.1，Apple Swift 6.4，Apple Silicon。
- Release 编译通过；应用临时签名及严格签名校验通过。
- 本次新增五项回归测试通过，覆盖奇偶/反选、页序及 OCR 元数据与撤销、备份保护、异常长度、导入中关闭保护。
- 全量轻量测试与标准 XCTest 均在已有 BatchChapterTests.testThePageRangeKeepsOnlyThosePagesAndTheOutlineFollows 失败，得到 0 个章节而非 3 个；后续断言触发越界退出。
- 未修改的同一 GitHub main 在本机轻量测试中也于同一断言失败。不能据此宣称全量测试通过；需要在 CI 支持的 macOS 15/26 上继续核查。

## 安装包

KongFolio-0.23.0-arm64.dmg，仅适用于 Apple Silicon；最低系统版本按项目配置为 macOS 14。本包为本机临时签名，未做 Apple 公证。

构建：bash scripts/build.sh；生成镜像：bash scripts/dmg.sh。

## 后续范围

本版尚未包含自动纠偏、跨页扫描切分、完整任务中心及导出质量预览。它们仍属于下一阶段计划。
