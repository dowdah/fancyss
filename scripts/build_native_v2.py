#!/usr/bin/env python3
"""hnd/full native.2 over pinned native.1; deterministic full and narrow delta."""
from pathlib import Path
import copy,gzip,hashlib,io,json,subprocess,tarfile
ROOT=Path(__file__).resolve().parents[1]; OUT=ROOT/'artifacts'
BASE=OUT/'fancyss_hnd_full-anytls-native.1.tar.gz'
assert hashlib.sha256(BASE.read_bytes()).hexdigest()=='4dcf963644a0a931918b94425671bd81a690f2ee5b73f5cb6115e34ba85a7eeb','native.1 baseline changed'
FILES=['ss/ssconfig.sh','scripts/ss_anytls_helper.sh','scripts/ss_node_shunt.sh','scripts/ss_proc_status.sh']
payload={'shadowsocks/'+n:(ROOT/'fancyss'/n).read_bytes().replace(b'#@',b'') if n.endswith('ss_proc_status.sh') else (ROOT/'fancyss'/n).read_bytes() for n in FILES}
payload['shadowsocks/bin/fss-anytls-client']=(OUT/'fss-anytls-client-hnd').read_bytes()
for src,dest in [('LICENSE','fss-anytls-LICENSE'),('LICENSE.x-sys','fss-anytls-LICENSE.x-sys'),('NOTICE','fss-anytls-NOTICE')]:payload['shadowsocks/ss/'+dest]=(ROOT/'tool/fss-anytls-client'/src).read_bytes()
manifest={'build':'3.5.30-anytls-native.2','platform':'hnd/full','baseline_commit':'463eb6ad019024bf5f23de55a7e9a08e33fb672a','baseline_package_sha256':hashlib.sha256(BASE.read_bytes()).hexdigest(),'client':{'version':'0.1.0','sing_anytls':'v0.0.11','sing':'v0.6.1','go':'go1.24.4','upx':'5.3.0','raw_sha256':hashlib.sha256((OUT/'fss-anytls-client-hnd.raw').read_bytes()).hexdigest(),'packed_sha256':hashlib.sha256(payload['shadowsocks/bin/fss-anytls-client']).hexdigest()},'source_files':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'tool/fss-anytls-client').iterdir()) if p.is_file()},'files':{k:hashlib.sha256(v).hexdigest() for k,v in payload.items()}}
# The delta manifest describes exactly the files the router guard will install.
payload['shadowsocks/ss/fork-build.json']=(json.dumps(manifest,indent=2)+'\n').encode()
def write(name,delta):
 path=OUT/name
 with path.open('wb') as f,gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as dest:
  if not delta:
   with tarfile.open(BASE) as source:
    for entry in source:
     if entry.name in payload:continue
     data=source.extractfile(entry) if entry.isfile() else None
     entry=copy.copy(entry);entry.uid=entry.gid=0;entry.uname=entry.gname='root';entry.mtime=0
     dest.addfile(entry,data)
  for name,data in payload.items():
   entry=tarfile.TarInfo(name);entry.size=len(data);entry.mode=0o755 if name.endswith('.sh') or name.endswith('/fss-anytls-client') else 0o644
   dest.addfile(entry,io.BytesIO(data))
 return {'name':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size}
result={'manifest':manifest,'packages':[write('fancyss_hnd_full-anytls-native.2.tar.gz',False),write('fancyss_hnd_native.2-delta.tar.gz',True)]}
(OUT/'native-v2-build.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result['packages'],indent=2))
