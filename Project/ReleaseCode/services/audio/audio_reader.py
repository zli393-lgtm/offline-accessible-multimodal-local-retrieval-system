"""Extract metadata, speech text, and semantic vectors from sampled audio.

The three operations are intentionally separate.  Speech recognition produces
text information; CLAP produces audio information.  Video streams are never
decoded by this service.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys
from typing import Any


def _audio_stream(container: Any) -> Any:
    streams = list(container.streams.audio)
    if not streams:
        raise ValueError("The file does not contain a sampled-audio stream.")
    return streams[0]


def _duration_ms(container: Any, stream: Any) -> int | None:
    if stream.duration is not None and stream.time_base is not None:
        return round(float(stream.duration * stream.time_base) * 1000)
    if container.duration is not None:
        import av

        return round(float(container.duration / av.time_base) * 1000)
    return None


def _string_tags(file_path: Path) -> dict[str, str]:
    try:
        import mutagen

        media = mutagen.File(file_path, easy=True)
    except Exception:
        return {}
    if media is None or media.tags is None:
        return {}
    result: dict[str, str] = {}
    for key, value in media.tags.items():
        if isinstance(value, (list, tuple)):
            result[str(key)] = "; ".join(str(item) for item in value)
        else:
            result[str(key)] = str(value)
    return result


def inspect_audio(file_path: str) -> dict[str, object]:
    import av

    path = Path(file_path)
    if not path.is_file():
        raise FileNotFoundError(f"Audio file not found: {path}")
    with av.open(str(path), mode="r") as container:
        stream = _audio_stream(container)
        codec = stream.codec_context
        channel_count = getattr(codec, "channels", None)
        if channel_count is None and getattr(codec, "layout", None) is not None:
            channel_count = len(codec.layout.channels)
        return {
            "format": (container.format.name or path.suffix.lstrip(".")).upper(),
            "long_format": container.format.long_name,
            "codec": codec.name,
            "duration_ms": _duration_ms(container, stream),
            "sample_rate": codec.sample_rate,
            "channels": channel_count,
            "bit_rate": codec.bit_rate or stream.bit_rate or container.bit_rate,
            "tags": _string_tags(path),
        }


def transcribe_audio(
    file_path: str,
    model_path: str,
    *,
    device: str = "cpu",
    compute_type: str = "int8",
) -> dict[str, object]:
    from faster_whisper import WhisperModel

    path = Path(file_path)
    checkpoint = Path(model_path)
    if not path.is_file():
        raise FileNotFoundError(f"Audio file not found: {path}")
    if not checkpoint.is_dir():
        raise FileNotFoundError(f"Whisper model not found: {checkpoint}")

    model = WhisperModel(
        str(checkpoint),
        device=device,
        compute_type=compute_type,
        local_files_only=True,
    )
    generated, info = model.transcribe(
        str(path),
        beam_size=5,
        vad_filter=True,
        condition_on_previous_text=True,
    )
    segments: list[dict[str, object]] = []
    full_text: list[str] = []
    for index, segment in enumerate(generated):
        text = segment.text.strip()
        if not text:
            continue
        full_text.append(text)
        segments.append(
            {
                "index": index,
                "start_ms": round(float(segment.start) * 1000),
                "end_ms": round(float(segment.end) * 1000),
                "text": text,
                "confidence": max(
                    0.0,
                    min(1.0, math.exp(float(getattr(segment, "avg_logprob", 0.0)))),
                ),
            }
        )
    return {
        "model": checkpoint.name,
        "language": info.language,
        "language_probability": float(info.language_probability),
        "text": " ".join(full_text),
        "segments": segments,
    }


def _decode_mono(file_path: str, sample_rate: int) -> Any:
    import av
    import numpy as np
    from av.audio.resampler import AudioResampler

    pieces: list[Any] = []
    with av.open(file_path, mode="r") as container:
        stream = _audio_stream(container)
        resampler = AudioResampler(format="fltp", layout="mono", rate=sample_rate)
        for frame in container.decode(stream):
            converted = resampler.resample(frame)
            if converted is None:
                continue
            if not isinstance(converted, list):
                converted = [converted]
            for output in converted:
                pieces.append(output.to_ndarray().reshape(-1).astype("float32"))
        flushed = resampler.resample(None)
        if flushed is not None:
            if not isinstance(flushed, list):
                flushed = [flushed]
            for output in flushed:
                pieces.append(output.to_ndarray().reshape(-1).astype("float32"))
    if not pieces:
        raise ValueError("No decodable audio samples were found.")
    return np.concatenate(pieces)


def analyze_audio(
    file_path: str,
    model_path: str,
    *,
    device: str = "cpu",
    chunk_seconds: float = 10.0,
) -> dict[str, object]:
    return analyze_audios(
        [file_path],
        model_path=model_path,
        device=device,
        chunk_seconds=chunk_seconds,
    )[0]


def _load_clap(model_path: str, device: str) -> tuple[Any, Any, int]:
    from transformers import AutoProcessor, ClapModel

    checkpoint = Path(model_path)
    if not checkpoint.is_dir():
        raise FileNotFoundError(f"CLAP model not found: {checkpoint}")
    processor = AutoProcessor.from_pretrained(
        str(checkpoint), local_files_only=True
    )
    model = ClapModel.from_pretrained(str(checkpoint), local_files_only=True)
    model.to(device)
    model.eval()
    sample_rate = int(
        getattr(getattr(processor, "feature_extractor", None), "sampling_rate", 48000)
    )
    return processor, model, sample_rate


def _analyze_audio_with_model(
    file_path: str,
    *,
    checkpoint_name: str,
    processor: Any,
    model: Any,
    sample_rate: int,
    device: str,
    chunk_seconds: float,
) -> dict[str, object]:
    import numpy as np
    import torch

    samples = _decode_mono(file_path, sample_rate)
    chunk_size = max(1, round(sample_rate * chunk_seconds))
    vectors: list[Any] = []
    regions: list[dict[str, int]] = []
    for start in range(0, len(samples), chunk_size):
        chunk = samples[start : start + chunk_size]
        if not np.any(chunk):
            continue
        inputs = processor(
            audios=chunk,
            sampling_rate=sample_rate,
            return_tensors="pt",
        )
        inputs = {
            key: value.to(device) if hasattr(value, "to") else value
            for key, value in inputs.items()
        }
        with torch.no_grad():
            vector = model.get_audio_features(**inputs)
            vector = vector / vector.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        vectors.append(vector[0].detach().cpu().to(torch.float32))
        regions.append(
            {
                "start_ms": round(start * 1000 / sample_rate),
                "end_ms": round(min(start + len(chunk), len(samples)) * 1000 / sample_rate),
            }
        )
    if not vectors:
        raise ValueError("Audio semantic analysis produced no non-silent chunks.")
    aggregate = torch.stack(vectors).mean(dim=0)
    aggregate = aggregate / aggregate.norm().clamp_min(1e-12)
    values = aggregate.tolist()
    return {
        "model": checkpoint_name,
        "dimensions": len(values),
        "sample_rate": sample_rate,
        "regions": regions,
        "vector": values,
    }


def analyze_audios(
    file_paths: list[str],
    *,
    model_path: str,
    device: str = "cpu",
    chunk_seconds: float = 10.0,
) -> list[dict[str, object]]:
    if not file_paths:
        return []
    processor, model, sample_rate = _load_clap(model_path, device)
    checkpoint_name = Path(model_path).name
    return [
        _analyze_audio_with_model(
            file_path,
            checkpoint_name=checkpoint_name,
            processor=processor,
            model=model,
            sample_rate=sample_rate,
            device=device,
            chunk_seconds=chunk_seconds,
        )
        for file_path in file_paths
    ]


def embed_audio_texts(
    texts: list[str],
    *,
    model_path: str,
    device: str = "cpu",
) -> list[dict[str, object]]:
    import torch

    if not texts:
        return []
    if any(not text.strip() for text in texts):
        raise ValueError("CLAP text queries must not be empty.")
    processor, model, _ = _load_clap(model_path, device)
    inputs = processor(text=texts, padding=True, return_tensors="pt")
    inputs = {
        key: value.to(device) if hasattr(value, "to") else value
        for key, value in inputs.items()
    }
    with torch.no_grad():
        vectors = model.get_text_features(**inputs)
        vectors = vectors / vectors.norm(dim=-1, keepdim=True).clamp_min(1e-12)
    checkpoint_name = Path(model_path).name
    return [
        {
            "model": checkpoint_name,
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
    commands = parser.add_subparsers(dest="operation", required=True)
    inspect_parser = commands.add_parser("inspect")
    inspect_parser.add_argument("--input", required=True)

    transcribe_parser = commands.add_parser("transcribe")
    transcribe_parser.add_argument("--input", required=True)
    transcribe_parser.add_argument("--model-path", required=True)
    transcribe_parser.add_argument("--device", default="cpu")
    transcribe_parser.add_argument("--compute-type", default="int8")

    analyze_parser = commands.add_parser("analyze")
    analyze_parser.add_argument("--input", required=True)
    analyze_parser.add_argument("--model-path", required=True)
    analyze_parser.add_argument("--device", default="cpu")
    analyze_parser.add_argument("--chunk-seconds", type=float, default=10.0)

    analyze_batch_parser = commands.add_parser("analyze-batch")
    analyze_batch_parser.add_argument("--request-json", required=True)
    analyze_batch_parser.add_argument("--model-path", required=True)
    analyze_batch_parser.add_argument("--device", default="cpu")
    analyze_batch_parser.add_argument("--chunk-seconds", type=float, default=10.0)

    text_batch_parser = commands.add_parser("embed-text-batch")
    text_batch_parser.add_argument("--request-json", required=True)
    text_batch_parser.add_argument("--model-path", required=True)
    text_batch_parser.add_argument("--device", default="cpu")
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        if arguments.operation == "inspect":
            result = inspect_audio(arguments.input)
        elif arguments.operation == "transcribe":
            result = transcribe_audio(
                arguments.input,
                arguments.model_path,
                device=arguments.device,
                compute_type=arguments.compute_type,
            )
        elif arguments.operation == "analyze":
            result = analyze_audio(
                arguments.input,
                arguments.model_path,
                device=arguments.device,
                chunk_seconds=arguments.chunk_seconds,
            )
        elif arguments.operation == "analyze-batch":
            requests = _read_request_list(arguments.request_json)
            result = {
                "results": analyze_audios(
                    [str(item.get("path", "")) for item in requests],
                    model_path=arguments.model_path,
                    device=arguments.device,
                    chunk_seconds=arguments.chunk_seconds,
                )
            }
        else:
            requests = _read_request_list(arguments.request_json)
            result = {
                "results": embed_audio_texts(
                    [str(item.get("text", "")) for item in requests],
                    model_path=arguments.model_path,
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
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
