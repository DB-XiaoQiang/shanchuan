#!/usr/bin/env python3
"""编译并签名独立的更新界面预览应用；不会启动 GUI、联网更新或安装软件。"""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def build(output, framework, identity):
    if sys.platform != 'darwin':
        raise ValueError('更新界面预览需要 macOS。')
    output, framework = Path(output), Path(framework)
    if output.exists() or output.is_symlink():
        raise ValueError('预览输出目录已存在，拒绝覆盖。')
    if output.suffix != '.app':
        raise ValueError('预览输出必须为一个新的 .app 路径。')
    output, framework = output.resolve(), framework.resolve()
    if not framework.is_dir():
        raise ValueError('找不到待复制的 Sparkle.framework，请先生成项目安装包或指定 --framework。')
    if not identity:
        found = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        matches = re.findall(r'([0-9A-F]{40}) "Apple Development:[^"]+"', found)
        if len(matches) != 1:
            raise ValueError('请用 --identity 指定稳定的本机代码签名身份。')
        identity = matches[0]
    if identity == '-':
        raise ValueError('预览应用需要稳定签名身份，不使用 ad hoc 签名。')
    with tempfile.TemporaryDirectory(prefix='shanchuan-update-preview-build-') as temporary:
        work = Path(temporary)
        app = work / '闪传更新界面预览.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        resources = contents / 'Resources'
        resources.mkdir()
        framework_copy = contents / 'Frameworks/Sparkle.framework'
        shutil.copytree(framework, framework_copy, symlinks=True)
        resource_bundle = resources / 'CopyTool_CopyToolCore.bundle'
        shutil.copytree(ROOT / 'Sources/CopyToolCore/Resources', resource_bundle / 'Contents/Resources')
        (resource_bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundlePackageType': 'BNDL', 'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans', 'en'],
        }))
        shutil.copyfile(ROOT / 'Resources/AppIcon.icns', resources / 'AppIcon.icns')
        version = (ROOT / 'VERSION').read_text().strip()
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.copytool.update-dialog-preview', 'CFBundleName': '闪传更新界面预览',
            'CFBundleDisplayName': '闪传更新界面预览', 'CFBundleExecutable': 'UpdateDialogPreview',
            'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon.icns',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': version, 'LSMinimumSystemVersion': '13.0',
            'NSPrincipalClass': 'NSApplication', 'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans', 'en'],
        }))
        sources = []
        for name in ['Sources/CopyToolCore/Localization.swift', 'Sources/CopyToolApp/LocalizedUpdatePresentation.swift',
                     'Sources/CopyToolApp/LocalizedUpdateUserDriver.swift', 'scripts/preview-update-dialogs.swift']:
            source = work / Path(name).name
            source.write_text((ROOT / name).read_text().replace('import CopyToolCore\n', ''))
            sources.append(str(source))
        shim = work / 'Bundle.swift'
        shim.write_text('import Foundation\nextension Bundle { static let module = Bundle(url: Bundle.main.resourceURL!.appendingPathComponent("CopyTool_CopyToolCore.bundle"))! }\n')
        sources.append(str(shim))
        subprocess.run(['swiftc', '-parse-as-library', '-D', 'SWIFT_PACKAGE', '-target', 'arm64-apple-macosx13.0',
                        *sources, '-F', str(framework.parent), '-framework', 'Sparkle',
                        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                        '-o', str(contents / 'MacOS/UpdateDialogPreview')], check=True)
        sparkle = framework_copy / 'Versions/B'
        for target in [sparkle / 'XPCServices/Downloader.xpc', sparkle / 'XPCServices/Installer.xpc',
                       sparkle / 'Autoupdate', sparkle / 'Updater.app', framework_copy, app]:
            command = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp']
            if target != app:
                command.append('--preserve-metadata=identifier,entitlements')
            subprocess.run([*command, str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(app, output, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
        print(output)
        print('已生成独立预览应用。请通过访达打开；此工具没有启动 GUI。按钮仅记录预览回调，不安装、不重启。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='尚不存在的 .app 输出路径')
    parser.add_argument('--framework', type=Path, default=ROOT / 'dist/闪传.app/Contents/Frameworks/Sparkle.framework')
    parser.add_argument('--identity', default='')
    args = parser.parse_args()
    try:
        build(args.output, args.framework, args.identity)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'预览应用生成失败：{error}\n')


if __name__ == '__main__':
    main()
