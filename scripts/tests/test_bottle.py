import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bottle_block", ROOT / "scripts/bottle_block.py")
bottle_block = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bottle_block)

SHA = "ab" * 32


def sample(root="https://github.com/dwagwd/quotapilot/releases/download/v1.2.3", filename="quotapilot-1.2.3.arm64_sequoia.bottle.tar.gz", sha=SHA):
    return {"dwagwd/quotapilot/quotapilot": {"bottle": {"root_url": root, "cellar": "any_skip_relocation", "rebuild": 0, "tags": {
        "arm64_sequoia": {"filename": filename, "local_filename": filename.replace("-1", "--1", 1), "sha256": sha}}}}}


class BottleBlockTests(unittest.TestCase):
    def test_block_and_placement(self):
        block = bottle_block.block_from(sample(), "v1.2.3")
        self.assertIn('root_url "https://github.com/dwagwd/quotapilot/releases/download/v1.2.3"', block)
        self.assertIn(f'sha256 cellar: :any_skip_relocation, arm64_sequoia: "{SHA}"', block)
        formula = (ROOT / "Formula/quotapilot.rb").read_text()
        once = bottle_block.with_bottle(formula, block)
        self.assertEqual(once.count("  bottle do\n"), 1)
        self.assertLess(once.index("  head "), once.index("  bottle do"))
        self.assertLess(once.index("  bottle do"), once.index("  depends_on"))
        # Adding again replaces the block; removing it gives the original formula back.
        self.assertEqual(bottle_block.with_bottle(once, block), once)
        self.assertEqual(bottle_block.without_bottle(once), bottle_block.without_bottle(formula))

    def test_refuses_other_releases_and_bad_values(self):
        with self.assertRaises(ValueError):
            bottle_block.block_from(sample(), "v1.2.4")
        with self.assertRaises(ValueError):
            bottle_block.block_from(sample(root="https://example.com/v1.2.3"), "v1.2.3")
        with self.assertRaises(ValueError):
            bottle_block.block_from(sample(filename="quotapilot-1.2.2.arm64_sequoia.bottle.tar.gz"), "v1.2.3")
        with self.assertRaises(ValueError):
            bottle_block.block_from(sample(sha='"; system "x'), "v1.2.3")


if __name__ == "__main__":
    unittest.main()
