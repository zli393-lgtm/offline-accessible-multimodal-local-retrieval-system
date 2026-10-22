# 各操作系统需要的原生依赖

以下依赖必须使用与目标操作系统及处理器架构匹配的版本，不能把Windows文件
直接复制到Linux或macOS使用。

| 依赖 | 用途 | Windows当前状态 | Linux/macOS要求 |
|---|---|---|---|
| Python运行时及原生扩展包 | 本地解析、OCR、音频、图像、嵌入和向量服务 | 已准备 | 准备对应系统的Python运行时和全部模块 |
| Java运行时 | 运行Apache Tika | 已准备 | 准备对应系统的Java运行时 |
| Tesseract运行时 | 执行OCR | 已准备 | 准备原生程序和动态库；语言数据已在`Packageable`中 |
| PDFium | PDF渲染与提取 | 已准备 | Linux提供`libpdfium.so`，macOS提供`libpdfium.dylib` |
| DjVuLibre | DjVu渲染与文字提取 | 已准备 | 准备原生`ddjvu`、`djvutxt`和`djvused` |
| GhostPDL/Ghostscript | PostScript等格式渲染 | 已准备 | 准备对应系统的命令行运行时 |
| JPEG XR工具 | 解码JPEG XR | 已准备 | 准备对应系统的原生解码程序 |
| 浏览器 | SVG/HTML后备渲染 | 按设计不内置 | 用户选择系统中已安装的受支持浏览器 |

程序依次检查用户保存的有效路径、程序随附依赖目录、环境变量或PATH、系统常见
安装位置。只有目标系统对应的原生依赖完整，才能生成该系统的自包含发布包。

Windows外置依赖版不携带Windows原生运行时，最终用户需要在设置中选择或由
程序自动发现。Windows自包含版会把已准备的Windows原生依赖复制到发布目录。
