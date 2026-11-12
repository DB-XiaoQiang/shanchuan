import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_policy', ROOT/'scripts/release_policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ReleasePolicyTests(unittest.TestCase):
    def test_prerelease_never_becomes_stable_even_with_credentials(self):
        for signed in (False, True):
            for key in (False, True):
                result = policy.release_policy('prerelease', signed, key)
                self.assertFalse(result['generate_manifest'])
                self.assertFalse(result['draft'])
                self.assertTrue(result['prerelease'])
                self.assertEqual(['--prerelease', '--latest=false'], result['arguments'])

    def test_stable_requires_both_signing_gates(self):
        for signed, key in ((False, False), (True, False), (False, True)):
            result = policy.release_policy('stable', signed, key)
            self.assertTrue(result['draft'])
            self.assertFalse(result['generate_manifest'])
        self.assertTrue(policy.release_policy('stable', True, True)['generate_manifest'])

    def test_explicit_draft_and_invalid_channel(self):
        self.assertEqual(['--draft'], policy.release_policy('draft', True, True)['arguments'])
        with self.assertRaises(ValueError):
            policy.release_policy('', True, True)


if __name__ == '__main__':
    unittest.main()
