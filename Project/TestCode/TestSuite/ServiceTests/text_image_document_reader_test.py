from __future__ import annotations

import base64
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import sys

_APPLICATION = Path(__file__).resolve().parents[3] / "ReleaseCode"
sys.path.insert(0, str(_APPLICATION))

from services.text_image_document.text_image_document_reader import (  # noqa: E402
    _empty_result,
    _extract_djvu,
    _extract_fb2,
    _extract_fb2_zip,
    _extract_postscript,
    _extract_xps,
    _image_reference,
    _issue,
    _local_name,
    _normalise_text,
    _package_path,
    _resolve_executable,
    _safe_output_name,
    _run_tool,
    _validate_input,
    _validate_zip,
    _write_image,
)


_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
    "AAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1WQAAAABJRU5ErkJggg=="
)


def _write_xps(
    path: Path,
    image_name: str = "pixel.png",
    image_bytes: bytes = _PIXEL_PNG,
    include_vector: bool = False,
) -> None:
    sequence = """<?xml version="1.0" encoding="utf-8"?>
<FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06">
  <DocumentReference Source="/Documents/1/FixedDocument.fdoc"/>
</FixedDocumentSequence>
"""
    document = """<?xml version="1.0" encoding="utf-8"?>
<FixedDocument xmlns="http://schemas.microsoft.com/xps/2005/06">
  <PageContent Source="Pages/1.fpage"/>
</FixedDocument>
"""
    vector_markup = (
        '<Path Data="M 10,10 L 90,10 90,90 10,90 Z" Fill="#00A0FF"/>'
        if include_vector
        else ""
    )
    page = f"""<?xml version="1.0" encoding="utf-8"?>
<FixedPage xmlns="http://schemas.microsoft.com/xps/2005/06"
           Width="100" Height="100">
  <Glyphs UnicodeString="Direct XPS text"/>
  <Path>
    <Path.Fill>
      <ImageBrush ImageSource="../Resources/{image_name}"/>
    </Path.Fill>
  </Path>
  {vector_markup}
</FixedPage>
"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("FixedDocSeq.fdseq", sequence)
        archive.writestr("Documents/1/FixedDocument.fdoc", document)
        archive.writestr("Documents/1/Pages/1.fpage", page)
        archive.writestr(f"Documents/1/Resources/{image_name}", image_bytes)


def _fb2_bytes(include_non_image: bool = False) -> bytes:
    extra = (
        '<binary id="payload" content-type="application/octet-stream">'
        'AQID</binary>'
        if include_non_image
        else ""
    )
    encoded = base64.b64encode(_PIXEL_PNG).decode("ascii")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
             xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info><book-title>Sample Book</book-title></title-info></description>
  <body><section><p>Direct FB2 text</p><image l:href="#cover"/></section></body>
  <binary id="cover" content-type="image/png">{encoded}</binary>
  {extra}
</FictionBook>
""".encode("utf-8")


def _write_postscript(path: Path) -> None:
    path.write_text(
        """%!PS-Adobe-3.0
%%Pages: 1
%%BoundingBox: 0 0 300 200
/Helvetica findfont 24 scalefont setfont
30 110 moveto
(PostScript integration text) show
newpath 25 80 moveto 275 80 lineto 275 150 lineto 25 150 lineto closepath stroke
showpage
%%EOF
""",
        encoding="ascii",
    )


def _write_ppm(path: Path) -> None:
    width = 64
    height = 64
    pixels = bytearray([255, 255, 255] * width * height)
    for y in range(20, 44):
        for x in range(10, 54):
            offset = (y * width + x) * 3
            pixels[offset : offset + 3] = b"\x00\x00\x00"
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode("ascii") + pixels)


class TextImageDocumentReaderTests(unittest.TestCase):
    def test_small_helpers_validate_names_references_and_outputs(self) -> None:
        self.assertEqual(_local_name("{namespace}Tag"), "Tag")
        self.assertEqual(_normalise_text(" a\n b  "), "a b")
        self.assertEqual(_issue("x", "y", "warning")["severity"], "warning")
        self.assertEqual(_empty_result("XPS")["detected_format"], "XPS")
        self.assertEqual(_safe_output_name(3, "folder\\picture.PNG", ".bin"), "image_00003.png")
        self.assertEqual(_safe_output_name(1, "no-extension", ".bin"), "image_00001.bin")
        self.assertEqual(_package_path("a/b/page.xml", "../image.png"), "a/image.png")
        self.assertEqual(_package_path("a/page.xml", "/root.png"), "root.png")
        for reference in ("", "../../escape.png"):
            with self.assertRaises(ValueError):
                _package_path("a/page.xml", reference)
        self.assertIsNone(_image_reference("  "))
        self.assertEqual(_image_reference("{ColorConvertedBitmap a.png profile}"), "a.png")
        self.assertIsNone(_image_reference("{Binding Image}"))
        self.assertEqual(_image_reference("plain.png"), "plain.png")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                _write_image(root, b"", "empty.png", 0, None, 0)
            written = _write_image(root, b"data", "x.png", 0, 2, 4)
            self.assertEqual(Path(written["file_path"]).read_bytes(), b"data")
            executable = root / "tool.exe"
            executable.write_bytes(b"tool")
            self.assertEqual(
                _resolve_executable(str(executable), ("missing",), "Tool"),
                str(executable),
            )
            with self.assertRaises(FileNotFoundError):
                _resolve_executable(str(root / "missing"), (), "Tool")

    def test_input_archive_and_process_safety_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                _validate_input(root / "missing.bin")

            archive_path = root / "encrypted.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("item.txt", "item")
            with zipfile.ZipFile(archive_path) as archive:
                info = archive.infolist()[0]
                with patch.object(info, "flag_bits", info.flag_bits | 0x1):
                    with self.assertRaisesRegex(ValueError, "Encrypted"):
                        _validate_zip(archive)

            failed = subprocess.CompletedProcess(["tool"], 2, "stdout", "stderr")
            with patch("subprocess.run", return_value=failed), self.assertRaisesRegex(
                RuntimeError, "stderr"
            ):
                _run_tool(["tool"], "Test tool")

            located = root / "located-tool"
            located.write_bytes(b"tool")
            with patch("shutil.which", side_effect=lambda name: str(located) if name == "second" else None):
                self.assertEqual(
                    _resolve_executable(None, ("first", "second"), "Located tool"),
                    str(located),
                )
            with patch("shutil.which", return_value=None), self.assertRaisesRegex(
                FileNotFoundError, "first, second"
            ):
                _resolve_executable(None, ("first", "second"), "Missing tool")

    def test_xps_extracts_direct_text_and_referenced_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.xps"
            output = root / "output"
            output.mkdir()
            _write_xps(source)

            result = _extract_xps(source, output, "XPS")

            self.assertEqual(result["detected_format"], "XPS")
            self.assertEqual(
                [item["text"] for item in result["text_blocks"]],
                ["Direct XPS text"],
            )
            self.assertEqual(len(result["image_parts"]), 1)
            image_path = Path(result["image_parts"][0]["file_path"])
            self.assertEqual(image_path.read_bytes(), _PIXEL_PNG)
            self.assertEqual(result["image_parts"][0]["page_index"], 0)
            self.assertEqual(result["issues"], [])

    def test_fb2_extracts_text_and_binary_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.fb2"
            output = root / "output"
            output.mkdir()
            source.write_bytes(_fb2_bytes())

            result = _extract_fb2(source, output)

            self.assertEqual(result["detected_format"], "FB2")
            self.assertIn("Sample Book", result["text_blocks"][0]["text"])
            self.assertIn("Direct FB2 text", result["text_blocks"][0]["text"])
            self.assertEqual(len(result["image_parts"]), 1)
            self.assertEqual(
                Path(result["image_parts"][0]["file_path"]).read_bytes(),
                _PIXEL_PNG,
            )
            self.assertEqual(result["issues"], [])

    def test_fb2_zip_uses_the_same_content_model(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.fb2.zip"
            output = root / "output"
            output.mkdir()
            with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("book.fb2", _fb2_bytes())

            result = _extract_fb2_zip(source, output)

            self.assertEqual(result["detected_format"], "FB2_ZIP")
            self.assertEqual(len(result["text_blocks"]), 1)
            self.assertEqual(len(result["image_parts"]), 1)

    def test_fb2_reports_binary_content_outside_the_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.fb2"
            output = root / "output"
            output.mkdir()
            source.write_bytes(_fb2_bytes(include_non_image=True))

            result = _extract_fb2(source, output)

            self.assertEqual(len(result["image_parts"]), 1)
            self.assertEqual(len(result["issues"]), 1)
            self.assertEqual(
                result["issues"][0]["stage"],
                "fb2_non_image_binary",
            )
            self.assertEqual(result["issues"][0]["severity"], "error")

    def test_xps_jpeg_xr_uses_the_configured_decoder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.oxps"
            output = root / "output"
            output.mkdir()
            _write_xps(source, image_name="pixel.wdp", image_bytes=b"JXR")

            def fake_run(command: list[str], description: str):
                source_path = Path(command[command.index("-i") + 1])
                output_path = Path(command[command.index("-o") + 1])
                shutil.copyfile(source_path, output_path)
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch(
                "services.text_image_document.text_image_document_reader._run_tool",
                side_effect=fake_run,
            ):
                result = _extract_xps(
                    source,
                    output,
                    "OXPS",
                    sys.executable,
                )

            self.assertEqual(result["detected_format"], "OXPS")
            self.assertEqual(len(result["image_parts"]), 1)
            self.assertEqual(
                Path(result["image_parts"][0]["file_path"]).suffix,
                ".tif",
            )

    def test_xps_vector_page_uses_the_configured_renderer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "vector.xps"
            output = root / "output"
            output.mkdir()
            _write_xps(source, include_vector=True)

            def fake_run(command: list[str], description: str):
                output_argument = next(
                    item for item in command if item.startswith("-sOutputFile=")
                )
                output_value = output_argument.split("=", 1)[1]
                Path(output_value.replace("%05d", "00001")).write_bytes(
                    b"P6\n1 1\n255\n\xff\xff\xff"
                )
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch(
                "services.text_image_document.text_image_document_reader._run_tool",
                side_effect=fake_run,
            ):
                result = _extract_xps(
                    source,
                    output,
                    "XPS",
                    None,
                    sys.executable,
                )

            self.assertEqual(len(result["image_parts"]), 2)
            self.assertEqual(
                result["image_parts"][1]["source_name"],
                "rendered_page_1.ppm",
            )
            self.assertEqual(result["image_parts"][1]["page_index"], 0)

    def test_xps_vector_page_falls_back_to_packaged_pymupdf(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "vector.xps"
            output = root / "output"
            output.mkdir()
            _write_xps(source, include_vector=True)

            class FakePixmap:
                def save(self, path: str) -> None:
                    Path(path).write_bytes(b"P6\n1 1\n255\n\xff\xff\xff")

            class FakePage:
                def get_pixmap(self, *, dpi: int, alpha: bool) -> FakePixmap:
                    self.dpi = dpi
                    self.alpha = alpha
                    return FakePixmap()

            class FakeDocument:
                def __enter__(self):
                    return self

                def __exit__(self, *_args) -> None:
                    return None

                def load_page(self, page_index: int) -> FakePage:
                    self.page_index = page_index
                    return FakePage()

            fake_pymupdf = SimpleNamespace(open=lambda _path: FakeDocument())
            with patch("shutil.which", return_value=None), patch.dict(
                sys.modules,
                {"pymupdf": fake_pymupdf},
            ):
                result = _extract_xps(source, output, "XPS")

            rendered = result["image_parts"][1]
            self.assertEqual(rendered["source_name"], "rendered_page_1.ppm")
            self.assertEqual(rendered["page_index"], 0)
            self.assertTrue(Path(rendered["file_path"]).is_file())

    def test_djvu_tool_boundary_returns_text_and_page_images(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.djvu"
            output = root / "output"
            output.mkdir()
            source.write_bytes(b"AT&TFORM")

            def fake_run(command: list[str], description: str):
                if "page-count" in description:
                    return subprocess.CompletedProcess(command, 0, "2\n", "")
                if "text extraction" in description:
                    page = command[1].split("=")[1]
                    return subprocess.CompletedProcess(
                        command, 0, f"DjVu page {page}", ""
                    )
                Path(command[-1]).write_bytes(b"P6\n1 1\n255\n\xff\xff\xff")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch(
                "services.text_image_document.text_image_document_reader._resolve_executable",
                side_effect=lambda explicit, candidates, description: candidates[0],
            ), patch(
                "services.text_image_document.text_image_document_reader._run_tool",
                side_effect=fake_run,
            ):
                result = _extract_djvu(source, output, None, None, None)

            self.assertEqual(len(result["text_blocks"]), 2)
            self.assertEqual(len(result["image_parts"]), 2)
            self.assertEqual(result["image_parts"][1]["page_index"], 1)

    def test_postscript_tool_boundary_returns_text_and_page_images(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.eps"
            output = root / "output"
            output.mkdir()
            source.write_text("%!PS-Adobe-3.0 EPSF-3.0\nshowpage\n", encoding="ascii")

            def fake_run(command: list[str], description: str):
                output_argument = next(
                    item for item in command if item.startswith("-sOutputFile=")
                )
                output_value = output_argument.split("=", 1)[1]
                if "text extraction" in description:
                    Path(output_value).write_text("PostScript text", encoding="utf-8")
                else:
                    Path(output_value.replace("%05d", "00001")).write_bytes(
                        b"P6\n1 1\n255\n\xff\xff\xff"
                    )
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch(
                "services.text_image_document.text_image_document_reader._resolve_executable",
                return_value="gs",
            ), patch(
                "services.text_image_document.text_image_document_reader._run_tool",
                side_effect=fake_run,
            ):
                result = _extract_postscript(
                    source,
                    output,
                    "EPS",
                    None,
                )

            self.assertEqual(result["text_blocks"][0]["text"], "PostScript text")
            self.assertEqual(len(result["image_parts"]), 1)

    def test_installed_ghostscript_extracts_text_and_page_pixels(self) -> None:
        ghostscript = next(
            (
                executable
                for candidate in ("gswin64c.exe", "gswin32c.exe", "gs")
                if (executable := shutil.which(candidate)) is not None
            ),
            None,
        )
        if ghostscript is None:
            self.skipTest("Ghostscript is not available through the process PATH.")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.ps"
            output = root / "output"
            output.mkdir()
            _write_postscript(source)

            result = _extract_postscript(source, output, "PS", None)

            self.assertIn(
                "PostScript integration text",
                "\n".join(block["text"] for block in result["text_blocks"]),
            )
            self.assertEqual(len(result["image_parts"]), 1)
            self.assertTrue(Path(result["image_parts"][0]["file_path"]).is_file())

    def test_installed_djvulibre_extracts_hidden_text_and_page_pixels(self) -> None:
        tool_names = ("c44.exe", "ddjvu.exe", "djvutxt.exe", "djvused.exe")
        tools = {name: shutil.which(name) for name in tool_names}
        missing = [name for name, executable in tools.items() if executable is None]
        if missing:
            self.skipTest(
                "DjVuLibre tools are not available through the process PATH: "
                + ", ".join(missing)
            )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_image = root / "page.ppm"
            source = root / "sample.djvu"
            hidden_text = root / "hidden_text.dsed"
            output = root / "output"
            output.mkdir()
            _write_ppm(source_image)
            hidden_text.write_text(
                """(page 0 0 64 64
  (line 0 0 64 64
    (word 0 0 64 64 "DjVu integration text")))
""",
                encoding="utf-8",
            )

            compressed = subprocess.run(
                [tools["c44.exe"], str(source_image), str(source)],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            self.assertEqual(compressed.returncode, 0, compressed.stderr)
            text_script = f"select 1; set-txt {hidden_text.as_posix()}"
            text_added = subprocess.run(
                [tools["djvused.exe"], "-s", str(source), "-e", text_script],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            self.assertEqual(text_added.returncode, 0, text_added.stderr)

            result = _extract_djvu(source, output, None, None, None)

            self.assertIn(
                "DjVu integration text",
                "\n".join(block["text"] for block in result["text_blocks"]),
            )
            self.assertEqual(len(result["image_parts"]), 1)
            self.assertTrue(Path(result["image_parts"][0]["file_path"]).is_file())


if __name__ == "__main__":
    unittest.main()
