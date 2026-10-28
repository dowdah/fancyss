#!/usr/bin/env python3
"""Repackage the pinned hnd/full baseline; no downloads or rule/core updates."""
from pathlib import Path
import copy, gzip, hashlib, io, json, re, subprocess, tarfile
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts';OUT.mkdir(exist_ok=True)
BASE=ROOT/'packages/fancyss_hnd_full.tar.gz'
PATCH_FILES=['install.sh','ss/ssconfig.sh','scripts/ss_base_dns.sh','scripts/ss_node_shunt.sh','scripts/ss_node_subscribe.sh','scripts/ss_subscribe_profile.sh','scripts/ss_proc_status.sh','scripts/ss_shunt_hot_reload.sh','scripts/ss_webtest.sh','scripts/ss_webtest_gen.sh','scripts/ss_anytls_helper.sh','scripts/ss_airport_dns_install.sh','scripts/ss_update.sh','webs/Module_shadowsocks.asp']
payload={}
for name in PATCH_FILES:
    data=(ROOT/'fancyss'/name).read_bytes()
    if name=='webs/Module_shadowsocks.asp':
        text=data.decode()
        for k,v in [('NAME','fancyss'),('ARCH','hnd'),('TYPE','full'),('EXTA','')]:
            text=re.sub(r'^var PKG_'+k+r'=.*$',f'var PKG_{k}="{v}"',text,flags=re.M)
        text=re.sub(r'[ \t]*//fancyss-full','',text)
        text=re.sub(r'[ \t]*<!--fancyss-full-->','',text)
        data=text.encode()
    if name=='scripts/ss_proc_status.sh':data=data.replace(b'#@',b'')
    payload['shadowsocks/'+name]=data
payload['shadowsocks/bin/node-tool']=(ROOT/'fancyss/bin-hnd/node-tool').read_bytes()
for name in ['airport-node-dns.sh','airport-node-dns-boot.sh','airport-node-dns-status.sh']:
    payload['shadowsocks/scripts/'+name]=(ROOT/'integrations/airport-node-dns'/name).read_bytes()
manifest={'build':'3.5.30-anytls-native.1','platform':'hnd/full','baseline_commit':'b19e82cb6a05e08990a96905353921819d44d134',
          'baseline_package_sha256':hashlib.sha256(BASE.read_bytes()).hexdigest(),
          'node_tool_commit':subprocess.check_output(['git','-C',str(ROOT/'tool/node-tool'),'rev-parse','HEAD'],text=True).strip(),
          'files':{k:hashlib.sha256(v).hexdigest() for k,v in payload.items()}}
payload['shadowsocks/ss/fork-build.json']=(json.dumps(manifest,indent=2)+'\n').encode()
def write(name,delta=False):
    path=OUT/name
    with path.open('wb') as f,gzip.GzipFile(fileobj=f,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as dest:
        if not delta:
            with tarfile.open(BASE) as source:
                for item in source:
                    if item.name in payload:continue
                    data=source.extractfile(item) if item.isfile() else None
                    item=copy.copy(item);item.uid=item.gid=0;item.uname=item.gname='root';item.mtime=0
                    dest.addfile(item,data)
        for path_name,data in payload.items():
            info=tarfile.TarInfo(path_name);info.size=len(data);info.mode=0o755 if path_name.endswith('.sh') or path_name.endswith('/node-tool') else 0o644
            info.uid=info.gid=0;info.mtime=0;dest.addfile(info,io.BytesIO(data))
    return {'name':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size}
results=[write('fancyss_hnd_full-anytls-native.1.tar.gz'),write('fancyss_hnd_native.1-delta.tar.gz',True)]
(OUT/'native-v1-build.json').write_text(json.dumps({'manifest':manifest,'packages':results},indent=2)+'\n')
print(json.dumps(results,indent=2))
