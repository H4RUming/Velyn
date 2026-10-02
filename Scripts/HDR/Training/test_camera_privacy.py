"""Synthetic-only regressions for untrusted archives and private job cleanup."""
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from stage_camera_archive import stage
from run_private_camera_job import extract


class PrivateCameraContracts(unittest.TestCase):
    def test_zip_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root);z=p/'input.zip'
            with zipfile.ZipFile(z,'w') as f:f.writestr('../outside.heic',b'not a photo')
            with self.assertRaises(ValueError):stage(z,p/'output')
            self.assertFalse((p/'outside.heic').exists())

    def test_zip_copies_bytes_deduplicates_and_anonymizes(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root);z=p/'input.zip'
            with zipfile.ZipFile(z,'w') as f:
                f.writestr('personal-name.jpg',b'synthetic bytes');f.writestr('duplicate.jpg',b'synthetic bytes')
            before=z.read_bytes();stage(z,p/'output');rows=json.loads((p/'output/inputs.json').read_text())
            self.assertEqual(len(rows),1);self.assertEqual(Path(rows[0]['path']).read_bytes(),b'synthetic bytes')
            self.assertNotIn('personal-name',json.dumps(rows));self.assertEqual(before,z.read_bytes())

    def test_tar_rejects_links(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)
            with tarfile.open(p/'data.tar','w') as f:
                item=tarfile.TarInfo('image.npz');item.type=tarfile.SYMTYPE;item.linkname='/etc/passwd';f.addfile(item)
            with self.assertRaises(ValueError):extract(p/'data.tar',p/'data')

    def test_failed_job_removes_archive_and_partial_pixels(self):
        with tempfile.TemporaryDirectory(prefix='velyn-private-camera-') as root:
            p=Path(root);(p/'.private-camera-job').touch()
            with tarfile.open(p/'pairs.tar','w') as f:
                value=b'private synthetic sentinel';item=tarfile.TarInfo('image.npz');item.size=len(value);f.addfile(item,io.BytesIO(value))
                bad=tarfile.TarInfo('../unsafe.json');bad.size=2;f.addfile(bad,io.BytesIO(b'{}'))
            result=subprocess.run([sys.executable,str(Path(__file__).with_name('run_private_camera_job.py')),str(p),'--initial','unused','--gmnet-source','unused'],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((p/'pairs.tar').exists());self.assertFalse((p/'data').exists())
            record=json.loads((p/'cleanup.json').read_text());self.assertTrue(record['decodedTrainingDataRemoved']);self.assertFalse(record['trainingSucceeded'])


if __name__=='__main__':unittest.main()
