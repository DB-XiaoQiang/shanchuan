#!/usr/bin/env python3
"""为既有草稿补齐未公证发行的签名更新源；不发布、不修改标签或包。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import unicodedata
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


attachment = module('unnotarized_attachment', 'attach-prerelease-windows.py')
manifest_tools = module('unnotarized_manifest', 'release_manifest.py')
require = attachment.require
REPOSITORY = attachment.REPOSITORY
EXTRAS = {'appcast.xml', 'update-manifest.json', 'update-manifest.sig'}
APP_NAME = '闪传.app'
MAX_MAC_BYTES = 512 * 1024**2
MAX_ZIP_MEMBERS = 20000
MAX_CHECKSUM_BYTES = 64 * 1024


def base_names(version):
    return attachment.windows_names(version) | {attachment.MAC_ZIP, attachment.MAC_DMG}


def draft_assets(release, tag, checkout_sha, mac):
    version = attachment.parse_tag(tag)
    require(re.fullmatch(r'[a-f0-9]{40}', checkout_sha or ''), '需要完整源码 SHA。')
    require(release.get('tag_name') == tag and release.get('draft') is True and release.get('prerelease') is True,
            '只能准备既有预发布草稿；公开发行或非预发布草稿均拒绝修改。')
    require(type(release.get('id')) is int and release['id'] > 0 and release.get('target_commitish') == checkout_sha,
            '草稿必须以完整 SHA 指向同一已验证源码。')
    require(set(mac) == {attachment.MAC_ZIP, attachment.MAC_DMG}, '需要两个 Mac 包的摘要。')
    allowed = base_names(version) | EXTRAS | {attachment.CHECKSUMS}
    values = release.get('assets')
    require(isinstance(values, list), '草稿附件列表无效。')
    found, folded = {}, set()
    for item in values:
        name = item.get('name')
        require(name in allowed and name.casefold() not in folded, '草稿包含未知或重复附件。')
        require(type(item.get('id')) is int and item['id'] > 0 and item.get('state') == 'uploaded' and
                type(item.get('size')) is int and 0 < item['size'] <= attachment.MAX_ARTIFACT_BYTES,
                '草稿存在未完成、无效或过大的附件。')
        attachment.api_digest(item.get('digest'))
        if name == attachment.CHECKSUMS:
            require(item['size'] <= MAX_CHECKSUM_BYTES, '既有校验文件过大。')
        elif name in {'appcast.xml', 'update-manifest.json'}:
            require(item['size'] <= manifest_tools.MAX_MANIFEST, '既有更新元数据过大。')
        elif name == 'update-manifest.sig':
            require(item['size'] <= 256, '既有清单签名过大。')
        found[name] = item
        folded.add(name.casefold())
    require(base_names(version) <= set(found), '必须先补齐九个 Mac/Windows 基础包。')
    for name, digest in mac.items():
        require(attachment.api_digest(found[name]['digest']) == attachment.digest_value(digest), 'Mac 包摘要与指定输入不一致。')
        require(found[name]['size'] <= MAX_MAC_BYTES, 'Mac 包大小超过上限。')
    return found


def checksum_bytes(hashes):
    return ''.join(f'{attachment.digest_value(hashes[name])}  {name}\n' for name in sorted(hashes)).encode('ascii')


def validate_checksum(data, found, version):
    require(isinstance(data, bytes) and 0 < len(data) <= MAX_CHECKSUM_BYTES, '既有校验文件大小无效。')
    base = {name: attachment.api_digest(found[name]['digest']) for name in base_names(version)}
    accepted = [checksum_bytes(base)]
    if EXTRAS <= set(found):
        accepted.append(checksum_bytes(base | {name: attachment.api_digest(found[name]['digest']) for name in EXTRAS}))
    require(data in accepted, '既有校验文件并非本次九个基础包或十二个最终附件的准确校验。')


def archive_name(member):
    # ditto's archives can contain UTF-8 filename bytes without setting ZIP's
    # UTF-8 flag. Python otherwise displays those bytes as CP437 mojibake.
    name = member.filename
    if not member.flag_bits & 0x800:
        try:
            name = name.encode('cp437').decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return name


def safe_mac_archive(archive):
    names, links, total = set(), {}, 0
    with zipfile.ZipFile(archive) as zipped:
        members = zipped.infolist()
        require(0 < len(members) <= MAX_ZIP_MEMBERS, 'Mac ZIP 文件数无效。')
        for item in members:
            require(not any(ord(c) < 32 for c in item.orig_filename), 'Mac ZIP 原始路径包含控制字符。')
            name = archive_name(item)
            path = PurePosixPath(name)
            require(name and '\\' not in name and not any(ord(c) < 32 for c in name) and
                    not path.is_absolute() and all(part not in {'.', '..'} for part in name.split('/') if part) and
                    path.parts[0] == APP_NAME and str(path) == name.rstrip('/') and '//' not in name,
                    'Mac ZIP 包含外部目录或不安全路径。')
            key = unicodedata.normalize('NFC', name.rstrip('/')).casefold()
            require(key not in names, 'Mac ZIP 包含重复或大小写冲突路径。')
            names.add(key)
            # Reject alternate Unicode names interpreted differently by unzip implementations.
            extra = item.extra
            while extra:
                require(len(extra) >= 4, 'Mac ZIP 扩展字段截断。')
                code, length = struct.unpack_from('<HH', extra)
                require(length <= len(extra) - 4 and code != 0x7075, 'Mac ZIP 包含替代路径或损坏扩展字段。')
                extra = extra[4 + length:]
            mode = stat.S_IFMT(item.external_attr >> 16)
            require(mode in {0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK} and not item.flag_bits & 1,
                    'Mac ZIP 包含特殊或加密文件。')
            total += item.file_size
            require(0 <= item.file_size <= MAX_MAC_BYTES and total <= attachment.MAX_UNCOMPRESSED_BYTES,
                    'Mac ZIP 解压大小超过限制。')
            if mode == stat.S_IFLNK:
                require(0 < item.file_size <= 4096, 'Mac ZIP 链接大小无效。')
                target = zipped.read(item).decode('utf-8')
                require(target and '\\' not in target and not PurePosixPath(target).is_absolute() and
                        not any(ord(c) < 32 for c in target), 'Mac ZIP 包含不安全链接。')
                parts = list(path.parent.parts)
                for part in target.split('/'):
                    if part in {'', '.'}: continue
                    if part == '..':
                        require(len(parts) > 1, 'Mac ZIP 链接越过应用边界。')
                        parts.pop()
                    else: parts.append(part)
                links[key] = target
        for name in names:
            parent = PurePosixPath(name).parent
            while parent != PurePosixPath('.'):
                require(str(parent) not in links, 'Mac ZIP 文件路径穿过符号链接。')
                parent = parent.parent
    require(APP_NAME.casefold() + '/contents/info.plist' in names, 'Mac ZIP 缺少应用 Info.plist。')


def validate_extracted_links(app):
    root = app.resolve()
    for item in app.rglob('*'):
        if item.is_symlink():
            try:
                require(item.resolve().is_relative_to(root), '解压后的链接越过应用边界。')
            except (RuntimeError, OSError) as error:
                raise ValueError('解压后的链接循环或目标无效。') from error


def run(arguments, **kwargs):
    # Callers never put private key material in command-line arguments.
    try:
        return subprocess.run(list(map(str, arguments)), check=True, capture_output=True, **kwargs)
    except subprocess.CalledProcessError as error:
        raise ValueError('准备工具执行失败：' + Path(str(arguments[0])).name) from error


def expected_build_number(repository_root=ROOT):
    result = run(['python3', repository_root / 'scripts/build-number.py', '--repo', repository_root])
    value = result.stdout.decode().strip()
    require(re.fullmatch(r'[1-9][0-9]*', value), '源码构建号工具未返回有效整数。')
    return value


def check_bundle(app, version, repository_root=ROOT, expected_build=None):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == 'local.copytool.independent' and
            info.get('CFBundleShortVersionString') == version and info.get('CFBundleExecutable') == 'CopyTool' and
            info.get('LSMinimumSystemVersion') == '13.0', 'Mac 应用标识、版本或最低系统配置与源码不一致。')
    build = info.get('CFBundleVersion')
    require(isinstance(build, str) and re.fullmatch(r'[1-9][0-9]*', build) and int(build) > 1,
            'Mac 构建号必须是大于旧构建 1 的递增正整数。')
    expected = expected_build if expected_build is not None else expected_build_number(repository_root)
    require(build == expected, 'Mac 构建号与该完整源码提交的派生构建号不同。')
    resources = app / 'Contents/Resources'
    require((resources / 'update-public-key.pem').read_bytes() ==
            (repository_root / 'Resources/update-public-key.pem').read_bytes(), '应用内发行公钥与源码不同。')
    public = (repository_root / 'Resources/sparkle-public-key.txt').read_text().strip()
    require(info.get('SUPublicEDKey') == public and
            (resources / 'sparkle-public-key.txt').read_text().strip() == public, '应用内 Sparkle 公钥与源码不同。')
    require(info.get('SUFeedURL') == f'https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml',
            '应用未固定到官方更新源。')
    validate_extracted_links(app)
    executable = app / 'Contents/MacOS/CopyTool'
    require(executable.is_file() and not executable.is_symlink(), 'Mac 主程序缺失或为链接。')
    require(run(['/usr/bin/lipo', '-archs', executable]).stdout.decode().strip() == 'arm64',
            'Mac 更新包必须为当前支持的 ARM64 架构。')
    run(['codesign', '--verify', '--deep', '--strict', app])
    identity = run(['codesign', '--display', '--verbose=4', app]).stderr.decode('utf-8', errors='replace')
    require('Signature=adhoc' not in identity and
            any(line.startswith(('Authority=Apple Development:', 'Authority=Developer ID Application:'))
                for line in identity.splitlines()) and
            any(line.startswith('TeamIdentifier=') and line != 'TeamIdentifier=not set' for line in identity.splitlines()),
            '未公证更新也必须使用稳定 Apple 代码签名身份，不能使用 ad hoc 或无签名包。')
    return build


class GitHub(attachment.GitHub):
    def download_asset(self, asset, destination):
        require(type(asset.get('id')) is int and asset['id'] > 0, '附件 id 无效。')
        with destination.open('xb') as output:
            try:
                subprocess.run(['gh', 'api', '--method', 'GET',
                                f'repos/{REPOSITORY}/releases/assets/{asset["id"]}',
                                '--header', 'Accept: application/octet-stream'], check=True,
                               stdout=output, stderr=subprocess.PIPE)
            except subprocess.CalledProcessError as error:
                raise ValueError('草稿附件下载失败。') from error
        require(destination.stat().st_size == asset['size'] and
                attachment.sha256(destination) == attachment.api_digest(asset['digest']), '附件下载大小或摘要不符。')

    def delete_checksum(self, release_id, asset_id, tag, checkout_sha, mac, files):
        # A second check lives at the mutation boundary, not merely at startup.
        current = self.refresh_release(release_id)
        missing, _ = final_plan(current, tag, checkout_sha, mac, files)
        require(not missing, '删除旧校验文件前载荷已改变。')
        found = draft_assets(current, tag, checkout_sha, mac)
        require(attachment.CHECKSUMS in found and found[attachment.CHECKSUMS]['id'] == asset_id,
                '校验附件已改变，停止替换。')
        run(['gh', 'api', '--method', 'DELETE', f'repos/{REPOSITORY}/releases/assets/{asset_id}'])


def validate_local_base(files, found, version):
    require(set(files) == base_names(version), '本地基础附件集合无效。')
    hashes = {}
    for name, path in files.items():
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == found[name]['size'],
                '基础附件大小或类型不符。')
        digest = attachment.sha256(path)
        require(digest == attachment.api_digest(found[name]['digest']), '本地基础附件与草稿摘要不符。')
        hashes[name] = digest
    return hashes


def expected_manifest_signature(directory, existing_signature):
    manifest = directory / 'update-manifest.json'
    require(manifest.stat().st_size <= manifest_tools.MAX_MANIFEST, '清单过大。')
    if existing_signature is not None:
        require(0 < existing_signature.stat().st_size <= 256, '已有清单签名长度无效。')
        run(['openssl', 'dgst', '-sha256', '-verify', ROOT / 'Resources/update-public-key.pem',
             '-signature', existing_signature, manifest])
        shutil.copyfile(existing_signature, directory / 'update-manifest.sig')
    else:
        run(['openssl', 'dgst', '-sha256', '-verify', ROOT / 'Resources/update-public-key.pem',
             '-signature', directory / 'update-manifest.sig', manifest])


def final_plan(release, tag, sha, mac, files):
    version = attachment.parse_tag(tag)
    found = draft_assets(release, tag, sha, mac)
    require(set(files) == base_names(version) | EXTRAS, '最终附件集合必须是十二项。')
    missing = []
    for name, path in files.items():
        digest = attachment.sha256(path)
        if name in found:
            require(found[name]['size'] == path.stat().st_size and attachment.api_digest(found[name]['digest']) == digest,
                    '已有附件内容不同，拒绝覆盖：' + name)
        else:
            require(name in EXTRAS, '不允许上传基础安装包。')
            missing.append(name)
    return missing, checksum_bytes({name: attachment.sha256(path) for name, path in files.items()})


def prepare(args):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and
            os.environ.get('GH_TOKEN'), '仅允许指定仓库 Actions 内使用 github.token 执行。')
    require((ROOT / 'RELEASE_CHANNEL').read_text().strip() == 'unnotarized', '源码未选择未公证发行通道。')
    require(os.environ.get('SPARKLE_PRIVATE_KEY') and os.environ.get('UPDATE_MANIFEST_PRIVATE_KEY'),
            '缺少更新签名凭据，不能准备发行。')
    version = attachment.validate_version(args.tag, (ROOT / 'VERSION').read_text())
    run_id = attachment.parse_run_id(args.ci_run_id)
    mac = {attachment.MAC_ZIP: attachment.digest_value(args.mac_zip_sha256),
           attachment.MAC_DMG: attachment.digest_value(args.mac_dmg_sha256)}
    sha = run(['git', '-C', ROOT, 'rev-parse', 'HEAD']).stdout.decode().strip()
    api = GitHub()
    ci = api.json(f'repos/{REPOSITORY}/actions/runs/{run_id}')
    workflow = api.json(f'repos/{REPOSITORY}/actions/workflows/ci.yml')
    jobs = api.pages(f'repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest', 'jobs')
    attachment.validate_ci_run(ci, jobs, workflow['id'], sha, run_id)
    release = api.release(args.tag)
    found = draft_assets(release, args.tag, sha, mac)
    artifact = attachment.select_artifact(api.pages(f'repos/{REPOSITORY}/actions/runs/{run_id}/artifacts', 'artifacts'),
                                          run_id, sha, ci['repository']['id'])
    dist = ROOT / 'dist'
    require(not dist.exists() and not dist.is_symlink(), '干净 checkout 的 dist 目录必须不存在。')
    with tempfile.TemporaryDirectory(prefix='shanchuan-unnotarized-', dir=os.environ.get('RUNNER_TEMP')) as temporary:
        work = Path(temporary)
        artifact_path = work / 'artifact.zip'
        api.download(artifact['id'], artifact_path)
        windows = attachment.unpack_artifact(artifact_path, work / 'windows', version,
                                             attachment.api_digest(artifact['digest']))
        attachment.validate_windows_files(windows, version)
        directory = work / 'release'; directory.mkdir()
        files = {}
        for name, source in windows.items():
            files[name] = directory / name
            shutil.copyfile(source, files[name])
        for name in [attachment.MAC_ZIP, attachment.MAC_DMG]:
            files[name] = directory / name
            api.download_asset(found[name], files[name])
        validate_local_base(files, found, version)
        if attachment.CHECKSUMS in found:
            old_sums = work / 'old-checksums'
            api.download_asset(found[attachment.CHECKSUMS], old_sums)
            validate_checksum(old_sums.read_bytes(), found, version)
        safe_mac_archive(files[attachment.MAC_ZIP])
        dist.mkdir()
        try:
            run(['/usr/bin/ditto', '-x', '-k', files[attachment.MAC_ZIP], dist])
            app = dist / APP_NAME
            build = check_bundle(app, version)
            run(['python3', ROOT / 'scripts/verify-dmg.py', files[attachment.MAC_DMG], '--signed'], cwd=ROOT)
            shutil.copyfile(files[attachment.MAC_ZIP], dist / attachment.MAC_ZIP)
            run(['python3', ROOT / 'scripts/generate-appcast.py'], cwd=ROOT)
            shutil.copyfile(dist / 'appcast.xml', directory / 'appcast.xml')
            notes = ROOT / 'docs/releases' / (version + '.md')
            require(notes.is_file(), '需要该版本的更新说明。')
            run(['python3', ROOT / 'scripts/release_manifest.py', '--directory', directory,
                 '--version', version, '--notes-file', notes], cwd=ROOT)
            if 'update-manifest.sig' in found:
                existing = work / 'existing-manifest.sig'
                api.download_asset(found['update-manifest.sig'], existing)
            else:
                existing = None
            expected_manifest_signature(directory, existing)
            for name in EXTRAS: files[name] = directory / name
            # Generators have verified Sparkle and P-256 against the embedded
            # production keys. Validate the release inputs one final time.
            manifest_tools.check_feed(directory, version)
            manifest_tools.check_appcast(directory, version)
            policy = module('unnotarized_release_policy', 'release_policy.py')
            ready = policy.release_policy('unnotarized', False, True,
                                           unnotarized_verified=True, sparkle_key_present=True)
            require(ready['generate_manifest'] and not ready['prerelease'] and not ready['draft'],
                    '发行规则未允许已验证的未公证包。')
            for name in sorted(EXTRAS):
                current = api.refresh_release(release['id'])
                missing, sums = final_plan(current, args.tag, sha, mac, files)
                if name not in missing: continue
                uploaded = api.upload(release['id'], name, files[name])
                require(uploaded.get('name') == name and uploaded.get('state') == 'uploaded' and
                        uploaded.get('size') == files[name].stat().st_size and
                        attachment.api_digest(uploaded.get('digest')) == attachment.sha256(files[name]),
                        '签名附件上传响应不符。')
                print('已准备草稿附件：' + name)
            current = api.refresh_release(release['id'])
            missing, sums = final_plan(current, args.tag, sha, mac, files)
            require(not missing, '草稿仍缺少签名附件。')
            current_found = draft_assets(current, args.tag, sha, mac)
            sums_path = directory / attachment.CHECKSUMS; sums_path.write_bytes(sums)
            old = current_found.get(attachment.CHECKSUMS)
            if old is not None and attachment.api_digest(old['digest']) == hashlib.sha256(sums).hexdigest():
                require(old['size'] == len(sums), '已有最终校验文件大小不符。')
            if old is not None and attachment.api_digest(old['digest']) != hashlib.sha256(sums).hexdigest():
                remote_sums = work / 'latest-old-checksums'
                api.download_asset(old, remote_sums)
                validate_checksum(remote_sums.read_bytes(), current_found, version)
                api.delete_checksum(release['id'], old['id'], args.tag, sha, mac, files)
                old = None
            if old is None:
                # Check draft and exact payload digests again after deleting the
                # old checksum, including on a retry after an interrupted upload.
                current = api.refresh_release(release['id'])
                missing, checked_sums = final_plan(current, args.tag, sha, mac, files)
                require(not missing and checked_sums == sums, '上传校验文件前草稿已改变。')
                uploaded = api.upload(release['id'], attachment.CHECKSUMS, sums_path)
                require(uploaded.get('name') == attachment.CHECKSUMS and uploaded.get('state') == 'uploaded' and uploaded.get('size') == len(sums) and
                        attachment.api_digest(uploaded.get('digest')) == hashlib.sha256(sums).hexdigest(),
                        '最终校验文件上传响应不符。')
            final = api.refresh_release(release['id'])
            final_found = draft_assets(final, args.tag, sha, mac)
            missing, sums = final_plan(final, args.tag, sha, mac, files)
            require(not missing and len(final_found) == 13 and
                    final_found[attachment.CHECKSUMS]['size'] == len(sums) and
                    attachment.api_digest(final_found[attachment.CHECKSUMS]['digest']) == hashlib.sha256(sums).hexdigest(),
                    '最终草稿不完整或校验不符。')
            report = {'version': version, 'sourceSHA': sha, 'releaseId': release['id'], 'assets': 13,
                      'buildNumber': build, 'unnotarized': True, 'codeSignatureVerified': True,
                      'sparkleSignatureVerified': True, 'manifestSignatureVerified': True,
                      'draft': True, 'published': False, 'checksumsSHA256': hashlib.sha256(sums).hexdigest()}
            if args.report:
                Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps(report, ensure_ascii=False))
        finally:
            if dist.exists(): shutil.rmtree(dist)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--ci-run-id', required=True)
    parser.add_argument('--mac-zip-sha256', required=True)
    parser.add_argument('--mac-dmg-sha256', required=True)
    parser.add_argument('--report')
    try:
        prepare(parser.parse_args())
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, UnicodeError) as error:
        # Never log subprocess stdout/stderr, environment, or signing material.
        parser.exit(1, '未公证发行准备失败：' + str(error) + '\n')


if __name__ == '__main__': main()
