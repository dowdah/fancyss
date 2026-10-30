"""Pi-only persistent verified HTTPS load through the isolated router proxy."""
import argparse,concurrent.futures,json,socket,ssl,threading,time
p=argparse.ArgumentParser();p.add_argument('--proxy',default='192.168.50.1:30556');p.add_argument('--credentials-file',required=True);p.add_argument('--connections',type=int,default=1);p.add_argument('--hold',type=float,default=30);a=p.parse_args()
if not 1<=a.connections<=128:raise SystemExit(2)
cred=json.load(open(a.credentials_file));host,port=a.proxy.rsplit(':',1);context=ssl.create_default_context();stop=threading.Event();lock=threading.Lock();sockets=[];workers=[];stats={'connected':0,'failed':0,'heartbeat_errors':0,'verified_https_204':0,'tls13':0}
def receive(s,n):
 b=b''
 while len(b)<n:
  v=s.recv(n-len(b))
  if not v:raise OSError('early close')
  b+=v
 return b
def request(s,r):
 s.sendall(b'GET /generate_204 HTTP/1.1\r\nHost: www.google.com\r\nConnection: keep-alive\r\n\r\n')
 status=r.readline(4096)
 if b' 204 ' not in status:raise OSError('unexpected status')
 while True:
  h=r.readline(4096)
  if not h:raise OSError('early response close')
  if h==b'\r\n':break
  if h.lower().startswith(b'connection:') and b'close' in h.lower():raise OSError('nonpersistent response')
 with lock:stats['verified_https_204']+=1
def maintain(s,r):
 while not stop.wait(5):
  try:request(s,r)
  except Exception:
   if not stop.is_set():
    with lock:stats['heartbeat_errors']+=1
   return
def connect(i):
 raw=None
 try:
  raw=socket.create_connection((host,int(port)),timeout=15);raw.sendall(b'\x05\x01\x02')
  if receive(raw,2)!=b'\x05\x02':raise OSError('auth selection')
  u=cred['user'].encode();pw=cred['pass'].encode();raw.sendall(bytes([1,len(u)])+u+bytes([len(pw)])+pw)
  if receive(raw,2)!=b'\x01\x00':raise OSError('auth failed')
  target=b'www.google.com';raw.sendall(bytes([5,1,0,3,len(target)])+target+b'\x01\xbb')
  h=receive(raw,4)
  if h[:2]!=b'\x05\x00':raise OSError('connect failed')
  n={1:4,4:16}.get(h[3]);n=receive(raw,1)[0] if h[3]==3 else n
  if n is None:raise OSError('reply address')
  receive(raw,n+2);s=context.wrap_socket(raw,server_hostname='www.google.com');s.settimeout(10);r=s.makefile('rb');request(s,r)
  t=threading.Thread(target=maintain,args=(s,r));t.daemon=True
  with lock:sockets.append((s,r));workers.append(t);stats['connected']+=1;stats['tls13']+=s.version()=='TLSv1.3'
  t.start()
 except Exception as e:
  if raw is not None:raw.close()
  with lock:stats['failed']+=1
  print(json.dumps({'event':'connection_failed','index':i,'error':type(e).__name__}),flush=True)
start=time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
 futures=[]
 for i in range(a.connections):
  futures.append(pool.submit(connect,i))
  if (i+1)%8==0:time.sleep(.25)
 for f in futures:f.result()
print(json.dumps({'event':'established','time':time.time(),'requested':a.connections,'setup_seconds':time.monotonic()-start,**stats}),flush=True)
if stats['connected']==a.connections:stop.wait(a.hold)
stop.set()
for s,r in sockets:
 try:s.shutdown(socket.SHUT_RDWR)
 except OSError:pass
 s.close()
for t in workers:t.join(timeout=11)
for s,r in sockets:r.close()
print(json.dumps({'event':'finished','time':time.time(),'requested':a.connections,'seconds':time.monotonic()-start,**stats}),flush=True)
raise SystemExit(bool(stats['failed'] or stats['heartbeat_errors']))
