import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import simulator as adapter


class ConfigureModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.binary = self.directory / 'simslim'
        self.binary.write_bytes(b'pin')
        self.config = {'binary_sha256': hashlib.sha256(b'pin').hexdigest(),
                       'all_categories': ['store', 'notifications']}
        self.profile = self.directory / 'profile.json'
        self.profile.write_text('{}')
        self.digest = hashlib.sha256(self.profile.read_bytes()).hexdigest()
        self.udid = '00000000-1111-2222-3333-444444444444'

    def apply(self, requested, previous, call):
        events = []
        with patch.object(adapter, 'call', side_effect=lambda args, **kw: call(args, events)):
            result = adapter.configure_mode(self.udid, requested, previous,
                                            self.binary, self.config, self.profile,
                                            self.directory,
                                            lambda mode: events.append(mode))
        return result, events

    def test_clean_stock_does_not_require_binary(self):
        self.binary.unlink()
        self.assertEqual(self.apply('stock', 'stock', lambda *_: self.fail()),
                         ('stock', []))

    def test_reused_slim_to_stock_restores_and_verifies(self):
        mode, events = self.apply('stock', 'minimal', lambda args, events: events.append(args[1]))
        self.assertEqual((mode, events), ('stock', ['dirty', 'off', 'verify', 'stock']))
        self.assertEqual(json.loads((self.directory / 'stock.json').read_text()),
                         {'except': self.config['all_categories']})

    def test_reused_slim_to_richer_profile_restores_baseline(self):
        mode, events = self.apply('app', 'minimal', lambda args, events: events.append(args[1]))
        self.assertEqual((mode, events),
                         ('app', ['dirty', 'off', 'verify', 'stock', 'dirty', 'on', 'verify', 'app:' + self.digest]))

    def test_failed_slim_uses_verified_stock(self):
        def call(args, events):
            events.append(args[1])
            if args[1] == 'on':
                raise subprocess.CalledProcessError(1, args)
        mode, events = self.apply('minimal', 'stock', call)
        self.assertEqual((mode, events), ('stock', ['dirty', 'on', 'off', 'verify', 'stock']))

    def test_dirty_never_runs_unauthenticated_helper(self):
        self.binary.write_bytes(b'wrong')
        with self.assertRaisesRegex(RuntimeError, 'pinned SimSlim binary'):
            self.apply('stock', 'dirty', lambda *_: self.fail())

    def test_unsuccessful_stock_restore_never_clears_dirty(self):
        recorded = []
        with patch.object(adapter, 'call', side_effect=subprocess.CalledProcessError(1, ['off'])):
            with self.assertRaises(subprocess.CalledProcessError):
                adapter.configure_mode(self.udid, 'stock', 'dirty', self.binary, self.config,
                                       self.profile, self.directory, recorded.append)
        self.assertEqual(recorded, ['dirty'])


class EnvironmentTests(unittest.TestCase):
    def test_fixture_exports_removed_if_guard_not_verified(self):
        guard = {'fixture_environment': {'FENCE': 'yes'}, 'fixture_run_id_environment': 'RUN_ID',
                 'fixture_feature': 'fixture', 'allowed_fixture_features': ['fixture']}
        env = {'FENCE': 'stale', 'RUN_ID': 'stale', 'SIMSLIM_FIXTURE_APP': 'stale'}
        adapter.child_environment({'launch_guard': guard}, None, {'fixture'},
                                  'test-uuid', 'test simulator', 'stock', Path('/lease'), env)
        self.assertEqual(env['SIMSLIM_LEASE'], '/lease')
        self.assertEqual(env['SIMSLIM_UDID'], 'test-uuid')
        self.assertTrue({'FENCE', 'RUN_ID', 'SIMSLIM_FIXTURE_APP'}.isdisjoint(env))


if __name__ == '__main__':
    unittest.main()
