from __future__ import annotations

import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from PIL import Image


ROOT = Path(__file__).resolve().parents[3]
APPLICATION = ROOT / "ReleaseCode"
MODELS = ROOT.parent / "Dependencies" / "Packageable" / "Models"
import sys

if str(APPLICATION) not in sys.path:
    sys.path.insert(0, str(APPLICATION))

from services.embedding.clap_engine import ClapEmbeddingEngine
from services.embedding.mobileclip_engine import MobileClipEmbeddingEngine


MOBILECLIP_MODEL = MODELS / "image" / "mobileclip_s0.pt"
CLAP_MODEL = (
    MODELS / "audio" / "clap-htsat-fused"
)


class EmbeddingEngineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not MOBILECLIP_MODEL.is_file():
            raise unittest.SkipTest(f"Missing MobileCLIP model: {MOBILECLIP_MODEL}")
        if not (CLAP_MODEL / "model.safetensors").is_file():
            raise unittest.SkipTest(f"Missing CLAP model: {CLAP_MODEL}")
        cls.mobileclip = MobileClipEmbeddingEngine(str(MOBILECLIP_MODEL))
        cls.clap = ClapEmbeddingEngine(str(CLAP_MODEL))

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _wave(self, *, silent: bool = False) -> Path:
        path = self.directory / ("silent.wav" if silent else "tone.wav")
        sample_rate = 16000
        values = [
            0
            if silent
            else round(math.sin(2 * math.pi * 440 * index / sample_rate) * 10000)
            for index in range(sample_rate)
        ]
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(b"".join(struct.pack("<h", value) for value in values))
        return path

    def test_mobileclip_embeds_image_batch_and_text_queries(self) -> None:
        red = self.directory / "red.png"
        blue = self.directory / "animated.gif"
        Image.new("RGB", (224, 224), "red").save(red)
        first = Image.new("RGB", (224, 224), "red")
        second = Image.new("RGB", (224, 224), "blue")
        first.save(blue, save_all=True, append_images=[second])
        images = self.mobileclip.embed_images(
            [
                {"path": str(red), "frame_index": 0},
                {"path": str(blue), "frame_index": 1},
            ]
        )
        texts = self.mobileclip.embed_texts(["red square", "blue square"])
        self.assertEqual([item["frame_index"] for item in images], [0, 1])
        self.assertTrue(all(item["dimensions"] == 512 for item in images))
        self.assertTrue(all(item["dimensions"] == 512 for item in texts))

    def test_mobileclip_validates_empty_and_invalid_inputs(self) -> None:
        self.assertEqual(self.mobileclip.embed_images([]), [])
        self.assertEqual(self.mobileclip.embed_texts([]), [])
        with self.assertRaises(ValueError):
            self.mobileclip.embed_texts([" "])
        with self.assertRaises(FileNotFoundError):
            self.mobileclip.embed_images([{"path": "missing.png"}])
        image = self.directory / "one.png"
        Image.new("RGB", (4, 4), "red").save(image)
        with self.assertRaises(IndexError):
            self.mobileclip.embed_images([{"path": str(image), "frame_index": 1}])
        with self.assertRaises(FileNotFoundError):
            MobileClipEmbeddingEngine(str(self.directory / "missing.pt"))

    def test_clap_embeds_audio_batch_and_text_queries(self) -> None:
        audio = self.clap.embed_audio_files([str(self._wave())], chunk_seconds=0.4)
        texts = self.clap.embed_texts(["a steady electronic tone"])
        self.assertEqual(audio[0]["dimensions"], 512)
        self.assertEqual(texts[0]["dimensions"], 512)
        self.assertEqual(audio[0]["sample_rate"], 48000)
        self.assertGreater(len(audio[0]["regions"]), 1)

    def test_clap_validates_empty_silent_and_invalid_inputs(self) -> None:
        self.assertEqual(self.clap.embed_audio_files([]), [])
        self.assertEqual(self.clap.embed_texts([]), [])
        with self.assertRaises(ValueError):
            self.clap.embed_audio_files([str(self._wave())], chunk_seconds=0)
        with self.assertRaises(ValueError):
            self.clap.embed_texts([""])
        with self.assertRaises(FileNotFoundError):
            self.clap.embed_audio_files(["missing.wav"])
        with self.assertRaises(ValueError):
            self.clap.embed_audio_files([str(self._wave(silent=True))])
        with self.assertRaises(FileNotFoundError):
            ClapEmbeddingEngine(str(self.directory / "missing-model"))


if __name__ == "__main__":
    unittest.main()
