import Foundation
import XCTest
@testable import CopyToolCore

final class ZipEncodingTests: XCTestCase {
    private func python(_ script: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", script] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertEqual(task.terminationStatus, 0, text)
        return text
    }

    func testDittoChinesePathsDecodeWithStandardReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let nested = source.appendingPathComponent("中文目录")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("内容一致".utf8).write(to: nested.appendingPathComponent("文件😀.txt"))
        let archive = root.appendingPathComponent("result.zip")
        try FTPTransfer.archiveDirectory(source, destination: archive)
        let output = try python(#"""
import sys, zipfile, struct
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    expected = '中文目录/文件😀.txt'
    assert expected in names, names
    assert z.read(expected).decode('utf-8') == '内容一致'
    with open(sys.argv[1], 'rb') as f:
        for entry in z.infolist():
            assert entry.flag_bits & 0x800, entry.filename
            f.seek(entry.header_offset)
            header = f.read(30)
            assert struct.unpack_from('<H', header, 6)[0] & 0x800
print('STANDARD_READER_UTF8_PASS')
"""#, [archive.path])
        XCTAssertTrue(output.contains("STANDARD_READER_UTF8_PASS"))
    }

    func testZIP64DirectoryAndLocalOffsetEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try python(#"""
import sys, struct, zlib
name = '中文😀.txt'.encode('utf-8')
content = b'PK\x03\x04 payload must not be scanned'
crc = zlib.crc32(content)
local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 45, 0, 0, 0, 0, crc, len(content), len(content), len(name), 0) + name + content
extra = struct.pack('<HHQ', 1, 8, 0)
central = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 45, 45, 0, 0, 0, 0, crc, len(content), len(content), len(name), len(extra), 0, 0, 0, 0, 0xffffffff) + name + extra
zip64_offset = len(local) + len(central)
end64 = struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, 1, 1, len(central), len(local))
locator = struct.pack('<IIQI', 0x07064b50, 0, zip64_offset, 1)
end = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff, 0)
open(sys.argv[1], 'wb').write(local + central + end64 + locator + end)
"""#, [url.path])
        try FTPTransfer().normalizeZIPEncoding(at: url)
        _ = try python(#"""
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.namelist() == ['中文😀.txt'], z.namelist()
    assert z.read('中文😀.txt') == b'PK\x03\x04 payload must not be scanned'
    assert z.infolist()[0].flag_bits & 0x800
"""#, [url.path])
    }
    func testInvalidUTF8NameIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try python(#"""
import sys, zipfile, struct
path = sys.argv[1]
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('a.txt', b'content')
with zipfile.ZipFile(path) as z:
    central = z.start_dir
    local = z.infolist()[0].header_offset
with open(path, 'r+b') as f:
    f.seek(local + 30); f.write(b'\xff')
    f.seek(central + 46); f.write(b'\xff')
"""#, [url.path])
        XCTAssertThrowsError(try FTPTransfer().normalizeZIPEncoding(at: url))
    }

}
