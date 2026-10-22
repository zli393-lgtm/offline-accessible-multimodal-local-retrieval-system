"""Read bitmap images through separate OCR and visual-analysis steps.

Static images and every composited frame/page of multi-frame images use the
same operations.  The caller selects a zero-based frame with ``--frame-index``.
"""

from __future__ import annotations

import argparse
import base64
from io import BytesIO
import json
import os
from pathlib import Path
import shutil
import sys
import warnings

from PIL import Image, ImageOps


def _open_image_frame(
    file_path: str,
    frame_index: int = 0,
) -> tuple[Image.Image, dict[str, object]]:
    path = Path(file_path)
    if not path.is_file():
        raise FileNotFoundError(f"Image file not found: {path}")

    warnings.simplefilter("error", Image.DecompressionBombWarning)
    with Image.open(path) as opened:
        frame_count = int(getattr(opened, "n_frames", 1))
        if frame_index < 0 or frame_index >= frame_count:
            raise IndexError(
                f"Frame index {frame_index} is outside 0..{frame_count - 1}."
            )

        detected_format = (opened.format or "").upper()
        opened.seek(frame_index)
        frame_duration_ms = opened.info.get("duration")
        if frame_duration_ms is not None:
            frame_duration_ms = int(frame_duration_ms)
        disposal_method = getattr(opened, "disposal_method", None)
        source_mode = opened.mode
        has_alpha = "A" in opened.getbands() or "transparency" in opened.info

        # Pillow presents GIF/APNG/WebP frames as their composited display
        # state after seek(), which is the pixel image a user actually sees.
        image = ImageOps.exif_transpose(opened.convert("RGBA")).copy()
        image.load()

    metadata = {
        "format": detected_format,
        "width": image.width,
        "height": image.height,
        "frame_count": frame_count,
        "frame_index": frame_index,
        "frame_duration_ms": frame_duration_ms,
        "disposal_method": disposal_method,
        "color_mode": source_mode,
        "has_alpha": has_alpha,
    }
    return image, metadata


def inspect_image(file_path: str, frame_index: int = 0) -> dict[str, object]:
    image, metadata = _open_image_frame(file_path, frame_index)
    pixels = image.convert("RGBA").tobytes()
    encoded = BytesIO()
    image.save(encoded, format="PNG")
    return {
        "metadata": {
            **metadata,
            "pixel_format": "RGBA8888",
            "row_stride": image.width * 4,
            "pixels_base64": base64.b64encode(pixels).decode("ascii"),
            "frame_png_base64": base64.b64encode(encoded.getvalue()).decode(
                "ascii"
            ),
        }
    }


def _registry_tesseract() -> str | None:
    if os.name != "nt":
        return None
    try:
        import winreg
    except ImportError:
        return None

    locations = (
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Tesseract-OCR"),
        (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Tesseract-OCR"),
    )
    for root, key_name in locations:
        try:
            with winreg.OpenKey(root, key_name) as key:
                install_path, _ = winreg.QueryValueEx(key, "Path")
        except OSError:
            continue
        candidate = Path(install_path) / "tesseract.exe"
        if candidate.is_file():
            return str(candidate)
    return None


def _resolve_tesseract(explicit_path: str | None) -> str:
    candidates: list[str | None] = [
        explicit_path,
        os.environ.get("TESSERACT_CMD"),
    ]

    home = os.environ.get("TESSERACT_HOME")
    if home:
        candidates.append(
            str(Path(home) / ("tesseract.exe" if os.name == "nt" else "tesseract"))
        )

    candidates.extend([shutil.which("tesseract"), _registry_tesseract()])
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))

    raise FileNotFoundError(
        "Tesseract executable was not found. Supply --tesseract-executable, "
        "configure TESSERACT_CMD/TESSERACT_HOME, or add Tesseract to PATH."
    )


def extract_ocr(
    file_path: str,
    languages: str,
    tesseract_executable: str | None = None,
    page_segmentation_mode: int = 6,
    frame_index: int = 0,
) -> dict[str, object]:
    import pytesseract
    from pytesseract import Output

    image, _ = _open_image_frame(file_path, frame_index)
    pytesseract.pytesseract.tesseract_cmd = _resolve_tesseract(
        tesseract_executable
    )

    configuration = f"--psm {page_segmentation_mode}"
    text_output = pytesseract.image_to_string(
        image,
        lang=languages,
        config=configuration,
    )
    data = pytesseract.image_to_data(
        image,
        lang=languages,
        config=configuration,
        output_type=Output.DICT,
    )

    words: list[dict[str, object]] = []
    confidences: list[float] = []

    for index, raw_text in enumerate(data["text"]):
        text = str(raw_text).strip()
        if not text:
            continue
        try:
            confidence = float(data["conf"][index])
        except (TypeError, ValueError):
            confidence = -1.0

        word = {
            "text": text,
            "confidence": confidence,
            "left": int(data["left"][index]),
            "top": int(data["top"][index]),
            "width": int(data["width"][index]),
            "height": int(data["height"][index]),
        }
        words.append(word)
        if confidence >= 0:
            confidences.append(confidence)

    mean_confidence = (
        sum(confidences) / len(confidences) if confidences else None
    )
    return {
        "text": text_output.strip(),
        "languages": languages,
        "mean_confidence": mean_confidence,
        "frame_index": frame_index,
        "words": words,
    }


def analyze_image(
    file_path: str,
    model_path: str,
    model_name: str = "mobileclip_s0",
    device: str = "cpu",
    frame_index: int = 0,
) -> dict[str, object]:
    return analyze_images(
        [{"path": file_path, "frame_index": frame_index}],
        model_path=model_path,
        model_name=model_name,
        device=device,
    )[0]


def _load_mobileclip(
    model_path: str,
    model_name: str,
    device: str,
) -> tuple[Any, Any]:
    import torch
    import mobileclip

    checkpoint = Path(model_path)
    if not checkpoint.is_file():
        raise FileNotFoundError(f"MobileCLIP model not found: {checkpoint}")

    model, _, preprocess = mobileclip.create_model_and_transforms(
        model_name,
        pretrained=str(checkpoint),
        device=device,
    )
    model.eval()
    return model, preprocess


def analyze_images(
    requests: list[dict[str, object]],
    *,
    model_path: str,
    model_name: str = "mobileclip_s0",
    device: str = "cpu",
) -> list[dict[str, object]]:
    import torch

    if not requests:
        return []
    model, preprocess = _load_mobileclip(model_path, model_name, device)
    tensors: list[Any] = []
    frame_indexes: list[int] = []
    for request in requests:
        file_path = str(request["path"])
        frame_index = int(request.get("frame_index", 0))
        image, _ = _open_image_frame(file_path, frame_index)
        tensors.append(preprocess(image.convert("RGB")))
        frame_indexes.append(frame_index)

    with torch.no_grad():
        vectors = model.encode_image(torch.stack(tensors).to(device))
        vectors = vectors / vectors.norm(dim=-1, keepdim=True).clamp_min(1e-12)

    results: list[dict[str, object]] = []
    for frame_index, vector in zip(frame_indexes, vectors, strict=True):
        values = vector.detach().cpu().to(torch.float32).tolist()
        if not values:
            raise RuntimeError("MobileCLIP returned an empty image vector.")
        results.append(
            {
                "model": model_name,
                "dimensions": len(values),
                "frame_index": frame_index,
                "vector": values,
            }
        )
    return results


def embed_image_texts(
    texts: list[str],
    *,
    model_path: str,
    model_name: str = "mobileclip_s0",
    device: str = "cpu",
) -> list[dict[str, object]]:
    import torch
    import mobileclip

    if not texts:
        return []
    if any(not text.strip() for text in texts):
        raise ValueError("MobileCLIP text queries must not be empty.")
    model, _ = _load_mobileclip(model_path, model_name, device)
    tokenizer = mobileclip.get_tokenizer(model_name)
    tokens = tokenizer(texts).to(device)
    with torch.no_grad():
        vectors = model.encode_text(tokens)
        vectors = vectors / vectors.norm(dim=-1, keepdim=True).clamp_min(1e-12)
    return [
        {
            "model": model_name,
            "dimensions": int(vector.numel()),
            "vector": vector.detach().cpu().to(torch.float32).tolist(),
        }
        for vector in vectors
    ]


def _read_request_list(file_path: str) -> list[dict[str, object]]:
    payload = json.loads(Path(file_path).read_text(encoding="utf-8"))
    if not isinstance(payload, list) or not all(
        isinstance(item, dict) for item in payload
    ):
        raise ValueError("Request JSON must contain a list of objects.")
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)

    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--input", required=True)
    inspect_parser.add_argument("--frame-index", type=int, default=0)

    ocr_parser = subparsers.add_parser("ocr")
    ocr_parser.add_argument("--input", required=True)
    ocr_parser.add_argument("--languages", default="chi_sim+eng")
    ocr_parser.add_argument("--tesseract-executable")
    ocr_parser.add_argument("--psm", type=int, default=6)
    ocr_parser.add_argument("--frame-index", type=int, default=0)

    analyze_parser = subparsers.add_parser("analyze")
    analyze_parser.add_argument("--input", required=True)
    analyze_parser.add_argument("--model-path", required=True)
    analyze_parser.add_argument("--model-name", default="mobileclip_s0")
    analyze_parser.add_argument("--device", default="cpu")
    analyze_parser.add_argument("--frame-index", type=int, default=0)

    analyze_batch_parser = subparsers.add_parser("analyze-batch")
    analyze_batch_parser.add_argument("--request-json", required=True)
    analyze_batch_parser.add_argument("--model-path", required=True)
    analyze_batch_parser.add_argument("--model-name", default="mobileclip_s0")
    analyze_batch_parser.add_argument("--device", default="cpu")

    text_batch_parser = subparsers.add_parser("embed-text-batch")
    text_batch_parser.add_argument("--request-json", required=True)
    text_batch_parser.add_argument("--model-path", required=True)
    text_batch_parser.add_argument("--model-name", default="mobileclip_s0")
    text_batch_parser.add_argument("--device", default="cpu")
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        if arguments.operation == "inspect":
            payload = inspect_image(arguments.input, arguments.frame_index)
        elif arguments.operation == "ocr":
            payload = extract_ocr(
                file_path=arguments.input,
                languages=arguments.languages,
                tesseract_executable=arguments.tesseract_executable,
                page_segmentation_mode=arguments.psm,
                frame_index=arguments.frame_index,
            )
        elif arguments.operation == "analyze":
            payload = analyze_image(
                file_path=arguments.input,
                model_path=arguments.model_path,
                model_name=arguments.model_name,
                device=arguments.device,
                frame_index=arguments.frame_index,
            )
        elif arguments.operation == "analyze-batch":
            requests = _read_request_list(arguments.request_json)
            payload = {
                "results": analyze_images(
                    requests,
                    model_path=arguments.model_path,
                    model_name=arguments.model_name,
                    device=arguments.device,
                )
            }
        else:
            requests = _read_request_list(arguments.request_json)
            payload = {
                "results": embed_image_texts(
                    [str(item.get("text", "")) for item in requests],
                    model_path=arguments.model_path,
                    model_name=arguments.model_name,
                    device=arguments.device,
                )
            }
    except Exception as error:
        print(
            json.dumps(
                {"error": str(error), "error_type": type(error).__name__},
                ensure_ascii=True,
            )
        )
        return 1

    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
