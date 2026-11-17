#!/usr/bin/env python3
"""从完整 Git 提交历史派生可复现的 macOS 构建号；不修改仓库。"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


class BuildNumberError(ValueError):
    """仓库或显式构建号不满足可复现构建要求。"""


def git(repo, *arguments):
    environment = os.environ.copy()
    # 固定使用 --repo 指向的仓库，避免调用者的 Git 工作目录变量改变计数。
    for variable in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                     'GIT_SHALLOW_FILE', 'GIT_REPLACE_REF_BASE'):
        environment.pop(variable, None)
    environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    completed = subprocess.run(['git', '-C', str(repo), *arguments], env=environment,
                               capture_output=True, text=True)
    if completed.returncode:
        raise BuildNumberError('无法读取完整 Git 历史；请使用完整检出（fetch-depth: 0），不回退为构建号 1。')
    return completed.stdout.strip()


def build_number(repo, revision='HEAD'):
    """同一提交返回同一整数；沿保留历史的后继提交严格增加。"""
    repository = Path(repo).resolve(strict=True)
    if Path(git(repository, 'rev-parse', '--show-toplevel')).resolve() != repository:
        raise BuildNumberError('--repo 必须是源码仓库根目录；不能借用父目录仓库为源码归档派生构建号。')
    if git(repository, 'rev-parse', '--is-shallow-repository') != 'false':
        raise BuildNumberError('浅仓库不能派生构建号；请先获取完整历史（fetch-depth: 0）。')
    if git(repository, 'for-each-ref', '--format=%(refname)', 'refs/replace/'):
        raise BuildNumberError('仓库存在 Git replace refs，已拒绝可能改变计数的历史替换。')
    grafts = Path(git(repository, 'rev-parse', '--git-path', 'info/grafts'))
    if not grafts.is_absolute():
        grafts = repository / grafts
    if grafts.exists() and grafts.stat().st_size:
        raise BuildNumberError('仓库存在 Git grafts，已拒绝不完整或被改写的提交历史。')
    commit = git(repository, 'rev-parse', '--verify', '--end-of-options', revision + '^{commit}')
    count = git(repository, 'rev-list', '--count', commit)
    if not re.fullmatch(r'[1-9][0-9]*', count):
        raise BuildNumberError('Git 提交计数必须是正整数。')
    return count


def validate_override(derived, override):
    """兼容旧环境变量，但不得脱离源码计数而造成后续构建号倒退。"""
    if override is not None and (not re.fullmatch(r'[1-9][0-9]*', override) or override != derived):
        raise BuildNumberError('SHANCHUAN_BUILD_NUMBER 只能等于完整 Git 历史派生值；不能使用固定值或独立流水号。')
    return derived


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1], help='源码仓库路径')
    parser.add_argument('--revision', default='HEAD', help='待构建提交或标签，默认 HEAD')
    arguments = parser.parse_args()
    try:
        print(validate_override(build_number(arguments.repo, arguments.revision), os.environ.get('SHANCHUAN_BUILD_NUMBER')))
    except (BuildNumberError, OSError) as error:
        print('构建号校验失败：' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
