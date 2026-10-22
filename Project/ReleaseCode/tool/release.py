"""Build one of the six desktop release variants with one command."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


TARGETS = {
    "windows-external": ("windows", "external"),
    "windows-self-contained": ("windows", "self-contained"),
    "linux-external": ("linux", "external"),
    "linux-self-contained": ("linux", "self-contained"),
    "macos-external": ("macos", "external"),
    "macos-self-contained": ("macos", "self-contained"),
}

HOSTS = {"Windows": "windows", "Linux": "linux", "Darwin": "macos"}


def flutter_command(*arguments: str) -> list[str]:
    flutter = shutil.which("flutter.bat" if os.name == "nt" else "flutter")
    if not flutter:
        raise FileNotFoundError("Flutter SDK was not found on PATH")
    if os.name == "nt":
        # flutter.bat invokes PowerShell before starting Flutter. Some Windows
        # systems intentionally disable PowerShell, so invoke the same Flutter
        # tool snapshot directly with the SDK-bundled Dart executable.
        sdk_root = Path(flutter).resolve().parent.parent
        dart = sdk_root / "bin" / "cache" / "dart-sdk" / "bin" / "dart.exe"
        snapshot = sdk_root / "bin" / "cache" / "flutter_tools.snapshot"
        packages = (
            sdk_root
            / "packages"
            / "flutter_tools"
            / ".dart_tool"
            / "package_config.json"
        )
        if not dart.is_file() or not snapshot.is_file() or not packages.is_file():
            raise FileNotFoundError("The configured Flutter SDK cache is incomplete")
        return [
            str(dart),
            f"--packages={packages}",
            str(snapshot),
            *arguments,
        ]
    return [flutter, *arguments]


def locate_one(root: Path, patterns: tuple[str, ...], label: str) -> Path:
    if not root.is_dir():
        raise FileNotFoundError(f"{label} dependency directory is missing: {root}")
    lowered = {name.lower() for name in patterns}
    matches = sorted(
        item for item in root.rglob("*")
        if item.is_file() and item.name.lower() in lowered
    )
    if not matches:
        raise FileNotFoundError(f"{label} is incomplete below {root}")
    return matches[0]


def release_source(application: Path, platform_name: str) -> Path:
    if platform_name == "windows":
        return application / "build" / "windows" / "x64" / "runner" / "Release"
    if platform_name == "linux":
        return application / "build" / "linux" / "x64" / "release" / "bundle"
    return application / "build" / "macos" / "Build" / "Products" / "Release" / "retrieval.app"


def clean_generated(application: Path) -> None:
    try:
        subprocess.run(flutter_command("clean"), cwd=application, check=False)
    except FileNotFoundError:
        # Manual cleanup below remains sufficient when the Flutter SDK is not
        # installed on the current machine.
        pass
    for relative in (
        ".dart_tool", ".pytest_cache", "build", "coverage",
        ".flutter_tool_state", ".flutter-plugins-dependencies",
        "windows/flutter/ephemeral", "linux/flutter/ephemeral",
        "macos/Flutter/ephemeral",
    ):
        target = application / relative
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
        elif target.exists():
            target.unlink(missing_ok=True)
    for cache in sorted(application.rglob("__pycache__"), reverse=True):
        shutil.rmtree(cache, ignore_errors=True)


def dependency_arguments(application: Path, platform_name: str) -> list[str]:
    dependency_root = application.parents[1] / "Dependencies"
    shared = dependency_root / "Packageable"
    platform_root = dependency_root / "Non-Packageable" / {
        "windows": "Windows",
        "linux": "Linux",
        "macos": "macOS",
    }[platform_name]
    tika = locate_one(
        shared / "Apache-Tika",
        ("tika-app.jar", "tika-app-4.0.0.jar"),
        "Apache Tika",
    )
    return [
        "--models-root", str(shared / "Models"),
        "--ocr-data-root", str(shared / "Tesseract-Data"),
        "--python-root", str(platform_root / "python"),
        "--java-root", str(platform_root / "java"),
        "--tika-jar", str(tika),
        "--tesseract-root", str(platform_root / "tesseract"),
        "--pdfium-root", str(platform_root / "pdfium"),
        "--djvu-root", str(platform_root / "djvulibre"),
        "--ghostpdl-root", str(platform_root / "ghostpdl"),
        "--jpeg-xr-root", str(platform_root / "jpeg_xr"),
    ]


def stage_flutter_assets(application: Path) -> None:
    """Stage build-time Flutter assets without storing dependencies in source."""
    source = application.parents[1] / "Dependencies" / "Packageable" / "Models" / "bert"
    destination = application / "assets" / "models" / "bert"
    required = (
        "bert_base_uncased_dynamic.tflite",
        "tokenizer.json",
        "vocab.txt",
    )
    missing = [name for name in required if not (source / name).is_file()]
    if missing:
        raise FileNotFoundError(
            "Cross-platform BERT assets are incomplete: " + ", ".join(missing)
        )
    destination.mkdir(parents=True, exist_ok=True)
    for name in required:
        shutil.copy2(source / name, destination / name)


def remove_staged_flutter_assets(application: Path) -> None:
    staged = application / "assets" / "models"
    shutil.rmtree(staged, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build Windows, Linux, or macOS external/self-contained releases."
    )
    parser.add_argument("target", choices=tuple(TARGETS))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    arguments = parser.parse_args()

    application = Path(__file__).resolve().parents[1]
    platform_name, mode = TARGETS[arguments.target]
    host = HOSTS.get(platform.system())
    if host != platform_name:
        raise RuntimeError(
            f"{arguments.target} must be built on {platform_name}; current host is {host or platform.system()}"
        )

    output = (arguments.output or (
        application.parents[1] / "Release" / arguments.target
    )).resolve()
    source = release_source(application, platform_name)
    packager = application / "tool" / "build_release.py"
    # Cross-platform dependencies are included in every release. Platform
    # runtimes are additionally required for a self-contained release.
    dependency_args = dependency_arguments(application, platform_name)

    if arguments.validate_only:
        placeholder = source if source.exists() else application
        command = [
            sys.executable, str(packager), "--mode", mode,
            "--platform", platform_name, "--release-source", str(placeholder),
            "--output", str(output), *dependency_args, "--validate-only",
        ]
        subprocess.run(command, cwd=application, check=True)
        print(f"{arguments.target}: configuration is complete")
        return 0

    if output.exists():
        raise FileExistsError(f"Release output already exists: {output}")

    try:
        stage_flutter_assets(application)
        subprocess.run(flutter_command("pub", "get"), cwd=application, check=True)
        subprocess.run(
            flutter_command("build", platform_name, "--release"),
            cwd=application,
            check=True,
        )
        command = [
            sys.executable, str(packager), "--mode", mode,
            "--platform", platform_name, "--release-source", str(source),
            "--output", str(output), *dependency_args,
        ]
        subprocess.run(command, cwd=application, check=True)
        print(output)
        return 0
    finally:
        remove_staged_flutter_assets(application)
        clean_generated(application)


if __name__ == "__main__":
    raise SystemExit(main())
