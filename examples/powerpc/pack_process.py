"""Package our own linked ELFv1 PPU diagnostic with its PT_TLS intact."""
from pathlib import Path
import argparse,struct

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('linked',type=Path)
p.add_argument('output_directory',type=Path)
args=p.parse_args()
raw=bytearray(args.linked.read_bytes())
assert raw[:7]==b'\x7fELF\x02\x02\x01','Expected ELF64 big endian'
raw[7]=0x66;struct.pack_into('>I',raw,48,0)
entry=struct.unpack_from('>Q',raw,24)[0]
phoff=struct.unpack_from('>Q',raw,32)[0];count=struct.unpack_from('>H',raw,56)[0]
phs=[list(struct.unpack_from('>IIQQQQQQ',raw,phoff+i*56)) for i in range(count)]
descriptor=next(ph for ph in phs if ph[0]==1 and ph[3]<=entry and entry+24<=ph[3]+ph[5])
at=descriptor[2]+entry-descriptor[3]
code,toc,environment=struct.unpack_from('>QQQ',raw,at)
assert code<2**32 and toc<2**32 and environment==0
struct.pack_into('>II',raw,at,code,toc)
args.output_directory.mkdir(parents=True,exist_ok=True)
(args.output_directory/'process-rpcs3.elf').write_bytes(raw)
out=bytearray(64+len(phs)*56);out[:64]=raw[:64]
struct.pack_into('>Q',out,32,64);struct.pack_into('>Q',out,40,0);struct.pack_into('>HHH',out,58,0,0,0)
loads=[]
for i,ph in enumerate(phs):
    if ph[0]!=1:continue
    out.extend(bytes((-len(out))%16));offset=len(out);out.extend(raw[ph[2]:ph[2]+ph[5]])
    loads.append((ph,offset));updated=ph.copy();updated[2],updated[7]=offset,16
    struct.pack_into('>IIQQQQQQ',out,64+i*56,*updated)
for i,ph in enumerate(phs):
    if ph[0]==1:continue
    assert ph[0]==7,'This example only uses LOAD and TLS program headers'
    updated=ph.copy()
    load,offset=next((s,offset) for s,offset in loads if s[3]<=ph[3] and ph[3]+ph[5]<=s[3]+s[5])
    updated[2]=offset+ph[3]-load[3]
    struct.pack_into('>IIQQQQQQ',out,64+i*56,*updated)
target=args.output_directory/'process-compact.elf';target.write_bytes(out)
print(target,len(out))
