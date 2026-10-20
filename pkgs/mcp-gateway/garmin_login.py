"""One-off interactive Garmin login with MFA. Credentials are typed here and never stored."""
import getpass
import os
import sys

from garminconnect import Garmin

tokens = os.environ.get("GARMINTOKENS", "/garmin/tokens")
os.makedirs(tokens, mode=0o700, exist_ok=True)
email = input("Garmin email: ").strip()
password = getpass.getpass("Garmin password: ")
g = Garmin(email, password, prompt_mfa=lambda: input("MFA code: ").strip())
g.login(tokens)
f = os.path.join(tokens, "garmin_tokens.json")
if not os.path.exists(f):
    sys.exit("login succeeded but no token file was written")
os.chmod(f, 0o600)
print("ok, token saved to", f)
