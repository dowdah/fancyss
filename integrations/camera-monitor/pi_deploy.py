"""Run as root after independent source verification; never opens SQLite."""
import hashlib,json,os,pathlib,shutil,subprocess,time
ROOT=pathlib.Path('/var/backups/camera-monitor/fancyss-direct-v1-control-v4')
STAGE=pathlib.Path('/tmp/fancyss-cm-native-v1')
APP=pathlib.Path('/opt/camera-monitor/camera_monitor')
if os.geteuid()!=0:raise SystemExit('root required for file installation only')
manifest=json.loads((STAGE/'source-manifest.json').read_text())
for name in ('graph.py','uploader.py'):
    info=manifest['camera_monitor/'+name]
    if hashlib.sha256((APP/name).read_bytes()).hexdigest()not in {info['baseline_sha256'],info.get('accepted_v1_sha256')}:raise SystemExit('production source drift: '+name)
    if hashlib.sha256((STAGE/'camera_monitor'/name).read_bytes()).hexdigest()!=info['patched_sha256']:raise SystemExit('payload mismatch: '+name)
if ROOT.exists():
    if (ROOT/'pending').exists() or not (ROOT/'rolled-back').exists():raise SystemExit('previous attempt is not a verified rollback')
    for name in ('graph.py','uploader.py'):
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()not in {manifest['camera_monitor/'+name]['baseline_sha256'],manifest['camera_monitor/'+name].get('accepted_v1_sha256')}:raise SystemExit('original backup drift')
    history=ROOT/'history'/time.strftime('%Y%m%dT%H%M%S')
    history.mkdir(parents=True,mode=0o700)
    for name in ('rolled-back','confirmed','deadline'):
        if (ROOT/name).exists():shutil.move(str(ROOT/name),str(history/name))
else:
    ROOT.mkdir(parents=True,mode=0o700)
    for name in ('graph.py','uploader.py'):shutil.copy2(APP/name,ROOT/name)
shutil.copy2(STAGE/'pi_guard.sh',ROOT/'guard.sh');os.chmod(ROOT/'guard.sh',0o700)
(ROOT/'deadline').write_text(str(int(float(pathlib.Path('/proc/uptime').read_text().split()[0]))+300)+'\n')
(ROOT/'pending').touch()
subprocess.run(['systemd-run','--unit=cm-fancyss-direct-v1-guard-'+str(int(time.time())),'--property=RuntimeMaxSec=900','/bin/sh',str(ROOT/'guard.sh')],check=True)
try:
    subprocess.run(['systemctl','stop','camera-uploader','camera-viewing-uploader','camera-web'],check=True)
    for name in ('graph.py','uploader.py'):
        target=APP/name;old=target.stat();temp=target.with_name('.'+name+'.native-v1')
        shutil.copyfile(STAGE/'camera_monitor'/name,temp);shutil.copystat(target,temp);os.chown(temp,old.st_uid,old.st_gid);os.replace(temp,target)
    subprocess.run(['systemctl','start','camera-uploader','camera-viewing-uploader','camera-web'],check=True)
    for name in ('graph.py','uploader.py'):
        if hashlib.sha256((APP/name).read_bytes()).hexdigest()!=manifest['camera_monitor/'+name]['patched_sha256']:raise RuntimeError('post-copy mismatch')
    print(json.dumps({'deployed':True,'guard':'pending','files':['graph.py','uploader.py']}))
except BaseException:
    subprocess.run(['/bin/sh',str(ROOT/'guard.sh'),'rollback'])
    raise
