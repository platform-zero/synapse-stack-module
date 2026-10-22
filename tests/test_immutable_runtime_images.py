import re,unittest
from pathlib import Path
EXPECTED=['matrixdotorg/synapse:v1.144.0@sha256:39405b7a2a86ab8e987aa3f4f1e74af11ffaf751a5306f1757bc3fdbd8d19832', 'matrixdotorg/synapse:v1.144.0@sha256:39405b7a2a86ab8e987aa3f4f1e74af11ffaf751a5306f1757bc3fdbd8d19832', 'matrixdotorg/synapse:v1.144.0@sha256:39405b7a2a86ab8e987aa3f4f1e74af11ffaf751a5306f1757bc3fdbd8d19832']
PINS=[['matrixdotorg/synapse:v1.144.0', '39405b7a2a86ab8e987aa3f4f1e74af11ffaf751a5306f1757bc3fdbd8d19832']]
def accept(ref,base,digest):
 if not re.fullmatch(r'[0-9a-f]{64}',digest) or ref!=base+'@sha256:'+digest:raise ValueError('unreviewed or mutable source reference')
class ImmutableRuntimeSource(unittest.TestCase):
 def test_actual_source_image_list(self):
  refs=re.findall(r'(?m)^\s*image:\s*["\']?([^"\'\s#]+)',(Path(__file__).parents[1]/'stack.runtime.yaml').read_text())
  self.assertEqual(EXPECTED,refs)
  for base,digest in PINS:accept(base+'@sha256:'+digest,base,digest)
 def test_floating_rejected(self):
  for base,digest in PINS:
   with self.subTest(base=base),self.assertRaises(ValueError):accept(base.rsplit(':',1)[0]+':latest',base,digest)
 def test_version_only_rejected(self):
  for base,digest in PINS:
   with self.subTest(base=base),self.assertRaises(ValueError):accept(base,base,digest)
 def test_malformed_digest_rejected(self):
  for base,digest in PINS:
   for bad in ['a'*63,'g'*64,'A'*64,'a'*65,'']:
    with self.subTest(base=base,bad=bad),self.assertRaises(ValueError):accept(base+'@sha256:'+bad,base,digest)
 def test_wrong_digest_rejected(self):
  for base,digest in PINS:
   with self.subTest(base=base),self.assertRaises(ValueError):accept(base+'@sha256:'+'0'*64,base,digest)
if __name__=='__main__':unittest.main()
