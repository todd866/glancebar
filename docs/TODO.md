# To do

Open work, newest decisions first. Each item says what "done" means. Background is in
`docs/music.md` ("Song embeddings", "Kinds from the embedding").

## Music: web radio (Ian, 18 Nov 2026)

Ian asked for "a music app ... run it as a website, password protected". It's the existing song map and R2 cold tier (`glancebar-music`) put behind a phone-first web player. Done when each item below works from his phone, away from home.
Live (18 Nov): https://6ian.vercel.app ("6IAN"), repo `~/Projects/music-radio` (private), Vercel project
`6ian` (syd1). One shared site password, then a cookie account per device; email magic links to keep it. Tests: `npm run ci` there (unit, headless smoke,
fake-mic voice), run from a Mac with the `~/.config/music-radio` secrets; there is no hosted CI.
- [ ] **Web player, password protected.** Two accounts (ian, mate), scrypt + signed session cookie; audio is
  session-checked and streamed through `/api/audio` from short-lived signed R2 URLs. Works on iPhone WebKit (ALAC)
  and Chrome (AAC). Not done until the AAC tier is complete: `radio/aac/` + covers are made on the M2 by
  `~/.local/state/music-radio-media/bin/build_media.py run --from-r2` (heavy-slot; 26 of 1,435 so far), and Chrome
  only offers AAC-ready songs. iPhone uses the 30-50 MB masters until then.
- [x] **Mood-based play.** Tuner (Chill, Alt, Drive, Dance, Rap, Heavy, Wide) plus the map (tap a region). Queue
  built server-side from embedding neighbours, steered by More / Less / likes / early skips, with an energy arc,
  left turns, and a time-of-day rules table (`lib/rules.ts`, per-account timezone, default Australia/Perth, tested).
- [ ] **Everything embedded.** Nightly incremental embed on the M2 in progress (another agent, 18 Nov). Gaps on
  the radio's Profile page; 16 vectors have no R2 master.
- [x] **Radio scouting beyond triple j.** Fetchers for KEXP, NTS, 6 Music, WFMU, RRR, PBS, 4ZZZ, RTR are in
  `tools/music-scout/radio.py`, switched on in `music-scout.json`, ranked by cross-station plays (commits
  26cde4f, 1c79c16, not pushed). FBi skipped (robots.txt). Not yet ranked by nearness to liked map regions.
- [ ] **Artist seeds.** Glancebar likes count as Ian's likes in the radio's queue. No settings list or voice add yet.
- [ ] **Voice mode.** Works in the browser: mic button, one mic stream, Gemini 3.1 flash-lite intents (not this,
  heavier, lighter, more new, something I know, who is this, go back, a mood, play X), ducking, barge-in, typed
  fallback, fail-closed daily caps. Fake-mic suite passes 9/9 on production; music never paused. Own pipeline on
  md3's Gemini key, not md3's realtime stack. Still to do: a command lands 3-4 s after you stop talking (target
  ~2 s); track changes are hard cuts (no crossfade); real-phone check of lock screen and speaker routing.
- [x] **Per-listener profiles.** Per-account play/skip/like log in R2 (`radio/profiles/`), AI-vs-random
  scoreboard (1 in 10 picks is a hidden random control), new-vs-library share slider. Test runs use separate
  `-qa` profiles.

## Music: the song map (logged 16 Nov 2026)

- [ ] **Nightly map refresh.** New songs reach the lossless library but not the map. A job on
  the M2 (`utc-daily`, after the 03:40Z push) embeds new masters through the batch tool
  (about 2¢ a song), then `embed.py export` rewrites `mix/music-space.json` on the M5.
  Done when a song added today is in a kind tomorrow without anyone running a command.
- [ ] **Kinds keep enough songs on the laptop.** Each kind asks `musiclib.py` to keep about
  40 of its songs in the hot set (Chill had 9 on this Mac before the map; 43 now).
- [ ] **Kind tile covers match the map.** The four covers on a kind tile are still picked by
  genre tag (`MusicKindMosaicTrackIDs`); the song counts already use the map.
- [ ] **Reception scores.** Per song, from Glancebar's own playback log (played through,
  early skip, thumbs, dislike, repeats) and Apple Music play counts. Glancebar's own
  signals outweigh account-wide ones: the YouTube account is shared (Jake's "6L GTR" has
  27 searches; Ian likes it but it isn't heavy rotation). The Takeout of 16 Nov had no
  watch history (YouTube watch history is off), only searches and playlists.
- [ ] **Check the map against reception.** For each song, compare its score with its ~10
  nearest neighbours; a lasting disagreement marks a place the map is wrong. One
  agreement number, tracked over time. Watch the hub artists (Gang of Youths, Car Seat
  Headrest, The Middle East turn up in many neighbour lists).
- [ ] **Scout fills thin, liked regions.** Density per region; `scout.py rank` aims part of
  its weekly budget at regions Ian likes that have few songs, and a small share at
  regions never tried.
- [ ] **Songs searched for but not in the library.** From the Takeout searches: Led
  Zeppelin "Whole Lotta Love" (7), "Big Foot Little Foot" (4), "Sunglasses at Night",
  Kendrick Lamar "Auntie Diaries", Willow "Wait a Minute", Imagine Dragons "Believer",
  Moby "God Moving Over the Face of the Waters". Queue for the scout once Ian confirms
  they are his, not another household member's.

## Onto the TV: music follows Ian (decided 16 Nov 2026)

TV music follows Ian's taste, not the household's, whoever is watching.

- [ ] **Put the TV's music videos on the map.** Match each `music/…` video to a library
  song by artist and title (it takes that song's vector); embed the rest from their own
  audio with the batch tool.
- [ ] **Score the station channels with the map.** `media-sync` builds
  `channel-scores.json` from closeness to what Ian likes, not only artist matches.
- [ ] **Kind channels on the TV** (Chill, Dance, Alt, Rap) built the same way as
  Glancebar's kinds.
- [ ] **Deploy** through the M2 (`incoming-m5`, kickstart while the TV is idle). The TV repo
  is public: pushing it needs Ian's yes.

## Glancebar

- [ ] **Pause-flip timing test is flaky on the M5.** `tools/check-playback.m` line 687 wants a
  pause under 50 ms; on the busy M5 with Bluetooth output it reads 90–250 ms, so the
  deploy job (`glancebar-sync`) refuses good commits. On the M2 it passes. Decide: run the
  deploy job's suite on a worker, or measure the flip without the real output device.
- [ ] **Confirm the first-click fix** (thumbs-up, 16 Nov) from Ian's use, and read any
  `~/Library/Logs/Glancebar/hangs/` sample if the popover freezes again.
