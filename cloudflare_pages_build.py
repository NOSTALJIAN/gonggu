#!/usr/bin/env python3
"""Build MINIYENA's public storefront and its separate Cloudflare admin page.

Cloudflare Pages: python3 cloudflare_pages_build.py
GitHub Pages:     python3 cloudflare_pages_build.py --github
Both publish the same public storefront; only Cloudflare publishes /admin/.
"""
from pathlib import Path
import json
import shutil
import sys

BASE = Path(__file__).resolve().parent
OUTPUT = BASE / "cloudflare-dist"
IS_GITHUB = "--github" in sys.argv
ASSETS = (
    "index.html",
    "manifest.webmanifest",
    "icon-192.png",
    "icon-512.png",
    "apple-touch-icon.png",
    "icon-gh-512.png",
    "icon-shop-512.png",
    "icon-admin-512.png",
    "icon-admin-white-512.png",
    "icon-babyshop-96.png",
    "icon-shop-readable-192.png",
    "OneSignalSDKWorker.js",
    "nuvo_shipping.js",
    "nuvo_import.js",
    "partial_shipping.js",
    "sw.js",
)

if OUTPUT.exists():
    shutil.rmtree(OUTPUT)
OUTPUT.mkdir()
for name in ASSETS:
    source = BASE / name
    if not source.is_file():
        raise SystemExit(f"Required site asset not found: {name}")
    shutil.copy2(source, OUTPUT / name)

page = (OUTPUT / "index.html").read_text(encoding="utf-8")


def change_once(before: str, after: str) -> None:
    global page
    if page.count(before) != 1:
        raise SystemExit(f"Expected one exact occurrence of: {before[:100]!r}")
    page = page.replace(before, after, 1)


if not IS_GITHUB:
    # The public order screen and the admin page share the same buyer URL rules.
    # A Cloudflare customer can also paste a link from the legacy GitHub site.
    change_once(
        "if(page.origin!==location.origin||norm(page.pathname)!==norm(STOREFRONT_PATH))throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
        "const isCurrentSite=page.origin===location.origin&&norm(page.pathname)===norm(STOREFRONT_PATH);\n"
        " const isOldSite=page.origin==='https://nostaljian.github.io'&&norm(page.pathname)==='/gonggu/';\n"
        " if(!isCurrentSite&&!isOldSite)throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
    )
    page = page.replace(
        'placeholder="https://nostaljian.github.io/gonggu/?page=track&id=...&token=..."',
        'placeholder="주문조회 링크를 붙여넣어 주세요"',
    )

# Give every installable shortcut a genuinely different PNG, including iOS.
# Use new asset filenames (not just query parameters) to avoid stale Apple icon caching.
icon_name = "icon-512.png" if IS_GITHUB else "icon-shop-readable-192.png"
touch_icon = "apple-touch-icon.png" if IS_GITHUB else icon_name
favicon_icon = "icon-192.png" if IS_GITHUB else icon_name
touch_size = "180x180" if IS_GITHUB else "192x192"
favicon_size = "192x192"
icon_tag = '<link rel="icon" type="image/png" sizes="192x192" href="./icon-192.png?v=exact-original-mini-logo-inverted-20261022">'
touch_tag = '<link rel="apple-touch-icon" sizes="180x180" href="./apple-touch-icon.png?v=exact-original-mini-logo-inverted-20261022">'
manifest_tag = '<link rel="manifest" href="./manifest.webmanifest?v=exact-original-mini-logo-inverted-20261022">'
change_once(touch_tag, f'<link rel="apple-touch-icon" sizes="{touch_size}" href="./{touch_icon}?v=20261104-shop-readable-v4">')
change_once(icon_tag, f'<link rel="icon" type="image/png" sizes="{favicon_size}" href="./{favicon_icon}?v=20261104-shop-readable-v4">')
change_once(manifest_tag, '<link rel="manifest" href="./manifest.webmanifest?v=20261104-shop-readable-v4">')
change_once('<meta name="apple-mobile-web-app-title" content="미니예나">', f'<meta name="apple-mobile-web-app-title" content="{"미니예나 맘" if IS_GITHUB else "미니예나"}">')
change_once('<meta name="application-name" content="MINIYENA">', f'<meta name="application-name" content="{"MINIYENA GH" if IS_GITHUB else "MINIYENA SHOP"}">')

manifest = json.loads((OUTPUT / "manifest.webmanifest").read_text(encoding="utf-8"))
manifest.update({
    "id": "./" if IS_GITHUB else "/",
    "name": "MINIYENA | 맘혜택" if IS_GITHUB else "미니예나",
    "short_name": "미니예나 맘" if IS_GITHUB else "미니예나",
    "icons": [{"src": f"{icon_name}?v=20261104-shop-readable-v4", "sizes": "512x512" if IS_GITHUB else "192x192", "type": "image/png", "purpose": "any maskable" if IS_GITHUB else "any"}],
})
(OUTPUT / "manifest.webmanifest").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
(OUTPUT / "index.html").write_text(page, encoding="utf-8")

if not IS_GITHUB:
    # Real standalone HTML at /admin/, not an iframe or a customer-page query.
    # Set the base so all relative images and icons resolve from the site root.
    admin = page.replace("<head>\n", '<head>\n<base href="../">\n', 1)
    admin = admin.replace("icon-shop-readable-192.png?v=20261104-shop-readable-v4", "icon-admin-white-512.png?v=20261104-icon-style-v2", 2)
    admin = admin.replace(
        '<meta name="apple-mobile-web-app-title" content="미니예나">',
        '<meta name="apple-mobile-web-app-title" content="미니예나 관리자">',
        1,
    )
    admin = admin.replace(
        '<meta name="application-name" content="MINIYENA SHOP">',
        '<meta name="application-name" content="MINIYENA ADMIN">',
        1,
    )
    manifest_tag = '<link rel="manifest" href="./manifest.webmanifest?v=20261104-shop-readable-v4">'
    if admin.count(manifest_tag) != 1:
        raise SystemExit("Cannot locate the storefront manifest reference.")
    admin = admin.replace(
        manifest_tag,
        '<link rel="manifest" href="admin/manifest.webmanifest?v=20261104-icon-style-v2">',
        1,
    )
    admin_folder = OUTPUT / "admin"
    admin_folder.mkdir()
    (admin_folder / "index.html").write_text(admin, encoding="utf-8")
    admin_manifest = {
        "id": "/admin/",
        "name": "MINIYENA | 관리자",
        "short_name": "미니예나 관리자",
        "description": "미니예나 관리자 전용 상품·주문·정산 화면",
        "start_url": "/admin/",
        "scope": "/admin/",
        "display": "standalone",
        "background_color": "#ffffff",
        "theme_color": "#ffffff",
        "lang": "ko",
        "icons": [
            {"src": "../icon-admin-white-512.png?v=20261104-icon-style-v2", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
        ],
    }
    (admin_folder / "manifest.webmanifest").write_text(
        json.dumps(admin_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

print("MINIYENA build:", "GitHub storefront" if IS_GITHUB else "Cloudflare storefront + /admin/", OUTPUT)
