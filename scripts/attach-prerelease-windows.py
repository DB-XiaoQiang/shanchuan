#!/usr/bin/env python3
"""把同一源码的成功主 CI Windows 附件补齐到预发布草稿；不创建或发布 Release。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.parse import quote
import zipfile

REPOSITORY = 'DB-XiaoQiang/shanchuan'
WORKFLOW_PATH = '.github/workflows/ci.yml'
ARTIFACT_NAME = 'Shanchuan-windows-x64'
MAC_ZIP = 'Shanchuan-macos-arm64.zip'
MAC_DMG = 'Shanchuan-macos-arm64.dmg'
CHECKSUMS = 'SHA256SUMS'
MAX_ARTIFACT_BYTES = 2 * 1024**3
MAX_UNCOMPRESSED_BYTES = 4 * 1024**3
MAX_INDEX_BYTES = 2 * 1024**2
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_tag(tag):
    require(isinstance(tag, str) and re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag),
            '标签必须为 vX.Y.Z，不能包含路径、前导零或额外内容。')
    version = tag[1:]
    require(all(int(part) <= 999999 for part in version.split('.')), '版本号超过客户端支持范围。')
    return version


def parse_run_id(value):
    require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]{0,18}', value), 'CI run id 必须为正整数。')
    return int(value)


def validate_version(tag, version_text):
    version = parse_tag(tag)
    require(isinstance(version_text, str) and version_text.strip() == version, '源码 VERSION 与标签不一致。')
    return version


def digest_value(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value), 'SHA-256 必须为 64 位小写十六进制。')
    return value


def api_digest(value):
    require(isinstance(value, str) and value.startswith('sha256:'), '远端附件缺少 GitHub SHA-256 摘要。')
    return digest_value(value[7:])


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024**2), b''):
            digest.update(chunk)
    return digest.hexdigest()


def windows_names(version):
    require(parse_tag('v' + version) == version, '版本无效。')
    return {
        'Shanchuan-win-x64-Setup.exe', 'Shanchuan-win-x64-Portable.zip', 'Shanchuan-win-x64.zip',
        f'Shanchuan-{version}-win-x64-full.nupkg', 'assets.win-x64.json',
        'RELEASES-win-x64', 'releases.win-x64.json',
    }


def validate_ci_run(run, jobs, workflow_id, checkout_sha, run_id):
    require(re.fullmatch(r'[0-9a-f]{40}', checkout_sha or ''), 'checkout SHA 必须为完整提交 SHA。')
    require(type(workflow_id) is int and workflow_id > 0 and isinstance(run, dict) and
            run.get('id') == run_id and run.get('repository', {}).get('full_name') == REPOSITORY and
            run.get('head_repository', {}).get('full_name') == REPOSITORY, 'CI 构建不属于指定源码仓库。')
    require(run.get('status') == 'completed' and run.get('conclusion') == 'success', 'CI 必须已经全部成功。')
    require(run.get('head_branch') == 'main' and run.get('event') in {'push', 'workflow_dispatch'} and
            run.get('path') == WORKFLOW_PATH and run.get('workflow_id') == workflow_id,
            '只能使用本仓库 main 的主 CI 构建，不能使用 PR、分支或其他工作流。')
    require(run.get('head_sha') == checkout_sha, 'CI 源码与 checkout SHA 不一致。')
    names = [job.get('name') for job in jobs]
    require(len(names) == len(set(names)) and {'windows', 'macos', 'release-tools'} <= set(names) and
            all(job.get('status') == 'completed' and job.get('conclusion') == 'success' for job in jobs),
            '主 CI 的双端构建和发行工具检查必须全部成功。')


def select_artifact(artifacts, run_id, checkout_sha, repository_id):
    matching = [item for item in artifacts if item.get('name') == ARTIFACT_NAME]
    require(len(matching) == 1, '指定 CI 必须恰好包含一份 Windows x64 构建附件。')
    artifact = matching[0]
    require(type(artifact.get('id')) is int and artifact['id'] > 0 and artifact.get('expired') is False and
            type(artifact.get('size_in_bytes')) is int and 0 < artifact['size_in_bytes'] <= MAX_ARTIFACT_BYTES,
            'Windows 构建附件已过期或大小无效。')
    source = artifact.get('workflow_run', {})
    require(source.get('id') == run_id and source.get('head_sha') == checkout_sha and
            source.get('repository_id') == repository_id and source.get('head_repository_id') == repository_id,
            'Windows artifact 来源与 CI 提交或仓库不一致。')
    api_digest(artifact.get('digest'))
    return artifact


def release_assets(release, tag, checkout_sha, mac_digests):
    require(release.get('tag_name') == tag and release.get('draft') is True and release.get('prerelease') is True,
            '仅允许补齐已存在的预发布草稿；公开 Release 或正式通道均拒绝。')
    require(type(release.get('id')) is int and release['id'] > 0 and release.get('target_commitish') == checkout_sha,
            '草稿必须以完整 SHA 指向同一 CI 和 checkout 提交。')
    allowed = windows_names(parse_tag(tag)) | {MAC_ZIP, MAC_DMG, CHECKSUMS}
    assets = release.get('assets')
    require(isinstance(assets, list), 'Release 附件列表无效。')
    found = {}
    folded = set()
    for asset in assets:
        name = asset.get('name')
        require(name in allowed and name.casefold() not in folded, '草稿包含非预期或重复附件，拒绝修改。')
        require(asset.get('state') == 'uploaded' and type(asset.get('size')) is int and asset['size'] > 0,
                '草稿中存在未完成或大小无效的附件。')
        api_digest(asset.get('digest'))
        found[name] = asset
        folded.add(name.casefold())
    require(set(mac_digests) == {MAC_ZIP, MAC_DMG}, '必须同时提供 Mac ZIP 和 DMG 摘要。')
    for name, expected in mac_digests.items():
        require(name in found and api_digest(found[name]['digest']) == digest_value(expected),
                f'Mac 附件缺失或摘要不符：{name}。')
    return found


def archive_members(members, version):
    expected = windows_names(version)
    found = {}
    total = 0
    paths = set()
    for member in members:
        name = member.filename
        require(name.casefold() not in paths, 'Windows artifact 包含重复路径。')
        paths.add(name.casefold())
        path = PurePosixPath(name)
        require(name and '\\' not in name and not any(ord(c) < 32 for c in name) and
                not path.is_absolute() and all(part not in {'.', '..'} for part in name.split('/') if part),
                'Windows artifact 包含不安全路径。')
        filetype = stat.S_IFMT(member.external_attr >> 16)
        require(filetype not in {stat.S_IFLNK, stat.S_IFCHR, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK} and
                not (member.external_attr & 0x400), 'Windows artifact 包含符号链接或特殊文件。')
        if member.is_dir():
            require(name == 'releases/' and filetype in {0, stat.S_IFDIR}, 'Windows artifact 包含非预期目录。')
            continue
        require(filetype in {0, stat.S_IFREG}, 'Windows artifact 文件类型无效。')
        basename = path.name
        require(basename in expected and name in {basename, 'releases/' + basename} and basename not in found,
                'Windows artifact 包含非预期文件、嵌套目录或重复文件名。')
        require(0 < member.file_size <= MAX_ARTIFACT_BYTES, 'Windows artifact 文件大小无效。')
        total += member.file_size
        require(total <= MAX_UNCOMPRESSED_BYTES, 'Windows artifact 解压总大小超过限制。')
        found[basename] = member
    require(set(found) == expected, 'Windows artifact 未包含且仅包含本版本的七个规范文件。')
    return found


def unpack_artifact(archive, output, version, expected_digest):
    require(archive.stat().st_size <= MAX_ARTIFACT_BYTES and sha256(archive) == digest_value(expected_digest),
            '下载的 Windows artifact 与 GitHub artifact 摘要不一致。')
    with zipfile.ZipFile(archive) as zipped:
        members = archive_members(zipped.infolist(), version)
        output.mkdir()
        for name, member in members.items():
            with zipped.open(member) as source, (output / name).open('xb') as target:
                shutil.copyfileobj(source, target, 1024**2)
            require((output / name).stat().st_size == member.file_size, 'Windows artifact 文件未完整解压。')
    return {name: output / name for name in members}


def read_index(path):
    require(path.stat().st_size <= MAX_INDEX_BYTES, 'Windows 更新索引过大。')
    # Duplicate properties must not create different views for this validator and Velopack.
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Windows 更新索引包含重复字段。')
            result[key] = value
        return result
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=unique)


def validate_windows_files(files, version):
    require(set(files) == windows_names(version), 'Windows 附件集合不匹配。')
    require(all(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= MAX_ARTIFACT_BYTES for path in files.values()),
            'Windows 附件必须是完整的常规文件，不能为符号链接。')
    hashes = {name: sha256(path) for name, path in files.items()}
    full_name = f'Shanchuan-{version}-win-x64-full.nupkg'
    full = files[full_name]
    with full.open('rb') as source:
        sha1 = hashlib.file_digest(source, 'sha1').hexdigest()
    feed = read_index(files['releases.win-x64.json'])
    require(isinstance(feed, dict) and isinstance(feed.get('Assets'), list) and len(feed['Assets']) == 1,
            'Velopack 更新索引必须仅引用本版唯一完整包。')
    entry = feed['Assets'][0]
    require(isinstance(entry, dict) and entry.get('PackageId') == 'Shanchuan' and entry.get('Type') == 'Full' and
            entry.get('Version') == version and entry.get('FileName') == full_name and
            type(entry.get('Size')) is int and entry['Size'] == full.stat().st_size and
            str(entry.get('SHA256', '')).lower() == hashes[full_name] and str(entry.get('SHA1', '')).lower() == sha1,
            'Windows 更新索引的产品、版本、文件名、大小或摘要不一致。')
    assets = read_index(files['assets.win-x64.json'])
    require(isinstance(assets, list) and len(assets) == 3 and all(isinstance(item, dict) for item in assets) and
            {(item.get('RelativeFileName'), item.get('Type')) for item in assets} == {
                ('Shanchuan-win-x64-Setup.exe', 'Installer'), (full_name, 'Full'),
                ('Shanchuan-win-x64-Portable.zip', 'Portable')}, 'Windows 发行附件索引引用了非本版文件。')
    release_index = files['RELEASES-win-x64']
    require(release_index.stat().st_size <= MAX_INDEX_BYTES, 'RELEASES 索引过大。')
    lines = release_index.read_text(encoding='utf-8-sig').splitlines()
    parts = lines[0].split() if len(lines) == 1 else []
    require(len(parts) == 3 and parts[0].lower() == sha1 and parts[1:] == [full_name, str(full.stat().st_size)],
            'RELEASES 索引的包名、大小或 SHA-1 不匹配。')
    return hashes


def checksum_bytes(hashes, version):
    require(set(hashes) == windows_names(version) | {MAC_ZIP, MAC_DMG}, '校验文件必须仅覆盖七个 Windows 附件和两个 Mac 附件。')
    return ''.join(f'{digest_value(hashes[name])}  {name}\n' for name in sorted(hashes)).encode('ascii')


def attachment_plan(release, tag, checkout_sha, files, hashes, mac_digests):
    found = release_assets(release, tag, checkout_sha, mac_digests)
    require(set(files) == set(hashes) == windows_names(parse_tag(tag)), 'Windows 文件和摘要集合无效。')
    sums = checksum_bytes(hashes | mac_digests, parse_tag(tag))
    expected = {name: (hashes[name], files[name].stat().st_size) for name in files}
    expected[CHECKSUMS] = (hashlib.sha256(sums).hexdigest(), len(sums))
    missing = []
    for name, (digest, size) in expected.items():
        if name in found:
            require(api_digest(found[name]['digest']) == digest and found[name]['size'] == size,
                    f'已有附件与本次内容不同，拒绝覆盖：{name}。')
        else:
            missing.append(name)
    return missing, sums


class GitHub:
    def json(self, endpoint):
        try:
            result = subprocess.run(['gh', 'api', '--method', 'GET', endpoint], check=True, capture_output=True)
        except subprocess.CalledProcessError as error:
            raise ValueError('无法读取 GitHub 元数据，未尝试更换凭据。') from error
        return json.loads(result.stdout)

    def pages(self, endpoint, key):
        result = []
        for page in range(1, 101):
            separator = '&' if '?' in endpoint else '?'
            data = self.json(f'{endpoint}{separator}per_page=100&page={page}')
            values = data[key] if key else data
            require(isinstance(values, list), 'GitHub 分页返回无效。')
            result.extend(values)
            if len(values) < 100:
                return result
        raise ValueError('GitHub 列表超过安全分页上限。')

    def release(self, tag):
        # REST by-tag does not return drafts. Enumerate releases instead.
        matching = [item for item in self.pages(f'repos/{REPOSITORY}/releases', None) if item.get('tag_name') == tag]
        require(len(matching) == 1, '必须预先创建唯一的预发布草稿，脚本不会创建 Release。')
        return self.refresh_release(matching[0]['id'])

    def refresh_release(self, release_id):
        release = self.json(f'repos/{REPOSITORY}/releases/{release_id}')
        release['assets'] = self.pages(f'repos/{REPOSITORY}/releases/{release_id}/assets', None)
        return release

    def download(self, artifact_id, destination):
        with destination.open('xb') as output:
            try:
                subprocess.run(['gh', 'api', '--method', 'GET',
                                f'repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip'],
                               stdout=output, stderr=subprocess.PIPE, check=True)
            except subprocess.CalledProcessError as error:
                raise ValueError('Windows artifact 下载失败。') from error

    def upload(self, release_id, name, path):
        endpoint = f'https://uploads.github.com/repos/{REPOSITORY}/releases/{release_id}/assets?name={quote(name, safe="")}'
        try:
            result = subprocess.run(['gh', 'api', '--method', 'POST', endpoint,
                                     '--header', 'Content-Type: application/octet-stream', '--input', str(path)],
                                    check=True, capture_output=True)
        except subprocess.CalledProcessError as error:
            raise ValueError(f'附件上传失败，未尝试覆盖或删除：{name}。') from error
        return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--ci-run-id', required=True)
    parser.add_argument('--mac-zip-sha256', required=True)
    parser.add_argument('--mac-dmg-sha256', required=True)
    args = parser.parse_args()
    try:
        version = parse_tag(args.tag)
        run_id = parse_run_id(args.ci_run_id)
        require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and
                os.environ.get('GH_TOKEN'), '仅在指定仓库的手动工作流中使用 github.token 执行。')
        mac = {MAC_ZIP: digest_value(args.mac_zip_sha256), MAC_DMG: digest_value(args.mac_dmg_sha256)}
        validate_version(args.tag, (ROOT / 'VERSION').read_text())
        checkout_sha = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], check=True,
                                      capture_output=True, text=True).stdout.strip()
        api = GitHub()
        run = api.json(f'repos/{REPOSITORY}/actions/runs/{run_id}')
        workflow = api.json(f'repos/{REPOSITORY}/actions/workflows/ci.yml')
        jobs = api.pages(f'repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest', 'jobs')
        validate_ci_run(run, jobs, workflow['id'], checkout_sha, run_id)
        release = api.release(args.tag)
        release_assets(release, args.tag, checkout_sha, mac)
        artifact = select_artifact(api.pages(f'repos/{REPOSITORY}/actions/runs/{run_id}/artifacts', 'artifacts'),
                                   run_id, checkout_sha, run['repository']['id'])
        print('已验证成功主 CI、checkout 与预发布草稿的源码一致。')
        with tempfile.TemporaryDirectory(prefix='shanchuan-prerelease-windows-', dir=os.environ.get('RUNNER_TEMP')) as work:
            work = Path(work)
            archive = work / 'artifact.zip'
            api.download(artifact['id'], archive)
            files = unpack_artifact(archive, work / 'windows', version, api_digest(artifact['digest']))
            hashes = validate_windows_files(files, version)
            missing, sums = attachment_plan(release, args.tag, checkout_sha, files, hashes, mac)
            sums_path = work / CHECKSUMS
            sums_path.write_bytes(sums)
            uploads = files | {CHECKSUMS: sums_path}
            print('七个 Windows 文件及三份索引校验通过；Mac 文件只核对远端摘要。')
            for name in sorted(windows_names(version)) + [CHECKSUMS]:
                # Recheck state and conflicts immediately before every mutation.
                current = api.refresh_release(release['id'])
                missing, _ = attachment_plan(current, args.tag, checkout_sha, files, hashes, mac)
                if name not in missing:
                    print('附件已存在且摘要一致，跳过：' + name)
                    continue
                uploaded = api.upload(release['id'], name, uploads[name])
                require(uploaded.get('name') == name and uploaded.get('state') == 'uploaded' and
                        uploaded.get('size') == uploads[name].stat().st_size and
                        api_digest(uploaded.get('digest')) == sha256(uploads[name]), '上传响应的附件名称、大小或摘要不符。')
                print('已补齐草稿附件：' + name)
            remaining, _ = attachment_plan(api.refresh_release(release['id']), args.tag, checkout_sha, files, hashes, mac)
            require(not remaining, '草稿仍缺少预期附件。')
        print('草稿附件准备完成；未发布、未修改标签，Mac 资源未上传或更改。')
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, '预发布附件准备失败：' + str(error) + '\n')


if __name__ == '__main__':
    main()
