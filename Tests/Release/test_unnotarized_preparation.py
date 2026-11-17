import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
from types import SimpleNamespace
import unittest
import warnings
from unittest.mock import patch, Mock
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('prepare_unnotarized_release', ROOT / 'scripts/prepare-unnotarized-release.py')
preparation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preparation)
a = preparation.attachment


class UnnotarizedPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.version = '0.2.3'
        self.tag = 'v' + self.version
        self.sha = 'a' * 40
        self.files = {}
        for name in preparation.base_names(self.version) | preparation.EXTRAS:
            path = self.root / name
            path.write_bytes(('synthetic fixture ' + name).encode())
            self.files[name] = path
        self.mac = {name: a.sha256(self.files[name]) for name in [a.MAC_ZIP, a.MAC_DMG]}
        self.release = {'id': 14, 'tag_name': self.tag, 'draft': True, 'prerelease': True,
                        'target_commitish': self.sha,
                        'assets': [self.remote(name) for name in sorted(preparation.base_names(self.version))]}

    def remote(self, name, number=None):
        path = self.files[name]
        return {'id': number or len(name) + 100, 'name': name, 'state': 'uploaded', 'size': path.stat().st_size,
                'digest': 'sha256:' + a.sha256(path)}

    def found(self):
        return preparation.draft_assets(self.release, self.tag, self.sha, self.mac)

    def checksums(self, names=None):
        names = names or preparation.base_names(self.version)
        return preparation.checksum_bytes({name: a.sha256(self.files[name]) for name in names})

    def test_public_or_mismatched_releases_are_rejected_before_mutation(self):
        self.assertEqual(preparation.base_names(self.version), set(self.found()))
        for field, value in [('draft', False), ('draft', 'true'), ('prerelease', False),
                             ('tag_name', 'v0.2.2'), ('target_commitish', 'main'), ('target_commitish', 'b' * 40)]:
            release = copy.deepcopy(self.release); release[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                preparation.draft_assets(release, self.tag, self.sha, self.mac)

    def test_complete_base_assets_ids_and_mac_digests_are_required(self):
        for bad in ['missing', 'duplicate', 'unknown', 'id', 'state', 'digest', 'mac']:
            release = copy.deepcopy(self.release)
            if bad == 'missing': release['assets'].pop()
            elif bad == 'duplicate': release['assets'].append(release['assets'][0])
            elif bad == 'unknown': release['assets'].append(dict(release['assets'][0], name='private-key.pem'))
            elif bad == 'id': release['assets'][0]['id'] = '../7'
            elif bad == 'state': release['assets'][0]['state'] = 'starter'
            elif bad == 'digest': release['assets'][0]['digest'] = None
            else: next(x for x in release['assets'] if x['name'] == a.MAC_ZIP)['digest'] = 'sha256:' + '0' * 64
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                preparation.draft_assets(release, self.tag, self.sha, self.mac)

    def test_local_payloads_match_all_base_digests_not_only_mac(self):
        files = {name: self.files[name] for name in preparation.base_names(self.version)}
        self.assertEqual(set(files), set(preparation.validate_local_base(files, self.found(), self.version)))
        self.files['RELEASES-win-x64'].write_bytes(b'changed')
        with self.assertRaises(ValueError): preparation.validate_local_base(files, self.found(), self.version)

    def test_checksum_can_only_be_exact_base_or_complete_final_set(self):
        preparation.validate_checksum(self.checksums(), self.found(), self.version)
        for name in sorted(preparation.EXTRAS): self.release['assets'].append(self.remote(name))
        found = self.found()
        final = self.checksums(set(self.files))
        preparation.validate_checksum(final, found, self.version)
        for data in [b'', final + final.splitlines(keepends=True)[0], final.replace(b'  ', b' ../', 1),
                     final.replace(a.sha256(self.files[a.MAC_ZIP]).encode(), b'0' * 64), b'x' * (preparation.MAX_CHECKSUM_BYTES + 1)]:
            with self.subTest(data=data[:20]), self.assertRaises(ValueError):
                preparation.validate_checksum(data, found, self.version)
        partial = copy.deepcopy(self.release); partial['assets'].pop()
        with self.assertRaises(ValueError):
            preparation.validate_checksum(final, preparation.draft_assets(partial, self.tag, self.sha, self.mac), self.version)

    def test_partial_uploads_only_plan_missing_extra_files_and_retries_are_idempotent(self):
        missing, sums = preparation.final_plan(self.release, self.tag, self.sha, self.mac, self.files)
        self.assertEqual(preparation.EXTRAS, set(missing))
        self.assertEqual(12, len(sums.splitlines()))
        self.release['assets'].append(self.remote('appcast.xml'))
        self.assertEqual(preparation.EXTRAS - {'appcast.xml'},
                         set(preparation.final_plan(self.release, self.tag, self.sha, self.mac, self.files)[0]))
        self.release['assets'] += [self.remote(name) for name in ['update-manifest.json', 'update-manifest.sig']]
        self.assertEqual([], preparation.final_plan(self.release, self.tag, self.sha, self.mac, self.files)[0])
        next(x for x in self.release['assets'] if x['name'] == 'appcast.xml')['digest'] = 'sha256:' + 'f' * 64
        with self.assertRaises(ValueError): preparation.final_plan(self.release, self.tag, self.sha, self.mac, self.files)

    def zip(self, entries, name='mac.zip'):
        archive = self.root / name
        with zipfile.ZipFile(archive, 'w') as zipped:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                for key, value in entries:
                    zipped.writestr(key, value)
        return archive

    @staticmethod
    def link(name):
        item = zipfile.ZipInfo(name)
        item.create_system = 3
        item.external_attr = (stat.S_IFLNK | 0o777) << 16
        return item

    def test_mac_archive_accepts_internal_framework_symlinks_and_ditto_utf8_names(self):
        archive = self.zip([
            ('闪传.app/Contents/Info.plist', b'info'),
            ('闪传.app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/value', b'value'),
            (self.link('闪传.app/Contents/Frameworks/Sparkle.framework/Resources'), b'Versions/B/Resources'),
        ])
        preparation.safe_mac_archive(archive)
        raw_name = '闪传.app/Contents/Info.plist'.encode('utf-8').decode('cp437')
        member = zipfile.ZipInfo(raw_name)
        self.assertEqual('闪传.app/Contents/Info.plist', preparation.archive_name(member))

    def test_mac_archive_rejects_traversal_aliases_links_and_special_files(self):
        normal = [('闪传.app/Contents/Info.plist', b'info')]
        for name in ['../outside', '/outside', 'other.app/Contents/a', '闪传.app/../outside',
                     '闪传.app//Contents/a', '闪传.app/Contents\\a', '闪传.app/Contents/./a']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                preparation.safe_mac_archive(self.zip(normal + [(name, b'bad')]))
        for target in [b'/outside', b'../../outside', b'..\\outside']:
            with self.subTest(target=target), self.assertRaises(ValueError):
                preparation.safe_mac_archive(self.zip(normal + [(self.link('闪传.app/a'), target)]))
        with self.assertRaises(ValueError):
            preparation.safe_mac_archive(self.zip(normal + [(self.link('闪传.app/a'), b'Contents'), ('闪传.app/a/file', b'bad')]))
        special = zipfile.ZipInfo('闪传.app/fifo'); special.external_attr = (stat.S_IFIFO | 0o600) << 16
        with self.assertRaises(ValueError): preparation.safe_mac_archive(self.zip(normal + [(special, b'bad')]))
        alternate = zipfile.ZipInfo('闪传.app/Contents/value')
        extra = struct.pack('<BL', 1, zlib.crc32(alternate.filename.encode('utf-8'))) + b'../outside'
        alternate.extra = struct.pack('<HH', 0x7075, len(extra)) + extra
        with self.assertRaises(ValueError): preparation.safe_mac_archive(self.zip(normal + [(alternate, b'bad')]))
        with self.assertRaises(ValueError): preparation.safe_mac_archive(self.zip(normal + normal))
        with patch.object(preparation, 'MAX_MAC_BYTES', 2), self.assertRaises(ValueError):
            preparation.safe_mac_archive(self.zip(normal))

    def test_extracted_links_are_checked_again_before_codesign(self):
        app = self.root / 'test.app'; app.mkdir()
        (app / 'outside').symlink_to(self.root)
        with self.assertRaises(ValueError): preparation.validate_extracted_links(app)

    def bundle(self):
        repo = self.root / 'repo'; resources = repo / 'Resources'; resources.mkdir(parents=True)
        (resources / 'update-public-key.pem').write_bytes(b'public fixture')
        (resources / 'sparkle-public-key.txt').write_text('public fixture')
        app = self.root / 'fixture.app'; inner = app / 'Contents/Resources'; inner.mkdir(parents=True)
        for source in resources.iterdir(): (inner / source.name).write_bytes(source.read_bytes())
        info = {'CFBundleIdentifier': 'local.copytool.independent', 'CFBundleShortVersionString': self.version,
                'CFBundleVersion': '3', 'CFBundleExecutable': 'CopyTool', 'LSMinimumSystemVersion': '13.0', 'SUPublicEDKey': 'public fixture',
                'SUFeedURL': 'https://github.com/DB-XiaoQiang/shanchuan/releases/latest/download/appcast.xml'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/MacOS').mkdir()
        (app / 'Contents/MacOS/CopyTool').write_bytes(b'Mach-O fixture')
        return app, repo, info

    def test_bundle_requires_matching_identity_keys_version_and_incremented_build(self):
        app, repo, info = self.bundle()
        identity = b'Authority=Apple Development: fixture\nTeamIdentifier=FIXTURE\n'
        with patch.object(preparation, 'run', return_value=SimpleNamespace(stderr=identity, stdout=b'arm64\n')):
            self.assertEqual('3', preparation.check_bundle(app, self.version, repo, expected_build='3'))
            for field, value in [('CFBundleVersion', '1'), ('CFBundleVersion', '4'), ('CFBundleVersion', '0.2.3'),
                                 ('CFBundleIdentifier', 'other'), ('CFBundleShortVersionString', '0.2.2'),
                                 ('SUPublicEDKey', 'other'), ('SUFeedURL', 'https://other/feed')]:
                changed = dict(info); changed[field] = value
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(changed))
                with self.subTest(field=field), self.assertRaises(ValueError): preparation.check_bundle(app, self.version, repo, expected_build='3')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        with patch.object(preparation, 'run', return_value=SimpleNamespace(stderr=b'Signature=adhoc\nTeamIdentifier=not set', stdout=b'arm64\n')):
            with self.assertRaises(ValueError): preparation.check_bundle(app, self.version, repo, expected_build='3')
        with patch.object(preparation, 'run', return_value=SimpleNamespace(stderr=identity, stdout=b'x86_64\n')):
            with self.assertRaises(ValueError): preparation.check_bundle(app, self.version, repo, expected_build='3')
        (app / 'Contents/Resources/update-public-key.pem').write_bytes(b'other key')
        with patch.object(preparation, 'run'):
            with self.assertRaises(ValueError): preparation.check_bundle(app, self.version, repo, expected_build='3')

    def test_expected_build_uses_the_checked_out_source_tool(self):
        with patch.object(preparation, 'run', return_value=SimpleNamespace(stdout=b'23\n')) as execute:
            self.assertEqual('23', preparation.expected_build_number(self.root))
            self.assertEqual(['python3', self.root / 'scripts/build-number.py', '--repo', self.root], execute.call_args.args[0])
        for invalid in [b'', b'01\n', b'23;echo unsafe', b'-1']:
            with patch.object(preparation, 'run', return_value=SimpleNamespace(stdout=invalid)), self.assertRaises(ValueError):
                preparation.expected_build_number(self.root)

    def test_existing_valid_signature_is_reused_and_tampering_rejected(self):
        fixture = ROOT / 'Fixtures/Updates'
        repo = self.root / 'signature-repo'; (repo / 'Resources').mkdir(parents=True)
        (repo / 'Resources/update-public-key.pem').write_bytes((fixture / 'public-key.pem').read_bytes())
        directory = self.root / 'signatures'; directory.mkdir()
        (directory / 'update-manifest.json').write_bytes((fixture / 'manifest.json').read_bytes())
        (directory / 'update-manifest.sig').write_bytes(b'new randomized signature placeholder')
        original = self.root / 'remote.sig'; original.write_bytes((fixture / 'manifest.sig').read_bytes())
        with patch.object(preparation, 'ROOT', repo):
            preparation.expected_manifest_signature(directory, original)
            self.assertEqual(original.read_bytes(), (directory / 'update-manifest.sig').read_bytes())
            (directory / 'update-manifest.json').write_bytes(b'tampered')
            with self.assertRaises(ValueError): preparation.expected_manifest_signature(directory, original)

    def test_checksum_delete_refuses_published_changed_or_incomplete_draft(self):
        self.release['assets'] += [self.remote(name) for name in sorted(preparation.EXTRAS)]
        checksum = self.root / a.CHECKSUMS; checksum.write_bytes(self.checksums(set(self.files)))
        remote = {'id': 901, 'name': a.CHECKSUMS, 'state': 'uploaded', 'size': checksum.stat().st_size,
                  'digest': 'sha256:' + a.sha256(checksum)}
        self.release['assets'].append(remote)
        api = preparation.GitHub()
        with patch.object(api, 'refresh_release', return_value=self.release), patch.object(preparation, 'run') as execute:
            api.delete_checksum(14, 901, self.tag, self.sha, self.mac, self.files)
            self.assertEqual(['gh', 'api', '--method', 'DELETE', 'repos/DB-XiaoQiang/shanchuan/releases/assets/901'], execute.call_args.args[0])
        for mutation in ['public', 'id', 'payload']:
            changed = copy.deepcopy(self.release)
            if mutation == 'public': changed['draft'] = False
            elif mutation == 'id': next(x for x in changed['assets'] if x['name'] == a.CHECKSUMS)['id'] = 902
            else: changed['assets'][0]['digest'] = 'sha256:' + '0' * 64
            with patch.object(api, 'refresh_release', return_value=changed), patch.object(preparation, 'run') as execute:
                with self.assertRaises(ValueError): api.delete_checksum(14, 901, self.tag, self.sha, self.mac, self.files)
                execute.assert_not_called()

    def test_download_uses_numeric_asset_id_not_untrusted_download_url(self):
        asset = self.remote(a.MAC_ZIP, 123)
        asset['browser_download_url'] = 'https://attacker.invalid/token'
        destination = self.root / 'download.zip'
        def download(arguments, **kwargs):
            kwargs['stdout'].write(self.files[a.MAC_ZIP].read_bytes())
            self.assertIn('repos/DB-XiaoQiang/shanchuan/releases/assets/123', arguments)
            self.assertNotIn(asset['browser_download_url'], arguments)
        with patch.object(preparation.subprocess, 'run', side_effect=download):
            preparation.GitHub().download_asset(asset, destination)
        self.assertEqual(self.files[a.MAC_ZIP].read_bytes(), destination.read_bytes())
        with self.assertRaises(ValueError): preparation.GitHub().download_asset(dict(asset, id='../123'), self.root / 'bad')

    def test_public_release_is_rejected_before_downloads_or_signing(self):
        repo = self.root / 'source'; repo.mkdir()
        (repo / 'VERSION').write_text(self.version)
        (repo / 'RELEASE_CHANNEL').write_text('unnotarized')
        api = Mock()
        ci = {'id': 15, 'repository': {'full_name': a.REPOSITORY, 'id': 19},
              'head_repository': {'full_name': a.REPOSITORY, 'id': 19}, 'head_sha': self.sha,
              'status': 'completed', 'conclusion': 'success', 'head_branch': 'main', 'event': 'push',
              'path': '.github/workflows/ci.yml', 'workflow_id': 22}
        api.json.side_effect = [ci, {'id': 22}]
        api.pages.return_value = [{'name': name, 'status': 'completed', 'conclusion': 'success'}
                                 for name in ['windows', 'macos', 'release-tools']]
        api.release.return_value = dict(self.release, draft=False)
        args = SimpleNamespace(tag=self.tag, ci_run_id='15', mac_zip_sha256=self.mac[a.MAC_ZIP],
                               mac_dmg_sha256=self.mac[a.MAC_DMG], report=None)
        environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': a.REPOSITORY, 'GH_TOKEN': 'synthetic-token',
                       'SPARKLE_PRIVATE_KEY': 'synthetic-key', 'UPDATE_MANIFEST_PRIVATE_KEY': 'synthetic-key'}
        with patch.dict(preparation.os.environ, environment, clear=True), patch.object(preparation, 'ROOT', repo), \
             patch.object(preparation, 'GitHub', return_value=api), \
             patch.object(preparation, 'run', return_value=SimpleNamespace(stdout=self.sha.encode())) as execute:
            with self.assertRaises(ValueError): preparation.prepare(args)
            execute.assert_called_once_with(['git', '-C', repo, 'rev-parse', 'HEAD'])
            api.download.assert_not_called()
            api.upload.assert_not_called()
            api.delete_checksum.assert_not_called()
            self.assertFalse((repo / 'dist').exists())

    def test_workflow_only_uses_existing_signing_secrets_and_never_publishes(self):
        workflow = (ROOT / '.github/workflows/prepare-unnotarized-release.yml').read_text()
        source = (ROOT / 'scripts/prepare-unnotarized-release.py').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('fetch-depth: 0', workflow)
        self.assertLess(workflow.index('run: swift package resolve'), workflow.index('SPARKLE_PRIVATE_KEY:'))
        self.assertIn('SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}', workflow)
        self.assertIn('UPDATE_MANIFEST_PRIVATE_KEY: ${{ secrets.UPDATE_MANIFEST_PRIVATE_KEY }}', workflow)
        for forbidden in ['MACOS_CERTIFICATE_P12', 'APPLE_APP_PASSWORD', 'release create', 'release edit', '--clobber', "'PATCH'"]:
            self.assertNotIn(forbidden, workflow + source)
        self.assertIn("unnotarized_verified=True", source)
        self.assertIn("release_policy('unnotarized', False", source)
        self.assertEqual(1, source.count("'DELETE'"))


if __name__ == '__main__': unittest.main()
