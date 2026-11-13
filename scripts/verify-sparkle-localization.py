#!/usr/bin/env python3
"""启动独立命令行探针验证应用与 Sparkle 双语；不会启动任何 GUI 或安装更新。"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stage_localizations', ROOT / 'scripts/stage-localizations.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


def verify(app=None, framework=None):
    if sys.platform != 'darwin':
        raise ValueError('Sparkle 本地化探针需要 macOS。')
    if app:
        app = Path(app)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleDevelopmentRegion') != 'zh-Hans' or info.get('CFBundleLocalizations') != ['zh-Hans', 'en']:
            raise ValueError('已打包应用缺少预期语言声明。')
        resource_bundle = app / 'Contents/Resources' / staging.RESOURCE_BUNDLE_NAME
        framework = Path(framework) if framework else app / 'Contents/Frameworks/Sparkle.framework'
    else:
        info = {'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans', 'en']}
        resource_bundle = ROOT / 'Sources/CopyToolCore/Resources'
        if not framework:
            framework = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
        framework = Path(framework)
    if not framework.is_dir():
        raise ValueError('缺少 Sparkle.framework，请先解析 SwiftPM 依赖或指定 --framework。')
    tables = staging.validate_core_resources(resource_bundle)
    chinese = staging.strings_table(framework / 'Versions/B/Resources/zh_CN.lproj/Sparkle.strings')
    english = staging.strings_table(framework / 'Versions/B/Resources/Base.lproj/Sparkle.strings')
    if app and not staging.SPARKLE_CHINESE_SUPPLEMENTS.keys() <= chinese.keys():
        raise ValueError('打包副本未补齐 Sparkle 简体中文错误提示。')
    with tempfile.TemporaryDirectory(prefix='shanchuan-localization-probe-') as temporary:
        work = Path(temporary)
        # 宿主语言元数据保持一致；替换应用身份，绝不读写真实应用的语言设置。
        info['CFBundleIdentifier'] = 'local.shanchuan.localization-probe.' + uuid.uuid4().hex
        (work / 'Info.plist').write_bytes(plistlib.dumps(info))
        if not app:
            staged = work / staging.RESOURCE_BUNDLE_NAME
            shutil.copytree(resource_bundle, staged / 'Contents/Resources')
            (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundlePackageType': 'BNDL', 'CFBundleDevelopmentRegion': 'zh-Hans',
                'CFBundleLocalizations': ['zh-Hans', 'en'],
            }))
            resource_bundle = staged
        (work / 'main.swift').write_bytes((ROOT / 'scripts/verify-sparkle-language.swift').read_bytes())
        (work / 'Bundle.swift').write_text('import Foundation\nextension Bundle { static let module = Bundle(path: CommandLine.arguments[3])! }\n')
        catalog_file = work / 'sparkle-keys.json'
        catalog_file.write_text(json.dumps(list(chinese)))
        core_file = work / 'core-keys.json'
        core_file.write_text(json.dumps(list(tables[0])))
        executable = work / 'probe'
        subprocess.run(['swiftc', str(ROOT / 'Sources/CopyToolCore/Localization.swift'), str(work / 'Bundle.swift'),
                        str(work / 'main.swift'), '-D', 'SWIFT_PACKAGE', '-o', str(executable), '-Xlinker', '-sectcreate',
                        '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(work / 'Info.plist')],
                       check=True, capture_output=True, text=True)
        results = []
        for requested in ('default', 'zh-Hans', 'en'):
            result = json.loads(subprocess.check_output([str(executable), requested, str(framework.resolve()), str(resource_bundle.resolve()), str(app.resolve()) if app else '-', str(catalog_file), str(core_file)], text=True))
            expected = 'en' if requested == 'en' else 'zh-Hans'
            strings = [english.get(key, key) for key in staging.SPARKLE_CHINESE_KEYS] if expected == 'en' else [chinese[key] for key in staging.SPARKLE_CHINESE_KEYS]
            table = tables[1 if expected == 'en' else 0]
            if result['appLanguage'] != expected or result['appleLanguages'] != [expected] or result['hostLocalizations'] != [expected]:
                raise ValueError(f'应用语言选择不正确：{requested}')
            if result['sparkleStrings'] != strings or result['checkForUpdates'] != table['检查更新']:
                raise ValueError(f'应用或 Sparkle 实际译文不匹配：{requested}；{json.dumps(result, ensure_ascii=False)}')
            if result.pop('coreCatalog') != table:
                raise ValueError(f'Core 完整语言资源匹配失败：{requested}')
            if app:
                expected_name = staging.strings_table(app / 'Contents/Resources' / (expected + '.lproj') / 'InfoPlist.strings')['CFBundleDisplayName']
                if result['hostDisplayName'] != expected_name:
                    raise ValueError(f'宿主应用名称未使用所选语言：{requested}')
            expected_catalog = {key: english.get(key, key) for key in chinese} if expected == 'en' else chinese
            catalog = result.pop('sparkleCatalog')
            if catalog != expected_catalog:
                mismatches = {key: value for key, value in catalog.items() if value != expected_catalog.get(key)}
                raise ValueError(f'Sparkle 完整语言资源匹配失败：{requested}；{json.dumps(mismatches, ensure_ascii=False)}')
            result['checkedSparkleEntries'] = len(chinese)
            result['checkedCoreEntries'] = len(table)
            results.append(result)
        return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='可选：验证已打包 .app 的语言声明与真实嵌入资源')
    parser.add_argument('--framework', type=Path, help='可选：指定 Sparkle.framework')
    args = parser.parse_args()
    try:
        results = verify(args.app, args.framework)
        print(json.dumps(results, ensure_ascii=False, indent=2))
        print('默认简体中文、显式简体中文及英文的新进程资源选择均通过；未启动 GUI。')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Sparkle 本地化验证失败：{error}\n')


if __name__ == '__main__':
    main()
