"""构建号必须由源码历史决定，不使用运行次数或打包主机的默认值。"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/build-number.py'


class BuildNumberTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shanchuan-build-number-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / 'source'
        self.repo.mkdir()
        self.environment = os.environ.copy()
        self.environment.pop('SHANCHUAN_BUILD_NUMBER', None)
        for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                     'GIT_SHALLOW_FILE', 'GIT_REPLACE_REF_BASE'):
            self.environment.pop(name, None)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Synthetic Build Tests')
        self.git('config', 'user.email', 'build-tests@example.invalid')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.first = self.commit('first')
        self.second = self.commit('second')

    def git(self, *arguments, cwd=None):
        result = subprocess.run(['git', '-C', str(cwd or self.repo), *arguments],
                                env=self.environment, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def commit(self, message):
        self.git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def invoke(self, *, repo=None, revision=None, override=None, extra_environment=None):
        arguments = [sys.executable, str(SCRIPT), '--repo', str(repo or self.repo)]
        if revision is not None:
            arguments += ['--revision', revision]
        environment = self.environment.copy()
        if override is not None:
            environment['SHANCHUAN_BUILD_NUMBER'] = override
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(arguments, env=environment, capture_output=True, text=True)

    def test_same_source_is_reproducible_and_successor_is_larger_than_old_build_one(self):
        first = self.invoke()
        second = self.invoke()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, '2\n')
        self.assertEqual(first.stdout, second.stdout)
        self.assertGreater(int(first.stdout), 1)
        self.commit('successor')
        self.assertEqual(self.invoke().stdout, '3\n')

    def test_selected_tag_retains_its_build_number_when_branch_moves_forward(self):
        self.git('-c', 'tag.gpgsign=false', 'tag', 'v0.2.3')
        self.commit('later source')
        tagged = self.invoke(revision='v0.2.3')
        self.assertEqual(tagged.returncode, 0, tagged.stderr)
        self.assertEqual(tagged.stdout, '2\n')
        self.assertEqual(self.invoke().stdout, '3\n')

    def test_explicit_number_must_equal_source_number(self):
        self.assertEqual(self.invoke(override='2').stdout, '2\n')
        for value in ('', '0', '1', '99', '02', '-1', '1.2.3', 'not-a-number'):
            with self.subTest(value=value):
                result = self.invoke(override=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('SHANCHUAN_BUILD_NUMBER', result.stderr)

    def test_shallow_history_is_rejected_instead_of_counting_one(self):
        clone = Path(self.temporary.name) / 'shallow'
        subprocess.run(['git', 'clone', '--quiet', '--depth', '1', self.repo.as_uri(), str(clone)],
                       env=self.environment, capture_output=True, text=True, check=True)
        result = self.invoke(repo=clone)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('浅仓库', result.stderr)

    def test_replace_refs_and_grafts_cannot_change_build_number(self):
        self.git('replace', self.second, self.first)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('replace', result.stderr)
        self.git('replace', '-d', self.second)
        grafts = self.repo / '.git/info/grafts'
        grafts.parent.mkdir(exist_ok=True)
        grafts.write_text(self.second + '\n')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('grafts', result.stderr)

    def test_missing_ancestor_and_archive_without_git_fail_closed(self):
        object_file = self.repo / '.git/objects' / self.first[:2] / self.first[2:]
        object_file.unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        archive = Path(self.temporary.name) / 'archive'
        archive.mkdir()
        result = self.invoke(repo=archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_archive_nested_inside_unrelated_repository_cannot_borrow_parent_history(self):
        archive = self.repo / 'downloaded-source'
        archive.mkdir()
        result = self.invoke(repo=archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('仓库根目录', result.stderr)

    def test_inherited_git_repository_variables_do_not_select_another_repository(self):
        result = self.invoke(extra_environment={'GIT_DIR': str(Path(self.temporary.name) / 'nonexistent.git'),
                                                'GIT_WORK_TREE': str(Path(self.temporary.name) / 'other')})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '2\n')

    def test_unknown_revision_fails_without_fallback(self):
        result = self.invoke(revision='does-not-exist')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
