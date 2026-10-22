"""Resumable, bounded parallel downloader for one pinned Hugging Face file."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
from pathlib import Path
import subprocess
import time
from urllib.parse import urljoin

import requests


def _download_part_requests(
    url: str,
    part: Path,
    start: int,
    end: int,
    retries: int,
) -> None:
    expected = end - start + 1
    current = part.stat().st_size if part.exists() else 0
    if current > expected:
        part.unlink()
        current = 0
    if current == expected:
        return
    for attempt in range(retries):
        offset = start + current
        try:
            response = requests.get(
                url,
                headers={"Range": f"bytes={offset}-{end}"},
                stream=True,
                allow_redirects=True,
                timeout=(30, 180),
            )
            if response.status_code != 206:
                raise RuntimeError(
                    f"Server ignored byte range {offset}-{end}: HTTP {response.status_code}"
                )
            with part.open("ab") as output:
                for block in response.iter_content(chunk_size=1024 * 1024):
                    if block:
                        output.write(block)
                        current += len(block)
            if current == expected:
                return
            if current > expected:
                raise RuntimeError(f"Part exceeded expected length: {part}")
        except Exception:
            if attempt + 1 == retries:
                raise
            time.sleep(min(30, 2 ** attempt))
            current = part.stat().st_size if part.exists() else 0
    raise RuntimeError(f"Failed to download {part}")


def _download_part_curl(
    url: str,
    part: Path,
    start: int,
    end: int,
    retries: int,
) -> None:
    expected = end - start + 1
    if part.is_file() and part.stat().st_size == expected:
        return
    temporary = part.with_suffix(".downloading")
    for attempt in range(retries):
        current = part.stat().st_size if part.is_file() else 0
        if current > expected:
            part.unlink()
            current = 0
        if temporary.is_file() and temporary.stat().st_size:
            if current + temporary.stat().st_size > expected:
                temporary.unlink()
            else:
                with part.open("ab") as output, temporary.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        output.write(block)
                temporary.unlink()
                current = part.stat().st_size
        if current == expected:
            return
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
                f"{start + current}-{end}",
                "-o",
                str(temporary),
                url,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if temporary.is_file() and temporary.stat().st_size:
            if current + temporary.stat().st_size > expected:
                raise RuntimeError(f"Part exceeded expected length: {part}")
            with part.open("ab") as output, temporary.open("rb") as source:
                while block := source.read(1024 * 1024):
                    output.write(block)
            temporary.unlink()
        if part.is_file() and part.stat().st_size == expected:
            return
        if attempt + 1 == retries:
            raise RuntimeError(
                f"curl failed for {start}-{end}: {result.stderr.strip()}"
            )
        time.sleep(min(30, 2 ** attempt))


def download(
    url: str,
    output: Path,
    size: int,
    sha256: str,
    workers: int,
    retries: int,
    part_size_mib: int,
    engine: str,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    parts_directory = output.with_name(output.name + ".parts")
    parts_directory.mkdir(exist_ok=True)
    chunk = part_size_mib * 1024 * 1024
    jobs: list[tuple[Path, int, int]] = []
    for index, start in enumerate(range(0, size, chunk)):
        end = min(size - 1, start + chunk - 1)
        part = parts_directory / f"part-{index:03d}"
        legacy_partial = part.with_suffix(".downloading")
        expected = end - start + 1
        if (
            not part.exists()
            and legacy_partial.is_file()
            and 0 < legacy_partial.stat().st_size <= expected
        ):
            legacy_partial.replace(part)
        jobs.append((part, start, end))

    # Reuse a verified-source prefix left by an interrupted single-file
    # download.  The final full-file SHA-256 remains the authority.
    if output.is_file() and 0 < output.stat().st_size < size:
        with output.open("rb") as source:
            for part, start, end in jobs:
                expected = end - start + 1
                block = source.read(expected)
                if not block:
                    break
                if not part.exists():
                    part.write_bytes(block)
                if len(block) < expected:
                    break

    worker_function = (
        _download_part_curl if engine == "curl" else _download_part_requests
    )
    with ThreadPoolExecutor(max_workers=min(workers, len(jobs))) as executor:
        futures = {
            executor.submit(worker_function, url, part, start, end, retries): part
            for part, start, end in jobs
        }
        for future in as_completed(futures):
            future.result()

    temporary = output.with_name(output.name + ".assembling")
    digest = hashlib.sha256()
    with temporary.open("wb") as combined:
        for part, start, end in jobs:
            if part.stat().st_size != end - start + 1:
                raise RuntimeError(f"Incomplete part: {part}")
            with part.open("rb") as source:
                while block := source.read(1024 * 1024):
                    combined.write(block)
                    digest.update(block)
    if temporary.stat().st_size != size:
        raise RuntimeError("Assembled file size does not match the pinned size.")
    if digest.hexdigest().lower() != sha256.lower():
        raise RuntimeError("Assembled file SHA-256 does not match the pinned hash.")
    temporary.replace(output)
    for part, _, _ in jobs:
        part.unlink()
    parts_directory.rmdir()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--retries", type=int, default=10)
    parser.add_argument("--part-size-mib", type=int, default=8)
    parser.add_argument("--engine", choices=("curl", "requests"), default="curl")
    parser.add_argument("--resolve-once", action="store_true")
    arguments = parser.parse_args()
    url = arguments.url
    if arguments.resolve_once:
        resolved = subprocess.run(
            ["curl.exe", "-sS", "-I", "--max-time", "120", url],
            capture_output=True,
            text=True,
            check=False,
        )
        if resolved.returncode != 0:
            raise RuntimeError(
                f"Could not resolve model redirect: {resolved.stderr.strip()}"
            )
        locations = [
            line.split(":", 1)[1].strip()
            for line in resolved.stdout.splitlines()
            if line.lower().startswith("location:")
        ]
        if not locations:
            raise RuntimeError("Model redirect did not include a Location header.")
        url = urljoin(url, locations[-1])
    download(
        url,
        arguments.output,
        arguments.size,
        arguments.sha256,
        arguments.workers,
        arguments.retries,
        arguments.part_size_mib,
        arguments.engine,
    )


if __name__ == "__main__":
    main()
