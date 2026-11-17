#!/usr/bin/env python3
"""显式发布通道；预发布永远不进入稳定自动更新。"""
import argparse
import json
import os
from pathlib import Path


def release_policy(channel, macos_signed, manifest_key_present, *,
                   unnotarized_verified=False, sparkle_key_present=False):
    if channel not in {'draft', 'prerelease', 'stable', 'unnotarized'}:
        raise ValueError('RELEASE_CHANNEL 只能是 draft、prerelease、stable 或 unnotarized。')
    stable_ready = channel == 'stable' and macos_signed and manifest_key_present
    # This proof is supplied only after the dedicated preparation workflow has
    # verified the stable code identity, both update signatures and all assets.
    # A normal unsigned CI build, or notarized credentials alone, cannot opt in.
    unnotarized_ready = (channel == 'unnotarized' and unnotarized_verified
                        and sparkle_key_present and manifest_key_present)
    update_ready = stable_ready or unnotarized_ready
    prerelease = channel == 'prerelease'
    arguments = ['--prerelease', '--latest=false'] if prerelease else ([] if update_ready else ['--draft'])
    return {'generate_manifest': update_ready, 'draft': not prerelease and not update_ready,
            'prerelease': prerelease, 'arguments': arguments}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = release_policy(args.channel, os.environ.get('MACOS_SIGNED') == 'true',
                                bool(os.environ.get('UPDATE_MANIFEST_PRIVATE_KEY')),
                                unnotarized_verified=os.environ.get('UNNOTARIZED_RELEASE_VERIFIED') == 'true',
                                sparkle_key_present=bool(os.environ.get('SPARKLE_PRIVATE_KEY')))
        args.output.write_text(json.dumps(result))
        print(f"发布通道：{args.channel}；正式更新清单：{'生成' if result['generate_manifest'] else '不生成'}")
    except ValueError as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
