"""Enforce the coverage thresholds stated by the project requirements PDF."""

from __future__ import annotations

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
FLUTTER_REPORT = ROOT / "TestResults" / "flutter_coverage.info"
PYTHON_REPORT = ROOT / "TestResults" / "python_coverage.json"
FLUTTER_CORE = (
    "/core/",
    "/domain/",
    "/embedding/",
    "/indexing/",
    "/query/",
    "/retrieval/",
    "/storage/",
    "/summary/",
)
MINIMUM = 90.0
PARSING_MINIMUM = 80.0
EMBEDDING_MINIMUM = 85.0


def flutter_coverage(prefixes: tuple[str, ...] = FLUTTER_CORE) -> tuple[int, int, float]:
    records = FLUTTER_REPORT.read_text(encoding="utf-8").replace("\\", "/").split("end_of_record")
    hit = found = 0
    for record in records:
        lines = record.splitlines()
        source = next((line[3:] for line in lines if line.startswith("SF:")), "")
        if not any(prefix in source for prefix in prefixes):
            continue
        hit += sum(int(line[3:]) for line in lines if line.startswith("LH:"))
        found += sum(int(line[3:]) for line in lines if line.startswith("LF:"))
    return hit, found, hit * 100 / found if found else 0.0


def python_coverage() -> tuple[int, int, float]:
    totals = json.loads(PYTHON_REPORT.read_text(encoding="utf-8"))["totals"]
    hit = int(totals["covered_lines"])
    found = int(totals["num_statements"])
    return hit, found, hit * 100 / found if found else 0.0


def python_modules() -> dict[str, tuple[int, int, float]]:
    files = json.loads(PYTHON_REPORT.read_text(encoding="utf-8"))["files"]
    results = {}
    for path, record in files.items():
        if path.replace("\\", "/").endswith("/__init__.py"):
            continue
        summary = record["summary"]
        hit = int(summary["covered_lines"])
        found = int(summary["num_statements"])
        results[Path(path).name] = (hit, found, hit * 100 / found if found else 0.0)
    return results


def main() -> int:
    results = {
        "Flutter core aggregate": (flutter_coverage(), MINIMUM),
        "Flutter parsing module": (flutter_coverage(("/core/parsing/",)), PARSING_MINIMUM),
        "Flutter embedding module": (flutter_coverage(("/embedding/",)), EMBEDDING_MINIMUM),
        "Python services aggregate": (python_coverage(), MINIMUM),
    }
    results.update({
        f"Python module {name}": (coverage, MINIMUM)
        for name, coverage in python_modules().items()
    })
    failed = False
    for name, (coverage, minimum) in results.items():
        hit, found, percent = coverage
        print(f"{name}: {hit}/{found} = {percent:.2f}% (minimum {minimum:.0f}%)")
        failed = failed or percent < minimum
    if failed:
        print("Coverage gate failed.", file=sys.stderr)
        return 1
    print("Coverage gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
