#!/usr/bin/env python3
"""只读检查同一提交已公开且附件完整的发行，避免标签重复发布。"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request


def validate_release(release, tag, source, channel):
    if channel not in {'draft', 'prerelease', 'stable', 'unnotarized'}:
        raise ValueError('发布通道无效。')
    if release.get('draft') is True:
        return False
    if (release.get('tag_name') != tag or release.get('draft') is not False
            or release.get('target_commitish') != source):
        raise ValueError('已有发行的标签或源码与本次提交不一致。')
    expected_pre = channel == 'prerelease'
    if channel == 'draft' or release.get('prerelease') is not expected_pre:
        raise ValueError('已有发行的公开状态与指定通道不一致。')
    version = tag[1:]
    expected = {'Shanchuan-macos-arm64.zip', 'Shanchuan-macos-arm64.dmg',
                'Shanchuan-win-x64.zip', 'Shanchuan-win-x64-Portable.zip',
                'Shanchuan-win-x64-Setup.exe', f'Shanchuan-{version}-win-x64-full.nupkg',
                'RELEASES-win-x64', 'releases.win-x64.json', 'assets.win-x64.json', 'SHA256SUMS'}
    if not expected_pre:
        expected |= {'appcast.xml', 'update-manifest.json', 'update-manifest.sig'}
    assets = release.get('assets', [])
    if len(assets) != len(expected) or {a.get('name') for a in assets} != expected:
        raise ValueError('已有公开发行的附件不完整或重复。')
    for asset in assets:
        if (asset.get('state') != 'uploaded' or type(asset.get('id')) is not int
                or asset['id'] <= 0 or type(asset.get('size')) is not int or asset['size'] <= 0
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', asset.get('digest', ''))):
            raise ValueError('已有公开发行的附件尚未上传完成或摘要无效。')
    return True


def validate_checksums(data, assets):
    by_name = {a['name']: a for a in assets}
    if hashlib.sha256(data).hexdigest() != by_name['SHA256SUMS']['digest'][7:]:
        raise ValueError('公开校验文件摘要不一致。')
    found = {}
    for line in data.decode('utf-8').splitlines():
        digest, name = line.split(maxsplit=1)
        name = name.strip().removeprefix('./')
        if name in found or not re.fullmatch(r'[a-f0-9]{64}', digest):
            raise ValueError('公开校验文件包含无效或重复项目。')
        found[name] = digest
    if set(found) != set(by_name) - {'SHA256SUMS'}:
        raise ValueError('公开校验文件未覆盖全部发行附件。')
    if any(by_name[name]['digest'] != 'sha256:' + digest for name, digest in found.items()):
        raise ValueError('公开附件与校验文件不一致。')


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    tag = os.environ['RELEASE_TAG']
    if repo != 'DB-XiaoQiang/shanchuan' or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('发行仓库或标签无效。')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    channel = Path('RELEASE_CHANNEL').read_text().strip()
    def read(endpoint, accept='application/vnd.github+json'):
        if accept == 'application/octet-stream':
            return subprocess.check_output(['gh', 'api', '--method', 'GET',
                'repos/' + repo + '/' + endpoint, '-H', 'Accept: application/octet-stream'])
        request = urllib.request.Request('https://api.github.com/repos/' + repo + '/' + endpoint,
            headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                     'Accept': accept, 'User-Agent': 'Shanchuan-release-check'})
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.read(256 * 1024 + 1)
    try:
        release = json.loads(read('releases/tags/' + tag))
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        print('published=false')
        return
    if not validate_release(release, tag, source, channel):
        print('published=false')
        return
    checksum = next(a for a in release['assets'] if a['name'] == 'SHA256SUMS')
    if checksum['size'] > 256 * 1024:
        raise ValueError('公开校验文件超过大小上限。')
    data = read('releases/assets/' + str(checksum['id']), 'application/octet-stream')
    validate_checksums(data, release['assets'])
    print('published=true')


if __name__ == '__main__':
    main()
