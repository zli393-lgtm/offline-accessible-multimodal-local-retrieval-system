"""Extract direct text and visual parts from text-and-image document files."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import mimetypes
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile


_MAX_FILE_BYTES = 512 * 1024 * 1024
_MAX_ZIP_ENTRIES = 10000
_MAX_ZIP_MEMBER_BYTES = 128 * 1024 * 1024
_MAX_ZIP_TOTAL_BYTES = 512 * 1024 * 1024
_IMAGE_EXTENSIONS = {
    ".bmp", ".dib", ".gif", ".jpe", ".jpeg", ".jpg", ".jfif",
    ".hdp", ".jxr", ".pbm", ".pgm", ".png", ".pnm", ".ppm", ".tif",
    ".tiff", ".wdp", ".webp",
}


def _local_name(name: str) -> str:
    return name.rsplit("}", 1)[-1]


def _normalise_text(value: str) -> str:
    return " ".join(value.split())


def _issue(stage: str, message: str, severity: str = "error") -> dict[str, str]:
    return {"stage": stage, "message": message, "severity": severity}


def _empty_result(detected_format: str) -> dict[str, object]:
    return {
        "detected_format": detected_format,
        "text_blocks": [],
        "image_parts": [],
        "issues": [],
    }


def _validate_input(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Document file not found: {path}")
    if path.stat().st_size > _MAX_FILE_BYTES:
        raise ValueError(f"Document exceeds the {_MAX_FILE_BYTES}-byte safety limit.")


def _validate_zip(archive: zipfile.ZipFile) -> None:
    entries = archive.infolist()
    if len(entries) > _MAX_ZIP_ENTRIES:
        raise ValueError("Archive contains too many entries.")

    total_size = 0
    for info in entries:
        if info.flag_bits & 0x1:
            raise ValueError(f"Encrypted archive entry is not supported: {info.filename}")
        if info.file_size > _MAX_ZIP_MEMBER_BYTES:
            raise ValueError(f"Archive entry is too large: {info.filename}")
        total_size += info.file_size
        if total_size > _MAX_ZIP_TOTAL_BYTES:
            raise ValueError("Archive expands beyond the configured safety limit.")


def _read_zip_member(archive: zipfile.ZipFile, name: str) -> bytes:
    info = archive.getinfo(name)
    if info.file_size > _MAX_ZIP_MEMBER_BYTES:
        raise ValueError(f"Archive entry is too large: {name}")
    data = archive.read(info)
    if len(data) != info.file_size:
        raise ValueError(f"Archive entry length changed while reading: {name}")
    return data


def _safe_output_name(index: int, source_name: str, fallback: str) -> str:
    suffix = PurePosixPath(source_name.replace("\\", "/")).suffix.lower()
    if not suffix or len(suffix) > 10:
        suffix = fallback
    return f"image_{index:05d}{suffix}"


def _write_image(
    output_directory: Path,
    data: bytes,
    source_name: str,
    index: int,
    page_index: int | None,
    source_order: int,
    fallback_extension: str = ".bin",
) -> dict[str, object]:
    if not data:
        raise ValueError(f"Embedded image is empty: {source_name}")
    output_name = _safe_output_name(index, source_name, fallback_extension)
    output_path = output_directory / output_name
    output_path.write_bytes(data)
    return {
        "file_path": str(output_path.resolve()),
        "source_name": source_name,
        "page_index": page_index,
        "source_order": source_order,
    }


def _package_path(current_part: str, reference: str) -> str:
    reference = unquote(urlsplit(reference).path)
    if not reference:
        raise ValueError("Package reference is empty.")
    if reference.startswith("/"):
        candidate = posixpath.normpath(reference.lstrip("/"))
    else:
        candidate = posixpath.normpath(
            posixpath.join(posixpath.dirname(current_part), reference)
        )
    if candidate == ".." or candidate.startswith("../") or candidate.startswith("/"):
        raise ValueError(f"Unsafe package reference: {reference}")
    return candidate


def _image_reference(raw_value: str) -> str | None:
    value = raw_value.strip()
    if not value:
        return None
    if value.startswith("{ColorConvertedBitmap"):
        tokens = value.strip("{}").split()
        return tokens[1] if len(tokens) >= 2 else None
    if value.startswith("{"):
        return None
    return value


def _page_has_vector_visual(page_root: ET.Element) -> bool:
    for element in page_root.iter():
        element_name = _local_name(element.tag)
        if element_name == "VisualBrush":
            return True
        if element_name != "Path":
            continue
        descendant_names = {_local_name(item.tag) for item in element.iter()}
        has_image_brush = "ImageBrush" in descendant_names
        has_non_image_paint = any(
            name in descendant_names
            for name in {
                "LinearGradientBrush",
                "RadialGradientBrush",
                "SolidColorBrush",
            }
        )
        if (
            not has_image_brush
            or has_non_image_paint
            or "Stroke" in element.attrib
        ):
            return True
    return False


def _ordered_xps_pages(
    archive: zipfile.ZipFile,
    names_by_lower: dict[str, str],
) -> list[str]:
    ordered: list[str] = []
    sequence_names = sorted(
        name for name in archive.namelist() if name.lower().endswith(".fdseq")
    )
    for sequence_name in sequence_names:
        sequence = ET.fromstring(_read_zip_member(archive, sequence_name))
        for element in sequence.iter():
            if _local_name(element.tag) != "DocumentReference":
                continue
            source = element.attrib.get("Source")
            if not source:
                continue
            document_path = _package_path(sequence_name, source)
            actual_document = names_by_lower.get(document_path.lower())
            if actual_document is None:
                continue
            document = ET.fromstring(
                _read_zip_member(archive, actual_document)
            )
            for page in document.iter():
                if _local_name(page.tag) != "PageContent":
                    continue
                page_source = page.attrib.get("Source")
                if not page_source:
                    continue
                page_path = _package_path(actual_document, page_source)
                actual_page = names_by_lower.get(page_path.lower())
                if actual_page is not None and actual_page not in ordered:
                    ordered.append(actual_page)

    if ordered:
        return ordered
    return sorted(
        name for name in archive.namelist() if name.lower().endswith(".fpage")
    )


def _extract_xps(
    file_path: Path,
    output_directory: Path,
    detected_format: str,
    jxr_decoder_executable: str | None = None,
    xps_renderer_executable: str | None = None,
) -> dict[str, object]:
    result = _empty_result(detected_format)
    with zipfile.ZipFile(file_path) as archive:
        _validate_zip(archive)
        names_by_lower = {name.lower(): name for name in archive.namelist()}
        pages = _ordered_xps_pages(archive, names_by_lower)
        if not pages:
            raise ValueError("XPS package does not contain a FixedPage.")

        image_index = 0
        source_order = 0
        vector_page_indices: list[int] = []
        for page_index, page_name in enumerate(pages):
            page_root = ET.fromstring(_read_zip_member(archive, page_name))
            if _local_name(page_root.tag) != "FixedPage":
                raise ValueError(f"Invalid FixedPage root: {page_name}")
            if _page_has_vector_visual(page_root):
                vector_page_indices.append(page_index)

            for element in page_root.iter():
                if _local_name(element.tag) == "Glyphs":
                    text = _normalise_text(element.attrib.get("UnicodeString", ""))
                    if text:
                        result["text_blocks"].append(
                            {
                                "text": text,
                                "page_index": page_index,
                                "source_order": source_order,
                            }
                        )
                        source_order += 1

                references: list[str] = []
                for attribute, value in element.attrib.items():
                    local_attribute = _local_name(attribute)
                    if local_attribute == "ImageSource":
                        reference = _image_reference(value)
                        if reference:
                            references.append(reference)
                    elif (
                        _local_name(element.tag) == "Image"
                        and local_attribute == "Source"
                    ):
                        reference = _image_reference(value)
                        if reference:
                            references.append(reference)

                for reference in references:
                    try:
                        package_name = _package_path(page_name, reference)
                    except ValueError as error:
                        result["issues"].append(
                            _issue("xps_image_reference", str(error))
                        )
                        continue
                    actual_name = names_by_lower.get(package_name.lower())
                    if actual_name is None:
                        result["issues"].append(
                            _issue(
                                "xps_image_reference",
                                f"Referenced image part is missing: {package_name}",
                            )
                        )
                        continue
                    if PurePosixPath(actual_name).suffix.lower() not in _IMAGE_EXTENSIONS:
                        result["issues"].append(
                            _issue(
                                "xps_image_format",
                                f"Referenced visual part has an unsupported image "
                                f"extension: {actual_name}",
                            )
                        )
                        continue

                    data = _read_zip_member(archive, actual_name)
                    image_extension = PurePosixPath(actual_name).suffix.lower()
                    image_part = _write_image(
                        output_directory,
                        data,
                        actual_name,
                        image_index,
                        page_index,
                        source_order,
                        image_extension or ".bin",
                    )
                    if image_extension in {".hdp", ".jxr", ".wdp"}:
                        decoder = _resolve_executable(
                            jxr_decoder_executable,
                            ("JxrDecApp.exe", "JxrDecApp"),
                            "JPEG XR JxrDecApp",
                        )
                        decoded_path = output_directory / f"image_{image_index:05d}.tif"
                        _run_tool(
                            [
                                decoder,
                                "-i",
                                str(image_part["file_path"]),
                                "-o",
                                str(decoded_path),
                            ],
                            f"JPEG XR decoding for {actual_name}",
                        )
                        image_part["file_path"] = str(decoded_path.resolve())
                    result["image_parts"].append(image_part)
                    image_index += 1
                    source_order += 1

    if vector_page_indices:
        renderer = None
        if xps_renderer_executable:
            renderer = _resolve_executable(
                xps_renderer_executable,
                ("gxpswin64c.exe", "gxpswin64.exe", "gxps"),
                "GhostXPS",
            )
        else:
            renderer = next(
                (
                    located
                    for name in ("gxpswin64c.exe", "gxpswin64.exe", "gxps")
                    if (located := shutil.which(name)) is not None
                ),
                None,
            )
        if renderer is None:
            try:
                import pymupdf
            except ImportError:
                import fitz as pymupdf

            with pymupdf.open(str(file_path)) as document:
                for page_index in vector_page_indices:
                    rendered_path = (
                        output_directory / f"rendered_page_{page_index + 1:05d}.ppm"
                    )
                    page = document.load_page(page_index)
                    page.get_pixmap(dpi=150, alpha=False).save(str(rendered_path))
                    result["image_parts"].append(
                        {
                            "file_path": str(rendered_path.resolve()),
                            "source_name": f"rendered_page_{page_index + 1}.ppm",
                            "page_index": page_index,
                            "source_order": source_order,
                        }
                    )
                    source_order += 1
            return result
        output_pattern = output_directory / "rendered_page_%05d.ppm"
        _run_tool(
            [
                renderer,
                "-dSAFER",
                "-dBATCH",
                "-dNOPAUSE",
                "-dQUIET",
                "-sDEVICE=ppmraw",
                "-r150",
                f"-sOutputFile={output_pattern}",
                str(file_path),
            ],
            "XPS vector-page rendering",
        )
        for page_index in vector_page_indices:
            rendered_path = (
                output_directory / f"rendered_page_{page_index + 1:05d}.ppm"
            )
            if not rendered_path.is_file():
                raise RuntimeError(
                    f"GhostXPS did not render XPS page {page_index + 1}."
                )
            result["image_parts"].append(
                {
                    "file_path": str(rendered_path.resolve()),
                    "source_name": f"rendered_page_{page_index + 1}.ppm",
                    "page_index": page_index,
                    "source_order": source_order,
                }
            )
            source_order += 1
    return result


def _collect_xml_text(root: ET.Element) -> str:
    pieces: list[str] = []

    def visit(element: ET.Element) -> None:
        if _local_name(element.tag) == "binary":
            return
        if element.text:
            text = _normalise_text(element.text)
            if text:
                pieces.append(text)
        for child in element:
            visit(child)
            if child.tail:
                tail = _normalise_text(child.tail)
                if tail:
                    pieces.append(tail)

    visit(root)
    return "\n".join(pieces)


def _image_suffix(content_type: str, identifier: str) -> str:
    known = {
        "image/bmp": ".bmp",
        "image/gif": ".gif",
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/tiff": ".tiff",
        "image/webp": ".webp",
    }
    return known.get(
        content_type.lower(),
        mimetypes.guess_extension(content_type.lower())
        or PurePosixPath(identifier).suffix
        or ".bin",
    )


def _extract_fb2_bytes(
    xml_bytes: bytes,
    source_name: str,
    output_directory: Path,
    result: dict[str, object],
    image_index: int,
    source_order: int,
) -> tuple[int, int]:
    root = ET.fromstring(xml_bytes)
    if _local_name(root.tag) != "FictionBook":
        raise ValueError(f"FB2 root element is not FictionBook: {source_name}")

    text = _collect_xml_text(root)
    if text:
        result["text_blocks"].append(
            {
                "text": text,
                "page_index": None,
                "source_order": source_order,
            }
        )
        source_order += 1

    for element in root.iter():
        if _local_name(element.tag) != "binary":
            continue
        identifier = element.attrib.get("id", f"binary_{image_index}")
        content_type = element.attrib.get("content-type", "").lower()
        if not content_type.startswith("image/"):
            result["issues"].append(
                _issue(
                    "fb2_non_image_binary",
                    f"FB2 binary part is not an image: {identifier} "
                    f"({content_type or 'unknown content type'}).",
                )
            )
            continue
        encoded = re.sub(r"\s+", "", "".join(element.itertext()))
        try:
            data = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            result["issues"].append(
                _issue(
                    "fb2_image_decode",
                    f"Cannot decode FB2 image {identifier}: {error}",
                )
            )
            continue

        suffix = _image_suffix(content_type, identifier)
        source_part_name = f"{source_name}#{identifier}"
        result["image_parts"].append(
            _write_image(
                output_directory,
                data,
                source_part_name + suffix
                if not PurePosixPath(identifier).suffix
                else source_part_name,
                image_index,
                None,
                source_order,
                suffix,
            )
        )
        image_index += 1
        source_order += 1
    return image_index, source_order


def _extract_fb2(file_path: Path, output_directory: Path) -> dict[str, object]:
    result = _empty_result("FB2")
    _extract_fb2_bytes(
        file_path.read_bytes(),
        file_path.name,
        output_directory,
        result,
        0,
        0,
    )
    return result


def _extract_fb2_zip(
    file_path: Path,
    output_directory: Path,
) -> dict[str, object]:
    result = _empty_result("FB2_ZIP")
    with zipfile.ZipFile(file_path) as archive:
        _validate_zip(archive)
        fb2_names = sorted(
            name
            for name in archive.namelist()
            if name.lower().endswith(".fb2") and not name.endswith("/")
        )
        if not fb2_names:
            raise ValueError("FB2.ZIP archive does not contain an FB2 document.")
        image_index = 0
        source_order = 0
        for name in fb2_names:
            image_index, source_order = _extract_fb2_bytes(
                _read_zip_member(archive, name),
                name,
                output_directory,
                result,
                image_index,
                source_order,
            )
    return result


def _resolve_executable(
    explicit: str | None,
    candidates: tuple[str, ...],
    description: str,
) -> str:
    if explicit:
        explicit_path = Path(explicit)
        if explicit_path.is_file():
            return str(explicit_path)
        located = shutil.which(explicit)
        if located:
            return located
        raise FileNotFoundError(f"{description} executable not found: {explicit}")

    for candidate in candidates:
        located = shutil.which(candidate)
        if located:
            return located
    raise FileNotFoundError(
        f"{description} executable was not found. Checked: "
        + ", ".join(candidates)
    )


def _run_tool(command: list[str], description: str) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{description} failed: {message}")
    return completed


def _extract_djvu(
    file_path: Path,
    output_directory: Path,
    render_executable: str | None,
    text_executable: str | None,
    script_executable: str | None,
) -> dict[str, object]:
    with file_path.open("rb") as source:
        signature = source.read(8)
    if signature != b"AT&TFORM":
        raise ValueError("File content does not have a DjVu container signature.")

    ddjvu = _resolve_executable(
        render_executable, ("ddjvu.exe", "ddjvu"), "DjVuLibre ddjvu"
    )
    djvutxt = _resolve_executable(
        text_executable, ("djvutxt.exe", "djvutxt"), "DjVuLibre djvutxt"
    )
    djvused = _resolve_executable(
        script_executable, ("djvused.exe", "djvused"), "DjVuLibre djvused"
    )
    count_result = _run_tool(
        [djvused, str(file_path), "-e", "n"], "DjVu page-count extraction"
    )
    match = re.search(r"\d+", count_result.stdout)
    if match is None or int(match.group()) <= 0:
        raise RuntimeError("DjVuLibre did not return a valid page count.")
    page_count = int(match.group())

    result = _empty_result("DJVU")
    source_order = 0
    for page_number in range(1, page_count + 1):
        text_result = _run_tool(
            [djvutxt, f"-page={page_number}", str(file_path)],
            f"DjVu text extraction for page {page_number}",
        )
        text = text_result.stdout.strip()
        if text:
            result["text_blocks"].append(
                {
                    "text": text,
                    "page_index": page_number - 1,
                    "source_order": source_order,
                }
            )
            source_order += 1

        output_path = output_directory / f"page_{page_number:05d}.ppm"
        _run_tool(
            [
                ddjvu,
                "-format=ppm",
                f"-page={page_number}",
                str(file_path),
                str(output_path),
            ],
            f"DjVu rendering for page {page_number}",
        )
        result["image_parts"].append(
            {
                "file_path": str(output_path.resolve()),
                "source_name": f"page_{page_number}.ppm",
                "page_index": page_number - 1,
                "source_order": source_order,
            }
        )
        source_order += 1
    return result


def _extract_postscript(
    file_path: Path,
    output_directory: Path,
    detected_format: str,
    ghostscript_executable: str | None,
) -> dict[str, object]:
    with file_path.open("rb") as source:
        signature = source.read(2048)
    if b"%!PS" not in signature:
        raise ValueError("File content does not have a PostScript signature.")

    ghostscript = _resolve_executable(
        ghostscript_executable,
        ("gswin64c.exe", "gswin32c.exe", "gs"),
        "Ghostscript",
    )
    result = _empty_result(detected_format)
    text_path = output_directory / "direct_text.txt"
    common = ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET"]
    crop = ["-dEPSCrop"] if detected_format == "EPS" else []

    _run_tool(
        [
            ghostscript,
            *common,
            *crop,
            "-sDEVICE=txtwrite",
            f"-sOutputFile={text_path}",
            str(file_path),
        ],
        "PostScript text extraction",
    )
    text = text_path.read_text(encoding="utf-8", errors="replace").strip()
    if text:
        result["text_blocks"].append(
            {"text": text, "page_index": None, "source_order": 0}
        )

    output_pattern = output_directory / "page_%05d.ppm"
    _run_tool(
        [
            ghostscript,
            *common,
            *crop,
            "-sDEVICE=ppmraw",
            "-r150",
            f"-sOutputFile={output_pattern}",
            str(file_path),
        ],
        "PostScript page rendering",
    )
    source_order = 1 if text else 0
    for page_index, image_path in enumerate(
        sorted(output_directory.glob("page_*.ppm"))
    ):
        result["image_parts"].append(
            {
                "file_path": str(image_path.resolve()),
                "source_name": image_path.name,
                "page_index": page_index,
                "source_order": source_order,
            }
        )
        source_order += 1
    if not result["image_parts"]:
        raise RuntimeError("Ghostscript did not render any PostScript page.")
    return result


def extract_document(arguments: argparse.Namespace) -> dict[str, object]:
    file_path = Path(arguments.input)
    output_directory = Path(arguments.output_directory)
    _validate_input(file_path)
    output_directory.mkdir(parents=True, exist_ok=True)

    lower_name = file_path.name.lower()
    if lower_name.endswith(".fb2.zip"):
        return _extract_fb2_zip(file_path, output_directory)
    suffix = file_path.suffix.lower()
    if suffix == ".xps":
        return _extract_xps(
            file_path,
            output_directory,
            "XPS",
            arguments.jxr_decoder_executable,
            arguments.xps_renderer_executable,
        )
    if suffix == ".oxps":
        return _extract_xps(
            file_path,
            output_directory,
            "OXPS",
            arguments.jxr_decoder_executable,
            arguments.xps_renderer_executable,
        )
    if suffix == ".fb2":
        return _extract_fb2(file_path, output_directory)
    if suffix in {".djvu", ".djv"}:
        return _extract_djvu(
            file_path,
            output_directory,
            arguments.djvu_render_executable,
            arguments.djvu_text_executable,
            arguments.djvu_script_executable,
        )
    if suffix in {".ps", ".eps"}:
        return _extract_postscript(
            file_path,
            output_directory,
            "EPS" if suffix == ".eps" else "PS",
            arguments.ghostscript_executable,
        )
    raise ValueError(f"Unsupported text-and-image document extension: {suffix}")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("--input", required=True)
    extract_parser.add_argument("--output-directory", required=True)
    extract_parser.add_argument("--djvu-render-executable")
    extract_parser.add_argument("--djvu-text-executable")
    extract_parser.add_argument("--djvu-script-executable")
    extract_parser.add_argument("--ghostscript-executable")
    extract_parser.add_argument("--jxr-decoder-executable")
    extract_parser.add_argument("--xps-renderer-executable")
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        payload = extract_document(arguments)
    except Exception as error:
        print(
            json.dumps(
                {"error": str(error), "error_type": type(error).__name__},
                ensure_ascii=True,
            )
        )
        return 1

    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
