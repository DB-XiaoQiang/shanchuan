import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('attach_prerelease_windows', ROOT / 'scripts/attach-prerelease-windows.py')
attachment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(attachment)


class PrereleaseAttachmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = '0.2.1'
        self.tag = 'v' + self.version
        self.sha = '1' * 40
        self.mac = {attachment.MAC_ZIP: 'a' * 64, attachment.MAC_DMG: 'b' * 64}
        self.files = {}
        for name in attachment.windows_names(self.version):
            path = self.root / name
            path.write_bytes(('synthetic fixture: ' + name).encode())
            self.files[name] = path
        self.full_name = f'Shanchuan-{self.version}-win-x64-full.nupkg'
        full = self.files[self.full_name].read_bytes()
        self.entry = {'PackageId': 'Shanchuan', 'Version': self.version, 'Type': 'Full',
                      'FileName': self.full_name, 'Size': len(full), 'SHA256': hashlib.sha256(full).hexdigest().upper(),
                      'SHA1': hashlib.sha1(full).hexdigest().upper()}
        self.write_feed(self.entry)
        self.write_assets()
        self.files['RELEASES-win-x64'].write_text('\ufeff' + self.entry['SHA1'] + ' ' + self.full_name + ' ' + str(len(full)) + '\n')
        self.release = {'id': 7, 'tag_name': self.tag, 'target_commitish': self.sha, 'draft': True, 'prerelease': True,
                        'assets': [self.remote(name, digest, 123) for name, digest in self.mac.items()]}
        self.run_id = 987654
        self.run = {'id': self.run_id, 'repository': {'full_name': attachment.REPOSITORY, 'id': 12},
                    'head_repository': {'full_name': attachment.REPOSITORY, 'id': 12}, 'head_sha': self.sha,
                    'status': 'completed', 'conclusion': 'success', 'head_branch': 'main', 'event': 'push',
                    'path': '.github/workflows/ci.yml', 'workflow_id': 18}
        self.jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in ['windows', 'macos', 'release-tools']]
        self.artifact = {'id': 31, 'name': attachment.ARTIFACT_NAME, 'expired': False, 'size_in_bytes': 123,
                         'digest': 'sha256:' + 'c' * 64, 'workflow_run': {'id': self.run_id, 'head_sha': self.sha,
                         'repository_id': 12, 'head_repository_id': 12}}

    def write_feed(self, entry):
        self.files['releases.win-x64.json'].write_text(json.dumps({'Assets': [entry]}))

    def write_assets(self):
        self.files['assets.win-x64.json'].write_text(json.dumps([
            {'RelativeFileName': 'Shanchuan-win-x64-Setup.exe', 'Type': 'Installer'},
            {'RelativeFileName': self.full_name, 'Type': 'Full'},
            {'RelativeFileName': 'Shanchuan-win-x64-Portable.zip', 'Type': 'Portable'}]))

    @staticmethod
    def remote(name, digest, size):
        return {'name': name, 'digest': 'sha256:' + digest, 'size': size, 'state': 'uploaded'}

    def test_tag_run_id_version_and_hash_inputs_are_strict(self):
        self.assertEqual(self.version, attachment.validate_version(self.tag, self.version + '\n'))
        self.assertEqual(self.run_id, attachment.parse_run_id(str(self.run_id)))
        for value in ['v01.2.3', 'v1.2', '1.2.3', 'v1.2.3-beta', 'v1.2.3/../x', 'v1.2.3\n', 'v1000000.0.0', 'v1.2.3;echo unsafe']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                attachment.parse_tag(value)
        with self.assertRaises(ValueError): attachment.validate_version(self.tag, '0.2.0')
        for value in ['0', '-1', '01', '../42', '42;echo unsafe', '12\n']:
            with self.assertRaises(ValueError): attachment.parse_run_id(value)
        for value in ['a' * 63, 'A' * 64, 'sha256:' + 'a' * 64, 'g' * 64]:
            with self.assertRaises(ValueError): attachment.digest_value(value)

    def test_ci_must_be_successful_main_workflow_from_the_same_commit_and_repo(self):
        attachment.validate_ci_run(self.run, self.jobs, 18, self.sha, self.run_id)
        for field, value in [('status', 'in_progress'), ('conclusion', 'failure'), ('head_branch', 'feature'),
                             ('event', 'pull_request'), ('path', '.github/workflows/release.yml'),
                             ('workflow_id', 19), ('head_sha', '2' * 40), ('id', self.run_id + 1)]:
            run = copy.deepcopy(self.run); run[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                attachment.validate_ci_run(run, self.jobs, 18, self.sha, self.run_id)
        for field in ['repository', 'head_repository']:
            run = copy.deepcopy(self.run); run[field]['full_name'] = 'another/repository'
            with self.assertRaises(ValueError): attachment.validate_ci_run(run, self.jobs, 18, self.sha, self.run_id)
        for jobs in [self.jobs[:-1], self.jobs + [self.jobs[0]], [dict(job, conclusion='skipped') for job in self.jobs]]:
            with self.assertRaises(ValueError): attachment.validate_ci_run(self.run, jobs, 18, self.sha, self.run_id)

    def test_artifact_must_be_unique_current_and_from_the_same_run_and_repository(self):
        self.assertEqual(31, attachment.select_artifact([self.artifact], self.run_id, self.sha, 12)['id'])
        for artifacts in [[], [self.artifact, self.artifact]]:
            with self.assertRaises(ValueError): attachment.select_artifact(artifacts, self.run_id, self.sha, 12)
        for field, value in [('expired', True), ('size_in_bytes', 0), ('digest', None), ('id', 0)]:
            artifact = copy.deepcopy(self.artifact); artifact[field] = value
            with self.assertRaises(ValueError): attachment.select_artifact([artifact], self.run_id, self.sha, 12)
        for field, value in [('id', 1), ('head_sha', '2' * 40), ('repository_id', 13), ('head_repository_id', 13)]:
            artifact = copy.deepcopy(self.artifact); artifact['workflow_run'][field] = value
            with self.assertRaises(ValueError): attachment.select_artifact([artifact], self.run_id, self.sha, 12)

    def test_release_must_remain_prerelease_draft_at_the_exact_sha(self):
        self.assertEqual(set(self.mac), set(attachment.release_assets(self.release, self.tag, self.sha, self.mac)))
        for field, value in [('draft', False), ('draft', 'true'), ('prerelease', False),
                             ('tag_name', 'v0.2.0'), ('target_commitish', 'main'), ('target_commitish', '2' * 40)]:
            release = copy.deepcopy(self.release); release[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                attachment.release_assets(release, self.tag, self.sha, self.mac)

    def test_mac_digest_missing_incomplete_or_unexpected_asset_rejects_before_upload(self):
        variants = []
        release = copy.deepcopy(self.release); release['assets'][0]['digest'] = 'sha256:' + 'e' * 64; variants.append(release)
        release = copy.deepcopy(self.release); release['assets'].pop(); variants.append(release)
        release = copy.deepcopy(self.release); release['assets'][0]['state'] = 'starter'; variants.append(release)
        release = copy.deepcopy(self.release); release['assets'].append(self.remote('update-manifest.json', 'e' * 64, 12)); variants.append(release)
        release = copy.deepcopy(self.release); release['assets'].append(release['assets'][0]); variants.append(release)
        for release in variants:
            with self.assertRaises(ValueError): attachment.release_assets(release, self.tag, self.sha, self.mac)

    def test_all_three_windows_indexes_bind_names_version_sizes_and_hashes(self):
        self.assertEqual(attachment.windows_names(self.version), set(attachment.validate_windows_files(self.files, self.version)))
        for field, value in [('PackageId', 'Other'), ('Type', 'Delta'), ('Version', '0.2.0'),
                             ('FileName', '../other.nupkg'), ('Size', self.entry['Size'] + 1),
                             ('SHA256', '0' * 64), ('SHA1', '0' * 40)]:
            entry = dict(self.entry); entry[field] = value; self.write_feed(entry)
            with self.subTest(field=field), self.assertRaises(ValueError):
                attachment.validate_windows_files(self.files, self.version)
        self.write_feed(self.entry)
        self.files['assets.win-x64.json'].write_text(json.dumps([{'RelativeFileName': '../other.exe', 'Type': 'Installer'}]))
        with self.assertRaises(ValueError): attachment.validate_windows_files(self.files, self.version)
        self.write_assets()
        self.files['RELEASES-win-x64'].write_text('0' * 40 + ' ' + self.full_name + ' 12\n')
        with self.assertRaises(ValueError): attachment.validate_windows_files(self.files, self.version)

    def test_duplicate_feed_properties_and_extra_package_are_rejected(self):
        self.files['releases.win-x64.json'].write_text('{"Assets":[],"Assets":[]}')
        with self.assertRaises(ValueError): attachment.validate_windows_files(self.files, self.version)
        files = dict(self.files); files['Shanchuan-0.2.0-win-x64-full.nupkg'] = self.files[self.full_name]
        with self.assertRaises(ValueError): attachment.validate_windows_files(files, self.version)

    def test_archive_allows_only_the_expected_layout_and_verifies_download_digest(self):
        archive = self.root / 'artifact.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            for name, path in self.files.items():
                zipped.write(path, name if name == 'Shanchuan-win-x64.zip' else 'releases/' + name)
        extracted = attachment.unpack_artifact(archive, self.root / 'safe-output', self.version, attachment.sha256(archive))
        self.assertEqual(set(self.files), set(extracted))
        self.assertEqual(attachment.validate_windows_files(self.files, self.version), attachment.validate_windows_files(extracted, self.version))
        with self.assertRaises(ValueError): attachment.unpack_artifact(archive, self.root / 'wrong-digest', self.version, '0' * 64)
        self.assertFalse((self.root / 'wrong-digest').exists())

    def test_archive_rejects_traversal_links_duplicates_and_unknown_files(self):
        members = []
        for name in self.files:
            item = zipfile.ZipInfo(name); item.file_size = 20; members.append(item)
        for bad_name in ['../outside', '/outside', 'releases/../outside', 'releases\\outside', 'other/unknown.exe',
                         'C:/outside', 'unknown.txt', 'releases/' + next(iter(self.files))]:
            extra = zipfile.ZipInfo(bad_name); extra.file_size = 20
            with self.subTest(name=bad_name), self.assertRaises(ValueError): attachment.archive_members(members + [extra], self.version)
        linked = copy.copy(members[0]); linked.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(ValueError): attachment.archive_members([linked] + members[1:], self.version)
        with self.assertRaises(ValueError): attachment.archive_members(members + [members[0]], self.version)
        with patch.object(attachment, 'MAX_UNCOMPRESSED_BYTES', 30):
            with self.assertRaises(ValueError): attachment.archive_members(members, self.version)

    def test_plan_uploads_only_windows_and_full_nine_file_checksums(self):
        hashes = attachment.validate_windows_files(self.files, self.version)
        missing, sums = attachment.attachment_plan(self.release, self.tag, self.sha, self.files, hashes, self.mac)
        self.assertEqual(attachment.windows_names(self.version) | {'SHA256SUMS'}, set(missing))
        self.assertEqual(9, len(sums.splitlines()))
        names = {line.decode().split('  ')[1] for line in sums.splitlines()}
        self.assertEqual(attachment.windows_names(self.version) | set(self.mac), names)
        self.assertNotIn(attachment.MAC_ZIP, missing)
        self.assertNotIn(attachment.MAC_DMG, missing)

    def test_existing_matching_assets_are_idempotent_and_conflicts_never_overwrite(self):
        hashes = attachment.validate_windows_files(self.files, self.version)
        _, sums = attachment.attachment_plan(self.release, self.tag, self.sha, self.files, hashes, self.mac)
        complete = copy.deepcopy(self.release)
        complete['assets'] += [self.remote(name, hashes[name], path.stat().st_size) for name, path in self.files.items()]
        complete['assets'].append(self.remote('SHA256SUMS', hashlib.sha256(sums).hexdigest(), len(sums)))
        self.assertEqual([], attachment.attachment_plan(complete, self.tag, self.sha, self.files, hashes, self.mac)[0])
        for name in [self.full_name, 'SHA256SUMS']:
            conflict = copy.deepcopy(complete)
            next(asset for asset in conflict['assets'] if asset['name'] == name)['digest'] = 'sha256:' + 'e' * 64
            with self.subTest(name=name), self.assertRaises(ValueError):
                attachment.attachment_plan(conflict, self.tag, self.sha, self.files, hashes, self.mac)

    def test_checksum_allowlist_and_upload_client_never_use_shell_or_modify_release(self):
        hashes = attachment.validate_windows_files(self.files, self.version) | self.mac
        invalid = dict(hashes); invalid['../bad'] = invalid.pop(attachment.MAC_ZIP)
        with self.assertRaises(ValueError): attachment.checksum_bytes(invalid, self.version)
        with patch.object(attachment.subprocess, 'run', return_value=SimpleNamespace(stdout=b'{}')) as run:
            attachment.GitHub().upload(7, 'Shanchuan-win-x64-Setup.exe', self.files['Shanchuan-win-x64-Setup.exe'])
        arguments = run.call_args.args[0]
        self.assertIsInstance(arguments, list)
        self.assertNotIn('shell', run.call_args.kwargs)
        self.assertEqual(['gh', 'api', '--method', 'POST'], arguments[:4])
        self.assertTrue(arguments[4].startswith('https://uploads.github.com/repos/DB-XiaoQiang/shanchuan/releases/7/assets?name='))
        workflow = (ROOT / '.github/workflows/attach-prerelease-windows.yml').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertIn('GH_TOKEN: ${{ github.token }}', workflow)
        self.assertIn('contents: write', workflow)
        self.assertIn('actions: read', workflow)
        source = (ROOT / 'scripts/attach-prerelease-windows.py').read_text()
        self.assertNotIn("'--clobber'", source)
        self.assertNotIn("'DELETE'", source)
        self.assertNotIn("'PATCH'", source)


if __name__ == '__main__':
    unittest.main()
