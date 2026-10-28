"""Confirm only after fresh health, matching source and a natural upload."""
import datetime,hashlib,json,pathlib,subprocess,urllib.request
root=pathlib.Path('/var/backups/camera-monitor/fancyss-direct-v1-control-v4')
manifest=json.loads(pathlib.Path('/tmp/fancyss-cm-native-v1/source-manifest.json').read_text())
for name in ('graph.py','uploader.py'):
    got=hashlib.sha256((pathlib.Path('/opt/camera-monitor/camera_monitor')/name).read_bytes()).hexdigest()
    if got!=manifest['camera_monitor/'+name]['patched_sha256']:raise SystemExit('source hash mismatch')
with urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=15) as r:health=json.load(r)
if health.get('ok') is not True:raise SystemExit('health not ready')
if not (root/'pending').exists():
    if (root/'confirmed').exists():
        print('application_component_already_confirmed=1');raise SystemExit(0)
    raise SystemExit('no pending or confirmed component')
started=(root/'pending').stat().st_mtime
# healthz pipeline metrics are cached and can lag a real completed upload.
# Fetch only completion metadata in a child running as camera-monitor; root
# never opens the production SQLite connection.
rows=json.loads(subprocess.check_output(['runuser','-u','camera-monitor','--','/opt/camera-monitor/venv/bin/python','/tmp/fancyss-cm-native-v1/probe_verified_upload.py'],text=True))
latest=max((datetime.datetime.fromisoformat(r['verified_at'].replace('Z','+00:00')).timestamp() for r in rows if r.get('verified_at')),default=0)
print(json.dumps({'health_ok':True,'natural_upload_after_deploy':latest>=started,'latest_verified_utc':datetime.datetime.fromtimestamp(latest,datetime.UTC).isoformat() if latest else None}))
if latest<started:raise SystemExit('waiting for natural upload verification')
subprocess.run(['/bin/sh',str(root/'guard.sh'),'commit'],check=True)
print('application_component_confirmed=1')
