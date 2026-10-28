import base64,json,pathlib,subprocess,tempfile,unittest
from test_shunt import function, ROOT
class SmartDnsTests(unittest.TestCase):
    def test_doh_group_roundtrip_and_validated_runtime_line(self):
        item={'id':'fixture','proto':'https','host':'https://cloudflare-dns.com/dns-query','host_ip':'162.159.36.1','port':443,'kind':'preset','provider':'fixture','net':'ipv4'}
        stored='j1:'+base64.b64encode(json.dumps({'version':1,'items':[item]}).encode()).decode()
        dns=ROOT/'fancyss/scripts/ss_base_dns.sh';core=ROOT/'fancyss/ss/ssconfig.sh'
        program='\n'.join(function(x,dns) for x in ['smartdns_decode_json_value','smartdns_validate_group_value'])
        program+='\n'+function('smartdns_append_server_line',core)
        with tempfile.TemporaryDirectory() as d:
            program+='\nSMARTDNS_STORAGE_PREFIX=j1:\nrun() { "$@"; }\nbase64_decode() { base64 -d; }\n'
            program+=f"smartdns_validate_group_value gfw '{stored}' || exit 1\n"
            program+=f"smartdns_append_server_line {d}/conf https '' 443 https://cloudflare-dns.com/dns-query 162.159.36.1 '-group gfw' 1\n"
            r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            text=(pathlib.Path(d)/'conf').read_text()
            self.assertIn('server-https https://cloudflare-dns.com/dns-query',text)
            self.assertIn('-host-ip 162.159.36.1',text);self.assertIn('-proxy fancy_proxy',text)
            self.assertNotIn('no-check-certificate',text)
    def test_explicit_proxy_aaaa_policy_overrides_china_exception(self):
        with tempfile.TemporaryDirectory() as d:
            program=function('smartdns_append_ipv6_policy',ROOT/'fancyss/ss/ssconfig.sh')
            program+='\nfss_airport_special_iter_active_tsv() { :; }\nss_basic_proxy_ipv6=0\n'
            for mode in (1,2,3,5):
                file=pathlib.Path(d)/str(mode)
                r=subprocess.run(['/bin/bash'],input=program+f'\nsmartdns_append_ipv6_policy {file} {mode}\n',text=True,capture_output=True)
                self.assertEqual(r.returncode,0,r.stderr)
                rules=file.read_text()
                self.assertIn('address /domain-set:black_list/#6',rules)
                self.assertIn('address /domain-set:shunt_proxy/#6',rules)
                if mode in (2,3):self.assertLess(rules.index('address /domain-set:chnlist/-6'),rules.rindex('address /domain-set:black_list/#6'))
    def test_shell_anytls_credentials_follow_output_directory(self):
        gen=ROOT/'fancyss/scripts/ss_webtest_gen.sh'
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d);(p/'nodes').mkdir();(p/'unrelated-cache').mkdir()
            program='\n'.join(function(x,gen) for x in ['wt_gen_anytls_outbound','wt_anytls_hostport','wt_shell_quote'])
            program+='''
wt_node_get_plain() { case "$1" in anytls_server) echo example.invalid;; anytls_port) echo 443;; anytls_pass) echo synthetic-only;; esac; }
wt_get_out_file_path() { echo "$WT_GEN_OUT_FILE"; }
wt_get_start_file_path() { echo "$WT_GEN_START_FILE"; }
wt_get_stop_file_path() { echo "$WT_GEN_STOP_FILE"; }
'''
            program+=f'''\nFSS_WEBTEST_CACHE_NODE_DIR={d}/unrelated-cache
WT_GEN_OUT_FILE={d}/nodes/1_outbounds.json.tmp
WT_GEN_START_FILE={d}/nodes/1_start.sh
WT_GEN_STOP_FILE={d}/nodes/1_stop.sh
WT_PRESET_START_PORT=18199
wt_gen_anytls_outbound 1 test
'''
            r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((p/'nodes/1_anytls.pass').read_text(),'synthetic-only')
            self.assertEqual((p/'nodes/1_anytls.pass').stat().st_mode & 0o777,0o600)
            self.assertEqual(list((p/'unrelated-cache').iterdir()),[])
if __name__=='__main__':unittest.main()
