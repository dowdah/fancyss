"""Return fresh upload completion metadata as the service account only."""
import json,os,pwd,sys
if os.geteuid()!=pwd.getpwnam('camera-monitor').pw_uid:raise SystemExit('service account required')
sys.path.insert(0,'/opt/camera-monitor')
from camera_monitor.config import load_config
from camera_monitor.db import Database
cfg=load_config('/etc/camera-monitor/config.toml')
with Database(cfg.database_path).connect() as c:
    rows=c.execute("SELECT id,kind,size_bytes,verified_at FROM recordings WHERE kind='emergency' AND verified_at IS NOT NULL ORDER BY id DESC LIMIT 5").fetchall()
print(json.dumps([dict(r) for r in rows]))
