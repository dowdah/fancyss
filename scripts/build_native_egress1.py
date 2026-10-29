#!/usr/bin/env python3
"""Build the two-script egress fix over the verified cancellation.1 package."""
from pathlib import Path
import copy, gzip, hashlib, io, json, tarfile
R=Path(__file__).resolve().parents[1]; O=R/'artifacts'
B=O/'fancyss_hnd_full-anytls-native.2-cancel.1.tar.gz'
sha=lambda b: hashlib.sha256(b).hexdigest()
assert sha(B.read_bytes())=='dbee31994714705241b12cbbc25023fbc9dd9660be468bacb7a6a76cf733f62f'
with tarfile.open(B) as t: m=json.load(t.extractfile('shadowsocks/ss/fork-build.json'))
payload={f'shadowsocks/{p}':(R/'fancyss'/p).read_bytes() for p in ['ss/ssconfig.sh','scripts/ss_node_shunt.sh']}
m['build']='3.5.30-anytls-native.2-egress.1'
for k,v in payload.items(): m['files'][k]=sha(v)
m['egress_fix']={'mark':255,'description':'Prevent DIRECT sockets from re-entering native router-IP OUTPUT capture','source_hashes':{f'fancyss/{p}':sha((R/'fancyss'/p).read_bytes()) for p in ['ss/ssconfig.sh','scripts/ss_node_shunt.sh']},'validation':'21 native tests and isolated same-version ARM64 NAT recursion regression; production not deployed'}
payload['shadowsocks/ss/fork-build.json']=(json.dumps(m,indent=2)+'\n').encode()
def build(name,full):
 p=O/name
 with p.open('wb') as f,gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as dst:
  if full:
   with tarfile.open(B) as src:
    for member in src:
     if member.name in payload: continue
     data=src.extractfile(member) if member.isfile() else None
     member=copy.copy(member); member.uid=member.gid=0;member.uname=member.gname='root';member.mtime=0;dst.addfile(member,data)
  for k,v in payload.items():
   info=tarfile.TarInfo(k);info.size=len(v);info.mode=0o755 if k.endswith('.sh') else 0o644;dst.addfile(info,io.BytesIO(v))
 return {'path':str(p.relative_to(R)),'bytes':p.stat().st_size,'sha256':sha(p.read_bytes())}
x={'manifest':m,'packages':[build('fancyss_hnd_full-anytls-native.2-egress.1.tar.gz',True),build('fancyss_hnd_native.2-egress.1-delta.tar.gz',False)]}
(O/'native-egress1-build.json').write_text(json.dumps(x,indent=2)+'\n');print(json.dumps(x['packages'],indent=2))
