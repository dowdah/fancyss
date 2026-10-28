"""Policy overlaps and DNS aggregation regressions; no production fixtures."""
import base64,json,pathlib,subprocess,tempfile,unittest
from test_shunt import function
class PolicyTests(unittest.TestCase):
    def test_dns_union_excludes_domestic_direct_preserves_body(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)
            entries=[('first','7','custom',''),('second','8','custom',''),('body','DIRECT','custom',''),('cn','DIRECT','builtin','chnlist')]
            for n,*_ in entries:(p/n).write_text('domain:'+n+'.invalid\n')
            (p/'active').write_text(''.join(f'{n}|{target}|{p/n}|{src}|{preset}|\n' for n,target,src,preset in entries))
            r=subprocess.run(['bash'],input=function('fss_shunt_rebuild_proxy_domains')+f'\nfss_shunt_rebuild_proxy_domains {p}/active {p}/dns',text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(set((p/'dns').read_text().splitlines()),{'first.invalid','second.invalid','body.invalid'})
    def test_explicit_graph_beats_microsoft_direct_and_cn_beats_default(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)
            for n in ['site','ip']:(p/n).touch();(p/n).write_text('fixture')
            rules=[{'type':'field','inboundTag':['socks-in'],'outboundTag':'proxy7'},
                   {'type':'field','ruleTag':'custom','domain':['full:my.microsoftpersonalcontent.com','domain:livefilestore.com'],'outboundTag':'direct'},
                   {'type':'field','ruleTag':'fss_default','network':'tcp,udp','outboundTag':'proxy7'}]
            f=p/'xray.json';f.write_text(json.dumps({'routing':{'rules':rules}}))
            black=base64.b64encode(b'graph.microsoft.com\nlogin.live.com').decode()
            white=base64.b64encode(b'microsoft.com\nqq.com').decode()
            prog='\n'.join(function(n) for n in ['fss_shunt_custom_domain_to_tokens','fss_shunt_custom_ip_to_tokens','fss_shunt_json_array_from_file','fss_shunt_emit_native_policy','fss_shunt_apply_native_policy'])
            prog+=f'''\ndbus() {{ case "$2" in ss_wan_black_domain) echo {black};; ss_wan_white_domain) echo {white};; esac; }}
fss_b64_decode() {{ printf '%s' "$1" | base64 -d; }}
fss_shunt_runtime_mode() {{ echo 2; }}
FSS_SHUNT_GEOSITE_FILE={p}/site
FSS_SHUNT_GEOIP_FILE={p}/ip
fss_shunt_apply_native_policy {f} proxy7
'''
            r=subprocess.run(['bash'],input=prog,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            out=json.loads(f.read_text())['routing']['rules']
            self.assertEqual([x.get('ruleTag') for x in out],[None,'fss_recording_body','fss_native_black_domain','fss_native_white_domain','custom','fss_native_cn_domain','fss_native_cn_ip','fss_default'])
            def route(domain):
                for rule in out:
                    if 'inboundTag' in rule:continue
                    for token in rule.get('domain',[]):
                        kind,_,host=token.partition(':')
                        if kind=='full' and host==domain or kind=='domain' and (host==domain or domain.endswith('.'+host)):return rule['outboundTag']
                return out[-1]['outboundTag']
            self.assertEqual(route('graph.microsoft.com'),'proxy7')
            self.assertEqual(route('static.microsoft.com'),'direct')
            self.assertEqual(route('my.microsoftpersonalcontent.com'),'direct')
            self.assertEqual(route('q.qlogo.cn'),'proxy7') # No invented avatar whitelist.
if __name__=='__main__':unittest.main()
