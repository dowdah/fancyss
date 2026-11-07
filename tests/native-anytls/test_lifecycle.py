"""Stop paths must not abandon the rest of shutdown on one helper failure."""
import pathlib,subprocess,tempfile,unittest
from test_shunt import function
ROOT=pathlib.Path(__file__).resolve().parents[2]
class LifecycleTests(unittest.TestCase):
    def test_kill_process_continues_after_helper_stop_failure(self):
      with tempfile.TemporaryDirectory() as d:
        log=pathlib.Path(d)/'log'
        program=function('kill_process',ROOT/'fancyss/ss/ssconfig.sh')+f'''
fss_require_shunt_lib() {{ :; }}
fss_shunt_stop_runtime_artifact_helpers() {{ return 1; }}
echo_date() {{ echo "$*"; }}
pidof() {{ [ "$1" = xray ] && echo 999999; }}
ps() {{ :; }}
killall() {{ echo killall "$1" >> {log}; }}
kill() {{ :; }}
perpctl() {{ :; }}
LINUX_VER=26
kill_process
echo status=$?
'''
        r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
        self.assertIn('killall xray',log.read_text(),r.stderr)
        self.assertIn('status=1',r.stdout)
    def test_unreachable_supervisor_still_stops_owned_pid(self):
        s=(ROOT/'fancyss/scripts/ss_anytls_helper.sh').read_text()
        stop=s[s.index('stop_instance() {'):s.index('case "$action" in')]
        with tempfile.TemporaryDirectory() as d:
            svc=pathlib.Path(d)/'fss-anytls-12';svc.mkdir()
            program=stop+f'''
service_name=fss-anytls-12
service_dir={svc}
perpctl() {{ return 1; }}
stop_owned() {{ [ ! -d "$service_dir" ] && echo stopped_after_definition_removed; }}
stop_instance
echo status=$?
'''
            r=subprocess.run(['/bin/bash'],input=program,text=True,capture_output=True)
            self.assertIn('stopped_after_definition_removed',r.stdout,r.stderr)
            self.assertIn('status=0',r.stdout);self.assertFalse(svc.exists())
if __name__=='__main__':unittest.main()
