#!/usr/bin/env python3
"""在应用签名前加入双语资源和宿主语言声明，保留 Sparkle 自带翻译。"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil


SUPPORTED_LANGUAGES = ('zh-Hans', 'en')
RESOURCE_BUNDLE_NAME = 'CopyTool_CopyToolCore.bundle'
SPARKLE_CHINESE_KEYS = ('Updating %@', 'Ready to Install', 'Install and Relaunch')
# Sparkle 2.10.1 的官方简体中文表暂缺这五个新增键；仅补签名前的打包副本。
SPARKLE_CHINESE_SUPPLEMENTS = {
    '%1$@ %2$@ is available but this update requires a new Apple silicon Mac.': '%1$@ %2$@ 已发布，但此次更新需要搭载 Apple 芯片的新款 Mac。',
    'The update feed is improperly signed and could not be validated. Please try again later or contact the app developer.': '更新信息的签名无效，无法完成验证。请稍后重试，或联系应用开发者。',
    'Your Mac is too old': '您的 Mac 型号过旧',
    'The release notes is improperly signed and could not be validated. Please contact the app developer for more information.': '更新说明的签名无效，无法完成验证。请联系应用开发者了解详情。',
    'An error occurred while downloading the release notes.': '下载更新说明时发生错误。',
}


def strings_table(path):
    data = Path(path).read_bytes()
    if data.startswith(b'bplist') or data.lstrip().startswith(b'<?xml'):
        result = plistlib.loads(data)
    else:
        # SwiftPM sources use quoted OpenStep string pairs; JSON escapes are a subset.
        source = data.decode('utf-8-sig')
        pattern = r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;'
        matches = list(re.finditer(pattern, source))
        remaining = re.sub(r'/\*.*?\*/|//[^\n]*', '', re.sub(pattern, '', source), flags=re.S)
        if remaining.strip():
            raise ValueError(f'本地化字符串格式无效：{Path(path).name}')
        pairs = [(json.loads(match[1]), json.loads(match[2])) for match in matches]
        if len({key for key, _ in pairs}) != len(pairs):
            raise ValueError(f'本地化资源存在重复键：{Path(path).name}')
        result = dict(pairs)
    if not isinstance(result, dict) or not result or any(
            not isinstance(key, str) or not isinstance(value, str) or not value.strip()
            for key, value in result.items()):
        raise ValueError(f'本地化资源为空或无效：{Path(path).name}')
    return result


def localization_directory(bundle, language):
    bundle = Path(bundle)
    resources = bundle / 'Contents/Resources'
    if not resources.is_dir():
        resources = bundle
    result = next((path for path in resources.glob('*.lproj')
                   if path.stem.lower() == language.lower()), None)
    if result is None:
        raise ValueError(f'缺少语言资源：{language}')
    return result


def validate_core_resources(bundle):
    tables = [strings_table(localization_directory(bundle, language) / 'Localizable.strings')
              for language in SUPPORTED_LANGUAGES]
    if tables[0].keys() != tables[1].keys():
        raise ValueError('简体中文与英文资源键不完整。')
    return tables


def validate_sparkle_resources(app):
    resources = Path(app) / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources'
    chinese = strings_table(resources / 'zh_CN.lproj/Sparkle.strings')
    for key in SPARKLE_CHINESE_KEYS:
        if key not in chinese or chinese[key] == key:
            raise ValueError(f'Sparkle 缺少简体中文更新文案：{key}')


def supplement_sparkle_chinese(app):
    table_path = Path(app) / 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings'
    table = strings_table(table_path)
    for key, translation in SPARKLE_CHINESE_SUPPLEMENTS.items():
        if key not in table or table[key] == key:
            table[key] = translation
    table_path.write_bytes(plistlib.dumps(table, fmt=plistlib.FMT_BINARY, sort_keys=False))


def stage_localizations(app, resource_bundle):
    app, resource_bundle = Path(app), Path(resource_bundle)
    if app.is_symlink() or not app.is_dir() or resource_bundle.is_symlink():
        raise ValueError('应用或资源路径无效，不接受符号链接。')
    if resource_bundle.name != RESOURCE_BUNDLE_NAME:
        raise ValueError('SwiftPM 本地化资源包名称不匹配。')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier') not in {'local.copytool.independent', 'local.copytool.update-test'}:
        raise ValueError('拒绝修改未知应用的本地化信息。')
    validate_core_resources(resource_bundle)
    validate_sparkle_resources(app)
    destination = app / 'Contents/Resources' / RESOURCE_BUNDLE_NAME
    if destination.exists() or destination.is_symlink():
        raise ValueError('目标资源包已存在，拒绝覆盖。')
    supplement_sparkle_chinese(app)
    shutil.copytree(resource_bundle, destination, symlinks=True)
    names = {'zh-Hans': '闪传', 'en': 'Shanchuan'} if info['CFBundleIdentifier'] == 'local.copytool.independent' else {
        'zh-Hans': '闪传更新测试', 'en': 'Shanchuan Update Test'
    }
    for language, name in names.items():
        directory = app / 'Contents/Resources' / (language + '.lproj')
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'InfoPlist.strings').write_text(''.join(
            json.dumps(key) + ' = ' + json.dumps(name, ensure_ascii=False) + ';\n'
            for key in ('CFBundleName', 'CFBundleDisplayName')), encoding='utf-8')
    info['CFBundleDevelopmentRegion'] = 'zh-Hans'
    info['CFBundleLocalizations'] = list(SUPPORTED_LANGUAGES)
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('resource_bundle', type=Path)
    args = parser.parse_args()
    try:
        stage_localizations(args.app, args.resource_bundle)
        print('已加入简体中文与英文资源，Sparkle 中文更新文案检查通过。')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'本地化打包失败：{error}\n')


if __name__ == '__main__':
    main()
