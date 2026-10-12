"""Run with the exact Synapse image's Python/PyYAML; no private inputs needed."""
import pathlib,re,unittest,yaml
ROOT=pathlib.Path(__file__).resolve().parents[1]
entry=(ROOT/'stack.config/synapse/entrypoint.sh').read_text()
ns={'yaml':yaml};exec(entry[entry.index('class UniqueYaml'):entry.index("with open('$HOMESERVER_TEMPLATE'")],ns)
Loader=ns['UniqueYaml']
class PrivateYamlTests(unittest.TestCase):
 def test_duplicate_root(self):
  with self.assertRaises(ValueError):yaml.load('private: one\nprivate: two\n',Loader=Loader)
 def test_duplicate_nested(self):
  with self.assertRaises(ValueError):yaml.load('auth:\n  token: one\n  token: two\n',Loader=Loader)
 def test_merge_shadow(self):
  with self.assertRaises(ValueError):yaml.load('base: &b {key: one}\nauth: {<<: *b, key: two}\n',Loader=Loader)
 def test_scalar_type_collision(self):
  with self.assertRaises(ValueError):yaml.load('true: one\n1: two\n',Loader=Loader)
 def test_canonical_template(self):
  s=(ROOT/'stack.config/synapse/homeserver.yaml').read_text().replace('{{SYNAPSE_LEGACY_SSO_CONFIG}}','')
  s=re.sub(r'\{\{[^}]+\}\}','synthetic',s);x=yaml.load(s,Loader=Loader)
  self.assertEqual(x['trusted_key_servers'],[{'server_name':'matrix.org'}])
 def test_private_file_and_generic_failure_contract(self):
  self.assertIn('umask 077',entry);self.assertIn('os.O_NOFOLLOW',entry);self.assertIn('os.fchmod(fd, 0o600)',entry)
  self.assertIn("raise SystemExit('Synapse configuration rejected: invalid or duplicate YAML')",entry)
  self.assertNotIn('print(parsed)',entry)
if __name__=='__main__':unittest.main()
