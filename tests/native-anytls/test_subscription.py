"""Run native reconciliation on synthetic revisions, without router services."""
import json,pathlib,subprocess,tempfile,unittest
from test_shunt import function
class SubscriptionTests(unittest.TestCase):
    NODE={'type':'9','anytls_server':'a.invalid','anytls_port':'443','anytls_pass':'secret','anytls_sni':'','anytls_ai':'1'}
    def run_reconcile(self,current='7',effective=True,restart_ok=True,recorded=None,node=None):
        node=dict(node or self.NODE,_rev=int(current))
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'meta').mkdir();(p/'meta/12.meta').write_text('node_type=9\nnode_rev=7\n')
            (p/'node.json').write_text(json.dumps(node))
            tool=p/'node-tool';tool.write_text('#!/bin/sh\necho '+("'[{}]'" if effective else "'[]'")+'\n');tool.chmod(0o700)
            program=function('fss_shunt_reconcile_anytls_subscription')+function('fss_shunt_anytls_transport_digest')+function('fss_shunt_record_anytls_transport')+f'''
dbus() {{ case "$2" in ss_basic_enable) echo 1;; ss_basic_mode) echo 7;; esac; }}
fss_shunt_has_anytls() {{ return 0; }}
fss_shunt_loaded_node_ids() {{ echo 12; }}
fss_pick_node_tool() {{ echo {tool}; }}
fss_v2_get_node_json_by_id() {{ cat {p}/node.json; }}
fss_shunt_get_default_node_id() {{ echo 12; }}
fss_shunt_get_effective_default_target() {{ echo 12; }}
fss_shunt_rules_json_resolved() {{ echo '[]'; }}
fss_get_node_field_plain() {{ echo 9; }}
fss_shunt_state_failed() {{ echo failed="$1"; }}
fss_shunt_log() {{ :; }}
fss_shunt_restart_after_subscription() {{ echo native_restart; return {0 if restart_ok else 1}; }}
FSS_SHUNT_RUNTIME_ARTIFACT_DIR={p}
FSS_SHUNT_RUNTIME_DIR={p}
'''
            if recorded is not None:
                # Record against the fields as built, then mutate per the case.
                (p/'built.json').write_text(json.dumps(dict(self.NODE,_rev=7)))
                (p/'ids').write_text('12\n')
                program+=f'fss_v2_get_node_json_by_id() {{ cat {p}/built.json; }}\nfss_shunt_record_anytls_transport {p}/ids\nfss_v2_get_node_json_by_id() {{ cat {p}/node.json; }}\n'
            program+='fss_shunt_reconcile_anytls_subscription\n'
            return subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
    def test_unchanged_revision_does_not_restart(self):
        r=self.run_reconcile();self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('native_restart',r.stdout)
    def test_changed_revision_restarts_once(self):
        r=self.run_reconcile(current='8');self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.count('native_restart'),1)
    def test_disabled_or_removed_target_fails_without_retargeting(self):
        r=self.run_reconcile(effective=False);self.assertEqual(r.returncode,2);self.assertIn('failed=missing_target',r.stdout);self.assertNotIn('native_restart',r.stdout)
    def test_rev_bump_with_same_transport_does_not_restart(self):
        # Source-level sync rewrites every node of a source; only real
        # transport changes may restart (2026-11-03 06:00 production case).
        r=self.run_reconcile(current='8',recorded=True);self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('native_restart',r.stdout)
    def test_transport_change_restarts_even_with_same_rev(self):
        for field,value in [('anytls_pass','rotated'),('anytls_port','8443'),('anytls_sni','sni.invalid'),('anytls_ai','0'),('anytls_server','b.invalid')]:
            with self.subTest(field=field):
                r=self.run_reconcile(recorded=True,node=dict(self.NODE,**{field:value}))
                self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.count('native_restart'),1)
    def test_restart_failure_is_reported(self):
        r=self.run_reconcile(current='8',restart_ok=False);self.assertEqual(r.returncode,1);self.assertIn('failed=subscription_restart',r.stdout)
