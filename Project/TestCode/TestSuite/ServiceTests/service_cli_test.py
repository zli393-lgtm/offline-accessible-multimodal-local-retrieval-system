import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[3]
SERVICES = ROOT / "ReleaseCode" / "services"


def load(name, relative):
    path = SERVICES / relative
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    ("operation", "function_name", "result", "extra"),
    [
        ("inspect", "inspect_audio", {"format": "WAV"}, []),
        (
            "transcribe",
            "transcribe_audio",
            {"text": "hello"},
            ["--model-path", "whisper"],
        ),
        (
            "analyze",
            "analyze_audio",
            {"vector": [1.0]},
            ["--model-path", "clap"],
        ),
    ],
)
def test_audio_cli_single_operations(
    monkeypatch, capsys, operation, function_name, result, extra
):
    module = load(f"audio_cli_{operation}", "audio/audio_reader.py")
    monkeypatch.setattr(module, function_name, lambda *args, **kwargs: result)
    monkeypatch.setattr(
        sys,
        "argv",
        ["audio_reader.py", operation, "--input", "sound.wav", *extra],
    )
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out) == result


def test_audio_cli_batch_operations_and_error(monkeypatch, capsys, tmp_path):
    module = load("audio_cli_batch", "audio/audio_reader.py")
    request = tmp_path / "requests.json"
    request.write_text(json.dumps([{"path": "a.wav"}]), encoding="utf-8")
    monkeypatch.setattr(module, "analyze_audios", lambda *args, **kwargs: [{"ok": 1}])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "audio_reader.py",
            "analyze-batch",
            "--request-json",
            str(request),
            "--model-path",
            "clap",
        ],
    )
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out)["results"] == [{"ok": 1}]

    request.write_text(json.dumps([{"text": "piano"}]), encoding="utf-8")
    monkeypatch.setattr(module, "embed_audio_texts", lambda *args, **kwargs: [[1.0]])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "audio_reader.py",
            "embed-text-batch",
            "--request-json",
            str(request),
            "--model-path",
            "clap",
        ],
    )
    assert module.main() == 0
    capsys.readouterr()

    monkeypatch.setattr(module, "inspect_audio", lambda *_: (_ for _ in ()).throw(ValueError("bad")))
    monkeypatch.setattr(
        sys, "argv", ["audio_reader.py", "inspect", "--input", "bad.wav"]
    )
    assert module.main() == 1
    assert json.loads(capsys.readouterr().out)["error_type"] == "ValueError"


@pytest.mark.parametrize(
    ("operation", "function_name", "extra"),
    [
        ("inspect", "inspect_image", []),
        ("ocr", "extract_ocr", []),
        ("analyze", "analyze_image", ["--model-path", "model"]),
    ],
)
def test_static_image_cli_single_operations(
    monkeypatch, capsys, operation, function_name, extra
):
    module = load(f"image_cli_{operation}", "static_image/static_image_reader.py")
    monkeypatch.setattr(module, function_name, lambda *args, **kwargs: {"ok": operation})
    monkeypatch.setattr(
        sys,
        "argv",
        ["static_image_reader.py", operation, "--input", "image.png", *extra],
    )
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out)["ok"] == operation


def test_static_image_cli_batches_and_error(monkeypatch, capsys, tmp_path):
    module = load("image_cli_batch", "static_image/static_image_reader.py")
    request = tmp_path / "requests.json"
    request.write_text(json.dumps([{"path": "a.png"}]), encoding="utf-8")
    monkeypatch.setattr(module, "analyze_images", lambda *args, **kwargs: [{"ok": 1}])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "static_image_reader.py",
            "analyze-batch",
            "--request-json",
            str(request),
            "--model-path",
            "model",
        ],
    )
    assert module.main() == 0
    capsys.readouterr()

    request.write_text(json.dumps([{"text": "red car"}]), encoding="utf-8")
    monkeypatch.setattr(module, "embed_image_texts", lambda *args, **kwargs: [[1.0]])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "static_image_reader.py",
            "embed-text-batch",
            "--request-json",
            str(request),
            "--model-path",
            "model",
        ],
    )
    assert module.main() == 0
    capsys.readouterr()

    monkeypatch.setattr(module, "inspect_image", lambda *_: (_ for _ in ()).throw(RuntimeError("bad")))
    monkeypatch.setattr(
        sys,
        "argv",
        ["static_image_reader.py", "inspect", "--input", "bad.png"],
    )
    assert module.main() == 1
    assert json.loads(capsys.readouterr().out)["error_type"] == "RuntimeError"


@pytest.mark.parametrize(
    ("name", "relative", "arguments", "target"),
    [
        (
            "compound_cli",
            "compound_document/compound_document_reader.py",
            ["--input", "file.docx", "--output-directory", "out"],
            "extract_document",
        ),
        (
            "structured_cli",
            "structured_visual/structured_visual_reader.py",
            ["--input", "file.svg", "--output-dir", "out"],
            "extract",
        ),
        (
            "text_image_cli",
            "text_image_document/text_image_document_reader.py",
            ["extract", "--input", "file.xps", "--output-directory", "out"],
            "extract_document",
        ),
    ],
)
def test_document_service_clis_success_and_error(
    monkeypatch, capsys, name, relative, arguments, target
):
    module = load(name, relative)
    monkeypatch.setattr(module, target, lambda *args, **kwargs: {"ok": True})
    monkeypatch.setattr(sys, "argv", [Path(relative).name, *arguments])
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True

    monkeypatch.setattr(
        module,
        target,
        lambda *args, **kwargs: (_ for _ in ()).throw(ValueError("bad")),
    )
    assert module.main() == 1
    assert json.loads(capsys.readouterr().out)["error_type"] == "ValueError"


@pytest.mark.parametrize(
    ("suffix", "expected"),
    [
        (".html", "html"),
        (".md", "markdown"),
        (".eml", "message"),
        (".rtf", "rtf"),
        (".docx", "package"),
        (".unknown", "tika"),
    ],
)
def test_compound_dispatches_outer_formats(monkeypatch, tmp_path, suffix, expected):
    module = load(f"compound_dispatch_{suffix[1:]}", "compound_document/compound_document_reader.py")
    source = tmp_path / f"source{suffix}"
    source.write_bytes(b"data")
    calls = []
    for name in [
        "_extract_html",
        "_extract_markdown",
        "_extract_message",
        "_extract_rtf",
        "_extract_package",
        "_tika_text",
        "_tika_embedded",
    ]:
        monkeypatch.setattr(
            module,
            name,
            lambda *args, _name=name, **kwargs: calls.append(_name),
        )
    monkeypatch.setattr(module, "_resolve_java", lambda value: "java")
    monkeypatch.setattr(module, "_resolve_tika_jar", lambda value: "tika-app.jar")

    result = module.extract_document(str(source), str(tmp_path / "out"))
    assert result["detected_format"]
    assert any(expected in call for call in calls)


@pytest.mark.parametrize(
    ("name", "expected_format", "helper"),
    [
        ("book.fb2.zip", "FB2_ZIP", "_extract_fb2_zip"),
        ("page.xps", "XPS", "_extract_xps"),
        ("page.oxps", "OXPS", "_extract_xps"),
        ("book.fb2", "FB2", "_extract_fb2"),
        ("scan.djvu", "DJVU", "_extract_djvu"),
        ("scan.djv", "DJVU", "_extract_djvu"),
        ("print.ps", "PS", "_extract_postscript"),
        ("print.eps", "EPS", "_extract_postscript"),
    ],
)
def test_text_image_dispatches_every_supported_outer_format(
    monkeypatch, tmp_path, name, expected_format, helper
):
    module = load(
        f"text_image_dispatch_{name.replace('.', '_')}",
        "text_image_document/text_image_document_reader.py",
    )
    source = tmp_path / name
    source.write_bytes(b"data")
    payload = {
        "detected_format": expected_format,
        "text_blocks": [],
        "image_parts": [],
        "issues": [],
    }
    monkeypatch.setattr(module, helper, lambda *args, **kwargs: payload)
    arguments = module.argparse.Namespace(
        input=str(source),
        output_directory=str(tmp_path / "out"),
        djvu_render_executable=None,
        djvu_text_executable=None,
        djvu_script_executable=None,
        ghostscript_executable=None,
        jxr_decoder_executable=None,
        xps_renderer_executable=None,
    )
    assert module.extract_document(arguments)["detected_format"] == expected_format


def test_text_image_rejects_unknown_extension(tmp_path):
    module = load(
        "text_image_unknown",
        "text_image_document/text_image_document_reader.py",
    )
    source = tmp_path / "unknown.bin"
    source.write_bytes(b"data")
    arguments = module.argparse.Namespace(
        input=str(source),
        output_directory=str(tmp_path / "out"),
        djvu_render_executable=None,
        djvu_text_executable=None,
        djvu_script_executable=None,
        ghostscript_executable=None,
        jxr_decoder_executable=None,
        xps_renderer_executable=None,
    )
    with pytest.raises(ValueError, match="Unsupported"):
        module.extract_document(arguments)


@pytest.mark.parametrize(
    ("suffix", "helper"),
    [(".xlsx", "_extract_spreadsheet"), (".svg", "_extract_vector")],
)
def test_structured_extract_dispatch(monkeypatch, tmp_path, suffix, helper):
    module = load(
        f"structured_dispatch_{suffix[1:]}",
        "structured_visual/structured_visual_reader.py",
    )
    source = tmp_path / f"source{suffix}"
    source.write_bytes(b"data")
    monkeypatch.setattr(
        module,
        helper,
        lambda *args, **kwargs: {
            "format": suffix[1:].upper(),
            "text_blocks": [],
            "visuals": [],
            "issues": [],
        },
    )
    assert module.extract(str(source), str(tmp_path / "out"))["format"]


def test_structured_extract_rejects_missing_and_unknown_files(tmp_path):
    module = load(
        "structured_dispatch_errors",
        "structured_visual/structured_visual_reader.py",
    )
    with pytest.raises(FileNotFoundError):
        module.extract(str(tmp_path / "missing.svg"), str(tmp_path / "out"))
    unknown = tmp_path / "file.bin"
    unknown.write_bytes(b"data")
    with pytest.raises(ValueError, match="Unsupported"):
        module.extract(str(unknown), str(tmp_path / "out"))


def test_audio_validation_helpers_cover_empty_and_invalid_inputs(tmp_path):
    module = load("audio_validation_helpers", "audio/audio_reader.py")

    class Streams:
        audio = []

    class Container:
        streams = Streams()

    with pytest.raises(ValueError, match="sampled-audio"):
        module._audio_stream(Container())
    assert module.analyze_audios([], model_path="missing") == []
    assert module.embed_audio_texts([], model_path="missing") == []
    with pytest.raises(ValueError, match="must not be empty"):
        module.embed_audio_texts(["  "], model_path="missing")
    invalid = tmp_path / "invalid.json"
    invalid.write_text(json.dumps({"not": "a list"}), encoding="utf-8")
    with pytest.raises(ValueError, match="list of objects"):
        module._read_request_list(str(invalid))


def test_audio_transcription_maps_nonempty_segments(monkeypatch, tmp_path):
    module = load("audio_transcription_mapping", "audio/audio_reader.py")
    source = tmp_path / "audio.wav"
    source.write_bytes(b"audio")
    model_directory = tmp_path / "whisper-medium"
    model_directory.mkdir()

    class WhisperModel:
        def __init__(self, *args, **kwargs):
            pass

        def transcribe(self, *args, **kwargs):
            segments = [
                SimpleNamespace(text="  ", start=0.0, end=0.1, avg_logprob=-1.0),
                SimpleNamespace(
                    text=" hello ", start=0.1, end=0.9, avg_logprob=-0.2
                ),
            ]
            info = SimpleNamespace(language="en", language_probability=0.95)
            return segments, info

    monkeypatch.setitem(
        sys.modules,
        "faster_whisper",
        SimpleNamespace(WhisperModel=WhisperModel),
    )
    result = module.transcribe_audio(
        str(source),
        str(model_directory),
        device="cpu",
        compute_type="int8",
    )
    assert result["text"] == "hello"
    assert result["segments"][0]["start_ms"] == 100
    assert 0 < result["segments"][0]["confidence"] <= 1


def test_compound_resource_resolution_and_no_dependency_fallbacks(
    monkeypatch, tmp_path
):
    module = load(
        "compound_resource_helpers",
        "compound_document/compound_document_reader.py",
    )
    executable = tmp_path / "java"
    executable.write_text("java", encoding="utf-8")
    jar = tmp_path / "tika.jar"
    jar.write_text("jar", encoding="utf-8")
    assert module._resolve_java(str(executable)) == str(executable)
    assert module._resolve_tika_jar(str(jar)) == str(jar)
    monkeypatch.delenv("TIKA_APP_JAR", raising=False)
    monkeypatch.setattr(module.shutil, "which", lambda _name: None)
    assert module._resolve_tika_jar(None) is None

    source = tmp_path / "file.bin"
    source.write_bytes(b"data")
    extraction = module.Extraction(source, tmp_path / "out")
    module._tika_text(extraction, None, None)
    module._tika_embedded(extraction, None, None)
    assert extraction.issues[-1]["stage"] == "tika"

    with pytest.raises(ValueError, match="declarations"):
        module._sanitize_svg('<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>')
    cleaned = module._sanitize_svg(
        '''<svg xmlns="http://www.w3.org/2000/svg" onload="bad()">
        <script>bad()</script><foreignObject/><image href="http://bad"
        style="fill:url(http://bad)"/></svg>'''
    )
    assert "script" not in cleaned
    assert "foreignObject" not in cleaned
    assert "onload" not in cleaned
    assert "http://bad" not in cleaned


def test_structured_svg_safety_dimensions_and_browser_resolution(
    monkeypatch, tmp_path
):
    module = load(
        "structured_svg_helpers",
        "structured_visual/structured_visual_reader.py",
    )
    root = module.ET.fromstring(
        b'''<svg xmlns="http://www.w3.org/2000/svg" width="10cm" height="bad"
        viewBox="0 0 400 200" onload="attack()">
        <script>attack()</script>
        <foreignObject><p>external</p></foreignObject>
        <image href="https://example.invalid/a.png" style="fill:url(http://x)"/>
        <style>@import url(http://x); rect{fill:url(http://x)}</style>
        </svg>'''
    )
    sanitized, changed = module._sanitized_svg(root)
    text = sanitized.decode("utf-8")
    assert changed is True
    assert "script" not in text
    assert "foreignObject" not in text
    assert "onload" not in text
    assert "example.invalid" not in text
    assert "@import" not in text

    assert round(module._svg_dimension("10cm")) == 378
    assert module._svg_dimension(None) is None
    assert module._svg_dimension("invalid") is None
    width, height = module._svg_size(root)
    assert width == 378
    assert height == 200
    default_root = module.ET.fromstring(b"<svg/>")
    assert module._svg_size(default_root) == (1024, 768)
    clamped = module.ET.fromstring(b'<svg width="99999" height="0"/>')
    assert module._svg_size(clamped) == (4096, 768)

    browser = tmp_path / "browser"
    browser.write_text("browser", encoding="utf-8")
    assert module._resolve_browser(str(browser)) == str(browser)
    monkeypatch.setattr(module.shutil, "which", lambda *_: None)
    monkeypatch.delenv("SVG_RENDERER_EXECUTABLE", raising=False)
    monkeypatch.setenv("PROGRAMFILES", str(tmp_path / "program-files"))
    monkeypatch.setenv("PROGRAMFILES(X86)", str(tmp_path / "program-files-x86"))
    with pytest.raises(FileNotFoundError, match="renderer"):
        module._resolve_browser(str(tmp_path / "missing"))


@pytest.mark.parametrize(
    "operation",
    ["image-batch", "image-text-batch", "audio-batch", "audio-text-batch"],
)
def test_embedding_service_routes_every_modality_cli(
    monkeypatch, capsys, tmp_path, operation
):
    module = load(f"embedding_service_{operation}", "embedding/embedding_service.py")
    request = tmp_path / f"{operation}.json"
    request.write_text(
        json.dumps([{"path": "media.dat", "text": "query"}]),
        encoding="utf-8",
    )

    class ImageEngine:
        def __init__(self, *args, **kwargs):
            pass

        def embed_images(self, requests):
            return [{"kind": "image"}]

        def embed_texts(self, texts):
            return [{"kind": "image-text"}]

    class AudioEngine:
        def __init__(self, *args, **kwargs):
            pass

        def embed_audio_files(self, paths, **kwargs):
            return [{"kind": "audio"}]

        def embed_texts(self, texts):
            return [{"kind": "audio-text"}]

    monkeypatch.setattr(module, "MobileClipEmbeddingEngine", ImageEngine)
    monkeypatch.setattr(module, "ClapEmbeddingEngine", AudioEngine)
    arguments = [
        "embedding_service.py",
        operation,
        "--request-json",
        str(request),
        "--model-path",
        "model",
    ]
    monkeypatch.setattr(sys, "argv", arguments)
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out)["results"]


def test_embedding_service_rejects_invalid_request(monkeypatch, capsys, tmp_path):
    module = load("embedding_service_invalid", "embedding/embedding_service.py")
    request = tmp_path / "invalid.json"
    request.write_text(json.dumps({"invalid": True}), encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "embedding_service.py",
            "image-batch",
            "--request-json",
            str(request),
            "--model-path",
            "model",
        ],
    )
    assert module.main() == 1
    assert json.loads(capsys.readouterr().out)["error_type"] == "ValueError"
