"""Batch MobileCLIP image and compatible text-query embeddings."""

from __future__ import annotations

from pathlib import Path
from typing import Any


class MobileClipEmbeddingEngine:
    def __init__(
        self,
        model_path: str,
        *,
        model_name: str = "mobileclip_s0",
        device: str = "cpu",
    ) -> None:
        import mobileclip

        checkpoint = Path(model_path)
        if not checkpoint.is_file():
            raise FileNotFoundError(f"MobileCLIP model not found: {checkpoint}")
        self.model_name = model_name
        self.device = device
        self._model, _, self._preprocess = mobileclip.create_model_and_transforms(
            model_name,
            pretrained=str(checkpoint),
            device=device,
        )
        self._tokenizer = mobileclip.get_tokenizer(model_name)
        self._model.eval()

    def embed_images(
        self,
        requests: list[dict[str, object]],
    ) -> list[dict[str, object]]:
        import torch
        from PIL import Image

        if not requests:
            return []
        tensors: list[Any] = []
        frame_indexes: list[int] = []
        for request in requests:
            path = Path(str(request.get("path", "")))
            frame_index = int(request.get("frame_index", 0))
            if not path.is_file():
                raise FileNotFoundError(f"Image file not found: {path}")
            with Image.open(path) as image:
                frame_count = int(getattr(image, "n_frames", 1))
                if frame_index < 0 or frame_index >= frame_count:
                    raise IndexError(
                        f"Frame index {frame_index} is outside 0..{frame_count - 1}."
                    )
                image.seek(frame_index)
                tensors.append(self._preprocess(image.convert("RGB")))
            frame_indexes.append(frame_index)
        with torch.no_grad():
            vectors = self._model.encode_image(torch.stack(tensors).to(self.device))
            vectors = vectors / vectors.norm(
                dim=-1, keepdim=True
            ).clamp_min(1e-12)
        return [
            self._result(vector, frame_index=frame_index)
            for frame_index, vector in zip(frame_indexes, vectors, strict=True)
        ]

    def embed_texts(self, texts: list[str]) -> list[dict[str, object]]:
        import torch

        if not texts:
            return []
        if any(not text.strip() for text in texts):
            raise ValueError("MobileCLIP text queries must not be empty.")
        tokens = self._tokenizer(texts).to(self.device)
        with torch.no_grad():
            vectors = self._model.encode_text(tokens)
            vectors = vectors / vectors.norm(
                dim=-1, keepdim=True
            ).clamp_min(1e-12)
        return [self._result(vector) for vector in vectors]

    def _result(
        self,
        vector: Any,
        *,
        frame_index: int | None = None,
    ) -> dict[str, object]:
        import torch

        values = vector.detach().cpu().to(torch.float32).tolist()
        if not values:
            raise RuntimeError("MobileCLIP returned an empty vector.")
        result: dict[str, object] = {
            "model": self.model_name,
            "dimensions": len(values),
            "vector": values,
        }
        if frame_index is not None:
            result["frame_index"] = frame_index
        return result
