#!/usr/bin/env bash

# <swiftbar.title>Packet Loss Monitor</swiftbar.title>
# <swiftbar.version>v1.1</swiftbar.version>
# <swiftbar.author>ChatGPT</swiftbar.author>
# <swiftbar.desc>Shows recent packet loss in the menu bar, including a 4x4 ping history icon.</swiftbar.desc>
# <swiftbar.dependencies>bash,ping,awk,tail,wc,python3</swiftbar.dependencies>

TARGET="${TARGET:-1.1.1.1}"
WINDOW_SIZE="${WINDOW_SIZE:-60}"
TIMEOUT_MS="${TIMEOUT_MS:-1000}"
WARN_THRESHOLD="${WARN_THRESHOLD:-5}"
CRIT_THRESHOLD="${CRIT_THRESHOLD:-20}"
ICON_PINGS=16

STATE_DIR="${HOME}/.cache/swiftbar-packet-loss"
mkdir -p "$STATE_DIR"
SAFE_TARGET="${TARGET//[^a-zA-Z0-9_.-]/_}"
STATE_FILE="${STATE_DIR}/${SAFE_TARGET}.log"
TMP_FILE="${STATE_FILE}.tmp"

PING_BIN="$(command -v ping)"
PYTHON_BIN="$(command -v python3)"

if [[ -z "$PING_BIN" ]]; then
  echo "❌ no ping"
  echo "---"
  echo "Could not find ping command."
  exit 0
fi

PING_OUTPUT="$($PING_BIN -n -c 1 -W "$TIMEOUT_MS" "$TARGET" 2>&1)"
PING_EXIT=$?

if [[ $PING_EXIT -eq 0 ]]; then
  RESULT=1
  LATENCY_MS="$(awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}' <<< "$PING_OUTPUT")"
else
  RESULT=0
  LATENCY_MS=""
fi

echo "$RESULT" >> "$STATE_FILE"

TOTAL="$(wc -l < "$STATE_FILE" | tr -d ' ')"
if (( TOTAL > WINDOW_SIZE )); then
  tail -n "$WINDOW_SIZE" "$STATE_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$STATE_FILE"
  TOTAL="$WINDOW_SIZE"
fi

FAILURES="$(awk '$1==0{c++} END{print c+0}' "$STATE_FILE")"
LOSS="$(awk -v f="$FAILURES" -v t="$TOTAL" 'BEGIN{if(t==0) printf "0.0"; else printf "%.1f", (f/t)*100}')"

if awk "BEGIN{exit !($LOSS >= $CRIT_THRESHOLD)}"; then
  ICON="🔴"
  COLOR="red"
elif awk "BEGIN{exit !($LOSS >= $WARN_THRESHOLD)}"; then
  ICON="🟡"
  COLOR="#d79b00"
else
  ICON="🟢"
  COLOR="green"
fi

ICON_BITS="$(tail -n "$ICON_PINGS" "$STATE_FILE" 2>/dev/null | tr -cd '01')"
ICON_B64=""

if [[ -n "$PYTHON_BIN" ]]; then
  ICON_B64="$(ICON_BITS="$ICON_BITS" "$PYTHON_BIN" - <<'PY'
import base64
import binascii
import os
import struct
import zlib

bits = ''.join(ch for ch in os.environ.get('ICON_BITS', '') if ch in '01')
vals = [int(ch) for ch in bits][-16:]
if len(vals) < 16:
    vals = [2] * (16 - len(vals)) + vals  # 2 = no-data gray

# 4x4 grid, oldest (of last 16) at top-left, newest at bottom-right.
cell = 3
gap = 1
pad = 1
grid = 4
w = pad * 2 + grid * cell + (grid - 1) * gap
h = w

# transparent background
img = bytearray([0, 0, 0, 0] * (w * h))

def set_px(x, y, rgba):
    i = (y * w + x) * 4
    img[i:i+4] = bytes(rgba)

COLORS = {
    1: (60, 181, 75, 255),    # success green
    0: (228, 74, 62, 255),    # failure red
    2: (130, 130, 130, 180),  # no-data gray
}

for idx, v in enumerate(vals):
    r = idx // 4
    c = idx % 4
    x0 = pad + c * (cell + gap)
    y0 = pad + r * (cell + gap)
    color = COLORS.get(v, COLORS[2])
    for yy in range(y0, y0 + cell):
        for xx in range(x0, x0 + cell):
            set_px(xx, yy, color)

# Build PNG
raw = bytearray()
for y in range(h):
    raw.append(0)  # filter type 0
    row_start = y * w * 4
    raw.extend(img[row_start:row_start + w * 4])
compressed = zlib.compress(bytes(raw), 9)

def chunk(tag, data):
    return (
        struct.pack('>I', len(data)) +
        tag +
        data +
        struct.pack('>I', binascii.crc32(tag + data) & 0xffffffff)
    )

png = bytearray(b'\x89PNG\r\n\x1a\n')
png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', compressed)
png += chunk(b'IEND', b'')

print(base64.b64encode(png).decode('ascii'), end='')
PY
)"
fi

if [[ -n "$ICON_B64" ]]; then
  echo "| image=$ICON_B64"
else
  echo "$ICON | color=${COLOR}"
fi

echo "---"
echo "Target: ${TARGET}"
echo "Recent loss: ${LOSS}% (${FAILURES}/${TOTAL} failed)"
if [[ $RESULT -eq 1 ]]; then
  if [[ -n "$LATENCY_MS" ]]; then
    echo "Last ping: ✅ ${LATENCY_MS} ms"
  else
    echo "Last ping: ✅ success"
  fi
else
  echo "Last ping: ❌ timeout/error"
fi
echo "Window: last ${TOTAL}/${WINDOW_SIZE} pings"
echo "Warn/Crit: ${WARN_THRESHOLD}% / ${CRIT_THRESHOLD}%"
echo "Timeout: ${TIMEOUT_MS} ms"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "⚠️ python3 not found; using emoji fallback"
fi
echo "---"
echo "Reset history | bash='/bin/rm' param1='-f' param2='${STATE_FILE}' terminal=false refresh=true"