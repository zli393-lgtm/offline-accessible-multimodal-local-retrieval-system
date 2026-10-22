# 测试目录说明

本目录只保存开发和验证所需内容，不参与用户程序运行。相邻的
`../ReleaseCode` 是被测试的正式发布源码。

- `TestSuite/ApplicationTests`：Flutter、Dart、集成、真实模型和压力测试。
- `TestSuite/ServiceTests`：Python 本地服务和发布工具测试。
- `TestSuite/NativeTests`：Windows 原生 C++ Google Test 测试。
- `TestSuite/Resources`：测试使用的固定样本和测试模型。
- `TestResults`：最近一次完整测试的覆盖率文件和结果报告。

## 运行 Flutter 测试

在 `Project/ReleaseCode` 中执行：

```text
flutter test ../TestCode/TestSuite/ApplicationTests --coverage --coverage-path ../TestCode/TestResults/flutter_coverage.info
```

真实 Python 模型测试需要能够找到 Python 3.11。必要时可在当前终端设置
`EMBEDDING_PYTHON`，其值为 Python 可执行文件路径。

## 运行 Python 服务测试

在 `Project` 中执行：

```text
python -m pytest TestCode/TestSuite/ServiceTests -q --cov=ReleaseCode/services --cov-report=json:TestCode/TestResults/python_coverage.json --cov-fail-under=90
```

## 运行 Windows 原生 Google Test

在 `Project` 中执行。`GTEST_SOURCE_DIR` 指向本机现有 Google Test 源码目录：

```text
cmake -S TestCode\TestSuite\NativeTests -B TestCode\TestResults\native_build -G "Visual Studio 17 2022" -A x64 -DGTEST_SOURCE_DIR="Google Test 源码目录" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build TestCode\TestResults\native_build --config Release
ctest --test-dir TestCode\TestResults\native_build -C Release --output-on-failure
```

## 校验覆盖率门槛

```text
python TestCode\verify_coverage.py
```
