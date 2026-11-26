import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "gen-prices.py"
spec = importlib.util.spec_from_file_location("gen_prices", SCRIPT)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


class GeneratedPricesTest(unittest.TestCase):
    def test_generated_swift_matches_models_json(self):
        self.assertEqual(gen.TARGET.read_text(encoding="utf-8"), gen.render(),
                         "run python3 scripts/gen-prices.py and commit the result")

    def test_cache_prices_never_exceed_input(self):
        import json
        for m in json.loads(gen.SOURCE.read_text(encoding="utf-8"))["models"]:
            if m.get("cacheRead") is not None:
                self.assertLessEqual(m["cacheRead"], m["input"], m["id"])
