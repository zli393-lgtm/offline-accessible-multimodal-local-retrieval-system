from __future__ import annotations

import importlib.util
import math
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import wave


ROOT = Path(__file__).resolve().parents[3]
SERVICE_PATH = ROOT / "ReleaseCode" / "services" / "audio" / "audio_reader.py"
SPEC = importlib.util.spec_from_file_location("audio_reader", SERVICE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load audio service: {SERVICE_PATH}")
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)

CLAP_MODEL_PATH = (
    ROOT.parent / "Dependencies" / "Packageable" / "Models" / "audio" / "clap-htsat-fused"
)


class AudioReaderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _wave(self) -> Path:
        path = self.directory / "tone.wav"
        sample_rate = 16000
        samples = [
            round(math.sin(2 * math.pi * 440 * index / sample_rate) * 10000)
            for index in range(sample_rate)
        ]
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(b"".join(struct.pack("<h", value) for value in samples))
        return path

    def test_inspect_returns_sampled_audio_metadata(self) -> None:
        result = READER.inspect_audio(str(self._wave()))

        self.assertIn("WAV", result["format"])
        self.assertEqual(result["codec"], "pcm_s16le")
        self.assertEqual(result["sample_rate"], 16000)
        self.assertEqual(result["channels"], 1)
        self.assertAlmostEqual(result["duration_ms"], 1000, delta=2)

    def test_decode_mono_returns_requested_sample_rate(self) -> None:
        samples = READER._decode_mono(str(self._wave()), 8000)

        self.assertAlmostEqual(len(samples), 8000, delta=100)
        self.assertGreater(float(abs(samples).max()), 0.1)

    def test_clap_audio_and_text_queries_share_vector_space(self) -> None:
        if not (CLAP_MODEL_PATH / "model.safetensors").is_file():
            self.skipTest(f"CLAP test model is unavailable: {CLAP_MODEL_PATH}")
        audio = READER.analyze_audios(
            [str(self._wave())],
            model_path=str(CLAP_MODEL_PATH),
        )[0]
        text = READER.embed_audio_texts(
            ["a steady tone"],
            model_path=str(CLAP_MODEL_PATH),
        )[0]

        self.assertEqual(audio["dimensions"], 512)
        self.assertEqual(text["dimensions"], 512)
        self.assertAlmostEqual(
            sum(value * value for value in audio["vector"]),
            1.0,
            places=4,
        )
        self.assertAlmostEqual(
            sum(value * value for value in text["vector"]),
            1.0,
            places=4,
        )

    def test_empty_clap_batches_do_not_load_a_model(self) -> None:
        self.assertEqual(READER.analyze_audios([], model_path="missing"), [])
        self.assertEqual(READER.embed_audio_texts([], model_path="missing"), [])

    def test_duration_and_tag_fallbacks(self) -> None:
        stream = mock.Mock(duration=None, time_base=None)
        container = mock.Mock(duration=1000000)
        self.assertEqual(READER._duration_ms(container, stream), 1000)
        self.assertIsNone(READER._duration_ms(mock.Mock(duration=None), stream))

        media = mock.Mock(tags={"artist": ["one", "two"], "year": 2026})
        with mock.patch("mutagen.File", return_value=media):
            self.assertEqual(
                READER._string_tags(self.directory / "tags.mp3"),
                {"artist": "one; two", "year": "2026"},
            )
        with mock.patch("mutagen.File", return_value=None):
            self.assertEqual(READER._string_tags(self.directory / "none.mp3"), {})
        with mock.patch("mutagen.File", side_effect=OSError("bad")):
            self.assertEqual(READER._string_tags(self.directory / "bad.mp3"), {})


if __name__ == "__main__":
    unittest.main()
