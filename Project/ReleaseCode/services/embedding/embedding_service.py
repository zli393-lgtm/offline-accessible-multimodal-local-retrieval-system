"""JSON CLI for text-query, image, and audio embedding batches."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


APPLICATION_ROOT = Path(__file__).resolve().parents[2]
if str(APPLICATION_ROOT) not in sys.path:
    sys.path.insert(0, str(APPLICATION_ROOT))

from services.embedding.clap_engine import ClapEmbeddingEngine
from services.embedding.mobileclip_engine import MobileClipEmbeddingEngine


def _requests(path: str) -> list[dict[str, object]]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, list) or not all(
        isinstance(item, dict) for item in payload
    ):
        raise ValueError("Request JSON must contain a list of objects.")
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("image-batch", "image-text-batch"):
        command = commands.add_parser(name)
        command.add_argument("--request-json", required=True)
        command.add_argument("--model-path", required=True)
        command.add_argument("--model-name", default="mobileclip_s0")
        command.add_argument("--device", default="cpu")
    for name in ("audio-batch", "audio-text-batch"):
        command = commands.add_parser(name)
        command.add_argument("--request-json", required=True)
        command.add_argument("--model-path", required=True)
        command.add_argument("--device", default="cpu")
        command.add_argument("--chunk-seconds", type=float, default=10.0)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        requests = _requests(arguments.request_json)
        if arguments.operation.startswith("image"):
            engine = MobileClipEmbeddingEngine(
                arguments.model_path,
                model_name=arguments.model_name,
                device=arguments.device,
            )
            if arguments.operation == "image-batch":
                results = engine.embed_images(requests)
            else:
                results = engine.embed_texts(
                    [str(item.get("text", "")) for item in requests]
                )
        else:
            engine = ClapEmbeddingEngine(
                arguments.model_path,
                device=arguments.device,
            )
            if arguments.operation == "audio-batch":
                results = engine.embed_audio_files(
                    [str(item.get("path", "")) for item in requests],
                    chunk_seconds=arguments.chunk_seconds,
                )
            else:
                results = engine.embed_texts(
                    [str(item.get("text", "")) for item in requests]
                )
        payload: dict[str, object] = {"results": results}
    except Exception as error:
        payload = {"error": str(error), "error_type": type(error).__name__}
        print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
        return 1
    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
