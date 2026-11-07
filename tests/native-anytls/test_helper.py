"""Ownership follows installed backend symlinks, not merely binary basenames."""
import pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
def owned_source():
    s=(ROOT/'fancyss/scripts/ss_anytls_helper.sh').read_text()
    return s[s.index('owned() {'):s.index('listening() {')]
class HelperTests(unittest.TestCase):
    def test_relocated_legacy_identity_and_stale_pid(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d).resolve();(p/'proc/123').mkdir(parents=True)
            old=p/'data-legacy';old.write_text('fixture');(p/'legacy-link').symlink_to(old)
            (p/'proc/123/exe').symlink_to(old)
            # Explicit bytes avoid accidental octal escapes in the fixture.
            (p/'proc/123/cmdline').write_bytes(b'legacy\x00/private/password-file\x00-l\x00127.0.0.1:18082\x00')
            (p/'pid').write_text('123 77\n')
            code=owned_source()+f'''\nproc={p}/proc
pidfile={p}/pid
binary={p}/new-client
legacy_binary={p}/legacy-link
passfile=/private/password-file
listen=127.0.0.1:18082
ticks() {{ echo 77; }}
owned || exit 1
[ "$instance_binary" != "$binary" ] || exit 1
printf '123 78\\n' > "$pidfile"
if owned; then exit 2; fi
printf '123 77\\n' > "$pidfile"
passfile=/different/password-file
if owned; then exit 3; fi
'''
            r=subprocess.run(['bash'],input=code,text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
if __name__=='__main__':unittest.main()
