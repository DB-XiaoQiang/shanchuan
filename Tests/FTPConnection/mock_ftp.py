#!/usr/bin/env python3
"""Read-only FTP connection fixture; loopback only, no credentials from user configuration."""
import pathlib
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

SECRET = 'p"\\word:中文 rest'
USERNAME = 'user"\\name'
DIRECTORY = '/研发中心/中文 file;type=A"quote'
sessions = []
errors = []
client_pid = None


class FTP(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write((text + '\r\n').encode())
        self.wfile.flush()

    def handle(self):
        commands = []
        sessions.append(commands)
        try:
            self.reply('220 Loopback read-only test')
            username = ''
            while line := self.rfile.readline():
                command, _, argument = line.decode().rstrip('\r\n').partition(' ')
                commands.append((command, argument))
                if command == 'USER':
                    username = argument
                    self.reply('331 Password required')
                elif command == 'PASS':
                    if argument != SECRET:
                        errors.append('Credential escaping mismatch')
                    # Credentials, host and target directory must stay out of curl argv.
                    processes = subprocess.check_output(['ps', '-ax', '-o', 'ppid=,args='], text=True)
                    matching = [row for row in processes.splitlines()
                                if row.split(None, 1)[0] == str(client_pid)
                                and '/usr/bin/curl' in row]
                    if not matching or any(SECRET in row or USERNAME in row or DIRECTORY in row for row in matching):
                        errors.append('Curl process arguments exposed dynamic configuration')
                    if username == 'reject':
                        # Deliberately echo synthetic sensitive text; the client must never expose it.
                        self.reply('530 Rejected ' + SECRET + ' ' + USERNAME)
                    elif username in ('timeout', 'cancel'):
                        time.sleep(16)
                        self.reply('230 Logged in')
                    else:
                        if username != USERNAME:
                            errors.append('Username escaping mismatch')
                        self.reply('230 Logged in')
                elif command == 'PWD': self.reply('257 "/home/test"')
                elif command == 'CWD':
                    if argument == '/deny': self.reply('550 Directory not accessible ' + SECRET)
                    elif argument == '/timeout':
                        time.sleep(16)
                        self.reply('250 Directory changed')
                    elif argument == DIRECTORY: self.reply('250 Directory changed')
                    else:
                        errors.append('Unexpected destination directory')
                        self.reply('550 Unexpected directory')
                elif command == 'QUIT':
                    self.reply('221 Goodbye')
                    break
                else:
                    errors.append('Unexpected command: ' + command)
                    self.reply('502 Unsupported command')
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


with Server(('127.0.0.1', 0), FTP) as server, tempfile.TemporaryDirectory() as temporary:
    with socket.socket() as unused:
        unused.bind(('127.0.0.1', 0))
        closed_port = unused.getsockname()[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = pathlib.Path(__file__).resolve().parents[2]
    executable = pathlib.Path(temporary) / 'ftp-connection-test'
    subprocess.run(['swiftc', '-swift-version', '6',
                    str(root / 'Sources/CopyToolCore/FTPTransfer.swift'),
                    str(root / 'Sources/CopyToolCore/DirectoryExclusions.swift'),
                    str(root / 'Sources/CopyToolCore/FTPConnectionTest.swift'),
                    str(root / 'Tests/FTPConnection/main.swift'), '-o', str(executable)], check=True)
    client = subprocess.Popen([str(executable), str(server.server_address[1]), str(closed_port)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    client_pid = client.pid
    output, diagnostic = client.communicate(timeout=30)
    assert SECRET not in output + diagnostic and USERNAME not in output + diagnostic, 'Credential exposed in diagnostics'
    assert client.returncode == 0, 'Swift connection fixture failed: ' + output + diagnostic
    print(output, end='')
    assert not errors, '; '.join(errors)
    assert len(sessions) == 7, 'Pre-cancelled or offline checks must not create FTP sessions'
    allowed = {'USER', 'PASS', 'PWD', 'CWD', 'QUIT'}
    assert all(command in allowed for session in sessions for command, _ in session), 'Non-read-only FTP command'
    successes = [session for session in sessions if ('CWD', DIRECTORY) in session]
    assert len(successes) == 2, 'Expected initial success and isolated post-cancel success'
    assert all(('USER', USERNAME) in session and ('PASS', SECRET) in session for session in successes)
    server.shutdown()
print('FTP_CONNECTION_CONTROL_ONLY_NO_WRITES_OR_DATA_CHANNEL_PASS')
print('FTP_CONNECTION_CREDENTIALS_ABSENT_FROM_ARGV_PASS')
