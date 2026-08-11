from __future__ import annotations

import unittest

from app.vision import VisionClassifier


class VisionHelpersTests(unittest.TestCase):
    def test_response_json_helpers(self):
        parsed = VisionClassifier._parse_json("```json\n{\"confidence\": 82, \"section\": \"裂縫補強\"}\n```")
        self.assertEqual("裂縫補強", parsed["section"])
        self.assertEqual(0.82, VisionClassifier._confidence(parsed["confidence"]))

    def test_confidence_is_clamped(self):
        self.assertEqual(0.0, VisionClassifier._confidence("not-a-number"))
        self.assertEqual(1.0, VisionClassifier._confidence(200))


if __name__ == "__main__":
    unittest.main()
