#!/usr/bin/env python3
"""Local-only integration check. Standard library, Swift and macOS ditto required."""
import io
import pathlib
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.parse
import zipfile

uploads = {}
class FTP(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write((text + '\r\n').encode())
        self.wfile.flush()
    def handle(self):
        self.reply('220 Loopback integration fixture')
        listener = None
        cwd = '/'
        try:
            while line := self.rfile.readline():
                command, _, arg = line.decode().rstrip('\r\n').partition(' ')
                if command == 'USER': self.reply('331 Password required')
                elif command == 'PASS':
                    assert arg == 'p"\\word', repr(arg)
                    self.reply('230 Logged in')
                elif command == 'PWD': self.reply('257 "/"')
                elif command == 'CWD':
                    cwd = arg
                    self.reply('250 Directory changed')
                elif command == 'TYPE': self.reply('200 Type set')
                elif command in ('EPSV', 'PASV'):
                    listener = socket.socket()
                    listener.bind(('127.0.0.1', 0))
                    listener.listen(1)
                    port = listener.getsockname()[1]
                    if command == 'EPSV': self.reply(f'229 Entering Extended Passive Mode (|||{port}|)')
                    else: self.reply(f'227 Entering Passive Mode (127,0,0,1,{port//256},{port%256})')
                elif command == 'STOR':
                    self.reply('150 Opening data connection')
                    if arg == 'cancel.bin': time.sleep(1)
                    connection, _ = listener.accept()
                    with connection:
                        content = bytearray()
                        while chunk := connection.recv(65536):
                            content.extend(chunk)
                            if arg == 'progress.bin': time.sleep(0.02)
                    listener.close()
                    listener = None
                    uploads[arg] = bytes(content)
                    self.reply('226 Transfer complete')
                elif command == 'QUIT':
                    self.reply('221 Goodbye')
                    break
                else: self.reply('200 OK')
        finally:
            if listener: listener.close()

with socketserver.ThreadingTCPServer(('127.0.0.1', 0), FTP) as server, tempfile.TemporaryDirectory() as temp:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = pathlib.Path(__file__).resolve().parents[2]
    executable = str(pathlib.Path(temp) / 'transfer-test')
    subprocess.run(['swiftc', '-swift-version', '6', str(root/'Sources/CopyToolCore/FTPTransfer.swift'), str(root/'Sources/CopyToolCore/DirectoryExclusions.swift'), str(root/'Sources/CopyToolCore/TransferProgress.swift'), str(root/'Tests/Transfer/main.swift'), '-o', executable], check=True)
    subprocess.run([executable, str(server.server_address[1])], check=True, timeout=30)
    assert uploads['中文 file;type=A.txt'] == '本地 FTP 测试\n'.encode()
    assert uploads['progress.bin'] == b'A' * (16 * 1024 * 1024)
    assert uploads['progress-control.txt'] == b'publish progress fixture\n'
    with zipfile.ZipFile(io.BytesIO(uploads['folder.zip'])) as archive:
        source = next(name for name in archive.namelist() if name == 'source.txt')
        assert archive.read(source) == b'nested content'
    server.shutdown()
print('LOOPBACK_FTP_CONTENT_AND_ARCHIVE_PASS')
