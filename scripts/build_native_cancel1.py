#!/usr/bin/env python3
"""Deterministic cancellation hotfix over the verified native.2 package."""
from pathlib import Path
import copy,gzip,hashlib,io,json,os,tarfile
R=Path(__file__).resolve().parents[1];O=R/'artifacts';B=O/'fancyss_hnd_full-anytls-native.2.tar.gz'
assert hashlib.sha256(B.read_bytes()).hexdigest()=='c6773e8497846329a9bc4b8e4a027f849aa1edb9b1a61d136fef1b47991ec785'
C=Path(os.environ.get('FSS_ANYTLS_BUILD_OUT',str(O)))
with tarfile.open(B) as t:m=json.load(t.extractfile('shadowsocks/ss/fork-build.json'))
payload={'shadowsocks/bin/fss-anytls-client':(C/'fss-anytls-client-hnd').read_bytes(),'shadowsocks/ss/fss-anytls-NOTICE':(R/'tool/fss-anytls-client/NOTICE').read_bytes()}
m['build']='3.5.30-anytls-native.2-cancel.1';m['client'].update(version='0.1.1',local_protocol_patch='cancellation.1',packed_sha256=hashlib.sha256(payload['shadowsocks/bin/fss-anytls-client']).hexdigest(),raw_sha256=hashlib.sha256((C/'fss-anytls-client-hnd.raw').read_bytes()).hexdigest())
m['source_files']={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((R/'tool/fss-anytls-client').rglob('*')) if p.is_file()}
for k,v in payload.items():m['files'][k]=hashlib.sha256(v).hexdigest()
payload['shadowsocks/ss/fork-build.json']=(json.dumps(m,indent=2)+'\n').encode()
def build(name,full):
 p=O/name
 with p.open('wb') as f,gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as dst:
  if full:
   with tarfile.open(B) as src:
    for member in src:
     if member.name in payload:continue
     data=src.extractfile(member) if member.isfile() else None
     member=copy.copy(member);member.uid=member.gid=0;member.uname=member.gname='root';member.mtime=0;dst.addfile(member,data)
  for k,v in payload.items():
   info=tarfile.TarInfo(k);info.size=len(v);info.mode=0o755 if k.endswith('/fss-anytls-client') else 0o644;dst.addfile(info,io.BytesIO(v))
 return {'path':str(p.relative_to(R)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
x={'manifest':m,'packages':[build('fancyss_hnd_full-anytls-native.2-cancel.1.tar.gz',True),build('fancyss_hnd_native.2-cancel.1-delta.tar.gz',False)]};(O/'native-cancel1-build.json').write_text(json.dumps(x,indent=2)+'\n');print(json.dumps(x['packages'],indent=2))
