# 开源合规报告

## 项目许可证

项目主体使用 Apache License 2.0。正式源码及发布内容必须保留 `Project/ReleaseCode` 中的：

- `LICENSE`
- `NOTICE`
- `THIRD_PARTY_NOTICES.md`
- 完整的 `Documentation` 目录

不得删除第三方软件要求保留的版权、许可证和声明文本。

## 第三方依赖管理

项目依赖分为可随项目携带的依赖与必须由目标平台准备的依赖。具体分类、安装责任和发布结构见：

- `Dependency-Classification.md`
- `Required-External-Dependencies.md`
- `Release-Packaging-Guide.txt`
- `Dependency-Licenses.md`

发布工具会校验项目级法律文件，并将项目许可证、NOTICE、第三方声明、依赖许可证索引和 Documentation 一并复制到发布包。

## 发布要求

1. 发布前核对实际包含的每一项第三方依赖及其版本。
2. 在 `THIRD_PARTY_NOTICES.md` 和依赖许可证索引中保留名称、来源、许可证与必要声明。
3. 对不可跨平台的原生依赖按目标操作系统分别准备，不得把 Windows 二进制冒充为 Linux 或 macOS 依赖。
4. 外置依赖版本不得错误声明已经携带未打包的运行环境。
5. 自包含版本必须携带运行所需依赖及相应许可证文本。
6. 不得把开发者个人配置、数据库、日志、缓存、测试数据或编译中间产物加入公开发行包。

## 当前状态

- 项目级 Apache 2.0 `LICENSE`、`NOTICE` 和 `THIRD_PARTY_NOTICES.md` 已位于 `Project/ReleaseCode`。
- Windows 外置依赖版和自包含版的发布结构已通过验证。
- Documentation 已纳入发布工具的必需内容。
- MobileCLIP 的具体发行限制和官方许可证文件仍必须在实际发布所含模型版本上逐项核对；在核对完成前不得把该模型误标为可无限制商业分发。
- Linux 和 macOS 发布包中的原生依赖及许可证仍需在目标平台构建时复核。

