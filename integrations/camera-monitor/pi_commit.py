"""Confirm only after fresh health, matching source and a natural upload."""
import datetime,hashlib,json,pathlib,subprocess,urllib.request
root=pathlib.Path('/var/backups/camera-monitor/fancyss-direct-v1-control-v4')
manifest=json.loads(pathlib.Path('/tmp/fancyss-cm-native-v1/source-manifest.json').read_text())
for name in ('graph.py','uploader.py'):
    got=hashlib.sha256((pathlib.Path('/opt/camera-monitor/camera_monitor')/name).read_bytes()).hexdigest()
    if got!=manifest['camera_monitor/'+name]['patched_sha256']:raise SystemExit('source hash mismatch')
with urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=15) as r:health=json.load(r)
if health.get('ok') is not True:raise SystemExit('health not ready')
started=(root/'pending').stat().st_mtime
found=[]
def walk(x,path=''):
    if isinstance(x,dict):
        for k,v in x.items():
            if k=='last_verified_at' and 'emergency' in path and v:
                found.append(datetime.datetime.fromisoformat(v.replace('Z','+00:00')).timestamp())
            else:walk(v,path+'/'+k)
    elif isinstance(x,list):
        for v in x:walk(v,path)
walk(health)
latest=max(found,default=0)
print(json.dumps({'health_ok':True,'natural_upload_after_deploy':latest>=started,'latest_verified_utc':datetime.datetime.fromtimestamp(latest,datetime.UTC).isoformat() if latest else None}))
if latest<started:raise SystemExit('waiting for natural upload verification')
subprocess.run(['/bin/sh',str(root/'guard.sh'),'commit'],check=True)
print('application_component_confirmed=1')
