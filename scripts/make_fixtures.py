"""Regenerates CrateKit's test fixtures from Crate's real API code (see Fixtures/README.md).
Usage: make_fixtures.py <path to crate repo> <empty data dir> <fixtures dir>"""
import os, sys, types, json, time
sys.path.insert(0, sys.argv[1]); out = sys.argv[3]
os.environ.update(DATA_DIR=sys.argv[2], API_TOKEN="tok", NAVIDROME_PUBLIC_URL="https://music.example.com", NAVIDROME_USER="jared")
for m in ("transformers", "torch"):
    mod = sys.modules.setdefault(m, types.ModuleType(m)); mod.Tensor = type("T", (), {})
from fastapi.testclient import TestClient
from app import main, db, jobs
db.init()
jobs.scheduler.start()
from apscheduler.triggers.cron import CronTrigger
jobs.scheduler.add_job(print, CronTrigger.from_crontab("0 3 * * mon"), id="discover")
c = TestClient(main.app); h = {"Authorization": "Bearer tok"}
now = time.time()
with db.conn() as k:
    k.execute("INSERT INTO playlists(key,name,comment,navidrome_id,updated_at) VALUES ('discover_weekly','Discover Weekly','New for you','pl1',?)", (now,))
    k.execute("INSERT INTO playlists(key,name,navidrome_id) VALUES ('daily_mix_1','Daily Mix 1: Dream pop','pl2')")
    k.execute("INSERT INTO playlist_tracks VALUES ('discover_weekly',0,'s1','Beach House','Space Song','Depression Cherry')")
    k.execute("INSERT INTO playlist_tracks VALUES ('discover_weekly',1,'s2','Slowdive','Alison','Souvlaki')")
    k.execute("INSERT INTO playlist_tracks VALUES ('daily_mix_1',0,'s2','Slowdive','Alison','Souvlaki')")
    k.execute("INSERT INTO songs(id,starred,rating,play_count,duration) VALUES ('s1',1,4,3,320)")
    k.execute("INSERT INTO inbox(navidrome_id,status,kind,artist,title,album,added_at) VALUES ('s2','new','discover','Slowdive','Alison','Souvlaki',?)", (now,))
    k.execute("INSERT INTO inbox(navidrome_id,status,kind,artist,title,album,reason,added_at,decided_at) VALUES ('s9','kept','discover','Low','Lullaby','I Could Live in Hope','kept',?,?)", (now, now))
    k.execute("INSERT INTO playlist_pins(key,song_id,artist_key,title_key) VALUES ('daily_mix_1','s2','slowdive','alison')")
    k.execute("INSERT INTO runs(kind,started,finished,status,summary,log) VALUES ('discover',?,?,'ok','30 tracks','09:00:00 Started\n')", (now-60, now))
    k.execute("INSERT INTO runs(kind,started,status,log) VALUES ('prompt:1',?,'running','')", (now,))
    k.execute("INSERT INTO prompts(prompt,size,new_tracks,auto_refresh,name,created_at) VALUES ('rainy sunday',30,5,1,'Rainy Sunday',?)", (now,))
    k.execute("INSERT INTO wants(deezer_id,artist,title,album,album_id,cover,status,created,via) VALUES (3135556,'Daft Punk','One More Time','Discovery',302127,'https://e-cdns-images.dzcdn.net/x.jpg','ok',?,'track')", (now,))
    k.execute("INSERT INTO suggestions(key,items,at,status) VALUES ('discover_weekly',?,?,'ready')", (json.dumps([
        {"kind": "new", "deezer_id": 916424, "title": "Myth", "artist": "Beach House", "album": "Bloom", "duration": 258,
         "preview": "https://cdnt-preview.dzcdn.net/x.mp3", "cover": "https://e-cdns-images.dzcdn.net/c.jpg", "reason": "Similar to Slowdive", "score": 1.2},
        {"kind": "library", "song_id": "s7", "title": "When the Sun Hits", "artist": "Slowdive", "album": "Souvlaki", "duration": 287,
         "preview": "/api/preview/s7", "cover": "/api/cover/s7", "reason": "From your library", "score": 0.9}]), now))
def dump(name, path):
    r = c.get(path, headers=h); assert r.status_code == 200, (path, r.status_code, r.text)
    open(f"{out}/{name}.json", "w").write(json.dumps(r.json(), indent=1))
dump("ping", "/api/ping"); dump("info", "/api/info"); dump("status", "/api/status")
dump("playlists", "/api/playlists"); dump("runs", "/api/runs"); dump("prompts", "/api/prompts")
dump("inbox", "/api/inbox"); dump("history_summary", "/api/history/summary"); dump("wants", "/api/wants")
dump("suggestions", "/api/playlists/discover_weekly/suggestions")
print(f"wrote fixtures to {out}")
