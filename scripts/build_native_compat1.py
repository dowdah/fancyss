#!/usr/bin/env python3
"""Build SNI/DNS-port compatibility fixes over the retained egress.1 release."""
from pathlib import Path
import copy
import gzip
import hashlib
import io
import json
import os
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts'
BASE = OUT / 'fancyss_hnd_full-anytls-native.2-egress.1.tar.gz'
CLIENT = Path(os.environ.get('FSS_ANYTLS_BUILD_OUT', str(OUT)))

def sha(data):
    return hashlib.sha256(data).hexdigest()

assert sha(BASE.read_bytes()) == 'd3dc1fa357a94602ce7741020fa24128fc825ceaa464955800df793edbcd49a8'
assert not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT)
with tarfile.open(BASE) as source:
    manifest = json.load(source.extractfile('shadowsocks/ss/fork-build.json'))
payload = {
    'shadowsocks/bin/fss-anytls-client': (CLIENT / 'fss-anytls-client-hnd').read_bytes(),
    'shadowsocks/ss/ssconfig.sh': (ROOT / 'fancyss/ss/ssconfig.sh').read_bytes(),
}
manifest['build'] = '3.5.30-anytls-native.2-compat.1'
manifest['source_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
manifest['client'].update(
    version='0.1.2',
    packed_sha256=sha(payload['shadowsocks/bin/fss-anytls-client']),
    raw_sha256=sha((CLIENT / 'fss-anytls-client-hnd.raw').read_bytes()),
)
manifest['source_files'] = {
    str(p.relative_to(ROOT)): sha(p.read_bytes())
    for p in sorted((ROOT / 'tool/fss-anytls-client').rglob('*')) if p.is_file()
}
for name, data in payload.items():
    manifest['files'][name] = sha(data)
# The shunt generator is inherited unchanged; update the recorded ssconfig hash.
manifest['egress_fix']['source_hashes']['fancyss/ss/ssconfig.sh'] = sha(payload['shadowsocks/ss/ssconfig.sh'])
manifest['compat_fix'] = {
    'default_sni_independent_of_verification': True,
    'tls_dns_port_precedence': 'explicit endpoint port > separate field > protocol default',
    'smartdns_port_option': False,
}
payload['shadowsocks/ss/fork-build.json'] = (json.dumps(manifest, indent=2) + '\n').encode()

def build(name, full):
    path = OUT / name
    with path.open('wb') as f, gzip.GzipFile(filename='', fileobj=f, mode='wb', mtime=0) as gz, tarfile.open(fileobj=gz, mode='w') as dest:
        if full:
            with tarfile.open(BASE) as source:
                for original in source:
                    if original.name in payload:
                        continue
                    member = copy.copy(original)
                    member.uid = member.gid = 0
                    member.uname = member.gname = 'root'
                    member.mtime = 0
                    dest.addfile(member, source.extractfile(original) if original.isfile() else None)
        for name, data in payload.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = 0o755 if name.endswith(('.sh', '/fss-anytls-client')) else 0o644
            dest.addfile(member, io.BytesIO(data))
    return {'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes())}

result = {'manifest': manifest, 'packages': [
    build('fancyss_hnd_full-anytls-native.2-compat.1.tar.gz', True),
    build('fancyss_hnd_native.2-compat.1-delta.tar.gz', False),
]}
(OUT / 'native-compat1-build.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['packages'], indent=2))
