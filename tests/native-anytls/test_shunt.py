"""Build real shunt JSON with synthetic nodes; never source router base files."""
import json,pathlib,re,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
LIB=ROOT/'fancyss/scripts/ss_node_shunt.sh'
def function(name,path=LIB):
    text=path.read_text();start=text.index(name+'() {');m=re.search(r'^\w+\(\)\s*\{',text[start+len(name)+4:],re.M)
    end=start+len(name)+4+m.start() if m else len(text)
    return text[start:end]
class ShuntTests(unittest.TestCase):
    def test_udp_reject_follows_target_without_overriding_direct(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'outbounds').mkdir();(p/'cache_ids.txt').write_text('1\n2\n')
            for id,protocol in [('1','socks'),('2','vless')]:
                (p/'outbounds'/f'{id}_outbounds.json').write_text(json.dumps({'tag':'proxy'+id,'protocol':protocol,'settings':{}}))
            program='\n'.join(function(x) for x in ['fss_shunt_emit_outbounds_json','fss_shunt_build_xray_config'])
            program+='''
fss_shunt_mode_selected() { return 0; }
fss_shunt_validate_current_node() { return 0; }
fss_shunt_prepare_runtime() { return 0; }
fss_shunt_prepare_outbound_cache() { return 0; }
fss_shunt_write_hot_reload_state() { return 0; }
fss_shunt_get_effective_default_target() { echo 1; }
fss_shunt_target_is_special() { return 1; }
fss_shunt_target_is_direct() { return 1; }
gen_xray_dns_inbound() { return 0; }
fss_shunt_emit_dns_relay_route_rule() { return 0; }
fss_shunt_emit_status_probe_route_rule() { return 0; }
fss_get_node_field_plain() { if [ "$1" = 1 ]; then echo 9; else echo 4; fi; }
fss_shunt_log() { :; }
fss_shunt_emit_routing_rules_json() { echo '{"type":"field","domain":["full:body.invalid"],"outboundTag":"direct"}, {"type":"field","domain":["full:vless.invalid"],"outboundTag":"proxy2"}'; }
'''
            program+=f'FSS_SHUNT_RUNTIME_DIR={d}\nFSS_SHUNT_RUNTIME_OUTBOUND_DIR={d}/outbounds\nFSS_SHUNT_RUNTIME_TARGET_FILE={d}/targets\nfss_shunt_build_xray_config {d}/xray.json 1\n'
            r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            rules=json.loads((p/'xray.json').read_text())['routing']['rules']
            body=next(i for i,x in enumerate(rules) if 'full:body.invalid' in x.get('domain',[]))
            self.assertEqual(rules[body]['outboundTag'],'direct')
            self.assertFalse(any(x.get('outboundTag')=='reject' and 'full:body.invalid' in x.get('domain',[]) for x in rules))
            self.assertFalse(any(x.get('outboundTag')=='reject' and 'full:vless.invalid' in x.get('domain',[]) for x in rules))
            self.assertEqual(rules[-2]['network'],'udp');self.assertEqual(rules[-2]['outboundTag'],'reject')
            self.assertEqual(rules[-1]['outboundTag'],'proxy1')
    def test_helper_failure_is_propagated(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'ids').write_text('1\n');(p/'1.meta').write_text('has_start=1\n')
            (p/'1_start.sh').write_text('#!/bin/sh\nexit 1\n');(p/'1_start.sh').chmod(0o700)
            program=function('fss_shunt_start_runtime_helpers')+f'''\nfss_shunt_state_failed() {{ echo failed; }}
fss_shunt_stop_runtime_artifact_helpers() {{ echo stopped; }}
fss_shunt_start_runtime_helpers {d}/ids {d} {d}
'''
            r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
            self.assertNotEqual(r.returncode,0);self.assertIn('failed',r.stdout);self.assertIn('stopped',r.stdout)
    def test_hot_guard_runs_before_cleanup(self):
        text=(ROOT/'fancyss/scripts/ss_shunt_hot_reload.sh').read_text()
        guard=text.index('if fss_shunt_has_anytls; then')
        self.assertLess(guard,text.index('fss_shunt_cleanup_runtime'))
if __name__=='__main__':unittest.main()
