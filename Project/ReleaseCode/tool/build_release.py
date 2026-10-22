"""Build real self-contained or external-dependency release directories."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


PYTHON_MODULES = (
    "av", "bs4", "chromadb", "ebooklib", "faster_whisper", "imagecodecs",
    "librosa", "lxml", "matplotlib", "mobileclip", "mutagen", "numpy", "odf",
    "olefile", "openpyxl", "PIL", "fitz", "pytesseract", "docx", "pptx",
    "resvg_py", "soundfile", "striprtf", "torch", "torchvision", "transformers",
)


def find_one(root: Path, names: tuple[str, ...], label: str) -> Path:
    if root.is_file() and root.name.lower() in {name.lower() for name in names}:
        return root
    lowered = {name.lower() for name in names}
    for name in names:
        direct = root / name
        if direct.is_file():
            return direct
    matches = sorted(
        (item for item in root.rglob("*") if item.is_file() and item.name.lower() in lowered),
        key=lambda item: str(item).lower(),
    )
    if not matches:
        raise FileNotFoundError(f"{label} is incomplete; expected one of {names} below {root}")
    return matches[0]


def validate_python(root: Path) -> Path:
    executable = find_one(root, ("python.exe", "python3", "python"), "Python")
    expression = (
        "import importlib.util,sys; names=" + repr(PYTHON_MODULES) + "; "
        "missing=[name for name in names if importlib.util.find_spec(name) is None]; "
        "print('\\n'.join(missing)); sys.exit(bool(missing))"
    )
    result = subprocess.run(
        [str(executable), "-c", expression], capture_output=True, text=True, check=False
    )
    if result.returncode:
        missing = result.stdout.strip() or result.stderr.strip()
        raise RuntimeError(f"Python lower-level dependencies are incomplete: {missing}")
    return executable


def validate_models(root: Path) -> None:
    required = (
        root / "image" / "mobileclip_s0.pt",
        root / "audio" / "faster-whisper-medium" / "model.bin",
        root / "audio" / "clap-htsat-fused" / "model.safetensors",
    )
    missing = [str(item) for item in required if not item.is_file()]
    if missing:
        raise FileNotFoundError("AI model files are incomplete: " + ", ".join(missing))


def validate_roots(sources: dict[str, Path]) -> dict[str, str]:
    resolved = {
        "python": str(validate_python(sources["python"])),
        "java": str(find_one(sources["java"], ("java.exe", "java"), "Java")),
        "tika": str(find_one(sources["tika"], (sources["tika"].name,), "Apache Tika")),
        "tesseract": str(find_one(sources["tesseract"], ("tesseract.exe", "tesseract"), "Tesseract")),
        "pdfium": str(find_one(sources["pdfium"], ("pdfium.dll", "libpdfium.so", "libpdfium.dylib"), "PDFium")),
        "jpeg_xr": str(find_one(sources["jpeg_xr"], ("JxrDecApp.exe", "JxrDecApp"), "JPEG XR")),
    }
    for name in ("ddjvu", "djvutxt", "djvused"):
        find_one(sources["djvulibre"], (f"{name}.exe", name), "DjVuLibre")
    find_one(sources["ghostpdl"], ("gswin64c.exe", "gswin32c.exe", "gs"), "Ghostscript")
    validate_models(sources["models"])
    return resolved


def copy_tree(source: Path, destination: Path) -> None:
    def runtime_ignore(directory: str, names: list[str]) -> set[str]:
        ignored = {
            name
            for name in names
            if name in {"__pycache__", ".cache", ".huggingface", ".xet-cache"}
            or name.endswith(".pyc")
        }
        parts = tuple(part.lower() for part in Path(directory).parts)
        if parts[-3:] == ("onnx", "backend", "test"):
            ignored.update(names)
        if parts[-1:] in {("tensorflow",), ("torch",)}:
            ignored.update(name for name in names if name.lower() == "include")
        return ignored

    shutil.copytree(
        source,
        destination,
        dirs_exist_ok=True,
        ignore=runtime_ignore,
    )


def require(path: Path, label: str) -> Path:
    if not path.exists():
        raise FileNotFoundError(f"{label} was not found: {path}")
    return path


def available_bytes(path: Path) -> int:
    return shutil.disk_usage(path.parent if path.parent.exists() else Path.cwd()).free


def tree_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def runtime_root(output: Path, platform_name: str) -> Path:
    if platform_name == "macos":
        return output / "Contents" / "Resources" / "local_retrieval"
    return output / "data" / "local_retrieval"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("self-contained", "external"), required=True)
    parser.add_argument(
        "--platform", choices=("windows", "linux", "macos"), required=True
    )
    parser.add_argument("--release-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--python-root", type=Path)
    parser.add_argument("--models-root", type=Path, required=True)
    parser.add_argument("--ocr-data-root", type=Path, required=True)
    parser.add_argument("--java-root", type=Path)
    parser.add_argument("--tika-jar", type=Path)
    parser.add_argument("--tesseract-root", type=Path)
    parser.add_argument("--pdfium-root", type=Path)
    parser.add_argument("--djvu-root", type=Path)
    parser.add_argument("--ghostpdl-root", type=Path)
    parser.add_argument("--jpeg-xr-root", type=Path)
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate every self-contained dependency without copying a release.",
    )
    arguments = parser.parse_args()

    application = Path(__file__).resolve().parents[1]
    source = require(arguments.release_source.resolve(), "Release source")
    output = arguments.output.resolve()
    if output.exists():
        raise FileExistsError(f"Output already exists: {output}")

    required_space = tree_size(source)
    shared_sources = {
        "models": require(arguments.models_root.resolve(), "Cross-platform models"),
        "tika": require(arguments.tika_jar.resolve(), "Apache Tika"),
        "ocr_data": require(arguments.ocr_data_root.resolve(), "Tesseract language data"),
    }
    require(application / "LICENSE", "Project Apache-2.0 license")
    require(application / "NOTICE", "Project NOTICE")
    require(
        application / "THIRD_PARTY_NOTICES.md",
        "Project third-party notices",
    )
    documentation = require(
        application.parents[1] / "Documentation",
        "Documentation",
    )
    dependency_license_index = require(
        documentation / "Dependency-Licenses.md",
        "Packageable dependency license index",
    )
    required_space += tree_size(documentation)
    validate_models(shared_sources["models"])
    required_space += sum(
        tree_size(value) if value.is_dir() else value.stat().st_size
        for value in shared_sources.values()
    )
    sources: dict[str, Path] = {}
    validated: dict[str, str] = {}
    if arguments.mode == "self-contained":
        values = {
            "python": arguments.python_root,
            "java": arguments.java_root,
            "tesseract": arguments.tesseract_root,
            "pdfium": arguments.pdfium_root,
            "djvulibre": arguments.djvu_root,
            "ghostpdl": arguments.ghostpdl_root,
            "jpeg_xr": arguments.jpeg_xr_root,
        }
        option_names = {
            "python": "--python-root",
            "java": "--java-root",
            "tesseract": "--tesseract-root",
            "pdfium": "--pdfium-root",
            "djvulibre": "--djvu-root",
            "ghostpdl": "--ghostpdl-root",
            "jpeg_xr": "--jpeg-xr-root",
        }
        for name, value in values.items():
            if value is None:
                raise ValueError(
                    f"{option_names[name]} is required for a self-contained release"
                )
            sources[name] = require(value.resolve(), name)
            required_space += tree_size(value) if value.is_dir() else value.stat().st_size
        validated = validate_roots({
            **sources,
            "tika": shared_sources["tika"],
            "models": shared_sources["models"],
        })

    if arguments.validate_only:
        print(json.dumps({"mode": arguments.mode, "validatedSources": validated}, indent=2))
        return 0

    if available_bytes(output) < required_space + 512 * 1024 * 1024:
        raise OSError(f"Not enough free space. Need at least {required_space + 512 * 1024 * 1024} bytes.")

    copy_tree(source, output)
    # Project and third-party license notices are part of every deliverable,
    # not optional documentation kept only beside the source tree.
    for notice_name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(
            require(application / notice_name, notice_name),
            output / notice_name,
        )
    shutil.copy2(dependency_license_index, output / "DEPENDENCY_LICENSES.md")
    # Documentation is a mandatory part of both the open-source source bundle
    # and every generated user release.
    copy_tree(
        documentation,
        output / "Documentation",
    )
    # Never ship the developer's saved paths, language choices, or index data.
    shutil.rmtree(output / "user_config", ignore_errors=True)
    runtime = runtime_root(output, arguments.platform)
    require(runtime, f"{arguments.platform} local runtime resources")
    dependencies = runtime / "dependencies"
    if arguments.mode == "external":
        # A previously staged release source can contain native runtimes.
        # Rebuild this directory from the explicitly portable inputs so an
        # external release never leaks a bundled Python or native toolchain.
        shutil.rmtree(dependencies, ignore_errors=True)
    model_assets = runtime / "assets" / "models"
    copy_tree(shared_sources["models"], model_assets)
    tika_destination = dependencies / "tika"
    tika_destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(
        shared_sources["tika"],
        tika_destination / shared_sources["tika"].name,
    )
    copy_tree(shared_sources["ocr_data"], dependencies / "tesseract" / "tessdata")
    if arguments.mode == "self-contained":
        for name, value in sources.items():
            destination = dependencies / name
            if value.is_dir():
                copy_tree(value, destination)
            else:
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(value, destination / value.name)

    (runtime / "release-mode.json").write_text(
        json.dumps(
            {
                "mode": arguments.mode,
                "platform": arguments.platform,
                "schema": 1,
                "portableDependencies": sorted({
                    *shared_sources,
                    *sources,
                }),
                "browserBundled": False,
                # A delivery manifest must never expose the developer machine's
                # absolute dependency paths.  The detailed paths are printed by
                # --validate-only, while shipped packages record only success.
                "validatedDependencies": {
                    name: True for name in sorted(validated)
                },
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
