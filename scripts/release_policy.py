#!/usr/bin/env python3
"""显式发布通道；预发布永远不进入稳定自动更新。"""
import argparse
import json
import os
from pathlib import Path


def release_policy(channel, macos_signed, manifest_key_present):
    if channel not in {'draft', 'prerelease', 'stable'}:
        raise ValueError('RELEASE_CHANNEL 只能是 draft、prerelease 或 stable。')
    stable_ready = channel == 'stable' and macos_signed and manifest_key_present
    prerelease = channel == 'prerelease'
    arguments = ['--prerelease', '--latest=false'] if prerelease else ([] if stable_ready else ['--draft'])
    return {'generate_manifest': stable_ready, 'draft': not prerelease and not stable_ready,
            'prerelease': prerelease, 'arguments': arguments}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = release_policy(args.channel, os.environ.get('MACOS_SIGNED') == 'true',
                                bool(os.environ.get('UPDATE_MANIFEST_PRIVATE_KEY')))
        args.output.write_text(json.dumps(result))
        print(f"发布通道：{args.channel}；正式更新清单：{'生成' if result['generate_manifest'] else '不生成'}")
    except ValueError as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
