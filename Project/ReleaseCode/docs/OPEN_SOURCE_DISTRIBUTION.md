# 开源发布文件边界

公开源码仓库必须以 `New` 为根，顶层只包含 `Project`、`Documentation` 和空壳
`Dependencies` 三个目录。不得引用 V8 外层文档、旧版本目录、开发机缓存或其他
绝对路径。`Documentation` 是正式开源交付内容，不能作为开发资料剔除。

`Project` 保存项目源代码；项目级 `LICENSE`、`NOTICE` 和
`THIRD_PARTY_NOTICES.md` 位于 `Project/ReleaseCode`。`Documentation` 保存项目
入口说明、贡献指南、编译说明、用户说明、依赖恢复方法和工程文档。
`Dependencies` 在 GitHub 中只保存带 `.gitkeep` 的目录结构，不保存模型、数据、
JAR 或平台运行时。用户按照依赖指南补齐内容后，才能生成相应发布包。

生成二进制发布包时，发布脚本必须把项目级许可证复制到发布目录根部，并保留
所有实际打入包内的第三方依赖原有许可证、NOTICE、legal、COPYING和模型卡。

不能把项目的 Apache-2.0 许可证解释为第三方组件许可证。某项第三方材料如果
没有可核实的许可证正文，或者许可证不允许预期用途和再分发，就不能进入公开
发布包。

