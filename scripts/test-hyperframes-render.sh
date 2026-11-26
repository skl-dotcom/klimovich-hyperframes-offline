#!/usr/bin/env bash
set -euo pipefail
export CI=true
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT=$(realpath -m "${1:?output directory required}")
mkdir -p "$OUT"
bash "$ROOT/scripts/build-hyperframes-offline.sh" "$TMP/kit"
tar -xzf "$TMP/kit/klimovich-hyperframes-offline-v1-linux-x64.tar.gz" -C "$TMP"
KIT="$TMP/klimovich-hyperframes-offline-linux-x64"
HF="$KIT/run-hyperframes"
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y ffmpeg
fi
"$HF" browser ensure
BROWSER=$("$HF" browser path)
test -x "$BROWSER"
test "$(basename "$BROWSER")" = chrome-headless-shell
{
  node --version
  "$HF" --version
  "$BROWSER" --version
  ffmpeg -version | sed -n '1p'
  ffprobe -version | sed -n '1p'
} | tee "$OUT/versions.txt"
"$HF" doctor > "$OUT/doctor.txt" 2>&1 || { rc=$?; printf '\nDoctor exit code: %s\n' "$rc" >> "$OUT/doctor.txt"; }
cat "$OUT/doctor.txt"
mkdir "$TMP/composition"
cp "$ROOT/tests/render-v1/"{index.html,DESIGN.md} "$TMP/composition/"
cp "$KIT/assets/gsap.min.js" "$TMP/composition/"
cd "$TMP/composition"
"$HF" lint | tee "$OUT/lint.txt"
"$HF" validate | tee "$OUT/validate.txt"
"$HF" inspect | tee "$OUT/inspect.txt"
export HYPERFRAMES_BROWSER_PATH="$BROWSER"
{ time -p "$HF" render --output "$OUT/hyperframes-render-test.mp4" --format mp4 --fps 30 --quality standard --workers 2 --strict --no-best-effort; } 2>&1 | tee "$OUT/render.log"
MP4="$OUT/hyperframes-render-test.mp4"
test -s "$MP4"
ffprobe -v error -count_frames -show_streams -show_format -of json "$MP4" > "$OUT/ffprobe.json"
ffmpeg -v error -xerror -i "$MP4" -f null -
python3 - "$MP4" "$OUT" <<'PY'
import json, subprocess, sys
from pathlib import Path
video, out = Path(sys.argv[1]), Path(sys.argv[2])
data=json.loads((out/'ffprobe.json').read_text())
v=next(s for s in data['streams'] if s['codec_type']=='video')
assert (v['width'],v['height'],v['codec_name'])==(1920,1080,'h264'),v
assert v['avg_frame_rate']=='30/1',v
assert int(v['nb_read_frames'])==90,v
assert abs(float(data['format']['duration'])-3)<0.04,data['format']
def sample(t):
    b=subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(video),'-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','-'])
    assert len(b)==1920*1080*3
    def pixel(x,y):
        i=(y*1920+x)*3
        return list(b[i:i+3])
    return {'left':pixel(320,540),'middle':pixel(960,540),'right':pixel(1600,540)}
samples={str(t):sample(t) for t in [0.1,1.5,2.8]}
def yellow(p):return p[0]>200 and p[1]>140 and p[2]<130
for t, pos in [('0.1','left'),('1.5','middle'),('2.8','right')]:
    assert yellow(samples[t][pos]),samples
    assert all(not yellow(p) for k,p in samples[t].items() if k!=pos),samples
(out/'motion-check.json').write_text(json.dumps({'status':'pass','samples':samples},indent=2))
print('PASS: 1920x1080 H.264, 30 fps, 90 decodable frames, GSAP marker verified in three positions')
PY
for t in 0.1 1.5 2.8; do
  ffmpeg -v error -ss "$t" -i "$MP4" -frames:v 1 -y "$OUT/frame-$t.png"
done
(cd "$OUT" && sha256sum hyperframes-render-test.mp4 > SHA256SUMS && sha256sum -c SHA256SUMS)
