"""Read process socket counters only; no database or URL/token access."""
import json,re,subprocess,time,urllib.request
pids={u:subprocess.check_output(['systemctl','show',u,'-p','MainPID','--value'],text=True).strip() for u in ['camera-uploader','camera-viewing-uploader']}
def sample():
    lines=subprocess.check_output(['ss','-tnpiH','state','established','(','dport','=',':443',')'],text=True).splitlines()
    result=[]
    for i,line in enumerate(lines):
        if not any('pid='+pid+',' in line for pid in pids.values()):continue
        counters=lines[i+1] if i+1<len(lines) and lines[i+1].startswith('\t') else ''
        fields=line.split();sent=re.search(r'bytes_sent:(\d+)',counters)
        result.append({'local':fields[2],'peer':fields[3],'bytes_sent':int(sent.group(1)) if sent else 0,'process_pids':[p for p in pids.values() if 'pid='+p+',' in line]})
    return result
first=sample();time.sleep(10);second=sample()
print(json.dumps({'pids':pids,'first':first,'second':second}))
with urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=15) as r:h=json.load(r)
print(json.dumps({'health_ok':h.get('ok'),'end_to_end_status':h.get('end_to_end',{}).get('status'),'queues':{k:{n:v.get(n) for n in ['last_verified_at','pending','status']} for k,v in h.get('end_to_end',{}).get('pipeline_metrics',{}).get('queues',{}).items() if isinstance(v,dict)}}))
