"""Batch CLAP audio and compatible text-query embeddings."""

from __future__ import annotations

from pathlib import Path
from typing import Any


class ClapEmbeddingEngine:
    def __init__(self, model_path: str, *, device: str = "cpu") -> None:
        from transformers import AutoProcessor, ClapModel

        checkpoint = Path(model_path)
        if not checkpoint.is_dir():
            raise FileNotFoundError(f"CLAP model not found: {checkpoint}")
        self.model_name = checkpoint.name
        self.device = device
        self._processor = AutoProcessor.from_pretrained(
            str(checkpoint), local_files_only=True
        )
        self._model = ClapModel.from_pretrained(
            str(checkpoint), local_files_only=True
        )
        self._model.to(device)
        self._model.eval()
        self.sample_rate = int(
            getattr(
                getattr(self._processor, "feature_extractor", None),
                "sampling_rate",
                48000,
            )
        )

    @staticmethod
    def _decode_mono(file_path: str, sample_rate: int) -> Any:
        import av
        import numpy as np
        from av.audio.resampler import AudioResampler

        path = Path(file_path)
        if not path.is_file():
            raise FileNotFoundError(f"Audio file not found: {path}")
        pieces: list[Any] = []
        with av.open(str(path), mode="r") as container:
            streams = list(container.streams.audio)
            if not streams:
                raise ValueError("The file does not contain a sampled-audio stream.")
            stream = streams[0]
            resampler = AudioResampler(
                format="fltp", layout="mono", rate=sample_rate
            )
            for frame in container.decode(stream):
                converted = resampler.resample(frame)
                if converted is None:
                    continue
                if not isinstance(converted, list):
                    converted = [converted]
                for output in converted:
                    pieces.append(
                        output.to_ndarray().reshape(-1).astype("float32")
                    )
            flushed = resampler.resample(None)
            if flushed is not None:
                if not isinstance(flushed, list):
                    flushed = [flushed]
                for output in flushed:
                    pieces.append(
                        output.to_ndarray().reshape(-1).astype("float32")
                    )
        if not pieces:
            raise ValueError("No decodable audio samples were found.")
        return np.concatenate(pieces)

    def embed_audio_files(
        self,
        file_paths: list[str],
        *,
        chunk_seconds: float = 10.0,
    ) -> list[dict[str, object]]:
        if not file_paths:
            return []
        if chunk_seconds <= 0:
            raise ValueError("chunk_seconds must be greater than zero.")
        return [
            self._embed_audio(file_path, chunk_seconds=chunk_seconds)
            for file_path in file_paths
        ]

    def _embed_audio(
        self,
        file_path: str,
        *,
        chunk_seconds: float,
    ) -> dict[str, object]:
        import numpy as np
        import torch

        samples = self._decode_mono(file_path, self.sample_rate)
        chunk_size = max(1, round(self.sample_rate * chunk_seconds))
        vectors: list[Any] = []
        regions: list[dict[str, int]] = []
        for start in range(0, len(samples), chunk_size):
            chunk = samples[start : start + chunk_size]
            if not np.any(chunk):
                continue
            inputs = self._processor(
                audios=chunk,
                sampling_rate=self.sample_rate,
                return_tensors="pt",
            )
            inputs = {
                key: value.to(self.device) if hasattr(value, "to") else value
                for key, value in inputs.items()
            }
            with torch.no_grad():
                vector = self._model.get_audio_features(**inputs)
                vector = vector / vector.norm(
                    dim=-1, keepdim=True
                ).clamp_min(1e-12)
            vectors.append(vector[0].detach().cpu().to(torch.float32))
            regions.append(
                {
                    "start_ms": round(start * 1000 / self.sample_rate),
                    "end_ms": round(
                        min(start + len(chunk), len(samples))
                        * 1000
                        / self.sample_rate
                    ),
                }
            )
        if not vectors:
            raise ValueError("Audio embedding produced no non-silent chunks.")
        aggregate = torch.stack(vectors).mean(dim=0)
        aggregate = aggregate / aggregate.norm().clamp_min(1e-12)
        return self._result(aggregate, regions=regions)

    def embed_texts(self, texts: list[str]) -> list[dict[str, object]]:
        import torch

        if not texts:
            return []
        if any(not text.strip() for text in texts):
            raise ValueError("CLAP text queries must not be empty.")
        inputs = self._processor(text=texts, padding=True, return_tensors="pt")
        inputs = {
            key: value.to(self.device) if hasattr(value, "to") else value
            for key, value in inputs.items()
        }
        with torch.no_grad():
            vectors = self._model.get_text_features(**inputs)
            vectors = vectors / vectors.norm(
                dim=-1, keepdim=True
            ).clamp_min(1e-12)
        return [self._result(vector) for vector in vectors]

    def _result(
        self,
        vector: Any,
        *,
        regions: list[dict[str, int]] | None = None,
    ) -> dict[str, object]:
        import torch

        values = vector.detach().cpu().to(torch.float32).tolist()
        if not values:
            raise RuntimeError("CLAP returned an empty vector.")
        result: dict[str, object] = {
            "model": self.model_name,
            "dimensions": len(values),
            "vector": values,
        }
        if regions is not None:
            result["sample_rate"] = self.sample_rate
            result["regions"] = regions
        return result
