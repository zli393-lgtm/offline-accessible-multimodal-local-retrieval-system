# Offline Accessible Multimodal Local Content Retrieval

离线、无障碍、跨平台的本地多模态内容检索系统。项目使用 Flutter 构建界面，使用 TensorFlow Lite、BERT、MobileCLIP、PDFium、Apache Tika 与 Chroma DB 完成本地解析、索引和检索。

An offline-first, accessible, cross-platform multimodal retrieval system for local files. The application uses Flutter, TensorFlow Lite, BERT, MobileCLIP, PDFium, Apache Tika, and Chroma DB.

## Repository layout / 仓库结构

公开仓库顶层只包含 `Project`、`Documentation` 和空壳 `Dependencies` 三个文件夹。
项目说明、贡献指南和发布文档均归入 `Documentation`；项目许可证及第三方声明归入生产源码目录。

- `../Project/ReleaseCode`: production application source / 生产应用源码
- `../Project/TestCode`: automated tests and test resources / 自动化测试与测试资源
- `../Dependencies`: empty dependency layout; binary payloads are downloaded separately / 空的依赖目录骨架，二进制内容另行下载
- `../Documentation`: architecture, user, test, compliance, dependency and release documentation / 架构、用户、测试、合规、依赖及发布文档

## Build / 编译

完整的 Windows、macOS、Linux 外部依赖版及自包含版编译步骤见 `Release-Packaging-Guide.txt`。目标系统必须自行提供对应平台的 Flutter SDK 和原生编译工具链。

See `Release-Packaging-Guide.txt` for Windows, macOS, and Linux external-dependency and self-contained build instructions. The target system must provide its platform Flutter SDK and native compiler toolchain.

## Tests / 测试

测试代码与产品代码完全分离。当前 Windows 验证结果和覆盖范围见 `Test-Report.md`。

Tests are separated from production code. See `Test-Report.md` for the currently verified Windows results and coverage scope.

## Accessibility / 无障碍

界面支持键盘导航、屏幕阅读器语义、高对比度、色觉无障碍配色与动态字号。具体操作见 `User-Manual.md`。

The interface supports keyboard navigation, screen-reader semantics, high contrast, color-vision accessibility palettes, and dynamic text sizing. See `User-Manual.md`.

## Dependencies and large files / 依赖与大文件

GitHub 源码仓库只保留空的依赖目录骨架，不提交平台运行时、模型权重、OCR 数据和测试模型缓存。克隆源码后，请按照 `Dependency-Download-and-Setup-Guide.md` 下载依赖并放入规定目录；分类与许可证要求见同目录下的依赖及合规文档。

Only the empty dependency directory layout is committed. Platform runtimes, model weights, OCR data, and test model caches are not committed. After cloning, follow `Dependency-Download-and-Setup-Guide.md` to restore them in the required locations.

## License / 许可证

本项目以 Apache License 2.0 发布。完整许可证见 `../Project/ReleaseCode/LICENSE`，第三方声明见 `../Project/ReleaseCode/THIRD_PARTY_NOTICES.md` 和合规报告。

Licensed under Apache License 2.0. See `../Project/ReleaseCode/LICENSE`, `../Project/ReleaseCode/THIRD_PARTY_NOTICES.md`, and the compliance report.

