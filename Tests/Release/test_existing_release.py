import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('existing', ROOT/'scripts/check-existing-release.py')
existing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(existing)


class ExistingReleaseTests(unittest.TestCase):
    def fixture(self, prerelease=True):
        names = ['Shanchuan-macos-arm64.zip', 'Shanchuan-macos-arm64.dmg', 'Shanchuan-win-x64.zip',
                 'Shanchuan-win-x64-Portable.zip', 'Shanchuan-win-x64-Setup.exe',
                 'Shanchuan-0.2.3-win-x64-full.nupkg', 'RELEASES-win-x64',
                 'releases.win-x64.json', 'assets.win-x64.json']
        if not prerelease:
            names += ['appcast.xml', 'update-manifest.json', 'update-manifest.sig']
        assets = [dict(id=i+1, name=n, size=1, state='uploaded',
                       digest='sha256:'+hashlib.sha256(n.encode()).hexdigest()) for i,n in enumerate(names)]
        sums = ''.join(a['digest'][7:]+'  '+a['name']+'\n' for a in assets).encode()
        assets.append(dict(id=99, name='SHA256SUMS', size=len(sums), state='uploaded',
                           digest='sha256:'+hashlib.sha256(sums).hexdigest()))
        return dict(tag_name='v0.2.3', target_commitish='a'*40, draft=False,
                    prerelease=prerelease, assets=assets), sums

    def test_complete_same_source_prerelease_can_skip_duplicate(self):
        release, sums = self.fixture()
        self.assertTrue(existing.validate_release(release, 'v0.2.3', 'a'*40, 'prerelease'))
        existing.validate_checksums(sums, release['assets'])

    def test_ordinary_channel_requires_signed_update_files(self):
        release, _ = self.fixture()
        release['prerelease'] = False
        with self.assertRaises(ValueError):
            existing.validate_release(release, 'v0.2.3', 'a'*40, 'unnotarized')
        release, sums = self.fixture(False)
        self.assertTrue(existing.validate_release(release, 'v0.2.3', 'a'*40, 'unnotarized'))
        existing.validate_checksums(sums, release['assets'])

    def test_wrong_source_channel_and_incomplete_assets_fail(self):
        release, _ = self.fixture()
        for source, channel in [('b'*40, 'prerelease'), ('a'*40, 'unnotarized'), ('a'*40, 'draft')]:
            with self.assertRaises(ValueError):
                existing.validate_release(release, 'v0.2.3', source, channel)
        for change in ('missing', 'duplicate', 'unfinished', 'digest'):
            changed = copy.deepcopy(release)
            if change == 'missing': changed['assets'].pop()
            if change == 'duplicate': changed['assets'][-1] = changed['assets'][0]
            if change == 'unfinished': changed['assets'][0]['state'] = 'new'
            if change == 'digest': changed['assets'][0]['digest'] = ''
            with self.assertRaises(ValueError):
                existing.validate_release(changed, 'v0.2.3', 'a'*40, 'prerelease')

    def test_drafts_do_not_skip_builds(self):
        release, _ = self.fixture()
        release['draft'] = True
        self.assertFalse(existing.validate_release(release, 'v0.2.3', 'a'*40, 'prerelease'))

    def test_mismatching_checksum_or_missing_coverage_fails(self):
        release, sums = self.fixture()
        with self.assertRaises(ValueError): existing.validate_checksums(sums+b'x', release['assets'])
        changed = copy.deepcopy(release['assets'])
        changed[0]['digest'] = 'sha256:'+'0'*64
        with self.assertRaises(ValueError): existing.validate_checksums(sums, changed)


if __name__ == '__main__': unittest.main()
