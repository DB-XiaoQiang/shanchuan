#!/usr/bin/env python3
"""Generate a signed Sparkle feed; private update hosting is configured separately."""
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import quote, urlparse

root = pathlib.Path(__file__).resolve().parents[1]
archive = root / 'dist/Shanchuan-macos-arm64.zip'
feed = os.environ.get('SHANCHUAN_UPDATE_FEED') or 'https://github.com/DB-XiaoQiang/shanchuan/releases/latest/download/appcast.xml'
key = os.environ.get('SPARKLE_PRIVATE_KEY', '')
if not key:
    raise SystemExit('配置更新源后必须同时配置 SPARKLE_PRIVATE_KEY。')
if urlparse(feed).scheme != 'https':
    raise SystemExit('正式更新源必须使用 HTTPS。')
version = (root / 'VERSION').read_text().strip()
tag = os.environ.get('RELEASE_TAG') or 'v' + version
if tag != 'v' + version:
    raise SystemExit('appcast 标签和 VERSION 不一致。')
base = f'https://github.com/DB-XiaoQiang/shanchuan/releases/download/{tag}'
if urlparse(base).scheme != 'https':
    raise SystemExit('需要 MACOS_DOWNLOAD_BASE（更新包所在 HTTPS 目录）。')
tools = list((root / '.build/artifacts').glob('**/bin/sign_update'))
if len(tools) != 1:
    raise SystemExit('找不到唯一的 Sparkle sign_update 工具。')
with tempfile.TemporaryDirectory() as temp:
    secret = pathlib.Path(temp) / 'sparkle-key'
    secret.write_text(key)
    secret.chmod(0o600)
    result = subprocess.run([str(tools[0]), '--ed-key-file', str(secret), str(archive)],
                            capture_output=True, text=True, check=True)
match = re.search(r'sparkle:edSignature="([^"]+)"', result.stdout)
if not match:
    raise SystemExit('Sparkle 签名输出格式不正确。')
with (root / 'dist/闪传.app/Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
if info['CFBundleShortVersionString'] != version:
    raise SystemExit('macOS 包版本与 VERSION 不一致。')
embedded_key = info.get('SUPublicEDKey', '')
repository_key = (root / 'Resources/sparkle-public-key.txt').read_text().strip()
if not embedded_key or embedded_key != repository_key:
    raise SystemExit('应用内 Sparkle 公钥与仓库验签材料不一致。')
try:
    subprocess.run(['swift', str(root / 'scripts/verify-sparkle.swift'), str(archive),
                    match.group(1), embedded_key], capture_output=True, check=True)
except subprocess.CalledProcessError:
    raise SystemExit('Sparkle 更新包未通过应用内公钥验签，禁止发布。') from None

ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', version='2.0')
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = '闪传更新'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = '闪传 ' + info['CFBundleShortVersionString']
ET.SubElement(item, '{' + ns + '}version').text = info['CFBundleVersion']
ET.SubElement(item, '{' + ns + '}shortVersionString').text = info['CFBundleShortVersionString']
ET.SubElement(item, '{' + ns + '}minimumSystemVersion').text = '13.0'
ET.SubElement(item, 'enclosure', {
    'url': base.rstrip('/') + '/' + quote(archive.name),
    'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
    '{' + ns + '}edSignature': match.group(1),
})
ET.indent(rss)
ET.ElementTree(rss).write(root / 'dist/appcast.xml', encoding='utf-8', xml_declaration=True)
