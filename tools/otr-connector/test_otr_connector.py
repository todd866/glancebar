import http.client
import http.server
import json
import os
import stat
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import otr_connector as oc  # noqa: E402


def _mp4_box(box_type: bytes, payload: bytes) -> bytes:
    return struct.pack(">I4s", 8 + len(payload), box_type) + payload


def _build_m4a_with_cover(image_bytes: bytes, type_ind: int = 13) -> bytes:
    data_box = _mp4_box(b"data", struct.pack(">II", type_ind, 0) + image_bytes)
    covr_box = _mp4_box(b"covr", data_box)
    ilst_box = _mp4_box(b"ilst", covr_box)
    meta_box = _mp4_box(b"meta", b"\x00\x00\x00\x00" + ilst_box)
    udta_box = _mp4_box(b"udta", meta_box)
    moov_box = _mp4_box(b"moov", udta_box)
    ftyp_box = _mp4_box(b"ftyp", b"M4A \x00\x00\x00\x00M4A mp42isom")
    return ftyp_box + moov_box + b"\x00\x00\x00\x08mdat"


class _MockHubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path.startswith("/api/v1/works"):
            payload = {
                "works": [
                    {
                        "workId": "mbid:test-anchor-ambient",
                        "kind": "ambient · tape loops",
                        "category": "electronic",
                        "creator": "Brian Eno",
                        "energy": 0.14,
                        "heaviness": 0.12,
                    }
                ]
            }
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/v1/lenses"):
            payload = {
                "lenses": [
                    {
                        "id": "late-night",
                        "name": "Late Night",
                        "color": "#7c3aed",
                        "kinds": ["chill"],
                        "genres": ["Ambient"],
                        "tags": ["ambient", "night"],
                    },
                    {
                        "id": "lens:radio:anchor-wire",
                        "name": "Anchor wire",
                        "summary": "Tape-loop ambient and slow electronic nocturnes",
                        "anchors": [{"workId": "mbid:test-anchor-ambient", "weight": 1.0}],
                    },
                ]
            }
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


class OtrConnectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.mix = root / "mix"
        self.mix.mkdir()
        (self.mix / "art").mkdir()
        self.hot = root / "hot"
        self.hot.mkdir()
        self.state = root / "state"
        self.state.mkdir()
        self.playlog = root / "playback.jsonl"
        self.hearts = root / "hearts.json"

        # Audio files: 2 in manifest, 1 scanned extra in hot_dir
        self.t1_dir = self.hot / "AM-Lossless" / "Artist One" / "Album A"
        self.t1_dir.mkdir(parents=True)
        self.t1_file = self.t1_dir / "01. Track One.m4a"
        self.t1_bytes = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        self.t1_file.write_bytes(self.t1_bytes)
        (self.mix / "art" / "1111111111111111.jpg").write_bytes(b"\xff\xd8\xff\xe0JPEG1")

        self.t2_dir = self.hot / "AM-Lossless" / "Artist Two" / "Album B"
        self.t2_dir.mkdir(parents=True)
        self.t2_file = self.t2_dir / "02. Track Two.mp3"
        self.t2_bytes = b"ID3-MP3-TEST-BYTES-0123456789"
        self.t2_file.write_bytes(self.t2_bytes)
        (self.t2_dir / "cover.png").write_bytes(b"\x89PNG\r\n\x1a\nPNG2")

        self.t3_dir = self.hot / "AM-Lossless" / "Artist Three" / "Album C"
        self.t3_dir.mkdir(parents=True)
        self.t3_file = self.t3_dir / "03. Scanned Chill.flac"
        self.t3_file.write_bytes(b"fLaC-TEST-AUDIO")

        self.t4_file = self.hot / "AM-Lossless" / "Artist Four" / "Album D" / "04. Disliked Track.m4a"
        self.t4_file.parent.mkdir(parents=True)
        self.t4_file.write_bytes(b"DISLIKED-AUDIO")

        (self.mix / "offline-manifest.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "playlists": [
                        {
                            "key": "kind:dance",
                            "tracks": [
                                {
                                    "id": "1111111111111111",
                                    "sha256": "a" * 64,
                                    "title": "Track One",
                                    "artist": "Artist One",
                                    "album": "Album A",
                                    "path": str(self.t1_file),
                                },
                                {
                                    "id": "4444444444444444",
                                    "sha256": "d" * 64,
                                    "title": "Disliked Track",
                                    "artist": "Artist Four",
                                    "album": "Album D",
                                    "path": str(self.t4_file),
                                },
                            ],
                        },
                        {
                            "key": "station:triplej",
                            "tracks": [
                                {
                                    "id": "2222222222222222",
                                    "sha256": "b" * 64,
                                    "title": "Track Two",
                                    "artist": "Artist Two",
                                    "album": "Album B",
                                    "path": str(self.t2_file),
                                }
                            ],
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )

        (self.mix / "library.json").write_text(
            json.dumps(
                {
                    "tracks": [
                        {
                            "id": "1111111111111111",
                            "artist": "Artist One",
                            "title": "Track One",
                            "album": "Album A",
                            "year": 2022,
                            "genre": "Dance",
                            "fav": 1,
                            "dislike": 0,
                            "plays": 5,
                        },
                        {
                            "id": "2222222222222222",
                            "artist": "Artist Two",
                            "title": "Track Two",
                            "album": "Album B",
                            "year": 2025,
                            "genre": "Alternative",
                            "fav": 0,
                            "dislike": 0,
                            "plays": 1,
                        },
                        {
                            "id": "3333333333333333",
                            "artist": "Artist Three",
                            "title": "Scanned Chill",
                            "album": "Album C",
                            "year": 2024,
                            "genre": "Ambient",
                            "fav": 0,
                            "dislike": 0,
                            "plays": 2,
                        },
                        {
                            "id": "4444444444444444",
                            "artist": "Artist Four",
                            "title": "Disliked Track",
                            "album": "Album D",
                            "year": 2020,
                            "genre": "Dance",
                            "fav": 0,
                            "dislike": 1,
                            "plays": 0,
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )

        (self.mix / "music-space.json").write_text(
            json.dumps(
                {
                    "kindNeighbours": {
                        "dance": ["alt", "rap", "chill"],
                        "alt": ["chill", "dance", "rap"],
                        "chill": ["alt", "dance", "rap"],
                        "rap": ["dance", "alt", "chill"],
                    },
                    "tracks": {
                        "1111111111111111": {
                            "kind": "dance",
                            "kindScore": 0.94,
                            "x": 0.12,
                            "y": -0.34,
                            "next": [["2222222222222222", 0.89]],
                        },
                        "2222222222222222": {
                            "kind": "alt",
                            "kindScore": 0.88,
                            "next": [["3333333333333333", 0.85]],
                        },
                        "3333333333333333": {
                            "kind": "chill",
                            "kindScore": 0.91,
                            "next": [],
                        },
                    },
                }
            ),
            encoding="utf-8",
        )

        self.commands = []

        def fake_runner(args, fallback):
            self.commands.append((args, fallback))

        self.hub = http.server.HTTPServer(("127.0.0.1", 0), _MockHubHandler)
        self.hub_thread = threading.Thread(target=self.hub.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.hub_thread.start()
        hub_port = self.hub.server_address[1]

        self.server = oc.create_server(
            host="127.0.0.1",
            port=0,
            name="Glancebar (Test)",
            mix_dir=self.mix,
            hot_dir=self.hot,
            playlog_path=self.playlog,
            hearts_path=self.hearts,
            state_dir=self.state,
            manifold_hub=f"http://127.0.0.1:{hub_port}",
            offline=False,
            tailscale_user="trusted@example.com",
            command_runner=fake_runner,
        )
        self.srv_thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.srv_thread.start()
        self.port = self.server.server_address[1]
        self.password = self.server.passphrase

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.hub.shutdown()
        self.hub.server_close()
        self.tmp.cleanup()

    def _req(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        hdrs = dict(headers or {})
        raw = None
        if body is not None:
            raw = json.dumps(body).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=raw, headers=hdrs)
        resp = conn.getresponse()
        data = resp.read()
        resp_hdrs = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, resp_hdrs, data

    def _login_cookie(self):
        status, hdrs, data = self._req("POST", "/api/login", {"pass": self.password, "name": "Phone"})
        self.assertEqual(status, 200)
        doc = json.loads(data)
        self.assertEqual(doc["name"], "Glancebar (Test)")
        self.assertEqual(doc["capabilities"], ["library", "glancebar-remote"])
        sc = hdrs["set-cookie"]
        self.assertIn("HttpOnly", sc)
        self.assertIn("SameSite=Lax", sc)
        return sc.split(";", 1)[0]

    def test_passphrase_file_generated_with_0600(self):
        pf = self.state / "passphrase"
        self.assertTrue(pf.is_file())
        mode = stat.S_IMODE(os.stat(pf).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(pf.read_text().strip(), self.password)

    def test_auth_login_cookie_and_bearer(self):
        # Unauthenticated rejected
        st, _, data = self._req("GET", "/api/home")
        self.assertEqual(st, 401)
        self.assertEqual(json.loads(data), {"error": "unauthorized"})

        # Wrong pass rejected
        st, _, data = self._req("POST", "/api/login", {"pass": "wrong", "name": "x"})
        self.assertEqual(st, 401)
        self.assertEqual(json.loads(data), {"error": "unauthorized"})

        # Cookie works
        cookie = self._login_cookie()
        st, _, _ = self._req("GET", "/api/home", headers={"Cookie": cookie})
        self.assertEqual(st, 200)

        # Bearer works
        st, _, _ = self._req("GET", "/api/home", headers={"Authorization": f"Bearer {self.password}"})
        self.assertEqual(st, 200)

    def test_home_schema_no_paths_and_manifold_station(self):
        cookie = self._login_cookie()
        st, _, data = self._req("GET", "/api/home", headers={"Cookie": cookie})
        self.assertEqual(st, 200)
        raw_text = data.decode("utf-8")
        # Never expose filesystem paths
        self.assertNotIn(str(self.hot), raw_text)
        self.assertNotIn(str(self.mix), raw_text)
        self.assertNotIn("01. Track One.m4a", raw_text)

        doc = json.loads(raw_text)
        shelves = {s["id"]: s for s in doc["shelves"]}
        self.assertIn("library", shelves)
        self.assertIn("stations", shelves)
        self.assertEqual(shelves["library"]["title"], "Glancebar Lossless")

        song_tiles = shelves["library"]["tiles"]
        self.assertEqual(len(song_tiles), 3)  # disliked Track Four excluded
        for tile in song_tiles:
            self.assertEqual(tile["kind"], "song")
            self.assertIsInstance(tile["art"], bool)
            for k in ("s", "title", "sub", "artist", "art", "color"):
                self.assertIn(k, tile)

        st_tiles = shelves["stations"]["tiles"]
        names = [t["station"]["name"] for t in st_tiles]
        for expected in ("Dance", "Alt", "Rap", "Chill", "New music", "All Lossless", "Late Night"):
            self.assertIn(expected, names)
        for tile in st_tiles:
            self.assertEqual(tile["kind"], "station")
            self.assertIsInstance(tile["station"], dict)
            for k in ("id", "name", "color", "count"):
                self.assertIn(k, tile["station"])

    def test_queue_ranking_and_event_feedback(self):
        cookie = self._login_cookie()
        st, _, data = self._req("POST", "/api/queue", {"mood": "station:dance", "n": 18}, headers={"Cookie": cookie})
        self.assertEqual(st, 200)
        picks = json.loads(data)["picks"]
        self.assertEqual(len(picks), 3)
        # Favorite dance track 1111111111111111 ranks first and carries x/yy
        self.assertEqual(picks[0]["s"], "1111111111111111")
        self.assertIsInstance(picks[0]["h"], float)
        self.assertIsInstance(picks[0]["art"], bool)
        self.assertTrue(picks[0]["art"])
        self.assertIn("x", picks[0])
        self.assertIn("yy", picks[0])
        for p in picks:
            self.assertIsInstance(p["h"], (int, float))
            self.assertNotIsInstance(p["h"], bool)
            self.assertIsInstance(p["art"], bool)
            for req_key in ("s", "a", "t", "al", "y", "g", "e", "h", "tag", "dur", "color", "art", "pt"):
                self.assertIn(req_key, p)

        # Submit dislike event on pick[0] -> writes feedback.jsonl with source=otr and removes from future queue
        pt0 = picks[0]["pt"]
        st, _, data = self._req(
            "POST",
            "/api/event",
            {"pt": pt0, "ev": "dislike", "pos": 12.5},
            headers={"Cookie": cookie},
        )
        self.assertEqual(st, 200)
        self.assertEqual(json.loads(data), {"ok": True})

        fb_lines = [json.loads(line) for line in (self.mix / "feedback.jsonl").read_text().splitlines() if line]
        self.assertEqual(len(fb_lines), 1)
        self.assertEqual(fb_lines[0]["source"], "otr")
        self.assertEqual(fb_lines[0]["event"], "dislike")
        self.assertEqual(fb_lines[0]["pos"], 12.5)
        self.assertEqual(fb_lines[0]["trackID"], "1111111111111111")

        st, _, data = self._req("POST", "/api/queue", {"mood": "dance", "n": 18}, headers={"Cookie": cookie})
        self.assertEqual(st, 200)
        ids_after = [p["s"] for p in json.loads(data)["picks"]]
        self.assertNotIn("1111111111111111", ids_after)

    def test_audio_200_206_head_and_traversal_404(self):
        hdrs = {"Authorization": f"Bearer {self.password}"}

        # Full 200 GET
        st, rh, body = self._req("GET", "/api/audio/1111111111111111", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "audio/mp4")
        self.assertEqual(rh["accept-ranges"], "bytes")
        self.assertEqual(body, self.t1_bytes)

        # HEAD
        st, rh, body = self._req("HEAD", "/api/audio/2222222222222222", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "audio/mpeg")
        self.assertEqual(int(rh["content-length"]), len(self.t2_bytes))
        self.assertEqual(body, b"")

        # Range 206 Partial Content
        st, rh, body = self._req(
            "GET",
            "/api/audio/1111111111111111",
            headers={**hdrs, "Range": "bytes=4-9"},
        )
        self.assertEqual(st, 206)
        self.assertEqual(rh["accept-ranges"], "bytes")
        self.assertEqual(rh["content-range"], f"bytes 4-9/{len(self.t1_bytes)}")
        self.assertEqual(body, self.t1_bytes[4:10])

        # Open-ended range
        st, rh, body = self._req(
            "GET",
            "/api/audio/1111111111111111",
            headers={**hdrs, "Range": f"bytes={len(self.t1_bytes) - 3}-"},
        )
        self.assertEqual(st, 206)
        self.assertEqual(body, self.t1_bytes[-3:])

        # Unknown and path traversal -> 404
        for bad in ("doesnotexist", "../etc/passwd", "..%2F..%2Fetc%2Fpasswd"):
            st, _, _ = self._req("GET", f"/api/audio/{bad}", headers=hdrs)
            self.assertEqual(st, 404)

    def test_art_serving(self):
        hdrs = {"Authorization": f"Bearer {self.password}"}
        st, rh, body = self._req("GET", "/api/art/1111111111111111", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "image/jpeg")
        self.assertEqual(body, b"\xff\xd8\xff\xe0JPEG1")

        st, rh, body = self._req("GET", "/api/art/2222222222222222", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "image/png")
        self.assertEqual(body, b"\x89PNG\r\n\x1a\nPNG2")

        st, _, _ = self._req("GET", "/api/art/unknown999", headers=hdrs)
        self.assertEqual(st, 404)

    def test_glancebar_now_and_cmd(self):
        hdrs = {"Authorization": f"Bearer {self.password}"}

        # Empty playlog -> stopped
        st, _, data = self._req("GET", "/api/glancebar/now", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(
            json.loads(data),
            {"state": "stopped", "title": None, "artist": None, "liked": False, "host": "Mac", "epoch": 0.0},
        )

        # Auto-advance + filename fallback + silentQA ignore + hearts check
        rows = [
            {"event": "launch", "epoch": 100.0},
            {"event": "rate", "state": "playing", "file": "Artist One - Track One.m4a", "title": "Track One", "artist": "Artist One", "epoch": 101.0},
            {"event": "track", "file": "07. Artist Beta - Track Two [XYZ12345].m4a", "title": "", "artist": "", "epoch": 200.0},
            {"event": "meta", "file": "07. Artist Beta - Track Two [XYZ12345].m4a", "title": "Track Two", "artist": "Artist Beta", "epoch": 200.5},
            {"event": "track", "file": "qa.m4a", "title": "QA", "artist": "QA", "silentQA": True, "epoch": 300.0},
        ]
        self.playlog.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
        self.hearts.write_text(json.dumps({"tracks": ["artist beta|track two"]}), encoding="utf-8")

        st, _, data = self._req("GET", "/api/glancebar/now", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(
            json.loads(data),
            {
                "state": "playing",
                "title": "Track Two",
                "artist": "Artist Beta",
                "liked": True,
                "host": "Mac",
                "epoch": 200.5,
            },
        )

        # Commands
        st, _, data = self._req("POST", "/api/glancebar/cmd", {"cmd": "toggle"}, headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(self.commands[-1], (["--pause"], "pause"))

        st, _, _ = self._req("POST", "/api/glancebar/cmd", {"cmd": "mood:dance"}, headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(self.commands[-1], (["--play", "dance"], "play dance"))

        st, _, _ = self._req("POST", "/api/glancebar/cmd", {"cmd": "mood:station:kexp"}, headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(self.commands[-1], (["--play", "radio:station:kexp"], "play radio:station:kexp"))

        # Invalid cmd -> 400
        for bad in ("", "rm -rf", "mood:bad cmd!", 123):
            st, _, data = self._req("POST", "/api/glancebar/cmd", {"cmd": bad}, headers=hdrs)
            self.assertEqual(st, 400)
            self.assertEqual(json.loads(data), {"error": "invalid_cmd"})

    def test_tailscale_identity_auth_and_csrf_guards(self):
        trusted = {"Tailscale-User-Login": "Trusted@Example.com"}
        # Trusted Tailscale login without Origin authorizes read/remote routes
        st, _, data = self._req("GET", "/api/home", headers=trusted)
        self.assertEqual(st, 200)
        self.assertIn("shelves", json.loads(data))

        st, _, _ = self._req("GET", "/api/glancebar/now", headers=trusted)
        self.assertEqual(st, 200)

        # Passwordless /api/login issues session cookie for trusted tailnet caller
        st, rh, data = self._req("POST", "/api/login", {"name": "iPhone"}, headers=trusted)
        self.assertEqual(st, 200)
        doc = json.loads(data)
        self.assertEqual(doc["auth"], "tailnet")
        self.assertIn("otr_session=", rh["set-cookie"])

        # Explicit wrong password is still rejected even over tailnet
        st, _, _ = self._req("POST", "/api/login", {"pass": "wrong", "name": "iPhone"}, headers=trusted)
        self.assertEqual(st, 401)

        # Wrong Tailscale user -> 401
        st, _, _ = self._req("GET", "/api/home", headers={"Tailscale-User-Login": "intruder@example.com"})
        self.assertEqual(st, 401)

        # Browser CORS/CSRF request carrying Origin -> 401 even with matching header
        st, _, _ = self._req(
            "GET",
            "/api/home",
            headers={**trusted, "Origin": "https://evil.example"},
        )
        self.assertEqual(st, 401)

        # Disabling tailscale auth blocks Tailscale header
        prev = self.server.trusted_tailscale_user
        self.server.trusted_tailscale_user = ""
        try:
            st, _, _ = self._req("GET", "/api/home", headers=trusted)
            self.assertEqual(st, 401)
        finally:
            self.server.trusted_tailscale_user = prev

    def test_coordinates_embedded_m4a_art_and_manifold_anchor_lens(self):
        # Track 2 & Track 3 had no x/y in music-space.json -> synthesized deterministically in [-1, 1]
        cookie = self._login_cookie()
        st, _, data = self._req("GET", "/api/home", headers={"Cookie": cookie})
        self.assertEqual(st, 200)
        doc = json.loads(data)
        shelves = {s["id"]: s for s in doc["shelves"]}
        song_tiles = shelves["library"]["tiles"]
        for tile in song_tiles:
            self.assertIn("point", tile)
            self.assertLessEqual(-1.0, tile["point"]["x"])
            self.assertLessEqual(tile["point"]["x"], 1.0)
            self.assertLessEqual(-1.0, tile["point"]["y"])
            self.assertLessEqual(tile["point"]["y"], 1.0)
            self.assertIn("e", tile)
            self.assertIn("h", tile)

        # Manifold anchor-derived lens (without explicit kinds/genres) matches chill/ambient track with count > 0
        st_tiles = {t["station"]["id"]: t["station"] for t in shelves["stations"]["tiles"]}
        self.assertGreater(st_tiles["lens:radio:anchor-wire"]["count"], 0)
        st, _, qdata = self._req(
            "POST",
            "/api/queue",
            {"mood": "lens:radio:anchor-wire", "n": 18},
            headers={"Cookie": cookie},
        )
        self.assertEqual(st, 200)
        qpicks = json.loads(qdata)["picks"]
        self.assertGreaterEqual(len(qpicks), 1)
        self.assertEqual(qpicks[0]["t"], "Scanned Chill")

        # Embedded M4A cover art extraction + artist|title mix/art lookup + /api/art serving
        embedded_jpeg = b"\xff\xd8\xff\xe0" + b"EMBEDDED_COVER_DATA" * 4
        m4a_path = self.hot / "AM-Lossless" / "Embedded Artist" / "05. Embedded Song.m4a"
        m4a_path.parent.mkdir(parents=True, exist_ok=True)
        m4a_path.write_bytes(_build_m4a_with_cover(embedded_jpeg, type_ind=13))

        at_file = self.hot / "AM-Lossless" / "Trophy Wyfe" / "Single" / "06. Spiders.m4a"
        at_file.parent.mkdir(parents=True, exist_ok=True)
        at_file.write_bytes(b"NO-EMBEDDED-ART")
        (self.mix / "art" / "trophy wyfe|spiders.jpg").write_bytes(b"\xff\xd8\xff\xe0ATJPEG")

        self.server.index.reload()
        emb_rec = next(t for t in self.server.index.tracks if t.title == "Embedded Song")
        at_rec = next(t for t in self.server.index.tracks if t.title == "Spiders")
        self.assertTrue(emb_rec.has_art)
        self.assertIsNone(emb_rec.art_path)
        self.assertTrue(emb_rec.has_embedded_art)
        self.assertTrue(at_rec.has_art)

        hdrs = {"Authorization": f"Bearer {self.password}"}
        st, rh, body = self._req("GET", f"/api/art/{emb_rec.s}", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "image/jpeg")
        self.assertEqual(body, embedded_jpeg)

        st, rh, body = self._req("GET", f"/api/art/{at_rec.s}", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "image/jpeg")
        self.assertEqual(body, b"\xff\xd8\xff\xe0ATJPEG")

    def test_audio_aac_transcode_caching_and_lossless_bypass(self):
        # Large ALAC .m4a (> 8 MB) triggers transcoder once for ?q=aac, caches result, and bypasses for lossless
        big_src = self.hot / "AM-Lossless" / "Artist One" / "Album A" / "07. Big Lossless.m4a"
        big_src.write_bytes(b"ALAC-DATA" * (1_000_000))  # ~9 MB
        self.server.index.reload()
        rec = next(t for t in self.server.index.tracks if t.title == "Big Lossless")

        calls = []
        aac_payload = b"ftypM4A-256K-AAC" * 100

        def fake_transcoder(src, dst):
            calls.append((src, dst))
            dst.write_bytes(aac_payload)
            return True

        self.server.aac_transcoder = fake_transcoder
        hdrs = {"Authorization": f"Bearer {self.password}"}

        # First ?q=aac call transcodes and caches
        st, rh, body = self._req("GET", f"/api/audio/{rec.s}?q=aac", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(rh["content-type"], "audio/mp4")
        self.assertEqual(body, aac_payload)
        self.assertEqual(len(calls), 1)

        # Second ?q=aac call + Range hits cache (no second transcode)
        st, rh, body = self._req("GET", f"/api/audio/{rec.s}?q=aac", headers={**hdrs, "Range": "bytes=0-15"})
        self.assertEqual(st, 206)
        self.assertEqual(body, aac_payload[:16])
        self.assertEqual(len(calls), 1)

        # Omitted query or ?q=lossless serves original file directly
        st, rh, _ = self._req("HEAD", f"/api/audio/{rec.s}?q=lossless", headers=hdrs)
        self.assertEqual(st, 200)
        self.assertEqual(int(rh["content-length"]), big_src.stat().st_size)


if __name__ == "__main__":
    unittest.main()
