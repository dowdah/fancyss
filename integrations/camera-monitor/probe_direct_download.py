"""Authenticated bounded acceptance as camera-monitor; logs no URLs or tokens."""
import json,os,pathlib,pwd,sys
if os.geteuid()!=pwd.getpwnam('camera-monitor').pw_uid:raise SystemExit('service account required')
sys.path.insert(0,'/opt/camera-monitor')
if os.environ.get('CREDENTIALS_DIRECTORY'):
    os.environ['CAMERA_PERSONAL_TOKEN_CREDENTIAL_PATH']=str(pathlib.Path(os.environ['CREDENTIALS_DIRECTORY'])/'camera-monitor-graph-token-cache')
from camera_monitor.config import load_config
from camera_monitor.db import Database
from camera_monitor.graph import GraphClient,GraphError
from urllib.parse import urlsplit

def hook(response,*args,**kwargs):
    connection=getattr(response.raw,'_connection',None)
    sock=getattr(connection,'sock',None)
    host=urlsplit(response.url).hostname
    result={'host':host,'http':response.status_code}
    if sock is not None:
        result.update(local=list(sock.getsockname())[:2],peer=list(sock.getpeername())[:2])
    print(json.dumps(result),flush=True)
try:
    cfg=load_config('/etc/camera-monitor/config.toml')
    db=Database(cfg.database_path)
    with db.connect() as c:
        found=c.execute("SELECT id,kind,remote_item_id,size_bytes,remote_storage_layout,remote_root_id FROM recordings WHERE kind='viewing' AND verified_at IS NOT NULL AND remote_item_id IS NOT NULL AND remote_deleted_at IS NULL AND size_bytes>=1048576 ORDER BY id DESC LIMIT 1").fetchone()
    if found is None:raise RuntimeError('no eligible existing recording')
    row=dict(found)
    client=GraphClient(cfg,request_retries=0,auth_deadline_seconds=40).for_recording(row)
    client.session.hooks['response']=[hook]
    client.data_session.hooks['response']=[hook]
    client.msal_http_client.session.hooks['response']=[hook]
    metadata=client.item(str(row['remote_item_id']))
    if int(metadata.get('size',0))<1048576:raise RuntimeError('metadata size mismatch')
    payload=client.download_range(str(row['remote_item_id']),0,1048576)
    print(json.dumps({'recording_id':row['id'],'control_authenticated':True,'range_bytes':len(payload),'direct_body_proxy_env':client.data_session.trust_env}),flush=True)
except GraphError as exc:
    print(json.dumps({'error':type(exc).__name__,'safe_code':exc.safe_code,'http':exc.status_code}),flush=True);raise SystemExit(1)
except Exception as exc:
    print(json.dumps({'error':type(exc).__name__}),flush=True);raise SystemExit(1)
