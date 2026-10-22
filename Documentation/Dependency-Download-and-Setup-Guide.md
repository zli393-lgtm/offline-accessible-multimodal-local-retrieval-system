# 依赖下载与目录配置指南

## 1. 适用范围

GitHub 源码仓库只提交项目源码、测试源码、文档以及许可证文件，不提交 `Dependencies` 中的大型模型、OCR 数据或平台原生运行时。原因不是源码无法发布，而是当前依赖总量约 8GB，且多个模型文件超过 GitHub 普通 Git 仓库单文件 100MB 的限制。

从 GitHub 克隆项目后，应在仓库根目录自行建立以下目录结构：

```text
Dependencies/
├─ Packageable/
│  ├─ Models/
│  │  ├─ bert/
│  │  ├─ image/
│  │  └─ audio/
│  ├─ Model-Sources/
│  │  └─ bert/
│  ├─ Apache-Tika/
│  └─ Tesseract-Data/
└─ Non-Packageable/
   ├─ Windows/
   ├─ Linux/
   └─ macOS/
```

`Packageable` 保存三个桌面系统可以共用的数据文件；`Non-Packageable` 保存必须与目标操作系统和处理器架构匹配的原生程序。不要把 Windows 的 EXE/DLL 复制到 Linux 或 macOS。

## 2. 跨平台共用依赖

### 2.1 模型文件

将文件放入下列固定位置。仓库中的 `Project/ReleaseCode/services/dependencies/install_runtime.py` 可以安装 Python 包并下载 MobileCLIP、Faster-Whisper 和 CLAP；其中模型版本已经固定，避免每次下载到不同版本。

| 用途 | 官方来源 | 固定版本 | 放置位置 |
|---|---|---|---|
| MobileCLIP S0 | `https://huggingface.co/apple/MobileCLIP-S0` | revision `71aa3e13dda93115871afbd017336535ba29886c` | `Dependencies/Packageable/Models/image/mobileclip_s0.pt` |
| Faster-Whisper medium | `https://huggingface.co/Systran/faster-whisper-medium` | revision `4d9f76bb96174a5625e9ed85e89be563d98d528c` | 完整仓库放入 `Dependencies/Packageable/Models/audio/faster-whisper-medium/` |
| CLAP HTSAT fused | `https://huggingface.co/laion/clap-htsat-fused` | revision `365dea6ef167def6676140ed93bbc43f84dabb28` | 完整仓库放入 `Dependencies/Packageable/Models/audio/clap-htsat-fused/` |
| BERT 转换源模型 | `https://huggingface.co/google-bert/bert-base-uncased` | revision `86b5e0934494bd15c9632b12f734a8a67f723594` | `Dependencies/Packageable/Model-Sources/bert/google-bert-base-uncased/` |
| BERT TFLite 运行文件 | 由项目转换脚本生成 | 固定为 512 token、动态批次和动态序列长度 | `Dependencies/Packageable/Models/bert/` |

BERT 目录至少必须包含：

```text
bert_base_uncased_dynamic.tflite
tokenizer.json
vocab.txt
```

发布脚本只会把这三个运行必需文件暂存到 Flutter assets。不得用不匹配的 tokenizer 或词表替换其中任一文件。

项目已经提供 BERT 转换工具：

```text
Project/TestCode/TestSuite/Utilities/export_bert_tflite.py
```

先在用于转换的 Python 环境中安装 TensorFlow、Transformers 和 Hugging Face Hub，再执行以下命令下载固定版本的 BERT 源模型：

```text
huggingface-cli download google-bert/bert-base-uncased --revision 86b5e0934494bd15c9632b12f734a8a67f723594 --local-dir Dependencies/Packageable/Model-Sources/bert/google-bert-base-uncased
```

下载完成后，该目录至少应包含 `model.safetensors`、`config.json`、`tokenizer.json`、`tokenizer_config.json` 和 `vocab.txt`。这里保存的是生成 TFLite 文件所需的转换源模型，不是程序运行时直接加载的模型，也不会被发布脚本复制进最终程序包。

然后从仓库根目录执行：

```text
python Project/TestCode/TestSuite/Utilities/export_bert_tflite.py
```

脚本会生成 `Dependencies/Packageable/Models/bert/bert_base_uncased_dynamic.tflite`。最后从同一份 `google-bert/bert-base-uncased` 快照复制 `tokenizer.json` 和 `vocab.txt` 到该目录。三者必须来自同一模型快照，不能混用。

`Dependencies/.gitignore` 会排除 `Dependencies` 下的所有实际依赖内容，只保留目录占位文件。因此，上述 BERT 源模型、生成后的 TFLite、MobileCLIP、音频模型、Tika、OCR 数据和各平台运行时均不会上传到 GitHub。克隆仓库后必须按照本指南重新下载或准备这些文件。

如需使用项目自带下载脚本，在仓库根目录用目标 Python 解释器执行：

```text
python Project/ReleaseCode/services/dependencies/install_runtime.py --mode python --program-root Project/ReleaseCode
```

该命令会在当前 Python 环境安装服务所需 Python 包，并把三种 Hugging Face 模型下载到该 Python 环境旁的 `local_retrieval_models`。下载完成后，必须把其中的 `image` 和 `audio` 目录复制到上表规定的 `Dependencies/Packageable/Models` 中。该脚本不会生成 BERT TFLite 文件、Apache Tika 或 Tesseract OCR 数据；这些项目仍须按本文件相应小节准备。

### 2.2 Apache Tika

从 Apache Tika 官方下载页获取 `tika-app-4.0.0.jar`：

```text
https://tika.apache.org/download.html
```

放置位置：

```text
Dependencies/Packageable/Apache-Tika/tika-app-4.0.0.jar
```

这里需要的是可直接通过 `java -jar` 运行的 `tika-app` JAR，不是源代码包，也不是 `tika-server`。

### 2.3 Tesseract OCR 数据

从 Tesseract 官方数据仓库获取所需的 `.traineddata` 文件：

```text
https://github.com/tesseract-ocr/tessdata
```

把语言数据以及需要的 `configs`、`script`、`tessconfigs` 目录放入：

```text
Dependencies/Packageable/Tesseract-Data/
```

至少应包含实际需要识别的语言；本项目中文与英文使用场景至少需要 `chi_sim.traineddata`、`chi_tra.traineddata`、`eng.traineddata` 和 `osd.traineddata`。语言数据不是 Tesseract 主程序，主程序仍要按目标平台准备。

## 3. 平台原生依赖

先选择目标系统目录：

```text
Windows: Dependencies/Non-Packageable/Windows/
Linux:   Dependencies/Non-Packageable/Linux/
macOS:   Dependencies/Non-Packageable/macOS/
```

然后建立并填充下面七个固定子目录：

| 子目录 | 作用 | 获取来源/方式 | 最低检查目标 |
|---|---|---|---|
| `python` | 运行解析、OCR 接入、向量和多模态服务 | `https://www.python.org/downloads/`，或目标系统的软件包管理器 | Windows `python.exe`；Linux/macOS `bin/python3` |
| `java` | 运行 Apache Tika | Eclipse Temurin/OpenJDK：`https://adoptium.net/temurin/releases/` | `bin/java.exe` 或 `bin/java` |
| `tesseract` | 执行 OCR | 官方项目与平台安装说明：`https://github.com/tesseract-ocr/tesseract` | `tesseract.exe` 或 `tesseract`，以及配套动态库 |
| `pdfium` | 渲染 PDF 页面 | PDFium 官方源码：`https://pdfium.googlesource.com/pdfium/`；使用与目标平台匹配的可信构建 | `pdfium.dll`、`libpdfium.so` 或 `libpdfium.dylib` |
| `djvulibre` | 读取 DjVu | `https://djvu.sourceforge.net/` | `ddjvu`、`djvutxt`、`djvused` 及配套动态库 |
| `ghostpdl` | 渲染 PS/EPS 等格式 | `https://www.ghostscript.com/releases/` | Windows `gswin64c.exe`/`gswin32c.exe`，其他系统 `gs` |
| `jpeg_xr` | 解码 JPEG XR/HDP/WDP | 目标平台的 JPEG XR/JXRLib 构建 | `JxrDecApp.exe` 或 `JxrDecApp` |

浏览器不放入 `Dependencies`，也不随自包含包发布。程序使用用户系统现有的受支持浏览器，并允许在设置界面选择其安装目录。

### 3.1 Python 包

所选 Python 环境必须安装 `Project/ReleaseCode/services` 各模块目录中的 `requirements.txt`。为避免遗漏，也可以使用第 2.1 节的 `install_runtime.py`。主要运行包包括 PyTorch、Transformers、MobileCLIP、Faster-Whisper、ChromaDB、PyMuPDF、Pillow、Tesseract 接口、音频处理和 Office/OpenDocument 解析库。

这些包中含有与操作系统相关的 DLL、SO 或 DYLIB，因此必须在目标系统中安装，不能把 Windows 的 `site-packages` 直接复制给 Linux 或 macOS。

## 4. 两种发布方式的差别

- 外置依赖版：可以不填充 `Dependencies/Non-Packageable/<目标系统>`；最终用户在程序设置页选择本机依赖目录。跨平台共用的 BERT 资源仍是编译所必需的。
- 自包含版：必须完整填充目标系统的七个原生依赖子目录，同时准备全部 `Packageable` 内容；发布脚本会校验并复制它们。

六种目标包的具体命令见 `Release-Packaging-Guide.txt`。Windows 包必须在 Windows 构建，Linux 包必须在 Linux 构建，macOS 包必须在 macOS 构建。

## 5. 完成后的检查

在 `Project/ReleaseCode` 中执行目标平台的校验命令。例如 Windows：

```text
python tool/release.py windows-external --validate-only
python tool/release.py windows-self-contained --validate-only
```

校验通过只证明目录与必需文件齐全；正式发布前仍应执行完整编译、自动化测试和目标系统上的启动检查。

下载或再分发任何依赖前，必须阅读 `Project/ReleaseCode/THIRD_PARTY_NOTICES.md` 与 `Documentation/Open-Source-Compliance-Report.md`。特别是 MobileCLIP 权重具有独立的研究用途许可，不能把它错误标记为 Apache-2.0，也不能在未复核许可的情况下直接随公开发布包分发。
