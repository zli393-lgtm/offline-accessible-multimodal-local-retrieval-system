from __future__ import annotations

from pathlib import Path
import re
import unittest


_ROOT = Path(__file__).resolve().parents[3]
_SCAN_ROOTS = (_ROOT / "ReleaseCode", _ROOT / "TestCode" / "TestSuite")
_TEXT_SUFFIXES = {
    ".dart",
    ".json",
    ".md",
    ".py",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}
_EXCLUDED_PARTS = {
    ".dart_tool",
    ".git",
    "__pycache__",
    "build",
    "ephemeral",
    "models",
}
_DRIVE_PATH = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/]")


class PathPortabilityTests(unittest.TestCase):
    def test_source_and_tests_do_not_hardcode_drive_paths(self) -> None:
        violations: list[str] = []
        for scan_root in _SCAN_ROOTS:
            for path in scan_root.rglob("*"):
                if not path.is_file() or path.suffix.lower() not in _TEXT_SUFFIXES:
                    continue
                relative = path.relative_to(_ROOT)
                if any(part in _EXCLUDED_PARTS for part in relative.parts):
                    continue
                for line_number, line in enumerate(
                    path.read_text(encoding="utf-8", errors="replace").splitlines(),
                    start=1,
                ):
                    if _DRIVE_PATH.search(line):
                        violations.append(f"{relative}:{line_number}")

        self.assertEqual(
            violations,
            [],
            "Drive-letter paths are forbidden outside generated files: "
            + ", ".join(violations),
        )


if __name__ == "__main__":
    unittest.main()
