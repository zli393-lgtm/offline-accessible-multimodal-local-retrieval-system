"""Install lower-level Python packages and local AI models for a thin release."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


PACKAGES = (
    "av==18.1.0",
    "beautifulsoup4==4.14.2",
    "chromadb==1.5.9",
    "EbookLib==0.20",
    "faster-whisper==1.2.1",
    "huggingface-hub",
    "imagecodecs==2025.11.11",
    "librosa==0.11.0",
    "lxml==6.0.2",
    "matplotlib==3.10.8",
    "mutagen==1.47.0",
    "numpy==2.4.3",
    "odfpy==1.4.1",
    "olefile==0.47",
    "openpyxl==3.1.5",
    "packaging==26.0",
    "Pillow==12.1.1",
    "PyMuPDF==1.28.2",
    "pytesseract==0.3.13",
    "python-docx==1.2.0",
    "python-pptx==1.0.2",
    "resvg_py==0.5.0",
    "soundfile==0.13.1",
    "striprtf==0.0.29",
    "torch==2.14.0",
    "torchvision==0.29.0",
    "transformers==4.51.1",
    "https://github.com/apple/ml-mobileclip/archive/aecfb5453d022e9deff12f81a150ea8f35194baa.zip",
)


def run(command: list[str]) -> None:
    completed = subprocess.run(command, check=False)
    if completed.returncode:
        raise RuntimeError(f"Command failed with exit code {completed.returncode}: {command}")


def install_models(model_root: Path) -> None:
    from huggingface_hub import hf_hub_download, snapshot_download

    image = model_root / "image"
    audio = model_root / "audio"
    image.mkdir(parents=True, exist_ok=True)
    audio.mkdir(parents=True, exist_ok=True)
    hf_hub_download(
        repo_id="apple/MobileCLIP-S0",
        revision="71aa3e13dda93115871afbd017336535ba29886c",
        filename="mobileclip_s0.pt",
        local_dir=image,
    )
    snapshot_download(
        repo_id="Systran/faster-whisper-medium",
        revision="4d9f76bb96174a5625e9ed85e89be563d98d528c",
        local_dir=audio / "faster-whisper-medium",
    )
    snapshot_download(
        repo_id="laion/clap-htsat-fused",
        revision="365dea6ef167def6676140ed93bbc43f84dabb28",
        local_dir=audio / "clap-htsat-fused",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("program", "python"), required=True)
    parser.add_argument("--program-root", type=Path, required=True)
    arguments = parser.parse_args()

    python = Path(sys.executable)
    if arguments.mode == "program":
        environment = arguments.program_root / "dependencies" / "python"
        if not environment.exists():
            run([str(python), "-m", "venv", str(environment)])
        python = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
        model_root = arguments.program_root / "dependencies" / "models"
    else:
        model_root = python.parent.parent / "local_retrieval_models"

    run([str(python), "-m", "pip", "install", "--upgrade", "pip"])
    run([str(python), "-m", "pip", "install", *PACKAGES])
    completed = subprocess.run(
        [str(python), "-c", "import sys; print(sys.executable)"],
        check=True,
        capture_output=True,
        text=True,
    )
    install_models(model_root)
    print(json.dumps({"python": completed.stdout.strip(), "models": str(model_root.resolve())}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
