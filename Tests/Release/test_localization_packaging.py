import importlib.util
import json
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage_localizations', ROOT / 'scripts/stage-localizations.py')
localizations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localizations)


class LocalizationPackagingTests(unittest.TestCase):
    def make_fixture(self, root):
        app = root / '闪传.app'
        contents = app / 'Contents'
        (contents / 'Resources').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.copytool.independent'}))
        sparkle = contents / 'Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj'
        sparkle.mkdir(parents=True)
        (sparkle / 'Sparkle.strings').write_bytes(plistlib.dumps({
            key: '中文更新文案' for key in localizations.SPARKLE_CHINESE_KEYS
        }, fmt=plistlib.FMT_BINARY))
        bundle = root / localizations.RESOURCE_BUNDLE_NAME
        for language in localizations.SUPPORTED_LANGUAGES:
            directory = bundle / (language + '.lproj')
            directory.mkdir(parents=True)
            (directory / 'Localizable.strings').write_text('"检查更新" = "' + ('检查更新' if language == 'zh-Hans' else 'Check for Updates') + '";\n')
        return app, bundle

    def test_staging_preserves_sparkle_and_declares_both_languages(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            sparkle = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings'
            before = localizations.strings_table(sparkle)
            localizations.stage_localizations(app, bundle)
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual('zh-Hans', info['CFBundleDevelopmentRegion'])
            self.assertEqual(['zh-Hans', 'en'], info['CFBundleLocalizations'])
            self.assertTrue((app / 'Contents/Resources' / localizations.RESOURCE_BUNDLE_NAME / 'en.lproj/Localizable.strings').exists())
            after = localizations.strings_table(sparkle)
            self.assertTrue(before.items() <= after.items())
            self.assertTrue(localizations.SPARKLE_CHINESE_SUPPLEMENTS.items() <= after.items())
            self.assertEqual('Shanchuan', localizations.strings_table(app / 'Contents/Resources/en.lproj/InfoPlist.strings')['CFBundleDisplayName'])
            self.assertEqual('闪传', localizations.strings_table(app / 'Contents/Resources/zh-Hans.lproj/InfoPlist.strings')['CFBundleName'])
            with self.assertRaises(ValueError):
                localizations.stage_localizations(app, bundle)

    def test_missing_language_and_translation_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            table = bundle / 'en.lproj/Localizable.strings'
            table.write_text('"另一键" = "Other";')
            with self.assertRaisesRegex(ValueError, '资源键'):
                localizations.stage_localizations(app, bundle)
            table.unlink()
            table.parent.rmdir()
            with self.assertRaisesRegex(ValueError, '缺少语言'):
                localizations.stage_localizations(app, bundle)

    def test_missing_sparkle_chinese_and_duplicate_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            sparkle = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings'
            sparkle.write_bytes(plistlib.dumps({'Ready to Install': 'Ready to Install'}))
            with self.assertRaisesRegex(ValueError, 'Sparkle'):
                localizations.stage_localizations(app, bundle)
            table = bundle / 'en.lproj/Localizable.strings'
            table.write_text('"重复" = "A"; "重复" = "B";')
            with self.assertRaisesRegex(ValueError, '重复键'):
                localizations.strings_table(table)

    def test_repository_tables_are_complete(self):
        # 真实资源的语言键须一致，防止某一端漏交翻译。
        localizations.validate_core_resources(ROOT / 'Sources/CopyToolCore/Resources')

    def test_macos_structured_resource_bundle_is_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            resources = bundle / 'Contents/Resources'
            resources.mkdir(parents=True)
            for language in localizations.SUPPORTED_LANGUAGES:
                (bundle / (language + '.lproj')).rename(resources / (language + '.lproj'))
            localizations.stage_localizations(app, bundle)
            installed = app / 'Contents/Resources' / localizations.RESOURCE_BUNDLE_NAME
            localizations.validate_core_resources(installed)

    def test_test_application_uses_its_own_localized_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.copytool.update-test'}))
            localizations.stage_localizations(app, bundle)
            self.assertEqual('Shanchuan Update Test', localizations.strings_table(app / 'Contents/Resources/en.lproj/InfoPlist.strings')['CFBundleDisplayName'])

    def test_all_mac_localized_literals_have_complete_translations_and_formats(self):
        chinese, english = localizations.validate_core_resources(ROOT / 'Sources/CopyToolCore/Resources')
        literal_call = re.compile(r'L10n\.(?:text|format|snapshot|snapshotFormat|snapshotCompose|compose)\(\s*("(?:[^"\\]|\\.)*")')
        for source in (ROOT / 'Sources').rglob('*.swift'):
            for match in literal_call.finditer(source.read_text()):
                key = json.loads(match[1])
                self.assertIn(key, chinese, f'{source.relative_to(ROOT)}: {key}')
                self.assertIn(key, english, f'{source.relative_to(ROOT)}: {key}')
        placeholder = re.compile(r'%(?:(\d+)\$)?[-+0# \x27]*\d*(?:\.\d+)?(hh|h|ll|l|z|t|j|L)?([@diuoxXfFeEgGaAcCsSpn])')
        def formats(value):
            result = []
            for sequence, match in enumerate(placeholder.finditer(value.replace('%%', ''))):
                position = int(match[1]) if match[1] else sequence + 1
                result.append((position, (match[2] or '') + match[3]))
            return sorted(result)
        for key, value in english.items():
            self.assertNotRegex(value, r'[\u3400-\u9fff]', f'英文译文残留中文：{key}')
            self.assertEqual(formats(chinese[key]), formats(value), f'格式参数不一致：{key}')

    def test_sparkle_chinese_supplements_preserve_official_translations(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, bundle = self.make_fixture(Path(temporary))
            path = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings'
            table = localizations.strings_table(path)
            table['Your Mac is too old'] = 'SDK 后续官方译文'
            path.write_bytes(plistlib.dumps(table))
            localizations.stage_localizations(app, bundle)
            self.assertEqual('SDK 后续官方译文', localizations.strings_table(path)['Your Mac is too old'])

    def test_resolved_sparkle_source_localized_keys_have_chinese_coverage(self):
        source = ROOT / '.build/checkouts/Sparkle/Sparkle'
        table = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings'
        if not source.is_dir() or not table.exists():
            self.skipTest('尚未解析 Sparkle 依赖；打包阶段会验证 SDK 资源。')
        catalog = localizations.strings_table(table) | localizations.SPARKLE_CHINESE_SUPPLEMENTS
        expression = re.compile(r'SULocalizedStringFromTableInBundle\(@("(?:[^"\\]|\\.)*")')
        for path in source.rglob('*.m'):
            for match in expression.finditer(path.read_text()):
                self.assertIn(json.loads(match[1]), catalog, str(path.relative_to(source)))


if __name__ == '__main__':
    unittest.main()
