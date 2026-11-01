"""Restore exported Luau sources while retaining the template's instance/GUI data."""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from patch_rbxl_sources import build_model_index

ROOT=Path(__file__).resolve().parent.parent
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template',type=Path,default=ROOT/'templates/RoEMU-layout.rbxl')
    parser.add_argument('--output',type=Path,default=ROOT/'build/RoEMU.rbxl')
    parser.add_argument('--preserve-payloads',action='store_true')
    args=parser.parse_args()
    source=args.template.resolve();target=args.output.resolve()
    if source==target:parser.error('Output must differ from the input template.')
    model=build_model_index(source.read_bytes())
    by_path={s.path:s for s in model.scripts}
    replacements=[]
    for entry in json.loads((ROOT/'sources.json').read_text(encoding='utf-8')):
        if args.preserve_payloads and entry['external_payload']:continue
        if entry['path'] not in by_path:parser.error('Template is missing '+entry['path'])
        row=by_path[entry['path']]
        replacements.append({'path':entry['path'],'file':str(ROOT/entry['file']),
                             'expected_sha256':hashlib.sha256(row.source).hexdigest()})
    target.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='roemu-build-') as tmp:
        manifest=Path(tmp)/'sources.json'
        manifest.write_text(json.dumps({'replacements':replacements}),encoding='utf-8')
        subprocess.run([sys.executable,str(ROOT/'tools/patch_rbxl_sources.py'),str(source),str(target),
                        '--manifest',str(manifest)],check=True)
    print('Built:',target)
    print('Guest payloads:', 'retained from the local template' if args.preserve_payloads else 'public placeholders')
if __name__=='__main__':main()
