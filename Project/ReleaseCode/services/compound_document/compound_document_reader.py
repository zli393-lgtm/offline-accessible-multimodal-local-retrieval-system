"""Extract the base information channels from compound document files.

Direct text and structured source data remain text.  Embedded bitmaps and
rendered page/chart/vector pixels are exported for the separate image service.
Embedded sampled audio is exported for the separate audio service.  Video and
embedded general archives are deliberately ignored.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from io import BytesIO
from email import policy
from email.parser import BytesParser
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any
from urllib.parse import unquote, urlparse
from posixpath import dirname as posix_dirname, join as posix_join, normpath as posix_normpath
import zipfile


IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".bmp", ".dib",
    ".tif", ".tiff", ".webp", ".gif", ".pbm", ".pgm", ".ppm",
    ".pnm", ".svg", ".svgz", ".jxr", ".wdp", ".hdp",
}
AUDIO_EXTENSIONS = {
    ".wav", ".wave", ".mp3", ".flac", ".m4a", ".aac", ".ogg",
    ".oga", ".opus", ".wma", ".aiff", ".aif", ".aifc", ".au",
    ".snd", ".amr", ".ac3", ".eac3", ".ape", ".wv",
}
VIDEO_EXTENSIONS = {
    ".mp4", ".m4v", ".mov", ".avi", ".mkv", ".webm", ".wmv",
    ".mpeg", ".mpg", ".3gp",
}
ARCHIVE_EXTENSIONS = {
    ".zip", ".rar", ".7z", ".tar", ".gz", ".tgz", ".bz2", ".xz",
}
PACKAGE_EXTENSIONS = {
    ".docx", ".docm", ".dotx", ".pptx", ".pptm", ".ppsx",
    ".xlsx", ".xlsm", ".odt", ".ods", ".odp", ".epub", ".pages",
    ".key", ".numbers",
}
MUPDF_EXTENSIONS = {".pdf", ".xps", ".oxps", ".epub", ".fb2"}
FORMAT_LABELS = {
    ".pdf": "PDF", ".doc": "DOC", ".docx": "DOCX", ".docm": "DOCM",
    ".dot": "DOT", ".dotx": "DOTX", ".ppt": "PPT", ".pptx": "PPTX",
    ".pptm": "PPTM", ".pps": "PPS", ".ppsx": "PPSX", ".xls": "XLS",
    ".xlsx": "XLSX", ".xlsm": "XLSM", ".xlsb": "XLSB", ".odt": "ODT",
    ".ods": "ODS", ".odp": "ODP", ".rtf": "RTF", ".md": "MD",
    ".mdx": "MDX", ".html": "HTML", ".htm": "HTML", ".xhtml": "XHTML",
    ".mhtml": "MHTML", ".mht": "MHTML", ".epub": "EPUB", ".fb2": "FB2",
    ".xps": "XPS", ".oxps": "OXPS", ".djvu": "DJVU", ".djv": "DJVU",
    ".ps": "PS", ".eps": "EPS", ".chm": "CHM", ".eml": "EML",
    ".msg": "MSG", ".pages": "PAGES", ".key": "KEY", ".numbers": "NUMBERS",
}


def _sanitize_svg(svg_text: str) -> str:
    from lxml import etree

    upper = svg_text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise ValueError("SVG entity and document-type declarations are rejected.")
    parser = etree.XMLParser(resolve_entities=False, no_network=True, recover=False)
    root = etree.fromstring(svg_text.encode("utf-8"), parser)
    for element in list(root.iter()):
        local = etree.QName(element).localname
        if local in {"script", "foreignObject"}:
            parent = element.getparent()
            if parent is not None:
                parent.remove(element)
            continue
        for key, value in list(element.attrib.items()):
            name = etree.QName(key).localname.lower()
            lower_value = value.strip().lower()
            if name.startswith("on"):
                del element.attrib[key]
            elif name == "href" and not (
                lower_value.startswith("#") or lower_value.startswith("data:image/")
            ):
                del element.attrib[key]
            elif name == "style" and "url(" in lower_value and "url(#" not in lower_value:
                del element.attrib[key]
    return etree.tostring(root, encoding="unicode")


class Extraction:
    def __init__(self, source: Path, output: Path) -> None:
        self.source = source
        self.output = output
        self.output.mkdir(parents=True, exist_ok=True)
        self.text_blocks: list[dict[str, object]] = []
        self.image_parts: list[dict[str, object]] = []
        self.audio_parts: list[dict[str, object]] = []
        self.issues: list[dict[str, str]] = []
        self.order = 0
        self._asset_hashes: set[str] = set()

    def text(
        self,
        value: str,
        *,
        kind: str = "plain_text",
        page_index: int | None = None,
        location: str | None = None,
    ) -> None:
        value = value.strip()
        if not value:
            return
        self.text_blocks.append(
            {
                "kind": kind,
                "text": value,
                "page_index": page_index,
                "source_order": self.order,
                "logical_location": location,
            }
        )
        self.order += 1

    def issue(self, stage: str, message: str, severity: str = "warning") -> None:
        self.issues.append(
            {"stage": stage, "message": message, "severity": severity}
        )

    def asset(
        self,
        data: bytes,
        source_name: str,
        *,
        page_index: int | None = None,
        location: str | None = None,
        image_kind: str = "embedded_image",
        media_type: str | None = None,
    ) -> None:
        suffix = Path(source_name).suffix.lower()
        if suffix in {".svg", ".svgz"} and media_type in (None, "image"):
            try:
                import gzip
                import resvg_py

                svg_bytes = gzip.decompress(data) if suffix == ".svgz" else data
                svg_text = svg_bytes.decode("utf-8", errors="replace")
                self.text(
                    svg_text,
                    kind="vector_data",
                    page_index=page_index,
                    location=location or source_name,
                )
                safe_svg = _sanitize_svg(svg_text)
                data = resvg_py.svg_to_bytes(
                    svg_string=safe_svg,
                    background="#ffffff",
                )
                source_name = f"{Path(source_name).stem}.png"
                suffix = ".png"
                image_kind = "rendered_vector"
                media_type = "image"
            except Exception as error:
                self.issue("embedded_vector_render", f"{source_name}: {error}", "error")
                return
        elif suffix in {".jxr", ".wdp", ".hdp"} and media_type in (None, "image"):
            try:
                import imagecodecs
                from PIL import Image

                decoded = imagecodecs.jpegxr_decode(data)
                encoded = BytesIO()
                Image.fromarray(decoded).save(encoded, format="PNG")
                data = encoded.getvalue()
                source_name = f"{Path(source_name).stem}.png"
                suffix = ".png"
                media_type = "image"
            except Exception as error:
                self.issue("jpeg_xr_decode", f"{source_name}: {error}", "error")
                return
        if media_type is None:
            if suffix in IMAGE_EXTENSIONS:
                media_type = "image"
            elif suffix in AUDIO_EXTENSIONS:
                media_type = "audio"
            elif suffix in VIDEO_EXTENSIONS or suffix in ARCHIVE_EXTENSIONS:
                return
            else:
                return
        digest = hashlib.sha256(data).hexdigest()
        # Preserve repeated placements of the same asset.  De-duplicate only
        # an identical extraction of the same logical source relationship.
        identity = f"{media_type}:{digest}:{page_index}:{location}:{source_name}"
        if identity in self._asset_hashes:
            return
        self._asset_hashes.add(identity)
        safe_stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", Path(source_name).stem)[:60]
        safe_suffix = suffix if suffix and len(suffix) <= 8 else ".bin"
        exported = self.output / f"{self.order:05d}_{safe_stem}_{digest[:10]}{safe_suffix}"
        exported.write_bytes(data)
        item = {
            "file_path": str(exported),
            "source_name": source_name,
            "page_index": page_index,
            "source_order": self.order,
            "logical_location": location,
        }
        if media_type == "image":
            item["kind"] = image_kind
            self.image_parts.append(item)
        elif media_type == "audio":
            self.audio_parts.append(item)
        self.order += 1

    def exported_asset(
        self,
        path: Path,
        source_name: str,
        *,
        page_index: int | None = None,
        location: str | None = None,
        image_kind: str = "embedded_image",
    ) -> None:
        suffix = path.suffix.lower()
        media_type = "image" if suffix in IMAGE_EXTENSIONS else "audio" if suffix in AUDIO_EXTENSIONS else None
        if media_type:
            self.asset(
                path.read_bytes(),
                source_name,
                page_index=page_index,
                location=location,
                image_kind=image_kind,
                media_type=media_type,
            )


def _format_label(path: Path) -> str:
    lower_name = path.name.lower()
    if lower_name.endswith(".fb2.zip"):
        return "FB2_ZIP"
    return FORMAT_LABELS.get(path.suffix.lower(), path.suffix.lstrip(".").upper())


def _json_safe_vector(value: Any) -> Any:
    """Convert PyMuPDF geometry objects into deterministic JSON values."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, dict):
        return {str(key): _json_safe_vector(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe_vector(item) for item in value]
    if all(hasattr(value, field) for field in ("x0", "y0", "x1", "y1")):
        return {
            "x0": float(value.x0),
            "y0": float(value.y0),
            "x1": float(value.x1),
            "y1": float(value.y1),
        }
    if all(hasattr(value, field) for field in ("x", "y")):
        return {"x": float(value.x), "y": float(value.y)}
    return str(value)


def _render_chart(extraction: Extraction, values: list[float], name: str, text: str) -> None:
    if not values:
        return
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    path = extraction.output / f"chart_{extraction.order:05d}.png"
    figure, axis = plt.subplots(figsize=(8, 4.5), dpi=120)
    axis.plot(range(1, len(values) + 1), values, marker="o")
    axis.set_title(Path(name).stem)
    axis.grid(True, alpha=0.25)
    figure.tight_layout()
    figure.savefig(path)
    plt.close(figure)
    extraction.text(text, kind="chart_data", location=name)
    extraction.asset(
        path.read_bytes(),
        path.name,
        location=name,
        image_kind="rendered_chart",
        media_type="image",
    )
    path.unlink(missing_ok=True)


def _relationship_source(rels_name: str) -> str | None:
    if rels_name == "_rels/.rels":
        return ""
    marker = "/_rels/"
    if marker not in rels_name or not rels_name.endswith(".rels"):
        return None
    prefix, leaf = rels_name.split(marker, 1)
    return f"{prefix}/{leaf[:-5]}"


def _package_relationships(package: zipfile.ZipFile) -> dict[str, list[str]]:
    from lxml import etree

    reverse: dict[str, list[str]] = {}
    for info in package.infolist():
        source = _relationship_source(info.filename)
        if source is None or info.file_size > 8 * 1024 * 1024:
            continue
        try:
            root = etree.fromstring(package.read(info))
        except Exception:
            continue
        for relationship in root.xpath("//*[local-name()='Relationship']"):
            if str(relationship.get("TargetMode", "")).lower() == "external":
                continue
            target = relationship.get("Target")
            if not target:
                continue
            resolved = posix_normpath(
                posix_join(posix_dirname(source), unquote(target))
            ).lstrip("/")
            reverse.setdefault(resolved, []).append(source)
    return reverse


def _media_origins(
    media_name: str,
    reverse: dict[str, list[str]],
) -> list[tuple[int | None, str]]:
    queue = [(media_name, 0)]
    visited = {media_name}
    origins: list[tuple[int | None, str]] = []
    while queue:
        current, depth = queue.pop(0)
        for source in reverse.get(current, []):
            if source in visited:
                continue
            visited.add(source)
            slide = re.fullmatch(r"ppt/slides/slide(\d+)\.xml", source)
            sheet = re.fullmatch(r"xl/worksheets/sheet(\d+)\.xml", source)
            if slide:
                number = int(slide.group(1))
                origins.append((number - 1, f"slide:{number}/{media_name}"))
            elif sheet:
                number = int(sheet.group(1))
                origins.append((None, f"sheet:{number}/{media_name}"))
            elif source.startswith("word/") and source.endswith(".xml"):
                origins.append((None, f"{source}/{media_name}"))
            elif depth < 6:
                queue.append((source, depth + 1))
    return origins or [(None, media_name)]


def _extract_package_text(extraction: Extraction, package: zipfile.ZipFile) -> None:
    from lxml import etree

    for info in package.infolist():
        name = info.filename
        lower = name.lower()
        if info.file_size > 32 * 1024 * 1024 or not lower.endswith(".xml"):
            continue
        page_index: int | None = None
        wanted = False
        if re.fullmatch(r"ppt/slides/slide\d+\.xml", lower):
            page_index = int(re.search(r"(\d+)", Path(lower).stem).group(1)) - 1
            wanted = True
        elif lower in {"word/document.xml", "content.xml"} or re.fullmatch(
            r"word/(?:header|footer|footnotes|endnotes|comments)\d*\.xml", lower
        ):
            wanted = True
        if not wanted:
            continue
        try:
            root = etree.fromstring(package.read(info))
            tokens = [
                str(value).strip()
                for value in root.xpath(
                    "//*[local-name()='t' or local-name()='p' or local-name()='span']/text()"
                )
                if str(value).strip()
            ]
            extraction.text(
                "\n".join(tokens),
                page_index=page_index,
                location=name,
            )
        except Exception as error:
            extraction.issue("package_text", f"{name}: {error}")


def _extract_odf_structured_data(
    extraction: Extraction,
    package: zipfile.ZipFile,
    info: zipfile.ZipInfo,
) -> bool:
    """Keep ODF table/chart source values and render chart pixels when present."""
    from lxml import etree

    try:
        root = etree.fromstring(package.read(info))
    except Exception:
        return False
    charts = root.xpath("//*[local-name()='chart']")
    rows: list[str] = []
    numbers: list[float] = []
    for row in root.xpath("//*[local-name()='table-row']"):
        values: list[str] = []
        for cell in row.xpath("./*[local-name()='table-cell']"):
            attributes = {
                etree.QName(key).localname: str(value)
                for key, value in cell.attrib.items()
            }
            value = next(
                (
                    attributes[key]
                    for key in (
                        "value",
                        "date-value",
                        "time-value",
                        "boolean-value",
                        "string-value",
                    )
                    if key in attributes
                ),
                "",
            )
            text = " ".join(
                str(item).strip()
                for item in cell.xpath(".//*[local-name()='p']/text()")
                if str(item).strip()
            )
            display = text or value
            values.append(display)
            if "value" in attributes:
                try:
                    numbers.append(float(attributes["value"]))
                except ValueError:
                    pass
        if any(values):
            rows.append("\t".join(values))
    table_text = "\n".join(rows)
    if table_text:
        extraction.text(table_text, kind="table", location=info.filename)
    if charts:
        chart_source = table_text or "\n".join(
            etree.tostring(chart, encoding="unicode") for chart in charts
        )
        _render_chart(
            extraction,
            numbers,
            info.filename,
            chart_source,
        )
    return bool(table_text or charts)


def _extract_package(extraction: Extraction) -> None:
    try:
        package = zipfile.ZipFile(extraction.source)
    except (zipfile.BadZipFile, OSError) as error:
        extraction.issue("package", str(error), "error")
        return
    with package:
        entries = package.infolist()
        if len(entries) > 20000:
            extraction.issue("package_limits", "Package has more than 20,000 entries.", "error")
            return
        reverse_relationships = _package_relationships(package)
        _extract_package_text(extraction, package)
        for info in entries:
            if info.is_dir() or info.file_size > 512 * 1024 * 1024:
                continue
            name = info.filename
            suffix = Path(name).suffix.lower()
            if (
                suffix == ".xml"
                and extraction.source.suffix.lower() in {".odt", ".ods", ".odp"}
                and info.file_size <= 32 * 1024 * 1024
            ):
                try:
                    _extract_odf_structured_data(extraction, package, info)
                except Exception as error:
                    extraction.issue("odf_structured_data", f"{name}: {error}")
            if suffix in IMAGE_EXTENSIONS or suffix in AUDIO_EXTENSIONS:
                try:
                    data = package.read(info)
                    for page_index, location in _media_origins(
                        name, reverse_relationships
                    ):
                        extraction.asset(
                            data,
                            name,
                            page_index=page_index,
                            location=location,
                        )
                except Exception as error:
                    extraction.issue("embedded_media", f"{name}: {error}")
            elif "/charts/" in name.lower() and suffix == ".xml" and info.file_size <= 16 * 1024 * 1024:
                try:
                    raw = package.read(info)
                    from lxml import etree

                    root = etree.fromstring(raw)
                    tokens = [
                        str(value).strip()
                        for value in root.xpath("//*[local-name()='v']/text()")
                        if str(value).strip()
                    ]
                    numbers = []
                    for token in tokens:
                        try:
                            numbers.append(float(token))
                        except ValueError:
                            pass
                    source_text = "\n".join(tokens)
                    if source_text:
                        _render_chart(extraction, numbers, name, source_text)
                except Exception as error:
                    extraction.issue("chart_source", f"{name}: {error}")


def _extract_pdf_like(extraction: Extraction) -> bool:
    try:
        import pymupdf as fitz

        document = fitz.open(extraction.source)
    except Exception as error:
        extraction.issue("document_open", str(error), "error")
        return False
    try:
        for page_index, page in enumerate(document):
            text = page.get_text("text", sort=True)
            extraction.text(
                text,
                page_index=page_index,
                location=f"page:{page_index + 1}",
            )
            try:
                drawings = page.get_drawings()
                if drawings:
                    maximum_drawings = 10000
                    serialized = {
                        "page": page_index + 1,
                        "drawings": _json_safe_vector(drawings[:maximum_drawings]),
                        "truncated": len(drawings) > maximum_drawings,
                    }
                    extraction.text(
                        json.dumps(
                            serialized,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        ),
                        kind="vector_data",
                        page_index=page_index,
                        location=f"page:{page_index + 1}/vector-paths",
                    )
                    if len(drawings) > maximum_drawings:
                        extraction.issue(
                            "vector_limits",
                            f"Page {page_index + 1}: vector paths were limited to "
                            f"{maximum_drawings} records.",
                        )
            except Exception as error:
                extraction.issue(
                    "vector_source",
                    f"Page {page_index + 1}: {error}",
                )
            try:
                pixmap = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
                extraction.asset(
                    pixmap.tobytes("png"),
                    f"page_{page_index + 1}.png",
                    page_index=page_index,
                    location=f"page:{page_index + 1}",
                    image_kind="rendered_page",
                    media_type="image",
                )
            except Exception as error:
                extraction.issue("page_render", f"Page {page_index + 1}: {error}", "error")

            seen_xrefs: set[int] = set()
            for image in page.get_images(full=True):
                xref = int(image[0])
                if xref in seen_xrefs:
                    continue
                seen_xrefs.add(xref)
                try:
                    embedded = document.extract_image(xref)
                    extension = embedded.get("ext", "bin")
                    extraction.asset(
                        embedded["image"],
                        f"page_{page_index + 1}_image_{xref}.{extension}",
                        page_index=page_index,
                        location=f"page:{page_index + 1}/image:{xref}",
                    )
                except Exception as error:
                    extraction.issue("embedded_image", f"xref {xref}: {error}")

        for name in document.embfile_names():
            try:
                extraction.asset(document.embfile_get(name), name, location=f"attachment:{name}")
            except Exception as error:
                extraction.issue("attachment", f"{name}: {error}")
    finally:
        document.close()
    return True


def _safe_local_reference(source: Path, reference: str) -> Path | None:
    parsed = urlparse(reference.strip().strip("<>\"'"))
    if parsed.scheme not in ("", "file"):
        return None
    candidate = Path(unquote(parsed.path))
    if not candidate.is_absolute():
        candidate = source.parent / candidate
    try:
        candidate = candidate.resolve()
        base = source.parent.resolve()
        candidate.relative_to(base)
    except (OSError, ValueError):
        return None
    return candidate if candidate.is_file() else None


def _asset_reference(extraction: Extraction, reference: str, location: str) -> None:
    if reference.startswith("data:"):
        try:
            header, payload = reference.split(",", 1)
            media = header[5:].split(";", 1)[0].lower()
            data = base64.b64decode(payload) if ";base64" in header else unquote(payload).encode()
            suffix = {
                "image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
                "image/webp": ".webp", "image/svg+xml": ".svg", "audio/mpeg": ".mp3",
                "audio/wav": ".wav", "audio/ogg": ".ogg",
            }.get(media, ".bin")
            media_type = "image" if media.startswith("image/") else "audio" if media.startswith("audio/") else None
            extraction.asset(data, f"data_uri{suffix}", location=location, media_type=media_type)
        except Exception as error:
            extraction.issue("data_uri", f"{location}: {error}")
        return
    local = _safe_local_reference(extraction.source, reference)
    if local is not None:
        extraction.exported_asset(local, local.name, location=location)


def _extract_html(extraction: Extraction, data: bytes | None = None, location: str | None = None) -> None:
    from bs4 import BeautifulSoup

    raw = data if data is not None else extraction.source.read_bytes()
    soup = BeautifulSoup(raw, "lxml")
    extraction.text(soup.get_text("\n", strip=True), location=location or extraction.source.name)
    for element in soup.find_all(["img", "audio", "source"]):
        reference = element.get("src")
        if reference:
            _asset_reference(extraction, str(reference), location or extraction.source.name)


def _extract_markdown(extraction: Extraction) -> None:
    text = extraction.source.read_text(encoding="utf-8", errors="replace")
    extraction.text(text, location=extraction.source.name)
    patterns = [
        r"!\[[^\]]*\]\(([^)]+)\)",
        r"<(?:img|audio|source)[^>]+src=[\"']([^\"']+)[\"']",
    ]
    for pattern in patterns:
        for reference in re.findall(pattern, text, flags=re.IGNORECASE):
            _asset_reference(extraction, reference.split(maxsplit=1)[0], extraction.source.name)


def _extract_message(extraction: Extraction) -> None:
    message = BytesParser(policy=policy.default).parsebytes(extraction.source.read_bytes())
    for index, part in enumerate(message.walk()):
        if part.is_multipart():
            continue
        content_type = part.get_content_type().lower()
        payload = part.get_payload(decode=True) or b""
        location = part.get("Content-Location") or part.get_filename() or f"part:{index}"
        if content_type == "text/plain":
            extraction.text(payload.decode(part.get_content_charset() or "utf-8", errors="replace"), location=location)
        elif content_type == "text/html":
            _extract_html(extraction, payload, location)
        elif content_type.startswith("image/"):
            suffix = "." + content_type.split("/", 1)[1].replace("jpeg", "jpg")
            extraction.asset(payload, part.get_filename() or f"image_{index}{suffix}", location=location, media_type="image")
        elif content_type.startswith("audio/"):
            subtype = content_type.split("/", 1)[1]
            extraction.asset(payload, part.get_filename() or f"audio_{index}.{subtype}", location=location, media_type="audio")


def _extract_rtf(extraction: Extraction) -> None:
    from striprtf.striprtf import rtf_to_text

    raw = extraction.source.read_text(encoding="latin-1", errors="replace")
    extraction.text(rtf_to_text(raw), location=extraction.source.name)


def _extract_fb2_xml(extraction: Extraction, data: bytes, source_name: str) -> None:
    from lxml import etree

    upper = data.upper()
    if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
        raise ValueError("FB2 entity and document-type declarations are rejected.")
    parser = etree.XMLParser(resolve_entities=False, no_network=True, recover=False)
    root = etree.fromstring(data, parser)
    if etree.QName(root).localname != "FictionBook":
        raise ValueError(f"FB2 root element is not FictionBook: {source_name}")
    pieces: list[str] = []
    for element in root.iter():
        if etree.QName(element).localname == "binary":
            continue
        if element.text and element.text.strip():
            pieces.append(element.text.strip())
        if element.tail and element.tail.strip():
            pieces.append(element.tail.strip())
    extraction.text("\n".join(pieces), location=source_name)

    mime_suffixes = {
        "image/bmp": ".bmp", "image/gif": ".gif", "image/jpeg": ".jpg",
        "image/png": ".png", "image/tiff": ".tiff", "image/webp": ".webp",
        "image/svg+xml": ".svg", "audio/mpeg": ".mp3", "audio/wav": ".wav",
        "audio/ogg": ".ogg", "audio/flac": ".flac", "audio/aac": ".aac",
    }
    for index, element in enumerate(root.iter()):
        if etree.QName(element).localname != "binary":
            continue
        content_type = str(element.get("content-type", "")).lower()
        media_type = "image" if content_type.startswith("image/") else "audio" if content_type.startswith("audio/") else None
        if media_type is None:
            extraction.issue(
                "fb2_binary",
                f"Ignored non-image/non-audio binary in {source_name}: {content_type or 'unknown'}",
            )
            continue
        identifier = str(element.get("id", f"binary_{index}"))
        encoded = re.sub(r"\s+", "", "".join(element.itertext()))
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            extraction.issue("fb2_binary", f"{identifier}: {error}", "error")
            continue
        suffix = Path(identifier).suffix or mime_suffixes.get(content_type, ".bin")
        extraction.asset(
            decoded,
            identifier if Path(identifier).suffix else f"{identifier}{suffix}",
            location=f"{source_name}#{identifier}",
            media_type=media_type,
        )


def _extract_fb2_zip(extraction: Extraction) -> None:
    with zipfile.ZipFile(extraction.source) as archive:
        names = sorted(
            info.filename
            for info in archive.infolist()
            if not info.is_dir() and info.filename.lower().endswith(".fb2")
        )
        if not names:
            raise ValueError("FB2.ZIP does not contain an FB2 document.")
        for name in names:
            info = archive.getinfo(name)
            if info.file_size > 512 * 1024 * 1024:
                raise ValueError(f"FB2 entry is too large: {name}")
            _extract_fb2_xml(extraction, archive.read(info), name)


def _resolve_java(explicit: str | None) -> str | None:
    candidates = [explicit, os.environ.get("JAVA_HOME"), shutil.which("java")]
    for value in candidates:
        if not value:
            continue
        path = Path(value)
        if path.is_dir():
            path = path / "bin" / ("java.exe" if os.name == "nt" else "java")
        if path.is_file():
            return str(path)
    return None


def _resolve_tika_jar(explicit: str | None) -> str | None:
    candidates: list[str | None] = [
        explicit,
        os.environ.get("TIKA_APP_JAR"),
    ]
    tika_home = os.environ.get("TIKA_HOME")
    if tika_home:
        candidates.extend(
            str(path)
            for path in sorted(
                Path(tika_home).glob("tika-app-*.jar"),
                reverse=True,
            )
        )
    tika_command = shutil.which("tika")
    if tika_command:
        command_directory = Path(tika_command).resolve().parent
        candidates.extend(
            str(path)
            for path in sorted(
                command_directory.glob("tika-app-*.jar"),
                reverse=True,
            )
        )
    for value in candidates:
        if value and Path(value).is_file():
            return str(Path(value))
    return None


def _tika_text(extraction: Extraction, java: str | None, tika_jar: str | None) -> None:
    if java is None or tika_jar is None:
        extraction.issue("tika", "Apache Tika or Java was not found.", "error")
        return
    try:
        result = subprocess.run(
            [java, "-jar", tika_jar, "-x", str(extraction.source)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=600,
            check=False,
        )
        if result.returncode != 0:
            extraction.issue("tika_text", result.stderr.strip() or result.stdout.strip(), "error")
        else:
            from bs4 import BeautifulSoup

            document = BeautifulSoup(result.stdout, "xml")
            for index, table in enumerate(document.find_all("table")):
                rows = []
                for row in table.find_all("tr"):
                    cells = [
                        cell.get_text(" ", strip=True)
                        for cell in row.find_all(["th", "td"])
                    ]
                    if cells:
                        rows.append("\t".join(cells))
                extraction.text(
                    "\n".join(rows),
                    kind="table",
                    location=f"{extraction.source.name}/table:{index + 1}",
                )
                table.decompose()
            extraction.text(
                document.get_text("\n", strip=True),
                location=extraction.source.name,
            )
    except Exception as error:
        extraction.issue("tika_text", str(error), "error")


def _tika_embedded(
    extraction: Extraction,
    java: str | None,
    tika_jar: str | None,
    *,
    include_images: bool = True,
) -> None:
    if java is None or tika_jar is None:
        return
    directory = extraction.output / "tika_embedded"
    directory.mkdir(exist_ok=True)
    try:
        result = subprocess.run(
            [
                java, "-jar", tika_jar, "-z",
                f"--extract-dir={directory}",
                str(extraction.source),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=600,
            check=False,
        )
        if result.returncode != 0:
            extraction.issue(
                "tika_embedded",
                result.stderr.strip() or result.stdout.strip(),
                "error",
            )
        for path in directory.rglob("*"):
            if path.is_file():
                if not include_images and path.suffix.lower() in IMAGE_EXTENSIONS:
                    continue
                extraction.exported_asset(path, path.name, location=f"embedded:{path.name}")
    except Exception as error:
        extraction.issue("tika_embedded", str(error), "error")
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def extract_document(
    file_path: str,
    output_directory: str,
    *,
    java_executable: str | None = None,
    tika_jar: str | None = None,
) -> dict[str, object]:
    source = Path(file_path)
    if not source.is_file():
        raise FileNotFoundError(f"Document file not found: {source}")
    extraction = Extraction(source, Path(output_directory))
    suffix = source.suffix.lower()
    lower_name = source.name.lower()
    java = _resolve_java(java_executable)
    jar = _resolve_tika_jar(tika_jar)
    if java is None:
        raise RuntimeError("Java 11 or later is required by Apache Tika.")
    if jar is None:
        raise RuntimeError("The required Apache Tika application JAR was not found.")

    if suffix in MUPDF_EXTENSIONS:
        if suffix == ".fb2":
            _extract_fb2_xml(extraction, source.read_bytes(), source.name)
        _extract_pdf_like(extraction)
        _tika_text(extraction, java, jar)
        _tika_embedded(extraction, java, jar, include_images=False)
        if suffix == ".epub":
            _extract_package(extraction)
    elif lower_name.endswith(".fb2.zip"):
        _extract_fb2_zip(extraction)
    elif suffix in {".html", ".htm", ".xhtml"}:
        _extract_html(extraction)
    elif suffix in {".md", ".mdx"}:
        _extract_markdown(extraction)
    elif suffix in {".mhtml", ".mht", ".eml"}:
        _extract_message(extraction)
    elif suffix == ".rtf":
        _extract_rtf(extraction)
        _tika_embedded(extraction, java, jar)
    elif suffix in PACKAGE_EXTENSIONS:
        _tika_text(extraction, java, jar)
        _extract_package(extraction)
    else:
        _tika_text(extraction, java, jar)
        _tika_embedded(extraction, java, jar)

    return {
        "detected_format": _format_label(source),
        "text_blocks": extraction.text_blocks,
        "image_parts": extraction.image_parts,
        "audio_parts": extraction.audio_parts,
        "issues": extraction.issues,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--java-executable")
    parser.add_argument("--tika-jar")
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        result = extract_document(
            arguments.input,
            arguments.output_directory,
            java_executable=arguments.java_executable,
            tika_jar=arguments.tika_jar,
        )
    except Exception as error:
        print(json.dumps({"error": str(error), "error_type": type(error).__name__}, ensure_ascii=True))
        return 1
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
