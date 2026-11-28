#!/bin/bash
# Stage the stock iOS 16 wallpaper for iPhone X into the UI hook.
#
# The wallpaper layers in iOS 16 are HEIC and this port has no A11 HEVC block,
# so the hook cannot decode them on the phone. This script fetches the composed
# still from the public SniperGER/iOS-Wallpapers archive, converts it to PNG off
# the phone and sends it to /private/var/vm/mondrian-wallpaper.png. A blurred
# copy goes to mondrian-wallpaper-blur.png and is used as the App Library's card
# material, which on this port cannot sample a live backdrop. The hook's
# mondrian_wallpaper_image() prefers the still over its generated gradient.
#
# The asset is Apple's; it is downloaded at run time into /root/wallpaper and
# is never added to this repository. Attribution:
#   https://github.com/SniperGER/iOS-Wallpapers (composed from Apple's assets).
set -euo pipefail

cd "$(dirname "$0")/../.."

base='https://raw.githubusercontent.com/SniperGER/iOS-Wallpapers/master/iPhone/5.8%22/iOS%2016/Stills/'
name='7400.WWDC_2022-375w-812h@3x~iphone.heic'
out=/root/wallpaper
mkdir -p "$out"

python3 - "$base" "$name" "$out" <<'PY'
import os, sys
import urllib.request
from PIL import Image, ImageFilter

base, name, out = sys.argv[1:]
src = os.path.join(out, name)
if not os.path.exists(src):
    with urllib.request.urlopen(base + name) as r:
        open(src, "wb").write(r.read())
try:
    import pillow_heif  # noqa: F401
except ImportError:
    raise SystemExit("install pillow-heif on the host: pip3 install --break-system-packages pillow-heif")
pillow_heif.register_heif_opener()
img = Image.open(src).convert("RGBA")
dst = os.path.join(out, name.replace(".heic", ".png"))
img.save(dst, optimize=True)
blur = os.path.join(out, "mondrian-wallpaper-blur.png")
img.filter(ImageFilter.GaussianBlur(36)).save(blur, optimize=True)
print(dst, img.size)
print(blur)
PY

bash tools/build-mondrian-ui-hook.sh out/mondrian-ui-hook.dylib
bash tools/wsl/attach.sh
python3 tools/usb-ring.py wfile /private/var/vm/mondrian-wallpaper.png \
  "$out/$(printf '%s' "$name" | sed 's/\.heic$/.png/')"
python3 tools/usb-ring.py wfile /private/var/vm/mondrian-wallpaper-blur.png \
  "$out/mondrian-wallpaper-blur.png"
python3 tools/usb-ring.py wfile /private/var/vm/mondrian-ui-hook.dylib \
  out/mondrian-ui-hook.dylib
