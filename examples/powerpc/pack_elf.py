"""Package only our own static C probe; no OS, runtime or firmware conversion."""
from pathlib import Path
import argparse, struct

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('linked',type=Path)
p.add_argument('output_directory',type=Path)
args=p.parse_args()
raw=args.linked.read_bytes()
assert raw[:7]==b'\x7fELF\x02\x02\x01','Expected ELF64 big endian'
entry,shoff=struct.unpack_from('>Q',raw,24)[0],struct.unpack_from('>Q',raw,40)[0]
shnum=struct.unpack_from('>H',raw,60)[0]
sections=[struct.unpack_from('>IIQQQQIIQQ',raw,shoff+i*64) for i in range(shnum)]
segments=[]
for sh in sections:
    if sh[2]&2 and sh[5]:
        segments.append(dict(address=sh[3],data=raw[sh[4]:sh[4]+sh[5]] if sh[1]!=8 else b'',
                             size=sh[5],flags=4|(2 if sh[2]&1 else 0)|(1 if sh[2]&4 else 0)))
descriptor=next(s for s in segments if s['address']<=entry and entry+24<=s['address']+len(s['data']))
code,toc,environment=struct.unpack_from('>QQQ',descriptor['data'],entry-descriptor['address'])
assert code<2**32 and toc<2**32 and environment==0,'Example requires low addresses and no environment'
args.output_directory.mkdir(parents=True,exist_ok=True)
for mode in ['elfv1','ps3-ppu']:
    out=bytearray(64+56*len(segments))
    out[:16]=b'\x7fELF\x02\x02\x01'+bytes([0x66 if mode=='ps3-ppu' else 0])+bytes(8)
    struct.pack_into('>HHIQQQIHHHHHH',out,16,2,21,1,entry,64,0,0 if mode=='ps3-ppu' else 1,64,56,len(segments),0,0,0)
    for i,s in enumerate(segments):
        content=s['data']
        if mode=='ps3-ppu' and s is descriptor:
            content=bytearray(content);struct.pack_into('>II',content,entry-s['address'],code,toc)
        out.extend(bytes((-len(out))%16));offset=len(out);out.extend(content)
        struct.pack_into('>IIQQQQQQ',out,64+i*56,1,s['flags'],offset,s['address'],s['address'],len(content),s['size'],1)
    target=args.output_directory/('bringup-'+mode+'.elf');target.write_bytes(out)
    print(target,len(out))
