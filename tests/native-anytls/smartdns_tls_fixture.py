"""Offline Linux fixture for the shipped SmartDNS binary; run with network=none.

Mount a synthetic cert/key for dns.fixture.invalid at /cert, the binary at
/opt/smartdns and generated cases at /cases.json. No external DNS or traffic.
"""
import base64
import http.server
import json
import pathlib
import socket
import socketserver
import ssl
import struct
import subprocess
import threading
import time
import urllib.parse

hits = []
lock = threading.Lock()
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/cert/cert.pem', '/cert/key.pem')

def answer(query):
    # Fixture queries contain one uncompressed question.
    end = 12
    while query[end]:
        end += query[end] + 1
    end += 5
    return query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:end] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xc0\x00\x02\x21'

class HTTP(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        query = self.rfile.read(int(self.headers['Content-Length']))
        self.reply(query)

    def do_GET(self):
        value = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['dns'][0]
        self.reply(base64.urlsafe_b64decode(value + '=' * (-len(value) % 4)))

    def reply(self, query):
        with lock:
            hits.append((self.server.server_port, self.path))
        body = answer(query)
        self.send_response(200)
        self.send_header('Content-Type', 'application/dns-message')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

class DOT(socketserver.StreamRequestHandler):
    def handle(self):
        size = self.rfile.read(2)
        if len(size) != 2:
            return
        query = self.rfile.read(struct.unpack('!H', size)[0])
        with lock:
            hits.append((self.server.server_address[1], 'dot'))
        body = answer(query)
        self.wfile.write(struct.pack('!H', len(body)) + body)

class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

for port in [443, 853, 8443, 9443, 8853]:
    server = TCP(('127.0.0.1', port), DOT) if port == 8853 else http.server.ThreadingHTTPServer(('127.0.0.1', port), HTTP)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()

version = subprocess.check_output(['/opt/smartdns', '-v'], text=True).strip()
print(version, flush=True)
assert '47.1' in version
query = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x04test\x00\x00\x01\x00\x01'
for case in json.loads(pathlib.Path('/cases.json').read_text()):
    pathlib.Path('/tmp/dns.conf').write_text('bind 127.0.0.1:15353\ncache-size 0\nspeed-check-mode none\nca-file /cert/cert.pem\nlog-level debug\nlog-file /tmp/dns.log\n' + case['line'] + '\n')
    with lock:
        hits.clear()
    p = subprocess.Popen(['/opt/smartdns', '-f', '-p', '/tmp/dns.pid', '-c', '/tmp/dns.conf'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        result = None
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if p.poll() is not None:
                break
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(.5)
                client.sendto(query, ('127.0.0.1', 15353))
                try:
                    result = client.recv(4096)
                    if result.endswith(b'\xc0\x00\x02\x21'):
                        break
                except TimeoutError:
                    pass
        with lock:
            observed = list(hits)
        assert result and result.endswith(b'\xc0\x00\x02\x21'), (case, observed, pathlib.Path('/tmp/dns.log').read_text()[-4000:])
        assert observed and all(port == case['port'] for port, _ in observed), (case, observed)
        print(json.dumps({'case': case['name'], 'dns_answer': '192.0.2.33', 'actual_tls_ports': sorted({port for port, _ in observed}), 'certificate_verification': True}), flush=True)
    finally:
        p.terminate()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
