"""Verify pinned research models; fetch only with explicit --download.

No photo paths or app integration. Run this developer tool manually.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def verify(directory):
    manifest = json.loads(Path(__file__).with_name('signed-model-sources.json').read_text())
    for entry in manifest['files']:
        path = directory/entry['path']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError(f'Missing or changed pinned model file: {entry["path"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--download', action='store_true')
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name('signed-model-sources.json').read_text())
    if args.download:
        for entry in manifest['files']:
            path = args.directory/entry['path']
            if path.is_file():
                if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
                    raise ValueError(f'Refusing to overwrite changed file: {path}')
                continue
            with urllib.request.urlopen(entry['url'], timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError(f'Download hash mismatch: {entry["path"]}')
            path.parent.mkdir(parents=True, exist_ok=True)
            staging = path.with_name(path.name+'.download')
            try:
                staging.write_bytes(data)
                staging.replace(path)
            finally:
                staging.unlink(missing_ok=True)
    verify(args.directory)
    print('Verified all pinned code, weights and MIT license notices.')


if __name__ == '__main__':
    main()
