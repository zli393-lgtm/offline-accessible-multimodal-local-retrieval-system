# Contributing / 贡献指南

感谢参与本项目。提交修改前请遵守以下要求：

1. 功能代码只修改 `Project/ReleaseCode`，测试只放在 `Project/TestCode`。
2. 不要把构建产物、用户配置、日志、数据库、平台运行时或大型模型提交到 Git。
3. 保持文件对象与索引记录一一对应，不得把同一文件的文本、图像或音频片段统计成多个文件结果。
4. 所有 UI 修改必须保留键盘操作、屏幕阅读器语义、动态字号和高对比度支持。
5. 修改共享数值时应使用现有常量与配置层，不要在多个控件中重复硬编码。
6. 提交前运行 Flutter 静态分析、Flutter 测试、Python 服务测试以及目标平台原生测试。
7. 新增第三方依赖时必须记录来源、版本、许可证和是否允许再分发。

Before submitting a change:

1. Keep production changes in `Project/ReleaseCode` and tests in `Project/TestCode`.
2. Do not commit build outputs, user settings, logs, databases, platform runtimes, or large model weights.
3. Preserve the one-file-one-index-record invariant.
4. Preserve keyboard, screen-reader, dynamic-text, and high-contrast accessibility.
5. Use the existing constants and configuration layers instead of duplicating UI values.
6. Run static analysis and all relevant Flutter, Python, and native tests.
7. Document the source, version, license, and redistribution status of every new dependency.

Contributions are submitted under the Apache License 2.0 unless explicitly stated otherwise.

