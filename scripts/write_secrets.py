#!/usr/bin/env python3

# Helper script for writing secrets fetched from vault to the file system.
# Usage: write_secrets.py [--base64] <secret-directory>

import base64
import json
import pathlib
import sys

args = sys.argv[1:]

# with `--base64` flag, values are expected to be in base64
secretsAreBase64 = False
if len(args) >= 1 and args[0] == "--base64":
  secretsAreBase64 = True
  args = args[1:]

# directory to write secrets to
secretsPath = args[0]

# get vault response from stdin
response = json.load(sys.stdin)

# write each secret to a file
data = response['data']['data']
if data != None:
  for name, value in data.items():
    secret_path = pathlib.Path(secretsPath, name)
    print(f'Writing to {secret_path}', file=sys.stderr)
    if secretsAreBase64:
      decoded_value = base64.b64decode(value)
      secret_path.write_bytes(decoded_value)
    else:
      secret_path.write_text(value)
