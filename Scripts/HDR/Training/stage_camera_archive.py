"""Explicit local ZIP import for private research; never modifies the source ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import zipfile


def stage(archive,output):
    output.mkdir(parents=True,exist_ok=False,mode=0o700)
    rows=[]; seen=set(); skipped=0; duplicates=0
    with zipfile.ZipFile(archive) as z:
        for item in z.infolist():
            path=Path(item.filename)
            if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(item.external_attr>>16):
                raise ValueError('Unsafe archive entry')
            if item.is_dir() or '__MACOSX' in path.parts or path.suffix.lower() not in {'.heic','.heif','.jpg','.jpeg','.png'}:
                skipped+=1; continue
            if item.file_size>256*1024**2: raise ValueError('Oversized image entry')
            data=z.read(item); digest=hashlib.sha256(data).hexdigest()
            if digest in seen: duplicates+=1; continue
            seen.add(digest); identifier=f'photo-{len(rows):05d}'
            destination=output/(identifier+path.suffix.lower())
            destination.write_bytes(data); destination.chmod(0o600)
            if hashlib.sha256(destination.read_bytes()).hexdigest()!=digest: raise ValueError('Copy hash mismatch')
            rows.append({'id':identifier,'path':str(destination.resolve()),'sha256':digest})
    (output/'inputs.json').write_text(json.dumps(rows))
    print(json.dumps({'uniqueImages':len(rows),'exactDuplicates':duplicates,'skippedEntries':skipped,'byteCopiesVerified':True}))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('archive',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();stage(a.archive,a.output)
