from __future__ import annotations

import importlib.util
import base64
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[3]
SERVICE_PATH = ROOT / "ReleaseCode" / "services" / "static_image" / "static_image_reader.py"
MODEL_PATH = (
    ROOT.parent
    / "Dependencies"
    / "Packageable"
    / "Models"
    / "image"
    / "mobileclip_s0.pt"
)

SPEC = importlib.util.spec_from_file_location("static_image_reader", SERVICE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load static-image service: {SERVICE_PATH}")
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class StaticImageReaderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _text_image(self) -> Path:
        path = self.directory / "ocr.png"
        image = Image.new("RGB", (900, 180), "white")
        drawing = ImageDraw.Draw(image)
        font = ImageFont.load_default(size=52)
        drawing.text((30, 50), "OCR TEST 2047", fill="black", font=font)
        image.save(path)
        return path

    def test_inspect_reports_static_image_metadata(self) -> None:
        path = self._text_image()

        result = READER.inspect_image(str(path))

        self.assertEqual(result["metadata"]["format"], "PNG")
        self.assertEqual(result["metadata"]["width"], 900)
        self.assertEqual(result["metadata"]["height"], 180)
        self.assertEqual(result["metadata"]["frame_count"], 1)
        self.assertEqual(result["metadata"]["pixel_format"], "RGBA8888")
        self.assertEqual(result["metadata"]["row_stride"], 900 * 4)
        self.assertEqual(
            len(base64.b64decode(result["metadata"]["pixels_base64"])),
            900 * 180 * 4,
        )

    def test_ocr_returns_text_regions_and_confidence(self) -> None:
        path = self._text_image()

        result = READER.extract_ocr(str(path), languages="eng")

        self.assertIn("OCR TEST 2047", result["text"])
        self.assertGreater(len(result["words"]), 0)
        self.assertIsNotNone(result["mean_confidence"])
        first_word = result["words"][0]
        self.assertGreaterEqual(first_word["left"], 0)
        self.assertGreater(first_word["width"], 0)

    def test_mobileclip_returns_normalized_512_dimension_vector(self) -> None:
        if not MODEL_PATH.is_file():
            self.skipTest(f"MobileCLIP test model is unavailable: {MODEL_PATH}")
        path = self.directory / "red.png"
        Image.new("RGB", (224, 224), "red").save(path)

        result = READER.analyze_image(
            str(path),
            model_path=str(MODEL_PATH),
            model_name="mobileclip_s0",
            device="cpu",
        )

        self.assertEqual(result["model"], "mobileclip_s0")
        self.assertEqual(result["dimensions"], 512)
        self.assertEqual(len(result["vector"]), 512)
        squared_norm = sum(value * value for value in result["vector"])
        self.assertAlmostEqual(squared_norm, 1.0, places=4)

    def test_mobileclip_batch_and_text_queries_share_vector_space(self) -> None:
        if not MODEL_PATH.is_file():
            self.skipTest(f"MobileCLIP test model is unavailable: {MODEL_PATH}")
        red = self.directory / "red.png"
        blue = self.directory / "blue.png"
        Image.new("RGB", (224, 224), "red").save(red)
        Image.new("RGB", (224, 224), "blue").save(blue)

        images = READER.analyze_images(
            [
                {"path": str(red), "frame_index": 0},
                {"path": str(blue), "frame_index": 0},
            ],
            model_path=str(MODEL_PATH),
        )
        texts = READER.embed_image_texts(
            ["a red square", "a blue square"],
            model_path=str(MODEL_PATH),
        )

        self.assertEqual(len(images), 2)
        self.assertEqual(len(texts), 2)
        self.assertTrue(all(item["dimensions"] == 512 for item in images))
        self.assertTrue(all(item["dimensions"] == 512 for item in texts))
        self.assertGreater(
            sum(a * b for a, b in zip(texts[0]["vector"], images[0]["vector"])),
            sum(a * b for a, b in zip(texts[0]["vector"], images[1]["vector"])),
        )

    def test_empty_mobileclip_batches_do_not_load_a_model(self) -> None:
        self.assertEqual(
            READER.analyze_images([], model_path="missing.pt"),
            [],
        )
        self.assertEqual(
            READER.embed_image_texts([], model_path="missing.pt"),
            [],
        )

    def test_multi_frame_image_returns_composited_frames_and_timing(self) -> None:
        path = self.directory / "animated.gif"
        first = Image.new("RGB", (16, 16), "red")
        second = Image.new("RGB", (16, 16), "blue")
        first.save(path, save_all=True, append_images=[second], duration=100)

        first_result = READER.inspect_image(str(path), frame_index=0)
        second_result = READER.inspect_image(str(path), frame_index=1)

        self.assertEqual(first_result["metadata"]["frame_count"], 2)
        self.assertEqual(first_result["metadata"]["frame_index"], 0)
        self.assertEqual(second_result["metadata"]["frame_index"], 1)
        self.assertEqual(second_result["metadata"]["frame_duration_ms"], 100)
        self.assertNotEqual(
            first_result["metadata"]["pixels_base64"],
            second_result["metadata"]["pixels_base64"],
        )
        self.assertGreater(
            len(base64.b64decode(second_result["metadata"]["frame_png_base64"])),
            0,
        )


if __name__ == "__main__":
    unittest.main()
