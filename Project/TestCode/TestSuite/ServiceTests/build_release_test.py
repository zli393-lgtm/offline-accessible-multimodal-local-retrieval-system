import importlib.util
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "ReleaseCode" / "tool" / "build_release.py"


def _load_builder():
    spec = importlib.util.spec_from_file_location("build_release", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _portable_dependencies(tmp_path):
    packageable = tmp_path / "packageable"
    models = packageable / "Models"
    for path in (
        models / "image" / "mobileclip_s0.pt",
        models / "audio" / "faster-whisper-medium" / "model.bin",
        models / "audio" / "clap-htsat-fused" / "model.safetensors",
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"test")
    (packageable / "LICENSES.md").write_text("test", encoding="utf-8")
    ocr_data = packageable / "Tesseract-Data"
    ocr_data.mkdir()
    (ocr_data / "eng.traineddata").write_bytes(b"test")
    tika = packageable / "Apache-Tika" / "tika-app.jar"
    tika.parent.mkdir()
    tika.write_bytes(b"test")
    return [
        "--models-root", str(models),
        "--ocr-data-root", str(ocr_data),
        "--tika-jar", str(tika),
    ]


def test_external_release_removes_private_state_and_optional_dependencies(tmp_path):
    source = tmp_path / "source"
    runtime = source / "data" / "local_retrieval"
    (source / "user_config").mkdir(parents=True)
    (source / "user_config" / "private.json").write_text("{}")
    (runtime / "dependencies" / "python").mkdir(parents=True)
    (runtime / "dependencies" / "python" / "python.exe").write_bytes(b"test")
    for channel in ("image", "audio", "text"):
        folder = runtime / "assets" / "models" / channel
        folder.mkdir(parents=True)
        (folder / "model.bin").write_bytes(b"test")
    (source / "retrieval.exe").write_bytes(b"test")
    output = tmp_path / "external"

    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--mode", "external", "--platform", "windows",
         "--release-source", str(source), "--output", str(output),
         *_portable_dependencies(tmp_path)],
        capture_output=True, text=True, check=False,
    )

    assert result.returncode == 0, result.stderr
    assert (output / "retrieval.exe").is_file()
    assert not (output / "user_config").exists()
    assert not (output / "data" / "local_retrieval" / "dependencies" / "python").exists()
    assert (output / "data" / "local_retrieval" / "dependencies" / "tika" / "tika-app.jar").is_file()
    assert (output / "data" / "local_retrieval" / "dependencies" / "tesseract" / "tessdata" / "eng.traineddata").is_file()
    assert (output / "data" / "local_retrieval" / "assets" / "models" / "image" / "mobileclip_s0.pt").is_file()
    assert (output / "data" / "local_retrieval" / "assets" / "models" / "audio" / "clap-htsat-fused" / "model.safetensors").is_file()
    manifest = json.loads(
        (output / "data" / "local_retrieval" / "release-mode.json").read_text()
    )
    assert manifest["mode"] == "external"
    assert manifest["portableDependencies"] == ["models", "ocr_data", "tika"]
    assert manifest["browserBundled"] is False


def test_self_contained_release_refuses_missing_required_roots(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--mode", "self-contained", "--platform", "windows",
         "--release-source", str(source), "--output", str(tmp_path / "output"),
         *_portable_dependencies(tmp_path)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert "--python-root is required" in result.stderr


def test_dependency_file_resolution_accepts_direct_and_nested_files(tmp_path):
    builder = _load_builder()
    direct = tmp_path / "java.exe"
    direct.write_bytes(b"test")
    assert builder.find_one(direct, ("java.exe", "java"), "Java") == direct

    nested = tmp_path / "runtime" / "bin" / "pdfium.dll"
    nested.parent.mkdir(parents=True)
    nested.write_bytes(b"test")
    assert builder.find_one(tmp_path / "runtime", ("pdfium.dll",), "PDFium") == nested
