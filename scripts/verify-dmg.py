#!/usr/bin/env python3
"""校验 DMG 内容与签名；只读挂载，不启动 Finder 或应用。"""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


class VerificationError(RuntimeError):
    pass


def run(arguments, *, timeout=120):
    result = subprocess.run(arguments, capture_output=True, timeout=timeout)
    if result.returncode:
        detail = (result.stderr or result.stdout).decode("utf-8", errors="replace").strip()
        raise VerificationError(f"命令失败（{result.returncode}）：{' '.join(arguments)}\n{detail}")
    return result


def verify_contents(mountpoint, expected_version):
    app = mountpoint / "闪传.app"
    if app.is_symlink() or not app.is_dir():
        raise VerificationError("DMG 根目录缺少独立的 闪传.app 目录。")
    applications = mountpoint / "Applications"
    if not applications.is_symlink() or os.readlink(applications) != "/Applications":
        raise VerificationError("DMG 根目录必须包含 Applications -> /Applications 符号链接。")

    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "local.copytool.independent":
        raise VerificationError("DMG 中应用的 Bundle ID 不匹配。")
    if info.get("CFBundleShortVersionString") != expected_version:
        raise VerificationError("DMG 中应用的版本与仓库 VERSION 不一致。")

    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name or Path(executable_name).name != executable_name:
        raise VerificationError("CFBundleExecutable 不是有效的可执行文件名。")
    executable = app / "Contents/MacOS" / executable_name
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for target in (executable, framework / "Sparkle"):
        if not target.is_file() or not target.resolve().is_relative_to(app.resolve()):
            raise VerificationError(f"应用内部文件缺失或指向包外：{target.relative_to(app)}")
    if not framework.is_dir():
        raise VerificationError("应用缺少 Sparkle.framework。")
    with executable.open("rb") as stream:
        magic = stream.read(4)
    if magic not in {
        b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",  # Mach-O 32
        b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",  # Mach-O 64
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # Universal
        b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",  # Universal 64
    }:
        raise VerificationError("CFBundleExecutable 不是 Mach-O 文件。")
    return app


def verify(image, signed):
    root = Path(__file__).resolve().parents[1]
    expected_version = (root / "VERSION").read_text().strip()
    run(["/usr/bin/hdiutil", "verify", str(image)])
    if signed:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(image)])

    # 不用 TemporaryDirectory：卸载失败时必须保留目录，不能递归删除挂载内容。
    temporary = Path(tempfile.mkdtemp(prefix="shanchuan-dmg-verify-"))
    mountpoint = temporary / "volume"
    mountpoint.mkdir()
    attach_attempted = False
    detach_target = str(mountpoint)
    primary_error = None
    cleanup_error = None
    try:
        attach_attempted = True
        attached = subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
             "-mountpoint", str(mountpoint), "-plist", str(image)],
            capture_output=True, timeout=120,
        )
        # 若挂载未完成但设备已创建，尽量卸载该设备，避免残留未挂载的磁盘映像。
        try:
            entities = plistlib.loads(attached.stdout).get("system-entities", [])
            devices = [entity["dev-entry"] for entity in entities if "dev-entry" in entity]
            if devices and not os.path.ismount(mountpoint):
                detach_target = devices[0]
        except (plistlib.InvalidFileException, ValueError, TypeError, KeyError):
            pass
        if attached.returncode:
            detail = (attached.stderr or attached.stdout).decode("utf-8", errors="replace").strip()
            raise VerificationError(f"DMG 只读挂载失败：{detail}")
        if not os.path.ismount(mountpoint):
            raise VerificationError("hdiutil 未将 DMG 挂载到指定的临时目录。")
        app = verify_contents(mountpoint, expected_version)
        if signed:
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    except BaseException as error:
        primary_error = error
    finally:
        if attach_attempted:
            try:
                run(["/usr/bin/hdiutil", "detach", detach_target], timeout=60)
                if os.path.ismount(mountpoint):
                    raise VerificationError("卸载后临时挂载点仍处于挂载状态。")
            except BaseException as error:
                cleanup_error = error
        if cleanup_error is None:
            shutil.rmtree(temporary)

    if cleanup_error is not None:
        detail = f"{primary_error}\n" if primary_error is not None else ""
        raise VerificationError(
            f"{detail}DMG 卸载失败，已保留临时目录，未删除其中内容：{temporary}\n{cleanup_error}"
        ) from cleanup_error
    if primary_error is not None:
        raise primary_error
    print(f"DMG 校验通过：{image.name}（版本 {expected_version}，{'含签名检查' if signed else '未要求签名'}）")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="待校验的 DMG 文件")
    parser.add_argument("--signed", action="store_true", help="同时校验 DMG 和应用签名")
    arguments = parser.parse_args()
    try:
        image = arguments.image.resolve(strict=True)
        if not image.is_file():
            raise VerificationError("DMG 路径必须是文件。")
        verify(image, arguments.signed)
    except (VerificationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"DMG 校验失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
