# 依赖分类说明

`NewVersion`目录分为源代码、依赖和正式文档三个部分。

## 可共同打包的依赖（Packageable）

`Dependencies/Packageable`保存Windows、Linux和macOS能够使用同一份文件的
平台无关依赖：

- `Models`：模型权重、分词器、词表和模型配置。
- `Model-Sources`：仅用于生成运行模型的原始模型文件，例如BERT转换源模型；发布脚本不会把此目录复制到最终程序包。
- `Apache-Tika`：平台无关的Apache Tika应用JAR。
- `Tesseract-Data`：所有受支持系统共用的OCR语言和文字系统数据。

发布组装程序只会把`Models`、Apache Tika与OCR数据等运行必需内容加入各平台
发布包，不会复制`Model-Sources`。下载缓存、锁文件、未完成的临时下载和生成
的字节码不得放入这里。

## 不可跨平台复用的依赖（Non-Packageable）

`Dependencies/Non-Packageable`保存针对操作系统和处理器架构编译的运行时与
原生二进制文件。Windows二进制不能作为Linux或macOS依赖：

- `Windows`：当前已准备Python、Java、PDFium、Tesseract、DjVuLibre、
  GhostPDL和JPEG XR。
- `Linux`：预留给上述依赖的Linux原生版本。
- `macOS`：预留给上述依赖的macOS原生版本。

Linux或macOS目录为空，表示生成对应自包含包以前仍需准备原生依赖。不得把
Windows文件复制过去冒充其他系统版本。

## 源代码边界

`Project`保存应用源代码、平台工程定义、必要界面资源和发布脚本，不保存Flutter
编译输出、`.dart_tool`、Python字节码缓存、模型下载缓存或原生依赖。

发布脚本只从相邻的`Dependencies`解析依赖，不引用旧版本或开发机其他目录。
`Documentation`是正式开源与发布内容，必须和源码一起保留。

