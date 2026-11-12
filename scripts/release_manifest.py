#!/usr/bin/env python3
"""为正式发行生成跨平台签名清单；私钥仅从发布环境读取。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MAX_MANIFEST = 256 * 1024


def openssl(*args):
    return subprocess.run(['openssl', *map(str, args)], capture_output=True, check=True).stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def check_feed(directory, version):
    full = directory / f'Shanchuan-{version}-win-x64-full.nupkg'
    feed = json.loads((directory / 'releases.win-x64.json').read_bytes())
    assets = feed.get('Assets')
    if not isinstance(assets, list) or len(assets) != 1:
        raise ValueError('稳定通道索引必须只包含本次完整更新包。')
    entry = assets[0]
    if entry.get('PackageId') != 'Shanchuan' or entry.get('FileName') != full.name or entry.get('Version') != version or entry.get('Type') != 'Full':
        raise ValueError('Windows 更新索引与发行版本不一致。')
    if entry.get('Size') != full.stat().st_size:
        raise ValueError('Windows 更新索引中的包大小不一致。')
    digest = sha256(full)
    if entry.get('SHA256', '').lower() != digest:
        raise ValueError('Windows 更新索引缺少匹配的 SHA256。')


def check_appcast(directory, version):
    path = directory / 'appcast.xml'
    if path.stat().st_size > MAX_MANIFEST:
        raise ValueError('appcast 过大。')
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    item = ET.fromstring(path.read_bytes()).find('./channel/item')
    if item is None or item.findtext(ns + 'shortVersionString') != version:
        raise ValueError('macOS appcast 版本与发行版本不一致。')
    enclosure = item.find('enclosure')
    expected = f'https://github.com/DB-XiaoQiang/shanchuan/releases/download/v{version}/Shanchuan-macos-arm64.zip'
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('macOS appcast 必须指向本仓库固定版本更新包。')
    if enclosure.get('length') != str((directory/'Shanchuan-macos-arm64.zip').stat().st_size):
        raise ValueError('macOS appcast 更新包长度不一致。')
    if len(base64.b64decode(enclosure.get(ns+'edSignature',''), validate=True)) != 64:
        raise ValueError('macOS appcast 缺少有效格式的 Sparkle 签名。')


def create_manifest(directory, version, notes, private_key, public_key):
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version):
        raise ValueError('正式版本必须为三段非负整数。')
    if any(int(part) > 999999 for part in version.split('.')) or len(notes.encode('utf-8')) > 64 * 1024:
        raise ValueError('版本段或更新说明超过客户端支持上限。')
    files = [
        ('windows', 'x64', 'velopack-full', f'Shanchuan-{version}-win-x64-full.nupkg'),
        ('windows', 'x64', 'velopack-feed', 'releases.win-x64.json'),
        ('windows', 'x64', 'setup', 'Shanchuan-win-x64-Setup.exe'),
        ('windows', 'x64', 'portable', 'Shanchuan-win-x64-Portable.zip'),
        ('macos', 'arm64', 'sparkle-zip', 'Shanchuan-macos-arm64.zip'),
        ('macos', 'arm64', 'dmg', 'Shanchuan-macos-arm64.dmg'),
        ('macos', 'arm64', 'appcast', 'appcast.xml'),
    ]
    check_feed(directory, version)
    check_appcast(directory, version)
    assets = []
    for platform, arch, kind, name in files:
        path = directory / name
        if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 2 * 1024 * 1024 * 1024:
            raise ValueError(f'缺少完整发行附件：{name}')
        digest = sha256(path)
        assets.append(dict(platform=platform, arch=arch, kind=kind, name=name,
                           size=path.stat().st_size, sha256=digest))
    data = (json.dumps(dict(schemaVersion=1, product='Shanchuan', channel='stable', version=version,
                            releaseNotes=notes, assets=assets), ensure_ascii=False,
                       separators=(',', ':')) + '\n').encode('utf-8')
    if len(data) > MAX_MANIFEST:
        raise ValueError('发行清单超过 256 KiB。')
    with tempfile.TemporaryDirectory(prefix='shanchuan-manifest-') as temporary:
        key = Path(temporary) / 'key.pem'
        key.write_text(private_key)
        key.chmod(0o600)
        manifest = Path(temporary) / 'manifest.json'
        manifest.write_bytes(data)
        signature = Path(temporary) / 'signature.der'
        openssl('dgst', '-sha256', '-sign', key, '-out', signature, manifest)
        openssl('dgst', '-sha256', '-verify', public_key, '-signature', signature, manifest)
        (directory / 'update-manifest.json').write_bytes(data)
        (directory / 'update-manifest.sig').write_bytes(signature.read_bytes())
    return len(assets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--version', default=(ROOT / 'VERSION').read_text().strip())
    parser.add_argument('--notes-file', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, default=ROOT / 'Resources/update-public-key.pem')
    args = parser.parse_args()
    try:
        key = os.environ.get('UPDATE_MANIFEST_PRIVATE_KEY', '')
        if not key:
            raise ValueError('缺少 UPDATE_MANIFEST_PRIVATE_KEY，禁止生成正式更新清单。')
        count = create_manifest(args.directory.resolve(), args.version,
                                args.notes_file.read_text(), key, args.public_key)
        print(f'发行清单签名及公钥复验通过，共 {count} 个附件。')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # 不输出 OpenSSL 的输入、私钥或环境内容。
        parser.exit(1, f'发行清单生成失败：{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()
