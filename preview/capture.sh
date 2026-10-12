#!/bin/sh
# Regenerates the README screenshots and demo (docs/) from the demo journal.
# Needs agent-browser and ffmpeg. Starts ./preview/serve.sh in the background.
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD; D=$ROOT/docs; TMP=$(mktemp -d)
./preview/serve.sh >/dev/null 2>&1 & SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 3
AB=agent-browser
slow() { s="$1"; i=0; while [ $i -lt ${#s} ]; do $AB keyboard type "$(printf %s "$s" | cut -c$((i+1)))" >/dev/null; i=$((i+1)); done; }
fresh() {
  $AB open http://localhost:8765/stage.html >/dev/null; sleep 2.5
  $AB eval '(() => { const w = document.getElementById("card").contentWindow; w.document.getElementById("main").scrollTop = 0; w.focus(); w.document.querySelector(".ProseMirror").focus(); })()' >/dev/null
  sleep 0.3
}
tick() { $AB eval "(() => { const w = document.getElementById('card').contentWindow; const li = [...w.document.querySelectorAll('.li.todo')].find(l => l.textContent.includes('$1')); li.querySelector('.mk').dispatchEvent(new w.MouseEvent('mousedown', {bubbles:true, cancelable:true})); })()" >/dev/null; }
crop() { python3 -c "from PIL import Image; Image.open('$1').crop((1180, 120, 2340, 1460)).save('$2', optimize=True)"; }

$AB set viewport 1200 760 2 >/dev/null

# Hero shots, light and dark
for mode in light dark; do
  $AB set media $mode >/dev/null; fresh
  $AB eval 'document.getElementById("card").contentWindow.document.activeElement.blur()' >/dev/null; sleep 0.3
  $AB screenshot "$D/screenshot-$mode.png" >/dev/null
done
$AB set media light >/dev/null

# "/" menu and "@" mention search
fresh; $AB press Enter >/dev/null; $AB keyboard type "/" >/dev/null; sleep 1
$AB screenshot "$TMP/commands.png" >/dev/null; crop "$TMP/commands.png" "$D/screenshot-commands.png"
fresh; $AB press Enter >/dev/null; slow "Send notes from "; $AB keyboard type "@" >/dev/null; slow "s"; sleep 1
$AB screenshot "$TMP/mention.png" >/dev/null; crop "$TMP/mention.png" "$D/screenshot-mention.png"

# Animated demo
fresh
$AB record start "$TMP/demo.webm" >/dev/null; sleep 1.2
$AB press Enter >/dev/null; sleep 0.3
$AB keyboard type "/" >/dev/null; sleep 1; slow "to"; sleep 0.6; $AB press Enter >/dev/null; sleep 0.4
slow "Send notes from "; $AB keyboard type "@" >/dev/null; sleep 0.6; slow "smart"; sleep 0.9
$AB press Down >/dev/null; sleep 0.5; $AB press Up >/dev/null; sleep 0.4; $AB press Enter >/dev/null; sleep 0.8
slow "to Maya"; sleep 0.8
tick "Reply to Maya"; sleep 1
tick "Send notes"; sleep 1.8
$AB record stop >/dev/null
CROP="crop=1400:1420:1000:40"
ffmpeg -v error -y -i "$TMP/demo.webm" -vf "$CROP,fps=12,scale=700:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" "$D/demo.gif"
ffmpeg -v error -y -i "$TMP/demo.webm" -vf "$CROP,scale=1000:-2" -c:v libx264 -pix_fmt yuv420p -crf 23 -movflags +faststart "$D/demo.mp4"
# GitHub social preview (1280×640; upload in repo Settings → Social preview)
$AB set viewport 1280 640 2 >/dev/null; $AB set media dark >/dev/null
$AB open http://localhost:8765/social.html >/dev/null; sleep 2.5
$AB eval '(() => { const w = document.getElementById("card").contentWindow; w.document.activeElement.blur(); w.document.getElementById("main").scrollTop = 0; })()' >/dev/null; sleep 0.4
$AB screenshot "$TMP/social.png" >/dev/null
python3 -c "from PIL import Image; Image.open('$TMP/social.png').convert('RGB').resize((1280, 640), Image.LANCZOS).save('$D/social-preview.png', optimize=True)"

$AB close >/dev/null 2>&1 || true
echo "Updated $(ls "$D" | tr '\n' ' ')"
