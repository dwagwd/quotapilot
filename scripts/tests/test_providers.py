import importlib.util
from pathlib import Path
import tempfile
import json
import os
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'provider_bridge.py')
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

class ProviderTests(unittest.TestCase):
    def test_claude_uses_quota_not_context(self):
        s = b.normalize('claude', {'session_id': 'test', 'context_window': {'used_percentage': 99},
            'rate_limits': {'five_hour': {'used_percentage': 25, 'resets_at': 12345}, 'seven_day': {'used_percentage': 5}}}, now=100)
        self.assertEqual(s['limits']['rateLimitsByLimitId']['claude:five_hour']['primary']['usedPercent'], 25)
        self.assertNotEqual(s['account'], 'test')
        other = b.normalize('claude', {'session_id': 'other'}, now=100)
        self.assertNotEqual(s['account'], other['account'])
    def test_antigravity_fraction_and_iso_reset(self):
        s = b.normalize('antigravity', {'email': 'test@example.invalid', 'plan_tier': 'Pro', 'quota': {
            'gemini-weekly': {'remaining_fraction': 0.75, 'reset_time': '2026-09-15T00:00:00Z'}}}, now=100)
        w = s['limits']['rateLimitsByLimitId']['antigravity:gemini-weekly']['primary']
        self.assertEqual(w['usedPercent'], 25)
        self.assertGreater(w['resetsAt'], 100)
        self.assertIsNone(w['windowDurationMins'])
        self.assertNotIn('email', s)
    def test_missing_and_invalid_never_become_zero(self):
        for value in (None, -1, 101, True):
            s = b.normalize('claude', {'session_id': 'test', 'rate_limits': {'five_hour': {'used_percentage': value}}})
            self.assertIsNone(s['limits']['rateLimitsByLimitId']['claude:five_hour']['primary']['usedPercent'])
        with self.assertRaises(ValueError): b.normalize('claude', {})
    def test_cursor_spend_scope_exact_member_and_cap_change(self):
        data = {'subscriptionCycleStart': 100, 'teamMemberSpend': [
            {'email': 'a@example.invalid', 'spendCents': 2500, 'overallSpendCents': 6000, 'effectivePerUserLimitDollars': 100}]}
        a = b.normalize('cursor', data, identity='a@example.invalid')
        self.assertEqual(a['limits']['rateLimitsByLimitId']['cursor:spend']['primary']['usedPercent'], 25)
        self.assertIsNone(a['limits']['rateLimitsByLimitId']['cursor:spend']['primary']['resetsAt'])
        data['subscriptionCycleStart'] = 200
        self.assertNotEqual(a['account'], b.normalize('cursor', data, identity='a@example.invalid')['account'])
        with self.assertRaises(ValueError): b.normalize('cursor', data, identity='missing@example.invalid')
    def test_installer_preserves_existing_command_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / '.claude'; base.mkdir()
            original = {'statusLine': {'type': 'command', 'command': "printf original-status", 'padding': 2}, 'unrelated': True}
            config = base / 'settings.json'; config.write_text(json.dumps(original))
            env = dict(os.environ, HOME=folder)
            installer = Path(__file__).parents[1] / 'setup-provider.py'
            for _ in range(2):
                subprocess.run([sys.executable, str(installer), 'claude'], env=env, capture_output=True, check=True)
            installed = json.loads(config.read_text())
            self.assertTrue(installed['unrelated'])
            self.assertEqual(installed['statusLine']['padding'], 2)
            backups = list(base.glob('settings.json.usage-widget-backup-*'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(backups[0].read_text()), original)
            self.assertEqual(list(base.glob('.usage-widget-*')), [])
            result = subprocess.run(installed['statusLine']['command'], shell=True, env=env,
                input=json.dumps({'session_id': 'test'}), text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout, 'original-status')
            self.assertTrue((Path(folder) / 'Library/Application Support/QuotaPilot/providers/claude.json').exists())
    def test_private_atomic_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            s = b.normalize('claude', {'session_id': 'test'}, now=100)
            b.write_snapshot(s, Path(folder))
            self.assertEqual((Path(folder)/'claude.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list(Path(folder).iterdir())), 1)

if __name__ == '__main__': unittest.main()
