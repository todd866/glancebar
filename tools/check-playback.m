// Headless playback harness: real AVQueuePlayer, silent QA, isolated home. Never launches the app.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import "pure.h"

static NSString *gFixtureHome;
static void CleanupFixture(void) {
    if (gFixtureHome) {
        [NSFileManager.defaultManager removeItemAtPath:gFixtureHome error:nil];
        gFixtureHome = nil;
    }
}
static void PlaybackExit(int code) {
    CleanupFixture();
    exit(code);
}
static void PlaybackSignal(int sig) {
    fprintf(stderr, "Playback check interrupted (%d)\n", sig);
    PlaybackExit(128 + sig);
}
static void FailAt(int line) {
    fprintf(stderr, "Playback check failed at line %d\n", line);
    PlaybackExit(1);
}
#define Fail(line) FailAt(line)

static void PumpUntil(NSDate *deadline) {
    while (deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static BOOL WaitUntil(BOOL (^cond)(void), double timeoutSec) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSec];
    while (deadline.timeIntervalSinceNow > 0) {
        if (cond()) return YES;
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.05]);
    }
    return NO;
}

static AVQueuePlayer *LocalPlayer(Controller *c) {
    return [c valueForKey:@"localPlayer"];
}
static AVQueuePlayer *OutgoingPlayer(Controller *c) {
    return [c valueForKey:@"localOutgoing"];
}
static NSInteger LocalIndex(Controller *c) {
    return [[c valueForKey:@"localIndex"] integerValue];
}

static void AssertSilentQA(Controller *c, int line) {
    (void)c;
    if (!MusicSilentQAEnabled()) Fail(line);
    AVQueuePlayer *lp = LocalPlayer(c), *out = OutgoingPlayer(c);
    for (AVQueuePlayer *player in (lp && out ? @[lp, out] : lp ? @[lp] : out ? @[out] : @[])) {
        if (!player.muted || player.volume > 0.001f) Fail(line);
    }
}

static double PlayerSeconds(AVQueuePlayer *player) {
    if (!player || player.currentTime.timescale == 0) return 0;
    double t = CMTimeGetSeconds(player.currentTime);
    return isfinite(t) ? t : 0;
}
static double TrackDuration(AVQueuePlayer *player) {
    if (!player.currentItem) return 0;
    CMTime d = player.currentItem.duration;
    double sec = CMTIME_IS_NUMERIC(d) ? CMTimeGetSeconds(d) : 0;
    return isfinite(sec) ? sec : 0;
}

static BOOL WriteToneWAV(NSString *path, double hz, double seconds) {
    const int sampleRate = 44100;
    int frames = (int)(sampleRate * seconds + 0.5);
    if (frames < 1) return NO;
    NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)frames * 2];
    int16_t *samples = pcm.mutableBytes;
    for (int i = 0; i < frames; i++) {
        double t = (double)i / sampleRate;
        double amp = 0.25 * sin(2.0 * M_PI * hz * t);
        int16_t s = (int16_t)lrint(amp * 32767.0);
        samples[i] = s;
    }
    uint32_t dataBytes = (uint32_t)pcm.length;
    uint32_t riffSize = 36 + dataBytes;
    NSMutableData *wav = [NSMutableData data];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;
    [wav appendBytes:&fmtSize length:4];
    uint16_t audioFormat = 1, channels = 1;
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&channels length:2];
    uint32_t rate = (uint32_t)sampleRate;
    [wav appendBytes:&rate length:4];
    uint32_t byteRate = rate * 2;
    [wav appendBytes:&byteRate length:4];
    uint16_t blockAlign = 2, bits = 16;
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataBytes length:4];
    [wav appendData:pcm];
    return [wav writeToFile:path atomically:YES];
}

static BOOL Afconvert(NSString *wav, NSString *m4a, NSString *dataFormat) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/afconvert"];
    task.arguments = @[@"-f", @"m4af", @"-d", dataFormat, wav, m4a];
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:m4a];
}

static NSDictionary *TrackRecord(NSString *path, NSString *tid, NSString *title, NSString *artist) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st)) return nil;
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buffer[65536];
    NSInteger n;
    while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)n);
    [stream close];
    if (n < 0) return nil;
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(bytes, &ctx);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    return @{@"id": tid, @"title": title, @"artist": artist, @"album": @"", @"path": path,
             @"sizeBytes": @(st.st_size), @"sha256": hash,
             @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino],
             @"mtimeNs": [NSString stringWithFormat:@"%lld",
                          (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec]};
}

static NSDictionary *PlaylistFixture(NSArray<NSDictionary *> *tracks, NSArray<NSString *> *paths, NSString *key) {
    NSMutableArray *wanted = [NSMutableArray array];
    NSMutableArray *records = [NSMutableArray array];
    for (NSUInteger i = 0; i < tracks.count; i++) {
        [wanted addObject:tracks[i]];
        NSDictionary *rec = TrackRecord(paths[i], tracks[i][@"id"], tracks[i][@"title"], tracks[i][@"artist"]);
        if (!rec) return nil;
        [records addObject:rec];
    }
    NSDictionary *request = @{@"key": key, @"title": @"Playback harness", @"tracks": wanted};
    NSDictionary *entry = @{@"key": key, @"requestedTracks": wanted,
                            @"requestedTrackIDs": [wanted valueForKey:@"id"], @"tracks": records, @"ready": @YES};
    NSDictionary *manifest = @{@"schemaVersion": @1, @"playlists": @[entry]};
    return @{@"request": request, @"manifest": manifest};
}

@interface PlaybackController : Controller
@property NSUInteger loveLaunches;
@property NSUInteger unloveLaunches;
@end
@implementation PlaybackController
- (void)loveCurrentLocalTrack {
    if (![[self valueForKey:@"musicProbesEnabled"] boolValue]) return;
    if ([[self valueForKey:@"localLoveInFlight"] boolValue]) return;
    NSDictionary *ident = [self currentLocalIdentity];
    if (![ident[@"artist"] length] || ![ident[@"title"] length] || ![ident[@"trackKey"] length]) return;
    NSString *key = ident[@"trackKey"];
    if ([[self heartedKeys] containsObject:key]) return;
    self.loveLaunches++;
    [self rememberHeart:key];
    [self appendHeartHistory:@"heart" trackKey:key artist:ident[@"artist"] title:ident[@"title"]
                        path:ident[@"path"] ?: @""];
}
- (void)unloveCurrentLocalTrack {
    if (![[self valueForKey:@"musicProbesEnabled"] boolValue]) return;
    if ([[self valueForKey:@"localLoveInFlight"] boolValue]) return;
    NSDictionary *ident = [self currentLocalIdentity];
    if (![ident[@"trackKey"] length]) return;
    NSString *key = ident[@"trackKey"];
    if (![[self heartedKeys] containsObject:key]) return;
    self.unloveLaunches++;
    [self forgetHeart:key];
    [self appendHeartHistory:@"unheart" trackKey:key artist:ident[@"artist"] title:ident[@"title"]
                        path:ident[@"path"] ?: @""];
}
@end

static NSUInteger HeartHistoryEventCount(NSString *home) {
    NSString *path = [home stringByAppendingPathComponent:@".local/state/selector/heart-history.jsonl"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSUInteger n = 0;
    for (NSString *line in [text ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        if (line.length) n++;
    return n;
}

static BOOL HeartButtonFilled(Controller *c) {
    NSDictionary *ident = [c currentLocalIdentity];
    NSString *key = ident[@"trackKey"];
    return key.length && [[c heartedKeys] containsObject:key];
}

static BOOL PlayerAdvancing(Controller *c, double minDelta, double window) {
    AVQueuePlayer *player = LocalPlayer(c);
    double start = PlayerSeconds(player);
    if (player.rate <= 0) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:window];
    while (deadline.timeIntervalSinceNow > 0) {
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.05]);
        if (PlayerSeconds(player) - start > minDelta) return YES;
    }
    return NO;
}

static NSSlider *SeekSlider(double seconds) {
    NSSlider *slider = [NSSlider new];
    slider.doubleValue = seconds;
    return slider;
}
@interface StallWatch : NSObject
@property double worstMs;
@property NSTimer *timer;
@property CFAbsoluteTime nextFire;
@end
@implementation StallWatch
- (void)tick:(NSTimer *)t {
    (void)t;
    double lateMs = (CFAbsoluteTimeGetCurrent() - self.nextFire) * 1000.0;
    if (lateMs > self.worstMs) self.worstMs = lateMs;
    self.nextFire = CFAbsoluteTimeGetCurrent() + 0.05;
}
- (void)start {
    self.worstMs = 0;
    self.nextFire = CFAbsoluteTimeGetCurrent() + 0.05;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(tick:)
                                                userInfo:nil repeats:YES];
}
- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
}
@end

static NSDictionary *ManifestWithCorruptHash(NSDictionary *manifest, NSString *key, NSUInteger trackIndex) {
    if (![manifest[@"playlists"] isKindOfClass:NSArray.class]) return manifest;
    NSMutableDictionary *root = [manifest mutableCopy];
    NSMutableArray *playlists = [NSMutableArray array];
    for (id item in manifest[@"playlists"]) {
        if (![item isKindOfClass:NSDictionary.class]) { [playlists addObject:item]; continue; }
        NSDictionary *pl = item;
        if (![pl[@"key"] isEqual:key]) { [playlists addObject:pl]; continue; }
        NSMutableDictionary *copy = [pl mutableCopy];
        NSMutableArray *tracks = [NSMutableArray array];
        NSUInteger i = 0;
        for (id tr in [pl[@"tracks"] isKindOfClass:NSArray.class] ? pl[@"tracks"] : @[]) {
            if (i == trackIndex && [tr isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *bad = [tr mutableCopy];
                bad[@"sha256"] = @"0000000000000000000000000000000000000000000000000000000000000000";
                [tracks addObject:bad];
            } else [tracks addObject:tr ?: @{}];
            i++;
        }
        copy[@"tracks"] = tracks;
        [playlists addObject:copy];
    }
    root[@"playlists"] = playlists;
    return root;
}

static NSArray<NSString *> *GenerateTracks(NSString *musicRoot, NSArray<NSDictionary *> *specs) {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray *formats = @[@"aac", @"aac", @"alac", @"alac"];
    double tones[] = {261.63, 329.63, 392.0, 493.88};
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSDictionary *spec = specs[i];
        NSString *wav = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"t%lu.wav", (unsigned long)i]];
        NSString *name = [NSString stringWithFormat:@"%@ - %@ [%@].m4a", spec[@"artist"], spec[@"title"], spec[@"id"]];
        NSString *m4a = [musicRoot stringByAppendingPathComponent:name];
        if (!WriteToneWAV(wav, tones[i % 4], 12.0)) return nil;
        if (!Afconvert(wav, m4a, formats[i % formats.count])) return nil;
        [paths addObject:m4a];
    }
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    return paths;
}

int main(void) {
    @autoreleasepool {
        signal(SIGINT, PlaybackSignal);
        signal(SIGTERM, PlaybackSignal);
        setenv("GLANCEBAR_SILENT_QA", "1", 1);
        setenv("GLANCEBAR_STUB_APPLESCRIPT", "1", 1);
        setenv("GLANCEBAR_SKIP_WELCOME", "1", 1);
        setenv("GLANCEBAR_MIX_FROZEN", "1", 1);
        if (!MusicSilentQAEnabled()) Fail(__LINE__);

        gFixtureHome = [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@".glancebar-playback-%@", NSUUID.UUID.UUIDString]];
        atexit(CleanupFixture);
        NSString *musicRoot = [gFixtureHome stringByAppendingPathComponent:@"Music"];
        NSString *likedDir = [musicRoot stringByAppendingPathComponent:@"YouTube Liked"];
        NSString *support = [gFixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar"];
        NSString *state = [gFixtureHome stringByAppendingPathComponent:@".local/state/selector"];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *dir in @[musicRoot, likedDir, support, state])
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("GLANCEBAR_HOME", gFixtureHome.UTF8String, 1);

        NSArray *specs = @[
            @{@"id": @"T1", @"title": @"Track One", @"artist": @"Artist One", @"album": @""},
            @{@"id": @"T2", @"title": @"Track Two", @"artist": @"Artist Two", @"album": @""},
            @{@"id": @"T3", @"title": @"Track Three", @"artist": @"Artist Three", @"album": @""},
            @{@"id": @"T4", @"title": @"Track Four", @"artist": @"Artist Four", @"album": @""},
        ];
        NSArray<NSString *> *paths = GenerateTracks(musicRoot, specs);
        if (paths.count != 4) Fail(__LINE__);

        NSDictionary *fixture = PlaylistFixture(specs, paths, @"song:playback");
        if (!fixture) Fail(__LINE__);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        PlaybackController *c = [PlaybackController new];
        if (!MusicSilentQAEnabled()) Fail(__LINE__);
        [c setValue:@YES forKey:@"musicSilentQA"];
        [c setValue:@YES forKey:@"musicProbesEnabled"];
        AssertSilentQA(c, __LINE__);
        [c setValue:@YES forKey:@"mixFrozen"];
        [c setValue:@NO forKey:@"musicOff"];
        [c setValue:@NO forKey:@"musiclibBusy"];
        [c setValue:[@{@"song:playback": fixture[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:fixture[@"manifest"] forKey:@"offlineManifest"];
        [c setValue:@[@{@"key": @"song:playback", @"kind": @"song", @"title": @"Track One", @"subtitle": @"Artist One",
                        @"trackID": @"T1", @"artist": @"Artist One", @"album": @"", @"family": @"other"}]
              forKey:@"mixSeeds"];

        // --- seed tile: 4-track queue starts and time advances ---
        if (![[c offlineCoverage:@"song:playback" verifyHash:YES][@"ready"] boolValue]) Fail(__LINE__);
        [c playOfflinePlaylist:@"song:playback"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c) != nil; }, 8)) Fail(__LINE__);
        AVQueuePlayer *player = LocalPlayer(c);
        if (!WaitUntil(^BOOL { return player.rate > 0; }, 5)) {
            fprintf(stderr, "AVPlayer did not start (rate stayed 0). "
                    "No playable audio output or headless environment cannot decode m4a.\n");
            Fail(__LINE__);
        }
        AssertSilentQA(c, __LINE__);
        if (!PlayerAdvancing(c, 1.0, 5.0)) Fail(__LINE__);

        // --- pause / resume via musicPlay: ---
        double moving = PlayerSeconds(player);
        [c musicPlay:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.5]);
        if (player.rate > 0) Fail(__LINE__);
        double pausedAt = PlayerSeconds(player);
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return player.rate > 0; }, 3)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);
        if (!PlayerAdvancing(c, 0.4, 3.0)) Fail(__LINE__);
        (void)moving; (void)pausedAt;

        // --- seek to 6 s ---
        [c musicSeek:SeekSlider(6.0)];
        if (!WaitUntil(^BOOL { return fabs(PlayerSeconds(player) - 6.0) < 0.5; }, 8)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- musicNext double-tap cut ---
        NSInteger cutFrom = LocalIndex(c);
        [c musicNext:nil];
        [c musicNext:nil];
        if (!WaitUntil(^BOOL { return LocalIndex(c) != cutFrom; }, 1.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- musicNext single tap blend ---
        [c musicSeek:SeekSlider(1.0)];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.2]);
        [c musicNext:nil];
        if (!WaitUntil(^BOOL {
            return OutgoingPlayer(c) != nil || [c valueForKey:@"localBlendTimer"] != nil;
        }, 2.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);
        if (OutgoingPlayer(c) && (!OutgoingPlayer(c).muted || OutgoingPlayer(c).volume != 0.f)) Fail(__LINE__);
        if (!WaitUntil(^BOOL { return !OutgoingPlayer(c) && ![c valueForKey:@"localBlendTimer"]; }, 8.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- natural end advances and wraps ---
        if (LocalPlayer(c).rate > 0) [c musicPlay:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.4]);
        if (![[c offlineCoverage:@"song:playback" verifyHash:YES][@"ready"] boolValue]) Fail(__LINE__);
        [c playOfflinePlaylist:@"song:playback"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 10)) Fail(__LINE__);
        player = LocalPlayer(c);
        NSInteger at = LocalIndex(c);
        double dur = TrackDuration(player);
        if (dur < 1.0) dur = 12.5;
        if (!WaitUntil(^BOOL { return LocalIndex(c) == at + 1; }, dur + 3.0)) Fail(__LINE__);
        while (LocalIndex(c) < 3) {
            at = LocalIndex(c);
            player = LocalPlayer(c);
            dur = TrackDuration(player);
            if (dur < 1.0) dur = 12.5;
            if (!WaitUntil(^BOOL { return LocalIndex(c) > at; }, dur + 3.0)) Fail(__LINE__);
        }
        at = LocalIndex(c);
        player = LocalPlayer(c);
        dur = TrackDuration(player);
        if (dur < 1.0) dur = 12.5;
        if (!WaitUntil(^BOOL { return LocalIndex(c) == 0; }, dur + 3.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- musicPrevious restart vs skip back ---
        [c musicSeek:SeekSlider(5.0)];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.3]);
        [c musicPrevious:nil];
        if (!WaitUntil(^BOOL { return PlayerSeconds(player) < 0.6; }, 2.0)) Fail(__LINE__);
        [c musicSeek:SeekSlider(2.0)];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.2]);
        NSInteger prevFrom = LocalIndex(c);
        [c musicPrevious:nil];
        if (!WaitUntil(^BOOL { return LocalIndex(c) == prevFrom - 1 || (prevFrom == 0 && LocalIndex(c) > 0); }, 2.0))
            Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- output device fallback ---
        [c setValue:@[@{@"uid": @"builtin", @"name": @"Built-in", @"transport": @(GlanceAudioTransportBuiltIn),
                        @"outputChannels": @2, @"volumeControllable": @YES, @"dataSource": @""}]
              forKey:@"audioDevices"];
        [c setValue:@"builtin" forKey:@"defaultOutputUID"];
        [c setPlayerOutputChoiceUID:@"missing-output-uid" name:@"Missing"];
        if (LocalPlayer(c).audioOutputDeviceUniqueID.length) Fail(__LINE__);
        if (LocalPlayer(c).rate <= 0) [LocalPlayer(c) play];
        if (!PlayerAdvancing(c, 0.3, 3.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- Now Playing + remote commands while playing; cleared on stop ---
        NSDictionary *np = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (![np[MPMediaItemPropertyTitle] isKindOfClass:NSString.class] || ![(NSString *)np[MPMediaItemPropertyTitle] length])
            Fail(__LINE__);
        if (![[c valueForKey:@"remoteCommandsOn"] boolValue]) Fail(__LINE__);
        [c musicPlay:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.3]);
        [c setValue:@YES forKey:@"networkKnown"];
        [c setValue:@YES forKey:@"networkOnline"];
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        [c disableRemoteCommands];
        if (!WaitUntil(^BOOL { return !MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo; }, 3)) Fail(__LINE__);
        if ([[c valueForKey:@"remoteCommandsOn"] boolValue]) Fail(__LINE__);

        // --- idle Play skips symlink and empty m4a ---
        NSString *good = paths[0];
        NSString *link = [likedDir stringByAppendingPathComponent:@"link.m4a"];
        NSString *empty = [likedDir stringByAppendingPathComponent:@"empty.m4a"];
        [fm copyItemAtPath:good toPath:[likedDir stringByAppendingPathComponent:good.lastPathComponent] error:nil];
        [fm createSymbolicLinkAtPath:link withDestinationPath:good error:nil];
        [@"" writeToFile:empty atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [c setValue:@NO forKey:@"localMode"];
        [c setValue:nil forKey:@"offlineTracks"];
        [c setValue:@NO forKey:@"offlineTracksReady"];
        [c setValue:@YES forKey:@"offlineTracksEntering"];
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return LocalPlayer(c) != nil; }, 5)) Fail(__LINE__);
        NSArray *urls = [c valueForKey:@"localURLs"];
        if (urls.count != 1) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);

        // --- heart toggle: heart → unheart → heart; history append-only ---
        if (![[c offlineCoverage:@"song:playback" verifyHash:YES][@"ready"] boolValue]) Fail(__LINE__);
        [c playOfflinePlaylist:@"song:playback"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 5)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);
        PlaybackController *pc = (PlaybackController *)c;
        if (pc.loveLaunches || pc.unloveLaunches) Fail(__LINE__);
        if (HeartButtonFilled(c)) Fail(__LINE__);
        [c musicFavorite:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.5]);
        if (pc.loveLaunches != 1 || pc.unloveLaunches) Fail(__LINE__);
        if (!HeartButtonFilled(c)) Fail(__LINE__);
        NSString *heartsPath = [gFixtureHome stringByAppendingPathComponent:@".local/state/selector/hearts.json"];
        NSString *heartsJSON = [NSString stringWithContentsOfFile:heartsPath encoding:NSUTF8StringEncoding error:nil];
        if (!HeartCacheContains(heartsJSON, @"artist one|track one")) Fail(__LINE__);
        [c musicFavorite:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.2]);
        if (pc.loveLaunches != 1 || pc.unloveLaunches != 1) Fail(__LINE__);
        if (HeartButtonFilled(c)) Fail(__LINE__);
        heartsJSON = [NSString stringWithContentsOfFile:heartsPath encoding:NSUTF8StringEncoding error:nil];
        if (HeartCacheContains(heartsJSON, @"artist one|track one")) Fail(__LINE__);
        [c musicFavorite:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.2]);
        if (pc.loveLaunches != 2 || pc.unloveLaunches != 1) Fail(__LINE__);
        if (!HeartButtonFilled(c)) Fail(__LINE__);
        heartsJSON = [NSString stringWithContentsOfFile:heartsPath encoding:NSUTF8StringEncoding error:nil];
        if (HeartCacheKeys(heartsJSON).count != 1) Fail(__LINE__);
        if (HeartHistoryEventCount(gFixtureHome) != 3) Fail(__LINE__);

        // --- silent system default: player pins built-in, not the display ---
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        NSDictionary *builtinOut = @{@"uid": @"builtin", @"name": @"MacBook Air Speakers",
                                     @"transport": @(GlanceAudioTransportBuiltIn), @"outputChannels": @2,
                                     @"deviceID": @1, @"volumeControllable": @YES, @"dataSource": @""};
        NSDictionary *dellOut = @{@"uid": @"dell", @"name": @"DELL U2424HE",
                                  @"transport": @(GlanceAudioTransportDisplay), @"outputChannels": @2,
                                  @"deviceID": @99, @"volumeControllable": @NO, @"dataSource": @""};
        [c setValue:@[builtinOut, dellOut] forKey:@"audioDevices"];
        [c setValue:@"dell" forKey:@"defaultOutputUID"];
        [c setPlayerOutputChoiceUID:@"" name:@""];
        if (![[c playerOutputChoice][@"effectiveUID"] isEqual:@"builtin"]) Fail(__LINE__);
        if (![[c offlineCoverage:@"song:playback" verifyHash:YES][@"ready"] boolValue]) Fail(__LINE__);
        [c playOfflinePlaylist:@"song:playback"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c) != nil; }, 8)) Fail(__LINE__);
        NSString *playerUID = LocalPlayer(c).audioOutputDeviceUniqueID;
        if (![playerUID isEqual:@"builtin"]) Fail(__LINE__);

        // --- responsiveness: tile click, background hash, transport, seeks, rebuild stalls ---
        double resp40StartMs = 0, respPauseMs = 0, respResumeMs = 0, respNextCutMs = 0;
        NSUInteger respHashBeforeAudio = 0, respSeekApplies = 0;
        double respRebuildStallMs = 0;
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        [c setValue:@NO forKey:@"mixFrozen"];
        [c setValue:@NO forKey:@"musicOff"];
        NSMutableArray *fortySpecs = [NSMutableArray array];
        for (NSUInteger i = 0; i < 40; i++) {
            [fortySpecs addObject:@{@"id": [NSString stringWithFormat:@"F%lu", (unsigned long)i],
                                    @"title": [NSString stringWithFormat:@"Fast %lu", (unsigned long)i],
                                    @"artist": @"Resp", @"album": @""}];
        }
        NSString *fortySeedPath = [GenerateTracks(musicRoot, @[fortySpecs[0]]) firstObject];
        if (!fortySeedPath.length) Fail(__LINE__);
        NSMutableArray<NSString *> *fortyPaths = [NSMutableArray arrayWithCapacity:40];
        for (NSUInteger i = 0; i < 40; i++) [fortyPaths addObject:fortySeedPath];
        NSDictionary *fortyFixture = PlaylistFixture(fortySpecs, fortyPaths, @"song:resp40");
        if (!fortyFixture) Fail(__LINE__);
        [c setValue:[@{@"song:resp40": fortyFixture[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:fortyFixture[@"manifest"] forKey:@"offlineManifest"];
        (void)[c offlineCoverageForDisplay:@"song:resp40"];
        [c preparePlaylistFirstItem:@"song:resp40"];
        NSArray *respPaths = [c offlineCoverage:@"song:resp40" verifyHash:NO][@"paths"];
        if (respPaths.count != 40) Fail(__LINE__);
        (void)respPaths;
        OfflinePlaylistResetHashMetrics();
        CFAbsoluteTime clickT0 = CFAbsoluteTimeGetCurrent();
        [c playOfflinePlaylist:@"song:resp40"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c) != nil && LocalPlayer(c).rate > 0; }, 1.0)) Fail(__LINE__);
        resp40StartMs = (CFAbsoluteTimeGetCurrent() - clickT0) * 1000.0;
        respHashBeforeAudio = OfflinePlaylistHashCallsBeforeFirstAudio();
        if (resp40StartMs > 300.0) {
            fprintf(stderr, "40-track tile click: rate > 0 took %.0f ms (limit 300)\n", resp40StartMs);
            Fail(__LINE__);
        }
        if (respHashBeforeAudio != 0) {
            fprintf(stderr, "hash calls before first audio: %lu (expected 0)\n", (unsigned long)respHashBeforeAudio);
            Fail(__LINE__);
        }
        player = LocalPlayer(c);
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        NSArray *hashSpecs = @[
            @{@"id": @"H0", @"title": @"Hash Zero", @"artist": @"Resp", @"album": @""},
            @{@"id": @"H1", @"title": @"Hash One", @"artist": @"Resp", @"album": @""},
            @{@"id": @"H2", @"title": @"Hash Two", @"artist": @"Resp", @"album": @""},
        ];
        NSArray *hashPaths = GenerateTracks(musicRoot, hashSpecs);
        if (hashPaths.count != 3) Fail(__LINE__);
        NSDictionary *hashFixture = PlaylistFixture(hashSpecs, hashPaths, @"song:hashfail");
        if (!hashFixture) Fail(__LINE__);
        NSDictionary *hashManifest = ManifestWithCorruptHash(hashFixture[@"manifest"], @"song:hashfail", 2);
        [c setValue:[@{@"song:hashfail": hashFixture[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:hashManifest forKey:@"offlineManifest"];
        [c playOfflinePlaylist:@"song:hashfail"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 3.0)) Fail(__LINE__);
        if (!WaitUntil(^BOOL { return (NSInteger)[[c valueForKey:@"localURLs"] count] == 2; }, 8.0)) Fail(__LINE__);
        if (LocalPlayer(c).rate <= 0 || LocalIndex(c) != 0) Fail(__LINE__);
        // The rejected file must be gone from the player's own queue, not only from the list.
        for (AVPlayerItem *queued in LocalPlayer(c).items) {
            NSURL *queuedURL = [queued.asset isKindOfClass:AVURLAsset.class] ? ((AVURLAsset *)queued.asset).URL : nil;
            if ([queuedURL.path isEqual:hashPaths[2]]) Fail(__LINE__);
        }
        if (LocalPlayer(c).items.count != 2) Fail(__LINE__);

        CFAbsoluteTime pauseT0 = CFAbsoluteTimeGetCurrent();
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate == 0; }, 0.25)) Fail(__LINE__);
        respPauseMs = (CFAbsoluteTimeGetCurrent() - pauseT0) * 1000.0;
        if (respPauseMs > 50.0) {
            fprintf(stderr, "pause flip took %.1f ms (limit 50)\n", respPauseMs);
            Fail(__LINE__);
        }
        CFAbsoluteTime resumeT0 = CFAbsoluteTimeGetCurrent();
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 0.25)) Fail(__LINE__);
        respResumeMs = (CFAbsoluteTimeGetCurrent() - resumeT0) * 1000.0;
        if (respResumeMs > 50.0) {
            fprintf(stderr, "resume flip took %.1f ms (limit 50)\n", respResumeMs);
            Fail(__LINE__);
        }

        NSInteger respCutFrom = LocalIndex(c);
        CFAbsoluteTime cutT0 = CFAbsoluteTimeGetCurrent();
        [c musicNext:nil];
        [c musicNext:nil];
        if (!WaitUntil(^BOOL { return LocalIndex(c) != respCutFrom; }, 0.2)) Fail(__LINE__);
        respNextCutMs = (CFAbsoluteTimeGetCurrent() - cutT0) * 1000.0;
        if (respNextCutMs > 150.0) {
            fprintf(stderr, "double-tap Next cut took %.0f ms (limit 150)\n", respNextCutMs);
            Fail(__LINE__);
        }

        [c setValue:@0 forKey:@"coalescedSeekCount"];
        for (int ev = 0; ev < 30; ev++) [c musicSeek:SeekSlider((double)(ev % 10))];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.25]);
        respSeekApplies = [c coalescedSeekApplyCount];
        if (respSeekApplies > 5) {
            fprintf(stderr, "30 scrub events → %lu seeks (limit 5)\n", (unsigned long)respSeekApplies);
            Fail(__LINE__);
        }

        StallWatch *rebuildStalls = [StallWatch new];
        [rebuildStalls start];
        for (int tick = 0; tick < 5; tick++) {
            [c rebuildContent];
            PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.35]);
        }
        [rebuildStalls stop];
        respRebuildStallMs = rebuildStalls.worstMs;
        if (respRebuildStallMs > 100.0) {
            fprintf(stderr, "popover rebuild stall %.1f ms during playback (limit 100)\n", respRebuildStallMs);
            Fail(__LINE__);
        }
        fprintf(stderr,
                "Responsiveness: 40-track start %.0f ms, hash-before-audio %lu, pause %.1f ms, resume %.1f ms, "
                "Next cut %.0f ms, seeks %lu/30 events, rebuild stall %.1f ms\n",
                resp40StartMs, (unsigned long)respHashBeforeAudio, respPauseMs, respResumeMs, respNextCutMs,
                (unsigned long)respSeekApplies, respRebuildStallMs);

        // --- a rejected track leaves by path; pause is kept; a deferred seek stays on its track ---
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        NSArray *dropSpecs = @[
            @{@"id": @"D0", @"title": @"Drop Zero", @"artist": @"Resp", @"album": @""},
            @{@"id": @"D1", @"title": @"Drop One", @"artist": @"Resp", @"album": @""},
            @{@"id": @"D2", @"title": @"Drop Two", @"artist": @"Resp", @"album": @""},
            @{@"id": @"D3", @"title": @"Drop Three", @"artist": @"Resp", @"album": @""},
        ];
        NSArray *dropPaths = GenerateTracks(musicRoot, dropSpecs);
        if (dropPaths.count != 4) Fail(__LINE__);
        NSDictionary *dropFixture = PlaylistFixture(dropSpecs, dropPaths, @"song:drop");
        if (!dropFixture) Fail(__LINE__);
        [c setValue:[@{@"song:drop": dropFixture[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:dropFixture[@"manifest"] forKey:@"offlineManifest"];
        [c playOfflinePlaylist:@"song:drop"];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 3.0)) Fail(__LINE__);
        AssertSilentQA(c, __LINE__);
        // An upcoming track is dropped while the first plays: the current item is untouched.
        AVPlayerItem *dropCurrent = LocalPlayer(c).currentItem;
        [c dropLocalPath:dropPaths[2] reason:@"harness"];
        if ([[c valueForKey:@"localURLs"] count] != 3 || LocalIndex(c) != 0) Fail(__LINE__);
        if (LocalPlayer(c).currentItem != dropCurrent || LocalPlayer(c).rate <= 0) Fail(__LINE__);
        if (LocalPlayer(c).items.count != 3) Fail(__LINE__);
        for (AVPlayerItem *queued in LocalPlayer(c).items) {
            NSURL *queuedURL = [queued.asset isKindOfClass:AVURLAsset.class] ? ((AVURLAsset *)queued.asset).URL : nil;
            if ([queuedURL.path isEqual:dropPaths[2]]) Fail(__LINE__);
        }
        // The current track is dropped while paused: the next one is loaded and stays paused.
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate == 0; }, 0.25)) Fail(__LINE__);
        [c dropLocalPath:dropPaths[0] reason:@"harness"];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.4]);
        if ([[c valueForKey:@"localURLs"] count] != 2 || LocalIndex(c) != 0) Fail(__LINE__);
        if (LocalPlayer(c).rate != 0 || [[c valueForKey:@"playbackPlaying"] boolValue]) Fail(__LINE__);
        NSURL *dropNow = [LocalPlayer(c).currentItem.asset isKindOfClass:AVURLAsset.class]
            ? ((AVURLAsset *)LocalPlayer(c).currentItem.asset).URL : nil;
        if (![dropNow.path isEqual:dropPaths[1]]) Fail(__LINE__);
        // A scrub followed at once by a cut to the next track: the seek must not land on the new track.
        [c musicPlay:nil];
        if (!WaitUntil(^BOOL { return LocalPlayer(c).rate > 0; }, 0.5)) Fail(__LINE__);
        NSInteger seekFrom = LocalIndex(c);
        [c musicSeek:SeekSlider(6.0)];
        [c musicNext:nil];
        [c musicNext:nil];
        if (!WaitUntil(^BOOL { return LocalIndex(c) != seekFrom; }, 0.3)) Fail(__LINE__);
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.3]);
        if (PlayerSeconds(LocalPlayer(c)) > 3.0) {
            fprintf(stderr, "deferred seek landed on the next track (%.1f s)\n", PlayerSeconds(LocalPlayer(c)));
            Fail(__LINE__);
        }
        fprintf(stderr, "Drop/seek: rejected track leaves the queue, pause kept, seek stays on its track\n");

        // --- 2,000-track scale: fast start, bounded queue, no main-thread stalls ---
        [c tearDownLocalPlayer];
        [c setValue:@NO forKey:@"localMode"];
        NSDictionary *bulkSpec = @{@"id": @"T0", @"title": @"Bulk Zero", @"artist": @"Bulk", @"album": @""};
        NSArray *bulkPaths = GenerateTracks(musicRoot, @[bulkSpec]);
        if (bulkPaths.count != 1) Fail(__LINE__);
        NSString *seedPath = bulkPaths[0];
        // 2,000 queue slots (one on-disk file); exercises queue-window arithmetic without
        // materializing 2,000 distinct paths (hard links / clonefile are flaky on some volumes).
        NSMutableArray<NSString *> *massPaths = [NSMutableArray arrayWithCapacity:2000];
        for (NSInteger i = 0; i < 2000; i++) [massPaths addObject:seedPath];

        CFAbsoluteTime playT0 = CFAbsoluteTimeGetCurrent();
        [c playLocalPaths:massPaths];
        if (!WaitUntil(^BOOL { return LocalPlayer(c) != nil && LocalPlayer(c).rate > 0; }, 1.5)) Fail(__LINE__);
        double startMs = (CFAbsoluteTimeGetCurrent() - playT0) * 1000.0;
        AVQueuePlayer *massPlayer = LocalPlayer(c);
        if (massPlayer.items.count > 16) Fail(__LINE__);
        [c setValue:@YES forKey:@"mixFrozen"];
        [c setValue:@YES forKey:@"musicOff"];
        StallWatch *stalls = [StallWatch new];
        [stalls start];
        for (int tick = 0; tick < 5; tick++) {
            [c rebuildContent];
            PumpUntil([NSDate dateWithTimeIntervalSinceNow:1.0]);
        }
        [stalls stop];
        [c musicNext:nil];
        [c musicNext:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.3]);
        [c musicPlay:nil];
        PumpUntil([NSDate dateWithTimeIntervalSinceNow:0.3]);
        if (startMs > 1500.0) {
            fprintf(stderr, "Scale play start took %.0f ms (limit 1500)\n", startMs);
            Fail(__LINE__);
        }
        if (stalls.worstMs > 250.0) {
            fprintf(stderr, "Main-thread stall %.1f ms (limit 250)\n", stalls.worstMs);
            Fail(__LINE__);
        }
        fprintf(stderr, "Scale: play start %.0f ms, worst main-thread stall %.1f ms\n", startMs, stalls.worstMs);

        fprintf(stderr, "OK: playback harness scenarios passed\n");
        CleanupFixture();
        return 0;
    }
}
