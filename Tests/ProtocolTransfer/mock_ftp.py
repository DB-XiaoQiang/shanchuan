#!/usr/bin/env python3
"""Loopback-only wire-format integration check; no real configuration or server."""
import hashlib
import io
import pathlib
import posixpath
import socket
import socketserver
import subprocess
import tempfile
import threading
import zipfile


uploads = []
failures = []
record_lock = threading.Lock()
expected_directory = "/share/system_temp"


class FTP(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write((text + "\r\n").encode())
        self.wfile.flush()

    def handle(self):
        listener = None
        cwd = "/"
        self.request.settimeout(15)
        self.reply("220 Loopback protocol integration fixture")
        try:
            while line := self.rfile.readline():
                command, _, arg = line.decode("utf-8").rstrip("\r\n").partition(" ")
                if command == "USER":
                    assert arg == "fixture"
                    self.reply("331 Password required")
                elif command == "PASS":
                    assert arg == "fixture-password"
                    self.reply("230 Logged in")
                elif command == "PWD":
                    self.reply('257 "/"')
                elif command == "CWD":
                    cwd = posixpath.normpath(posixpath.join(cwd, arg))
                    self.reply("250 Directory changed")
                elif command == "TYPE":
                    assert arg == "I", "Protocol payloads must use binary transfer"
                    self.reply("200 Type set")
                elif command in ("EPSV", "PASV"):
                    listener = socket.socket()
                    listener.settimeout(15)
                    listener.bind(("127.0.0.1", 0))
                    listener.listen(1)
                    port = listener.getsockname()[1]
                    if command == "EPSV":
                        self.reply(f"229 Entering Extended Passive Mode (|||{port}|)")
                    else:
                        self.reply(f"227 Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})")
                elif command == "STOR":
                    assert cwd == expected_directory, f"Unexpected remote directory: {cwd}"
                    assert "/" not in arg and "\\" not in arg
                    assert listener is not None
                    self.reply("150 Opening data connection")
                    connection, address = listener.accept()
                    assert address[0] == "127.0.0.1"
                    with connection:
                        connection.settimeout(15)
                        content = bytearray()
                        while chunk := connection.recv(65536):
                            content.extend(chunk)
                    listener.close()
                    listener = None
                    with record_lock:
                        uploads.append((cwd, arg, bytes(content)))
                    self.reply("226 Transfer complete")
                elif command == "QUIT":
                    self.reply("221 Goodbye")
                    break
                elif command in ("SYST", "FEAT"):
                    self.reply("215 UNIX Type: L8" if command == "SYST" else "211 No extensions")
                else:
                    raise AssertionError(f"Unexpected FTP command: {command}")
        except Exception as error:
            with record_lock:
                failures.append(repr(error))
            try:
                self.reply("550 Fixture rejected unexpected operation")
            except OSError:
                pass
        finally:
            if listener is not None:
                listener.close()


class LoopbackServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


with LoopbackServer(("127.0.0.1", 0), FTP) as server, tempfile.TemporaryDirectory(prefix="copytool-protocol-test-") as temp:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    root = pathlib.Path(__file__).resolve().parents[2]
    executable = str(pathlib.Path(temp) / "protocol-transfer-test")
    sources = [root / "Sources/CopyToolCore" / name for name in ("KeyboardShortcutConfiguration.swift", "History.swift", "DirectoryExclusions.swift", "FTPTransfer.swift", "TransferProtocol.swift")]
    try:
        subprocess.run(["swiftc", "-swift-version", "6", *(str(source) for source in sources), str(root / "Tests/ProtocolTransfer/main.swift"), "-o", executable], check=True, timeout=60)
        subprocess.run([executable, str(server.server_address[1])], check=True, timeout=30)
    finally:
        server.shutdown()
        thread.join(timeout=5)

assert not failures, failures
assert [(directory, name) for directory, name, _ in uploads[:4]] == [
    (expected_directory, "copy.temp.1729000000001"),
    (expected_directory, "普通文件"),
    (expected_directory, "测试文件夹"),
    (expected_directory, "copy.temp.1729000000002"),
], "Remote entity names, exact directories, or upload order differ from the protocol"

text = uploads[0][2]
assert text == "REA 独立版协议集成测试\r\n第二行 UTF-8：中文与 emoji 🧪\n".encode("utf-8")
print("EXACT_UTF8_TEXT_AND_REMOTE_PATH_PASS")

file_payload = uploads[1][2]
assert file_payload == "独立文件内容\nline 2\r\n".encode("utf-8")
folder_payload = uploads[2][2]
file_md5 = hashlib.md5(file_payload).hexdigest()
folder_md5 = hashlib.md5(folder_payload).hexdigest()
control = uploads[3][2]
assert control == f"file=普通文件.txt|{file_md5},folder:测试文件夹|{folder_md5}\r\n1729000000002".encode("utf-8")
assert control.count(b"\r\n") == 1
assert not control.endswith(b"\n")
print("CONTROL_LAST_MD5_CRLF_TIMESTAMP_PASS")

with zipfile.ZipFile(io.BytesIO(folder_payload)) as archive:
    for entry in archive.infolist():
        if not entry.filename.isascii():
            assert entry.flag_bits & 0x800, "Unicode paths require the ZIP UTF-8 flag in the central directory"
            offset = entry.header_offset
            assert folder_payload[offset:offset + 4] == b"PK\x03\x04"
            assert int.from_bytes(folder_payload[offset + 6:offset + 8], "little") & 0x800, "Unicode paths require the ZIP UTF-8 flag in the local header"
    files = {entry.filename: archive.read(entry) for entry in archive.infolist() if not entry.is_dir()}
    assert files == {
        "root.txt": b"folder root\n",
        "子目录 with spaces/中文.txt": "相对路径内容\r\n".encode("utf-8"),
        "子目录 with spaces/bytes.bin": bytes([0, 1, 2, 127, 128, 254, 255]),
    }, f"Folder archive must restore relative paths and preserve all file bytes: {list(files)}"
print("FILE_ENTITY_AND_FOLDER_ZIP_PASS")
assert len(uploads) == 6
assert uploads[4][0] == expected_directory
assert uploads[4][1].startswith("闪传多格式-1729000000003-")
assert uploads[5][:2] == (expected_directory, "copy.temp.1729000000003")
with zipfile.ZipFile(io.BytesIO(uploads[4][2])) as archive:
    assert {entry.filename: archive.read(entry) for entry in archive.infolist() if not entry.is_dir()} == {
        "部署.pdf": b"%PDF synthetic format",
        "部署.md": "# 合成部署说明\n".encode("utf-8"),
    }
name = uploads[4][1]
digest = hashlib.md5(uploads[4][2]).hexdigest()
assert uploads[5][2] == f"file=folder:{name}|{digest}\r\n1729000000003".encode("utf-8")
print("SAME_STEM_FORMATS_FOLDER_AND_CONTROL_LAST_PASS")
print("LOOPBACK_PROTOCOL_TRANSFER_PASS")
