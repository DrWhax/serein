#!/bin/bash
# Builds Signal-Desktop/packages/mock-server (upstream's in-tree mock server, the one
# Signal Desktop's own ts/test-mock suite runs) for SignalCore's integration tests.
#
# Signal-Desktop/ stays a read-only reference: the package is copied to
# Tests/MockServer/.mock-server, its dependencies are installed with npm (upstream
# uses pnpm, whose engines pin rejects this machine's Node), and it is compiled with
# its own build script (protopiler + tsc). Tests/MockServer depends on it via file:.
set -euo pipefail
cd "$(dirname "$0")/.."
src=Signal-Desktop/packages/mock-server
dst=Tests/MockServer/.mock-server
rsync -a --delete --exclude node_modules --exclude '*.tsbuildinfo' "$src/" "$dst/"
# Apple's TLS policy (URLSession, used for the storage service and CDN) rejects upstream's
# leaf certificate: 100-year validity and no serverAuth extended key usage (Chromium and
# rustls accept it). Re-issue the leaf from the mock's own CA, whose key and passphrase
# ship with the package (certs/Makefile), with 397 days and EKU serverAuth. The CA, and
# with it every trust anchor the tests pin, is unchanged.
certs="$dst/certs"
ext="$certs/leaf-ext.cnf"
cat > "$ext" <<'EXT'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1,IP:::1,DNS:localhost
EXT
openssl x509 -req -in "$certs/csr.pem" -CA "$certs/ca-cert.pem" -CAkey "$certs/ca-key.pem" -passin pass:password \
  -CAserial "$certs/ca-cert.srl" -days 397 -sha256 -extfile "$ext" -out "$certs/cert.pem"
cat "$certs/cert.pem" "$certs/ca-cert.pem" > "$certs/full-cert.pem"
# Pin every dependency to the exact version in upstream's pnpm-lock.yaml (workspace
# links keep their published version), so npm resolves what upstream tests with.
python3 -I - "$dst/package.json" Signal-Desktop/pnpm-lock.yaml <<'PY'
import json, re, sys
pkg_path, lock_path = sys.argv[1], sys.argv[2]
pkg = json.load(open(pkg_path))
lock = open(lock_path).read()
block = re.search(r"^  packages/mock-server:\n(.*?)(?=^  \S)", lock, re.S | re.M).group(1)
pins = {m.group(1): m.group(2) for m in re.finditer(r"^      '?([^':\n]+)'?:\n        specifier: .*\n        version: ([^\s(]+)", block, re.M)}
for section in ("dependencies", "devDependencies"):
    for name in pkg.get(section, {}):
        v = pins.get(name)
        if v and not v.startswith("link:"):
            pkg[section][name] = v
pkg.pop("pnpm", None)
pkg.pop("packageManager", None)
json.dump(pkg, open(pkg_path, "w"), indent=2)
print("pinned", sum(1 for n in pins if not pins[n].startswith("link:")), "dependencies from pnpm-lock.yaml")
PY
(cd "$dst" && npm install --no-audit --no-fund --ignore-scripts --loglevel=error && npm run build --silent)
(cd Tests/MockServer && npm install --no-audit --no-fund --loglevel=error)
node -e "const p=require('./Tests/MockServer/node_modules/@signalapp/mock-server/package.json'); console.log('mock-server', p.version, 'from', require('fs').realpathSync('./Tests/MockServer/node_modules/@signalapp/mock-server'))"
