"""发行签名与门禁测试：使用临时私钥，不读取生产秘密。"""
import hashlib
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_manifest', ROOT/'scripts/release_manifest.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root/'release'
        self.directory.mkdir()
        self.key = self.root/'key.pem'
        release.openssl('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', self.key)
        self.public = self.root/'public.pem'
        self.public.write_bytes(release.openssl('pkey', '-in', self.key, '-pubout'))
        self.version = '0.3.0'
        for name in ('Shanchuan-0.3.0-win-x64-full.nupkg','Shanchuan-win-x64-Setup.exe',
                     'Shanchuan-win-x64-Portable.zip','Shanchuan-macos-arm64.zip',
                     'Shanchuan-macos-arm64.dmg','appcast.xml'):
            (self.directory/name).write_bytes(('Synthetic '+name).encode())
        package = self.directory/'Shanchuan-0.3.0-win-x64-full.nupkg'
        self.feed = {'Assets':[{'PackageId':'Shanchuan','Version':self.version,'Type':'Full',
                    'FileName':package.name,'Size':package.stat().st_size,
                    'SHA256':hashlib.sha256(package.read_bytes()).hexdigest().upper()}]}
        self.write_feed()
        zip_size=(self.directory/'Shanchuan-macos-arm64.zip').stat().st_size
        signature=base64.b64encode(b'x'*64).decode()
        (self.directory/'appcast.xml').write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>0.3.0</sparkle:shortVersionString><enclosure url="https://github.com/DB-XiaoQiang/shanchuan/releases/download/v0.3.0/Shanchuan-macos-arm64.zip" length="{zip_size}" sparkle:edSignature="{signature}" /></item></channel></rss>''')

    def write_feed(self):
        (self.directory/'releases.win-x64.json').write_text(json.dumps(self.feed))

    def generate(self, public=None):
        return release.create_manifest(self.directory,self.version,'合成发布说明',
                                        self.key.read_text(),public or self.public)

    def test_signed_manifest_covers_every_update_asset(self):
        self.assertEqual(7,self.generate())
        path=self.directory/'update-manifest.json'
        raw=path.read_bytes()
        payload=json.loads(raw)
        self.assertEqual(self.version,payload['version'])
        self.assertEqual('合成发布说明',payload['releaseNotes'])
        self.assertEqual(7,len(payload['assets']))
        release.openssl('dgst','-sha256','-verify',self.public,'-signature',
                        self.directory/'update-manifest.sig',path)
        for asset in payload['assets']:
            self.assertEqual(asset['sha256'],release.sha256(self.directory/asset['name']))

    def test_modified_manifest_rejected(self):
        self.generate()
        path=self.directory/'update-manifest.json'
        path.write_bytes(path.read_bytes().replace(b'0.3.0',b'0.3.1'))
        with self.assertRaises(subprocess.CalledProcessError):
            release.openssl('dgst','-sha256','-verify',self.public,'-signature',
                            self.directory/'update-manifest.sig',path)

    def test_missing_package_or_empty_asset_prevents_publication(self):
        (self.directory/'Shanchuan-macos-arm64.dmg').write_bytes(b'')
        with self.assertRaises(ValueError):self.generate()
        self.assertFalse((self.directory/'update-manifest.json').exists())

    def test_mismatched_feed_hash_or_version_prevents_publication(self):
        for field,value in [('SHA256','0'*64),('Version','0.2.0'),('FileName','../escape.nupkg'),('Size',1)]:
            with self.subTest(field=field):
                original=self.feed['Assets'][0][field]
                self.feed['Assets'][0][field]=value
                self.write_feed()
                with self.assertRaises(ValueError):self.generate()
                self.feed['Assets'][0][field]=original

    def test_appcast_cannot_redirect_or_change_version(self):
        path=self.directory/'appcast.xml'
        original=path.read_text()
        for old,new in [('github.com/DB-XiaoQiang/shanchuan','example.org/untrusted'),
                        ('>0.3.0<','>0.2.0<')]:
            path.write_text(original.replace(old,new))
            with self.assertRaises(ValueError):self.generate()

    def test_oversized_release_notes_or_asset_prevent_publication(self):
        with self.assertRaises(ValueError):
            release.create_manifest(self.directory,self.version,'x'*65537,self.key.read_text(),self.public)
        with (self.directory/'Shanchuan-macos-arm64.dmg').open('wb') as output:
            output.truncate(2*1024*1024*1024+1)
        with self.assertRaises(ValueError):self.generate()

    def test_key_mismatch_does_not_publish_manifest(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.generate(ROOT/'Fixtures/Updates/public-key.pem')
        self.assertFalse((self.directory/'update-manifest.json').exists())

    def test_shared_cross_platform_signature_fixture(self):
        fixture=ROOT/'Fixtures/Updates'
        release.openssl('dgst','-sha256','-verify',fixture/'public-key.pem',
                        '-signature',fixture/'manifest.sig',fixture/'manifest.json')
        manifest=json.loads((fixture/'manifest.json').read_bytes())
        self.assertEqual(manifest['assets'][0]['sha256'],release.sha256(fixture/'payload.bin'))


@unittest.skipUnless(sys.platform=='darwin', 'CryptoKit 验签在 macOS CI 执行')
class SparkleEmbeddedKeyTests(unittest.TestCase):
    def test_embedded_public_key_accepts_only_matching_archive_and_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            fixture=ROOT/'Fixtures/Sparkle'
            public=(fixture/'public-key.base64').read_text().strip()
            original=(fixture/'payload.bin').read_bytes()
            archive=root/'update.zip';archive.write_bytes(original)
            arguments=['swift',str(ROOT/'scripts/verify-sparkle.swift'),str(archive),
                       (fixture/'signature.base64').read_text().strip(),public]
            self.assertEqual(0,subprocess.run(arguments,capture_output=True).returncode)
            archive.write_bytes(b'Corrupted archive')
            self.assertNotEqual(0,subprocess.run(arguments,capture_output=True).returncode)
            archive.write_bytes(original)
            arguments[-1]=base64.b64encode(b'x'*32).decode()
            self.assertNotEqual(0,subprocess.run(arguments,capture_output=True).returncode)


if __name__=='__main__':unittest.main()
