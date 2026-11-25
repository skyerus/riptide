import json
from pathlib import Path
from struct import unpack
import unittest


class SafariManifestTests(unittest.TestCase):
    def test_distribution_and_toolbar_icons_are_packaged_at_declared_sizes(self):
        resources = Path(__file__).resolve().parent.parent / "SafariExtension" / "Resources"
        manifest = json.loads((resources / "manifest.json").read_text())
        for entries, expected in (
            (manifest["icons"], {48, 64, 96, 128, 256, 512}),
            (manifest["action"]["default_icon"], {16, 19, 32, 38}),
        ):
            self.assertEqual({int(size) for size in entries}, expected)
            for size, name in entries.items():
                with self.subTest(icon=name), (resources / name).open("rb") as icon:
                    self.assertEqual(icon.read(16), b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
                    self.assertEqual(unpack(">II", icon.read(8)), (int(size), int(size)))


if __name__ == "__main__":
    unittest.main()
