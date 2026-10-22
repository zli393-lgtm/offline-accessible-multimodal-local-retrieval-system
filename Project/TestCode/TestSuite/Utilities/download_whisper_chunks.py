"""Download pinned GitHub chunks and verify against the official model hash."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess
import time

def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _download(
    base_url: str,
    whole_file_url: str | None,
    range_offset: int,
    directory: Path,
    item: dict[str, object],
) -> Path:
    filename = str(item["filename"])
    size = int(item["size"])
    expected_hash = str(item["sha256"])
    destination = directory / filename
    if (
        destination.is_file()
        and destination.stat().st_size == size
        and _sha256(destination) == expected_hash
    ):
        return destination
    temporary = destination.with_suffix(destination.suffix + ".downloading")
    if temporary.is_file() and temporary.stat().st_size > size:
        temporary.unlink()
    current = temporary.stat().st_size if temporary.is_file() else 0
    url = whole_file_url or f"{base_url}/{filename}"
    if url.startswith(("http://", "https://")):
        offset_base = range_offset if whole_file_url else 0
        tail = destination.with_suffix(destination.suffix + ".tail")
        if tail.is_file():
            if current + tail.stat().st_size > size:
                tail.unlink()
            else:
                with temporary.open("ab") as output, tail.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        output.write(block)
                tail.unlink()
                current = temporary.stat().st_size
        for attempt in range(10):
            absolute_start = offset_base + current
            absolute_end = offset_base + size - 1
            result = subprocess.run(
                [
                    "curl.exe",
                    "-sS",
                    "-L",
                    "--fail",
                    "--connect-timeout",
                    "30",
                    "--speed-limit",
                    "1024",
                    "--speed-time",
                    "180",
                    "-r",
                    f"{absolute_start}-{absolute_end}",
                    "-o",
                    str(tail),
                    url,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if tail.is_file() and tail.stat().st_size:
                if current + tail.stat().st_size > size:
                    raise RuntimeError(f"{filename}: received too many bytes")
                with temporary.open("ab") as output, tail.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        output.write(block)
                tail.unlink()
                current = temporary.stat().st_size
            if current == size:
                break
            if attempt == 9:
                raise RuntimeError(
                    f"{filename}: curl failed at {current} bytes: "
                    f"{result.stderr.strip()}"
                )
            time.sleep(min(30, 2**attempt))
    if temporary.stat().st_size != size:
        raise RuntimeError(f"{filename}: size mismatch")
    if _sha256(temporary) != expected_hash:
        raise RuntimeError(f"{filename}: SHA-256 mismatch")
    temporary.replace(destination)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--whole-file-url")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download-directory", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=16)
    arguments = parser.parse_args()

    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    model = next(
        item
        for item in manifest["files"]
        if item.get("original_filename") == "model.bin"
    )
    chunks = sorted(model["chunks"], key=lambda item: int(item["index"]))
    arguments.download_directory.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=min(arguments.workers, len(chunks))) as executor:
        futures = [
            executor.submit(
                _download,
                arguments.base_url.rstrip("/"),
                arguments.whole_file_url,
                int(item["index"]) * int(model["chunk_size"]),
                arguments.download_directory,
                item,
            )
            for item in chunks
        ]
        for future in as_completed(futures):
            future.result()

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    assembling = arguments.output.with_name(arguments.output.name + ".assembling")
    digest = hashlib.sha256()
    with assembling.open("wb") as combined:
        for item in chunks:
            path = arguments.download_directory / str(item["filename"])
            with path.open("rb") as source:
                while block := source.read(1024 * 1024):
                    combined.write(block)
                    digest.update(block)
    if assembling.stat().st_size != int(model["original_size"]):
        raise RuntimeError("Reassembled model size does not match the official size.")
    if digest.hexdigest() != str(model["original_sha256"]):
        raise RuntimeError("Reassembled model SHA-256 does not match the official hash.")
    assembling.replace(arguments.output)
    for item in chunks:
        (arguments.download_directory / str(item["filename"])).unlink()
    arguments.download_directory.rmdir()


if __name__ == "__main__":
    main()
