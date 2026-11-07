"""Exercise the maintained DNS script with fake processes and no network."""
import json, os, pathlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'integrations/airport-node-dns/airport-node-dns.sh'
class AirportDnsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name);self.bin=self.root/'bin';self.bin.mkdir()
        self.proc=self.root/'proc';(self.proc/'42').mkdir(parents=True)
        self.airdns=self.root/'airdns';self.airdns.write_text('fixture')
        (self.proc/'42/exe').symlink_to(self.airdns)
        self.conf=self.root/'smartdns.conf';self.conf.write_text('fixture')
        (self.proc/'42/cmdline').write_bytes(b'airdns\0-f\0-c\0'+str(self.conf).encode()+b'\0')
        (self.proc/'42/stat').write_text('42 (airdns) '+' '.join(['S']+['0']*18+['99'])+'\n')
        self.pid=self.root/'pid';self.pid.write_text('42 99\n')
        self.scope=self.root/'identities';self.scope.write_text('airport-a\n')
        self.nodes=self.root/'nodes.json';self.nodes.write_text(json.dumps([
            {'id':'1','airport_identity':'airport-a','server':'a.airport.invalid'},
            {'id':'2','airport_identity':'airport-a','server':'192.0.2.1'},
            {'id':'3','airport_identity':'unrelated','server':'b.unrelated.invalid'}]))
        self.rule=self.root/'rules.conf'
        self.command('netstat', '''
cat "$FIXTURE_ROOT/netstat"
pid=$(cat "$FIXTURE_ROOT/dnsmasq-pid" 2>/dev/null) || exit 0
echo "udp 0 0 127.0.0.1:53 0.0.0.0:* $pid/dnsmasq"
''')
        (self.root/'netstat').write_text('tcp 0 0 127.0.0.1:6053 0.0.0.0:* LISTEN 42/airdns\nudp 0 0 127.0.0.1:6053 0.0.0.0:* 42/airdns\n')
        self.command('node-tool','cat "$FIXTURE_ROOT/nodes.json"')
        self.command('logger',':')
        self.command('dnsmasq','[ ! -e "$FIXTURE_ROOT/bad-syntax" ]')
        self.command('service', '''
[ ! -e "$FIXTURE_ROOT/reload-fails" ] || exit 1
echo reload >> "$FIXTURE_ROOT/reloads"
pid=$((50+$(wc -l < "$FIXTURE_ROOT/reloads")))
mkdir -p "$FIXTURE_ROOT/proc/$pid"
printf '%s (dnsmasq) S %s99\n' "$pid" "$(printf '0 %.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18)" > "$FIXTURE_ROOT/proc/$pid/stat"
echo "$pid" > "$FIXTURE_ROOT/dnsmasq-pid"
''')
        (self.root/'dnsmasq.conf').write_text(f'conf-dir={self.root}\n')
        self.command('sleep', ':')
        self.command('dnsclient','[ ! -e "$FIXTURE_ROOT/no-answer" ] && echo 192.0.2.20')
        self.env=dict(os.environ,AIRPORT_TEST_PATH=str(self.bin)+':'+os.environ['PATH'],
            AIRPORT_AIRDNS=str(self.airdns),AIRPORT_CONF=str(self.conf),AIRPORT_PIDFILE=str(self.pid),
            AIRPORT_RULE=str(self.rule),AIRPORT_SCOPE=str(self.scope),AIRPORT_SUFFIXES=str(self.root/"suffixes"),AIRPORT_PROC=str(self.proc),
            AIRPORT_LOCK=str(self.root/'lock'),AIRPORT_STATUS=str(self.root/'status'),AIRPORT_DNSMASQ_CONF=str(self.root/'dnsmasq.conf'),
            AIRPORT_NODE_TOOL=str(self.bin/'node-tool'),AIRPORT_JQ=shutil.which('jq'),FIXTURE_ROOT=str(self.root))
    def command(self,name,body):
        p=self.bin/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
    def run_script(self,*args):
        return subprocess.run(['/bin/sh',str(SCRIPT),*args],env=self.env,text=True,capture_output=True)
    def test_scope_ip_filter_and_noop_does_not_reload(self):
        a=self.run_script('sync');self.assertEqual(a.returncode,0,a.stderr)
        text=self.rule.read_text();self.assertIn('a.airport.invalid',text);self.assertNotIn('192.0.2.1',text);self.assertNotIn('unrelated',text)
        self.assertEqual((self.root/'reloads').read_text(),'reload\n')
        self.assertEqual(self.run_script('sync').returncode,0)
        self.assertEqual((self.root/'reloads').read_text(),'reload\n')
    def test_defer_and_removed_source_clear_rules(self):
        self.assertEqual(self.run_script('sync','--defer-reload').returncode,0)
        self.assertFalse((self.root/'reloads').exists())
        self.nodes.write_text('[]')
        self.assertEqual(self.run_script('sync').returncode,0)
        self.assertNotIn('server=/',self.rule.read_text())

    def test_deferred_rules_reload_before_system_dns_is_queried(self):
        ids = self.root/'ids'
        ids.write_text('1\n')
        self.assertEqual(self.run_script('sync', '--defer-reload').returncode, 0)
        self.assertIn('state=deferred', (self.root/'status').read_text())
        self.command('dnsclient', '''
[ "$3" = 6053 ] || [ -s "$FIXTURE_ROOT/reloads" ] || {
    touch "$FIXTURE_ROOT/stale-query"
    echo 192.0.2.99
    exit 0
}
echo 192.0.2.20
''')
        result = self.run_script('check', '--ids-file', str(ids))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'stale-query').exists())
        self.assertEqual((self.root/'reloads').read_text(), 'reload\n')

    def test_failed_reload_restores_verified_rules_and_leaves_retry_pending(self):
        self.assertEqual(self.run_script('sync').returncode, 0)
        old = self.rule.read_text()
        self.nodes.write_text('[]')
        self.assertEqual(self.run_script('sync', '--defer-reload').returncode, 0)
        (self.root/'reload-fails').touch()
        self.assertNotEqual(self.run_script('sync').returncode, 0)
        self.assertEqual(self.rule.read_text(), old)
        self.assertTrue((self.root/'status.pending').is_file())
        (self.root/'reload-fails').unlink()
        self.assertEqual(self.run_script('sync').returncode, 0)
        self.assertFalse((self.root/'status.pending').exists())
    def test_invalid_export_preserves_old_rules(self):
        self.rule.write_text('old\n');self.nodes.write_text('bad-json')
        self.assertNotEqual(self.run_script('sync').returncode,0)
        self.assertEqual(self.rule.read_text(),'old\n')
    def test_wrong_port_owner_is_rejected(self):
        (self.root/'netstat').write_text('tcp 0 0 127.0.0.1:6053 0.0.0.0:* LISTEN 77/other\n')
        r=self.run_script('sync');self.assertNotEqual(r.returncode,0);self.assertIn('AIRPORT_DNS_PORT_OWNER',r.stderr)
    def test_recycled_pid_is_rejected(self):
        self.pid.write_text('42 98\n')
        self.assertNotEqual(self.run_script('sync').returncode,0)
    def test_target_without_answer_fails_visibly(self):
        ids=self.root/'ids';ids.write_text('1\n');(self.root/'no-answer').touch()
        r=self.run_script('check','--ids-file',str(ids));self.assertNotEqual(r.returncode,0);self.assertIn('AIRPORT_DNS_NO_ANSWER',r.stderr)
    def test_transient_miss_is_retried(self):
        # Production 2026-11-03 13:26: one lost DoH answer refused a node.
        ids=self.root/'ids';ids.write_text('1\n')
        self.command('dnsclient','n=$(cat "$FIXTURE_ROOT/tries" 2>/dev/null || echo 0); echo $((n+1)) > "$FIXTURE_ROOT/tries"; [ "$n" -ge 1 ] && echo 192.0.2.20')
        r=self.run_script('check','--ids-file',str(ids),'--defer-reload');self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.root/'tries').read_text(),'2\n')
    def test_bad_syntax_restores_prior_rule(self):
        self.rule.write_text('server=/old.invalid/127.0.0.1#6053\n');(self.root/'bad-syntax').touch()
        r=self.run_script('sync');self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.rule.read_text(),'server=/old.invalid/127.0.0.1#6053\n')
    def test_stale_lock_identity_is_recovered(self):
        lock=self.root/'lock';lock.mkdir();(lock/'pid').write_text('42 98\n')
        self.assertEqual(self.run_script('sync').returncode,0)
        self.assertFalse(lock.exists())
if __name__=='__main__':unittest.main()
