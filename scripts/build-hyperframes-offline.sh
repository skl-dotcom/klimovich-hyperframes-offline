#!/usr/bin/env bash
set -euo pipefail
umask 022
HF_VERSION=0.9.98
GSAP_VERSION=3.14.2
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Requires Linux x86_64' >&2; exit 1; }
[[ $(node -p 'process.versions.node') == 22.16.0 ]] || { echo 'Requires Node 22.16.0 for this build' >&2; exit 1; }
OUT=$(realpath -m "${1:-$PWD/dist-offline}")
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/klimovich-hyperframes-offline-linux-x64"
mkdir -p "$KIT/assets" "$TMP/test-home"
cd "$KIT"
cat > package.json <<JSON
{"name":"klimovich-hyperframes-offline","version":"1.0.0","private":true,"dependencies":{"hyperframes":"$HF_VERSION","gsap":"$GSAP_VERSION"}}
JSON
export npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
npm install --package-lock-only --no-audit --no-fund --registry=https://registry.npmjs.org
npm ci --omit=dev --no-audit --no-fund --registry=https://registry.npmjs.org
npm ls --all --omit=dev --json > dependencies.json
cp node_modules/gsap/dist/gsap.min.js assets/gsap.min.js
cat > run-hyperframes <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec node "$HERE/node_modules/hyperframes/bin/hyperframes.mjs" "$@"
SH
chmod +x run-hyperframes
node -p 'JSON.stringify({platform:process.platform,arch:process.arch,node:process.versions.node,hyperframes:require("./node_modules/hyperframes/package.json").version,gsap:require("./node_modules/gsap/package.json").version},null,2)' > manifest.json
node -e 'const m=require("./manifest.json");if(m.hyperframes!=="0.9.98"||m.gsap!=="3.14.2")process.exit(1)'
ARCHIVE=klimovich-hyperframes-offline-v1-linux-x64.tar.gz
tar -czf "$OUT/$ARCHIVE" -C "$TMP" "$(basename "$KIT")"
# Limit upload size to 200 MiB; no artifact is published above the cap.
[[ $(stat -c%s "$OUT/$ARCHIVE") -le 209715200 ]] || { echo 'Archive exceeds 200 MiB upload guard' >&2; exit 1; }
(cd "$OUT" && sha256sum "$ARCHIVE" > "$ARCHIVE.sha256" && sha256sum -c "$ARCHIVE.sha256")
mkdir "$TMP/extracted"
tar -xzf "$OUT/$ARCHIVE" -C "$TMP/extracted"
RUN="$TMP/extracted/$(basename "$KIT")/run-hyperframes"
# Verify the unpacked CLI with a network namespace, not merely npm's offline flag.
# GitHub's standard Ubuntu runner provides passwordless sudo. Failure is a failed gate.
if [[ ${EUID} -eq 0 ]]; then
  VERSION=$(unshare --net -- env HOME="$TMP/test-home" PATH="$PATH" "$RUN" --version)
  unshare --net -- env HOME="$TMP/test-home" PATH="$PATH" "$RUN" --help >/dev/null
else
  VERSION=$(sudo -n unshare --net -- runuser -u "$(id -un)" -- env HOME="$TMP/test-home" PATH="$PATH" "$RUN" --version)
  sudo -n unshare --net -- runuser -u "$(id -un)" -- env HOME="$TMP/test-home" PATH="$PATH" "$RUN" --help >/dev/null
fi
printf '%s\n' "$VERSION" | tee "$OUT/offline-cli-version.txt"
printf '%s\n' "$VERSION" | grep -Eq '(^|[^0-9])0\.9\.98([^0-9]|$)'
echo 'Offline CLI startup verified. Browser/FFmpeg and rendering remain separate gates.'
