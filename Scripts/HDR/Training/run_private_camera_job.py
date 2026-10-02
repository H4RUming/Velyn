"""Bounded server job: remove uploaded camera tensors on success or failure.

The caller must create a new mode-0700 Velyn private workspace (prefix below),
download results, and then remove that complete workspace. No service is started.
"""
import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile


def extract(archive,destination):
    destination.mkdir(mode=0o700)
    total=0;seen=set()
    with tarfile.open(archive,'r:') as tar:
        for member in tar:
            name=Path(member.name)
            if not member.isfile() or str(name)!=name.name or name.suffix not in {'.npz','.json'} or name.name in seen:
                raise ValueError('Unsafe dataset archive entry')
            seen.add(name.name);total+=member.size
            if member.size>64*1024**2 or total>16*1024**3 or len(seen)>5000:raise ValueError('Dataset archive exceeds limits')
            with tar.extractfile(member) as src,(destination/name.name).open('xb') as dst:shutil.copyfileobj(src,dst)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('workspace',type=Path);p.add_argument('--initial',type=Path,required=True);p.add_argument('--gmnet-source',type=Path,required=True)
    p.add_argument('--trainer',choices=['signed','gmnet'],default='signed')
    a=p.parse_args();root=a.workspace.resolve()
    if not root.name.startswith('velyn-private-camera-') or not (root/'.private-camera-job').is_file():raise ValueError('Unrecognized private workspace')
    def stopped(*args):raise KeyboardInterrupt('Private job interrupted')
    signal.signal(signal.SIGTERM,stopped)
    data=root/'data';archive=root/'pairs.tar';success=False
    try:
        extract(archive,data)
        with (root/'training.log').open('w') as log:
            trainer='train_camera.py' if a.trainer=='signed' else 'train_gmnet_camera.py'
            subprocess.run([sys.executable,str(Path(__file__).with_name(trainer)),str(data),str(a.initial),str(root/'results'),
                            '--gmnet-source',str(a.gmnet_source)],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=1200)
        success=True
    finally:
        if data.exists():shutil.rmtree(data)
        archive.unlink(missing_ok=True)
        status={'trainingSucceeded':success,'uploadedArchiveRemoved':not archive.exists(),'decodedTrainingDataRemoved':not data.exists()}
        (root/'cleanup.json').write_text(json.dumps(status)+'\n');print(json.dumps(status),flush=True)


if __name__=='__main__':main()
