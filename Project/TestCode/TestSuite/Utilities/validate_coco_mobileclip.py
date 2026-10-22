"""Validate MobileCLIP image/text alignment on a deterministic COCO subset."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time
from typing import Any


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--device", default="cpu")
    return parser.parse_args()


def _load_rows(manifest: Path, limit: int) -> list[dict[str, Any]]:
    if limit <= 0:
        raise ValueError("--limit must be greater than zero")
    rows: list[dict[str, Any]] = []
    with manifest.open("r", encoding="utf-8") as source:
        for line in source:
            if not line.strip():
                continue
            row = json.loads(line)
            captions = row.get("captions") or []
            if row.get("image_path") and captions:
                rows.append(row)
            if len(rows) >= limit:
                break
    if len(rows) < 2:
        raise ValueError("COCO manifest did not provide at least two valid samples")
    return rows


def _ranks(similarities: Any) -> list[int]:
    order = similarities.argsort(dim=1, descending=True)
    ranks: list[int] = []
    for index in range(order.shape[0]):
        position = (order[index] == index).nonzero(as_tuple=False)
        ranks.append(int(position[0, 0].item()) + 1)
    return ranks


def _metrics(ranks: list[int]) -> dict[str, float]:
    total = len(ranks)
    return {
        "recall_at_1": sum(rank <= 1 for rank in ranks) / total,
        "recall_at_5": sum(rank <= 5 for rank in ranks) / total,
        "recall_at_10": sum(rank <= 10 for rank in ranks) / total,
        "mrr": sum(1.0 / rank for rank in ranks) / total,
    }


def validate(
    *,
    rows: list[dict[str, Any]],
    dataset_root: Path,
    model_path: Path,
    batch_size: int,
    device: str,
) -> dict[str, Any]:
    import mobileclip
    import torch
    from PIL import Image

    if batch_size <= 0:
        raise ValueError("--batch-size must be greater than zero")
    model, _, preprocess = mobileclip.create_model_and_transforms(
        "mobileclip_s0",
        pretrained=str(model_path),
        device=device,
    )
    tokenizer = mobileclip.get_tokenizer("mobileclip_s0")
    model.eval()
    captions = [str(row["captions"][0]).strip() for row in rows]
    image_vectors: list[Any] = []
    text_vectors: list[Any] = []
    started = time.perf_counter()
    with torch.no_grad():
        for start in range(0, len(rows), batch_size):
            batch = rows[start : start + batch_size]
            images = []
            for row in batch:
                path = dataset_root / str(row["image_path"])
                with Image.open(path) as image:
                    images.append(preprocess(image.convert("RGB")))
            vectors = model.encode_image(torch.stack(images).to(device))
            vectors = vectors / vectors.norm(dim=-1, keepdim=True).clamp_min(1e-12)
            image_vectors.append(vectors.cpu())
        for start in range(0, len(captions), batch_size):
            tokens = tokenizer(captions[start : start + batch_size]).to(device)
            vectors = model.encode_text(tokens)
            vectors = vectors / vectors.norm(dim=-1, keepdim=True).clamp_min(1e-12)
            text_vectors.append(vectors.cpu())
    images = torch.cat(image_vectors)
    texts = torch.cat(text_vectors)
    similarities = texts @ images.T
    text_to_image_ranks = _ranks(similarities)
    image_to_text_ranks = _ranks(similarities.T)
    return {
        "metrics": {
            "protocol": "COCO first-caption retrieval within deterministic subset",
            "model": "MobileCLIP-S0",
            "samples": len(rows),
            "batch_size": batch_size,
            "dimensions": int(images.shape[1]),
            "elapsed_seconds": time.perf_counter() - started,
            "text_to_image": _metrics(text_to_image_ranks),
            "image_to_text": _metrics(image_to_text_ranks),
        },
        "samples": [
            {
                "image_id": row["image_id"],
                "image_path": row["image_path"],
                "caption": captions[index],
                "text_to_image_rank": text_to_image_ranks[index],
                "image_to_text_rank": image_to_text_ranks[index],
            }
            for index, row in enumerate(rows)
        ],
    }


def main() -> int:
    arguments = _arguments()
    rows = _load_rows(arguments.manifest, arguments.limit)
    result = validate(
        rows=rows,
        dataset_root=arguments.dataset_root,
        model_path=arguments.model,
        batch_size=arguments.batch_size,
        device=arguments.device,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(result["metrics"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
