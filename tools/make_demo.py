#!/usr/bin/env python3
"""Write test/demo/{CloudTabs,SafariTabs}.db: realistic fake Safari data for screenshots and design review."""
import json
import os
import sqlite3
import sys
import time
import zlib

d = sys.argv[1] if len(sys.argv) > 1 else "test/demo"
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.endswith((".db", ".db-wal", ".db-shm")):
        os.remove(os.path.join(d, f))

now = time.time() - 978307200
c = sqlite3.connect(os.path.join(d, "CloudTabs.db"))
c.executescript("""
CREATE TABLE cloud_tab_devices (device_uuid TEXT PRIMARY KEY, system_fields BLOB, device_name TEXT, device_type_identifier TEXT,
  has_duplicate_device_name BOOLEAN, is_ephemeral_device BOOLEAN, last_modified REAL);
CREATE TABLE cloud_tabs (tab_uuid TEXT PRIMARY KEY, system_fields BLOB, device_uuid TEXT, position BLOB, title TEXT, url TEXT,
  is_showing_reader BOOLEAN, is_pinned BOOLEAN, reader_scroll_position_page_index INTEGER, scene_id TEXT, last_viewed_time REAL);
""")
devices = [("p", "Alex’s iPhone", "com.apple.iphone-15-pro-2"), ("i", "Alex’s iPad Pro", "com.apple.ipad-pro-m4-13-2")]
for uuid, name, kind in devices:
    c.execute("INSERT INTO cloud_tab_devices VALUES (?,NULL,?,?,0,0,?)", (uuid, name, kind, now - 86400 * 3))
tabs = {
    "p": [("Hacker News", "https://news.ycombinator.com/"),
          ("MagicDNS · Tailscale Docs", "https://tailscale.com/kb/1081/magicdns"),
          ("GitHub - zen-browser/desktop: Welcome to a calmer internet", "https://github.com/zen-browser/desktop"),
          ("Wikipedia, la enciclopedia libre", "https://es.wikipedia.org/wiki/Wikipedia:Portada"),
          ("YouTube", "https://m.youtube.com/")],
    "i": [("Figma", "https://www.figma.com/"), ("MDN Web Docs", "https://developer.mozilla.org/en-US/")],
}
k = 0
for dev, ts in tabs.items():
    viewed = now - (1800 if dev == "p" else 86400 * 2)
    for i, (title, url) in enumerate(ts):
        k += 1
        pos = zlib.compress(json.dumps({"sortValues": [{"changeID": 0, "sortValue": i}]}).encode())
        c.execute("INSERT INTO cloud_tabs VALUES (?,NULL,?,?,?,?,0,0,0,NULL,?)", ("t%d" % k, dev, pos, title, url, viewed - i * 60))
c.commit()

g = sqlite3.connect(os.path.join(d, "SafariTabs.db"))
g.execute("CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, subtype INTEGER DEFAULT 0, title TEXT, "
          "url TEXT, order_index INTEGER, external_uuid TEXT, deleted INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0)")
g.execute("INSERT INTO bookmarks VALUES (0,NULL,1,0,'Root',NULL,0,NULL,0,0)")
groups = [
    ("Design", [("Dribbble - Discover the World’s Top Designers & Creative Professionals", "https://dribbble.com/"),
                ("Mobbin — UI & UX design inspiration", "https://mobbin.com/"),
                ("Refactoring UI", "https://www.refactoringui.com/"),
                ("Coolors - The super fast color palettes generator!", "https://coolors.co/"),
                ("Figma: The Collaborative Interface Design Tool", "https://www.figma.com/")]),
    ("T3 Code", [("T3 Chat", "https://t3.chat/"), ("Origami Studio — Origami Studio 3", "https://origami.design/"),
                 ("The <model> element", "https://immersive-web.github.io/model-element/")]),
    ("CSS Styles", [("Tailwind CSS - Rapidly build modern websites without ever leaving your HTML", "https://tailwindcss.com/"),
                    ("CSS-Tricks", "https://css-tricks.com/"), ("Josh W. Comeau", "https://www.joshwcomeau.com/")]),
    ("Sneakers", [("Nike. Just Do It. Nike.com", "https://www.nike.com/"), ("New Balance", "https://www.newbalance.com/"),
                  ("adidas Official Website", "https://www.adidas.com/us"), ("END. Clothing", "https://www.endclothing.com/")]),
    ("Ropa en mexico", [("Zara México", "https://www.zara.com/mx/"), ("UNIQLO", "https://www.uniqlo.com/")]),
    ("ESP32", [("ESP32 Wi-Fi & Bluetooth SoC | Espressif Systems", "https://www.espressif.com/en/products/socs/esp32"),
               ("Random Nerd Tutorials", "https://randomnerdtutorials.com/")]),
    ("Raspberry Pi / Self Hosting", [("Raspberry Pi", "https://www.raspberrypi.com/"), ("awesome-selfhosted", "https://awesome-selfhosted.net/")]),
    ("Learn Programming", [("The Odin Project", "https://www.theodinproject.com/"), ("freeCodeCamp", "https://www.freecodecamp.org/")]),
    ("Tinta Y Plumas", [("Goulet Pens", "https://www.gouletpens.com/"), ("JetPens", "https://www.jetpens.com/")]),
    ("Tasky", [("Linear – Plan and build products", "https://linear.app/")]),
    ("Apps", [("Raycast", "https://www.raycast.com/"), ("Things 3", "https://culturedcode.com/things/")]),
    ("Downloads", [("Releases · zen-browser/desktop", "https://github.com/zen-browser/desktop/releases")]),
]
gid, tid = 10, 1000
for oi, (name, ts) in enumerate(groups):
    g.execute("INSERT INTO bookmarks VALUES (?,0,1,0,?,NULL,?,?,0,0)", (gid, name, oi, "G%d" % gid))
    pin = gid + 1
    g.execute("INSERT INTO bookmarks VALUES (?,?,1,1,'TopScopedBookmarkList',NULL,0,?,0,0)", (pin, gid, "P%d" % pin))
    for i, (title, url) in enumerate(ts):
        tid += 1
        parent = pin if (name == "Design" and i == 0) else gid
        g.execute("INSERT INTO bookmarks VALUES (?,?,0,0,?,?,?,?,0,0)", (tid, parent, title, url, i + 1, "T%d" % tid))
    gid += 10
g.commit()
print("demo data written to", d)
