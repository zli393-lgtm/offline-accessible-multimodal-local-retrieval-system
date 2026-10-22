"""Reuse complete aligned ranges from the fixed-commit Whisper chunk mirror."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--chunks", type=Path, required=True)
    parser.add_argument("--parts", type=Path, required=True)
    parser.add_argument("--part-size-mib", type=int, default=8)
    arguments = parser.parse_args()

    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    model = next(
        item
        for item in manifest["files"]
        if item.get("original_filename") == "model.bin"
    )
    chunk_size = int(model["chunk_size"])
    total_size = int(model["original_size"])
    part_size = arguments.part_size_mib * 1024 * 1024
    arguments.parts.mkdir(parents=True, exist_ok=True)

    copied = 0
    copied_bytes = 0
    for item in model["chunks"]:
        index = int(item["index"])
        filename = str(item["filename"])
        candidates = [
            arguments.chunks / filename,
            arguments.chunks / f"{filename}.downloading",
        ]
        source_path = next((path for path in candidates if path.is_file()), None)
        if source_path is None or source_path.stat().st_size == 0:
            continue
        source_start = index * chunk_size
        source_end = min(total_size, source_start + source_path.stat().st_size)
        aligned_start = math.ceil(source_start / part_size) * part_size
        with source_path.open("rb") as source:
            for range_start in range(aligned_start, source_end, part_size):
                range_end = min(total_size, range_start + part_size)
                expected = range_end - range_start
                if range_start + expected > source_end:
                    break
                part_index = range_start // part_size
                destination = arguments.parts / f"part-{part_index:03d}"
                if destination.is_file() and destination.stat().st_size == expected:
                    continue
                source.seek(range_start - source_start)
                data = source.read(expected)
                if len(data) != expected:
                    break
                destination.write_bytes(data)
                copied += 1
                copied_bytes += len(data)
    print(f"seeded_parts={copied} seeded_bytes={copied_bytes}")


if __name__ == "__main__":
    main()
