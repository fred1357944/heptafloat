#!/bin/sh
# Records the 4:3 feature demo (docs/demo-4x3.mp4) from preview/video.html with the demo journal.
# Needs agent-browser and ffmpeg. Starts ./preview/serve.sh in the background.
set -e
cd "$(dirname "$0")/.."
OUT=docs/demo-4x3.mp4; TMP=$(mktemp -d)
./preview/serve.sh >/dev/null 2>&1 & SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 3
AB=agent-browser
js() { $AB eval "$1" >/dev/null; }
f() { js "(() => { const w = demo.frame(), d = w.document; $1 })()"; }   # run inside the card
cap() { js "demo.caption(\`$1\`)"; }
key() { $AB press "$1" >/dev/null; }
slow() { s="$1"; i=0; while [ $i -lt ${#s} ]; do $AB keyboard type "$(printf %s "$s" | cut -c$((i+1)))" >/dev/null; i=$((i+1)); done; }
pause() { sleep "$1"; }

$AB set viewport 1200 900 2 >/dev/null
$AB set media light >/dev/null
$AB record start "$TMP/demo.webm" http://localhost:8765/video.html >/dev/null
pause 2.5
js "demo.overlay('title', true)"; pause 3.2
js "demo.overlay('title', false)"; pause 0.5

# 2. pops up over any app
cap '<kbd>⌥N</kbd> Pops up over any app'; pause 1.4
f "w.hf.setScale(1.12);"
js "demo.card(true)"
f "w.focus(); d.querySelector('.ProseMirror').focus(); d.getElementById('main').scrollTop = 0;"; pause 2.4

# 3. write like in Heptabase
cap 'Write just like in Heptabase'
f "w.focus(); d.querySelector('.ProseMirror').focus();"
key End; key Enter; slow "[] "; slow "Call the bank"; pause 1.4

# 4. "/" blocks
cap '<kbd>/</kbd> Insert any block'
key Enter; key Enter; $AB keyboard type "/" >/dev/null; pause 1.3; slow "h2"; pause 0.6; key Enter; slow "Ideas"; pause 1.2

# 5. "@" mentions
cap '<kbd>@</kbd> Mention any card'
key Enter; slow "Read "; $AB keyboard type "@" >/dev/null; pause 0.6; slow "smart"; pause 1.3; key Enter; pause 1.4

# 6. to-dos
cap 'Tick off to-dos'
f "const li = [...d.querySelectorAll('.li.todo')].find(l => l.textContent.includes('Call the bank')); li.querySelector('.mk').dispatchEvent(new w.MouseEvent('mousedown', {bubbles:true, cancelable:true}));"; pause 1.6

# 7. highlight
cap 'Highlight & color'
f "const h = [...d.querySelectorAll('.ProseMirror h2')].find(e => e.textContent === 'Ideas'); const r = d.createRange(); r.selectNodeContents(h); const s = w.getSelection(); s.removeAllRanges(); s.addRange(r); d.querySelector('.ProseMirror').dispatchEvent(new w.MouseEvent('mouseup', {bubbles:true}));"; pause 1.2
f "d.querySelector('.toolbar [data-action=color]').dispatchEvent(new w.MouseEvent('mousedown', {bubbles:true, cancelable:true}));"; pause 1.3
f "d.querySelector('.toolbar .sw[data-color-type=background][data-color=green]').dispatchEvent(new w.MouseEvent('mousedown', {bubbles:true, cancelable:true}));"; pause 0.5
key End; pause 1.2

# 8. open linked cards
cap 'Open linked cards here — or in Heptabase'
f "const c = [...d.querySelectorAll('.ProseMirror .chip[data-id]')].find(e => e.textContent.includes('Smart Notes') && e.closest('p')?.textContent.startsWith('Read')); c.scrollIntoView({block: 'center'}); c.dispatchEvent(new w.MouseEvent('mouseover', {bubbles:true}));"; pause 2.0
f "d.querySelector('.mention-pop [data-where=here]').dispatchEvent(new w.MouseEvent('mousedown', {bubbles:true, cancelable:true}));"; pause 2.4

# 9. recent cards
cap '<kbd>⌘P</kbd> Recent cards'
key Meta+p; pause 1.6; slow "prod"; pause 0.8; key Enter; pause 1.8

# 10. back to today
cap '<kbd>⌘⇧D</kbd> Back to today'
key Meta+Shift+d; pause 1.0; f "d.getElementById('main').scrollTop = 0;"; pause 1.4

# ⌘N new card
cap '<kbd>⌘N</kbd> Start a new card'
key Meta+n; pause 1.2; slow "Weekend plans"; key Enter; slow "[] "; slow "Hike Lion's Head"; pause 1.6
key Meta+Shift+d; pause 0.8; f "d.getElementById('main').scrollTop = 0;"; pause 0.4

# 11. search
cap '<kbd>⌘O</kbd> Search all your Heptabase cards'
key Meta+o; pause 0.8; slow "smart"; pause 2.2; key Escape; pause 0.6

# 12. light & dark
cap 'Light & dark, like Heptabase'
$AB set media dark >/dev/null; js "demo.dark(true)"; pause 2.4

# 13. settings
cap 'Every shortcut is yours to change'
js "demo.overlay('settings', true)"; pause 3.0
js "demo.overlay('settings', false)"; cap ''; pause 0.4

# 14. end card
js "demo.link('Free & open source · github.com/madeyexz/heptafloat')"; js "demo.overlay('title', true)"; pause 3.5
$AB record stop >/dev/null
$AB set media light >/dev/null
$AB close >/dev/null 2>&1 || true

# Trim the page-load lead-in, then 4:3 1440×1080 H.264
ffmpeg -v error -y -ss 2.3 -i "$TMP/demo.webm" -vf "scale=1440:1080:flags=lanczos,fps=30" -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -movflags +faststart "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
