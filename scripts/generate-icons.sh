#!/bin/sh
# Regenerates AppIcon.icns, icon-mark-1024.png, and SkeletonKey.ico from
# assets/icon-1024.png. Run on macOS whenever the master artwork changes.
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
src="$root/assets/icon-1024.png"
assets="$root/assets"

if [ ! -f "$src" ]; then
  echo "Missing $src" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Transparent tight mark for tray / menu bar ---
# Flood-fills near-black pixels connected to the image edge to alpha=0 so
# eye sockets / outlines (interior black) stay opaque, then crops padding.
mark_crop="$tmp/mark-crop.png"
python3 - "$src" "$mark_crop" <<'PY'
import struct, zlib, sys
from collections import deque
from pathlib import Path

def read_png(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    width = height = None
    idat = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height = struct.unpack(">II", chunk[:8])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = width * 4 + 1
    pixels = []
    for y in range(height):
        row = raw[y * stride:(y + 1) * stride]
        assert row[0] == 0
        pixels.append(bytearray(row[1:]))
    return width, height, pixels

def write_png(path: Path, width: int, height: int, pixels):
    def chunk(ctype, payload):
        c = ctype + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    raw = b"".join(b"\x00" + bytes(r) for r in pixels)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )

def is_bg(r, g, b, a):
    if a < 10:
        return True
    return r < 22 and g < 22 and b < 22

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
w, h, pixels = read_png(src)

bg = [[False] * w for _ in range(h)]
q = deque()

def try_seed(x, y):
    i = x * 4
    r, g, b, a = pixels[y][i], pixels[y][i + 1], pixels[y][i + 2], pixels[y][i + 3]
    if not bg[y][x] and is_bg(r, g, b, a):
        bg[y][x] = True
        q.append((x, y))

for x in range(w):
    try_seed(x, 0)
    try_seed(x, h - 1)
for y in range(h):
    try_seed(0, y)
    try_seed(w - 1, y)

while q:
    x, y = q.popleft()
    for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
        if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx]:
            i = nx * 4
            r, g, b, a = pixels[ny][i], pixels[ny][i + 1], pixels[ny][i + 2], pixels[ny][i + 3]
            if is_bg(r, g, b, a):
                bg[ny][nx] = True
                q.append((nx, ny))

for y in range(h):
    row = pixels[y]
    for x in range(w):
        if bg[y][x]:
            i = x * 4
            row[i:i + 4] = b"\x00\x00\x00\x00"

minx, miny, maxx, maxy = w, h, 0, 0
for y in range(h):
    row = pixels[y]
    for x in range(w):
        if row[x * 4 + 3] > 10:
            minx = min(minx, x)
            miny = min(miny, y)
            maxx = max(maxx, x)
            maxy = max(maxy, y)

margin = 16
left, top = max(0, minx - margin), max(0, miny - margin)
right, bottom = min(w, maxx + 1 + margin), min(h, maxy + 1 + margin)
cw, ch = right - left, bottom - top
side = max(cw, ch)
ox, oy = (side - cw) // 2, (side - ch) // 2

out = [bytearray(side * 4) for _ in range(side)]  # transparent
for y in range(ch):
    src_row = pixels[top + y]
    dst_row = out[oy + y]
    for x in range(cw):
        si = (left + x) * 4
        di = (ox + x) * 4
        dst_row[di:di + 4] = src_row[si:si + 4]

write_png(dst, side, side, out)
print(f"transparent mark crop {cw}x{ch} → square {side}x{side}")
PY

sips -z 1024 1024 "$mark_crop" --out "$assets/icon-mark-1024.png" >/dev/null
echo "Wrote $assets/icon-mark-1024.png"

# --- Dock / Finder .icns from the transparent tight mark (preserve alpha) ---
iconset="$tmp/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for spec in \
  "16:icon_16x16.png" \
  "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" \
  "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" \
  "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" \
  "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" \
  "1024:icon_512x512@2x.png"
do
  size="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$size" "$size" "$assets/icon-mark-1024.png" --out "$iconset/$name" >/dev/null
done
xattr -cr "$iconset" 2>/dev/null || true
iconutil -c icns "$iconset" -o "$assets/AppIcon.icns"
echo "Wrote $assets/AppIcon.icns"

# --- Windows .ico from the transparent tight mark ---
png_dir="$tmp/png"
mkdir -p "$png_dir"
for size in 16 32 48 64 128 256; do
  sips -z "$size" "$size" "$assets/icon-mark-1024.png" --out "$png_dir/icon_${size}.png" >/dev/null
done

python3 - "$png_dir" "$assets/SkeletonKey.ico" <<'PY'
import struct, pathlib, sys
png_dir = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
sizes = [16, 32, 48, 64, 128, 256]
images = [(s, (png_dir / f"icon_{s}.png").read_bytes()) for s in sizes]
count = len(images)
header = struct.pack("<HHH", 0, 1, count)
offset = 6 + 16 * count
entries, blobs = [], []
for size, data in images:
    w = 0 if size >= 256 else size
    h = 0 if size >= 256 else size
    entries.append(struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset))
    blobs.append(data)
    offset += len(data)
out.write_bytes(header + b"".join(entries) + b"".join(blobs))
print(f"Wrote {out} ({out.stat().st_size} bytes)")
PY

echo "Done."
