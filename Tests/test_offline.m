// Offline tests intercept the final player boundary; no audio devices or providers are used.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop
#import "offline_fixture.h"
static int failures;
static void check(BOOL ok, NSString *message) { fprintf(stderr, "%s %s\n", ok ? "ok" : "FAIL", message.UTF8String); if (!ok) failures++; }
@interface OfflineController : Controller
@property NSArray *received;
@property NSUInteger preparations, playerCalls;
@property NSUInteger mixPrepareStarts;
@end
@implementation OfflineController
- (void)playLocalPaths:(NSArray<NSString *> *)paths { self.received = paths; self.playerCalls++; }
- (void)prepareOfflineCache { self.preparations++; }
- (void)prepareMix:(NSDictionary *)seed then:(void (^)(NSArray *))done {
    self.mixPrepareStarts++;
    [super prepareMix:seed then:done];
}
@end
static void settle(void) { NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.2]; while (end.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
int main(void) {
    @autoreleasepool {
        NSString *home = [NSHomeDirectory() stringByAppendingPathComponent:[@".glancebar-offline-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *root = [home stringByAppendingPathComponent:@"Music"], *path = [root stringByAppendingPathComponent:@"track.m4a"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("GLANCEBAR_HOME", home.UTF8String, 1);
        @try {
            [@"synthetic offline fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary *f = OfflineFixture(path, @"song:test"), *request = f[@"request"], *manifest = f[@"manifest"];
            NSDictionary *ok = OfflinePlaylistCoverage(request, manifest, root, YES);
            check([ok[@"ready"] boolValue] && [ok[@"paths"] isEqual:@[path]], @"ordered exact byte-verified fixture is ready");
            NSMutableDictionary *stale = [request mutableCopy];
            NSMutableDictionary *retag = [request[@"tracks"][0] mutableCopy]; retag[@"album"] = @"Different edition"; stale[@"tracks"] = @[retag];
            check(![OfflinePlaylistCoverage(stale, manifest, root, NO)[@"ready"] boolValue], @"same ID with stale metadata fails closed");
            NSDictionary *missing = @{@"id": @"missing-id", @"title": @"Missing", @"artist": @"Nobody", @"album": @""};
            NSMutableDictionary *partialRequest = [request mutableCopy];
            partialRequest[@"tracks"] = @[request[@"tracks"][0], missing];
            NSMutableDictionary *partialManifest = [manifest mutableCopy];
            NSMutableArray *playlists = [manifest[@"playlists"] mutableCopy];
            NSMutableDictionary *entry = [playlists[0] mutableCopy];
            entry[@"requestedTracks"] = partialRequest[@"tracks"];
            entry[@"requestedTrackIDs"] = @[@"fixture-id", @"missing-id"];
            entry[@"tracks"] = playlists[0][@"tracks"];
            playlists[0] = entry;
            partialManifest[@"playlists"] = playlists;
            NSDictionary *partial = OfflinePlaylistCoverage(partialRequest, partialManifest, root, NO);
            check([partial[@"ready"] boolValue] && [partial[@"paths"] count] == 1, @"partial playlist supplies on-disk tracks in order");
            check(![OfflinePlaylistCoverage(request, manifest, [root stringByAppendingPathComponent:@"other"], NO)[@"ready"] boolValue], @"out of pool file rejected");
            NSString *link = [root stringByAppendingPathComponent:@"link.m4a"];
            [fm createSymbolicLinkAtPath:link withDestinationPath:path error:nil];
            check(![OfflinePathsCoverage(@[link], root)[@"ready"] boolValue], @"symlink source rejected");
            OfflineController *c = [OfflineController new];
            [c setValue:@YES forKey:@"musicProbesEnabled"];
            [c setValue:@[@{@"key": @"song:test"}] forKey:@"mixSeeds"];
            [c setValue:[@{@"song:test": request} mutableCopy] forKey:@"offlineRequests"];
            [c setValue:manifest forKey:@"offlineManifest"];
            [c playOfflinePlaylist:@"song:test"]; settle();
            check([c.received isEqual:@[path]], @"seed click reaches intercepted local boundary in exact order");
            c.received = nil;
            NSUInteger before = c.playerCalls;
            for (NSUInteger i = 0; i < 10; i++) [c playOfflinePlaylist:@"song:test"];
            settle();
            check(c.playerCalls == before + 1, @"repeated clicks coalesce into one verification and player entry");
            c.received = nil;
            NSString *other = [root stringByAppendingPathComponent:@"other.m4a"];
            [@"other synthetic bytes" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary *replacement = OfflineFixture(other, @"song:test");
            [c playOfflinePlaylist:@"song:test"];
            [c setValue:replacement[@"manifest"] forKey:@"offlineManifest"]; settle();
            check(!c.received, @"manifest mapping swap cannot play captured old paths");
            [c setValue:manifest forKey:@"offlineManifest"];
            [c playOfflinePlaylist:@"song:test"]; [c remotePause:nil]; settle();
            check(!c.received, @"media-key pause cancels a pending playlist start");
            [c setValue:@YES forKey:@"localMode"]; [c setValue:@YES forKey:@"networkKnown"]; [c setValue:@YES forKey:@"networkOnline"];
            [c setValue:@"song:test" forKey:@"mixPlayingKey"]; [c yieldLocalMusicIfIdle];
            check([[c valueForKey:@"localMode"] boolValue], @"yield no longer tears down paused offline queue");
            [c setValue:@NO forKey:@"localMode"];
            [c playOfflinePlaylist:@"song:test"]; settle();
            check([c.received isEqual:@[path]], @"local player starts without Music/Chrome/deck guards");
            c.received = nil;
            [c setValue:@[] forKey:@"mixSeeds"]; settle();
            check(!c.received, @"hidden old seed cannot start after asynchronous validation");
            [c setValue:@[@{@"key": @"song:test"}] forKey:@"mixSeeds"];
            [c playOfflinePlaylist:@"song:test"];
            [c setValue:@NO forKey:@"musicProbesEnabled"]; settle();
            check(!c.received, @"disabled audio gate prevents queued player entry");
            [c setValue:@YES forKey:@"musicProbesEnabled"];
            [@"different offline fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            check(![OfflinePlaylistCoverage(request, manifest, root, YES)[@"ready"] boolValue], @"changed file invalidates readiness");
            [c playOfflinePlaylist:@"song:test"]; settle();
            check(!c.received && c.preparations > 0, @"missing/stale queue triggers preparation only, no cloud fallback");
            NSString *stationDir = [home stringByAppendingPathComponent:@".local/state/selector"];
            [fm createDirectoryAtPath:stationDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSData *station = [NSJSONSerialization dataWithJSONObject:@{@"queue": @[@{@"file": path, @"title": @"Present"}, @{@"title": @"Missing"}]} options:0 error:nil];
            [station writeToFile:[stationDir stringByAppendingPathComponent:@"station.json"] atomically:YES];
            [c ensureStation];
            NSDictionary *stationRequest = [c valueForKey:@"offlineRequests"][@"station:triplej"];
            check([stationRequest[@"tracks"] count] == 2, @"station retains pathless queue entries as gaps");
            NSDictionary *present = stationRequest[@"tracks"][0];
            struct stat st; stat(path.fileSystemRepresentation, &st);
            NSData *data = [NSData dataWithContentsOfFile:path];
            uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
            NSMutableString *hash = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
            NSDictionary *record = @{@"id": present[@"id"], @"title": present[@"title"], @"artist": present[@"artist"],
                @"album": present[@"album"], @"path": path, @"sizeBytes": @(st.st_size), @"sha256": hash,
                @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino],
                @"mtimeNs": [NSString stringWithFormat:@"%lld", (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec]};
            NSMutableArray *requested = [NSMutableArray array];
            for (NSDictionary *t in stationRequest[@"tracks"])
                [requested addObject:@{@"id": t[@"id"], @"title": t[@"title"], @"artist": t[@"artist"], @"album": t[@"album"] ?: @""}];
            NSDictionary *stationEntry = @{@"key": @"station:triplej", @"requestedTracks": requested,
                @"requestedTrackIDs": @[present[@"id"], stationRequest[@"tracks"][1][@"id"]], @"tracks": @[record], @"ready": @YES};
            NSMutableDictionary *stationManifest = [manifest mutableCopy];
            stationManifest[@"playlists"] = @[manifest[@"playlists"][0], stationEntry];
            [c setValue:stationManifest forKey:@"offlineManifest"];
            [c playStation:nil]; settle();
            check([c.received isEqual:@[path]], @"partial station plays verified on-disk tracks only");
            [c setOfflineRequest:@"test:invalid" title:@"Invalid" tracks:request[@"tracks"]];
            [c setOfflineRequest:@"test:invalid" title:@"Invalid" tracks:@[@{@"title": @"Missing ID"}]];
            check([[c valueForKey:@"offlineRequests"][@"test:invalid"][@"tracks"] count] == 0, @"invalid newer request clears stale ready track list");
            {   // Manifest after library read retries visible seeds that found nothing on disk yet.
                OfflineController *retry = [OfflineController new];
                [retry setValue:@YES forKey:@"musicProbesEnabled"];
                [retry setValue:dispatch_queue_create("test.mix", DISPATCH_QUEUE_SERIAL) forKey:@"_mixQueue"];
                [retry setValue:[NSMutableSet set] forKey:@"_mixPreparing"];
                [retry setValue:[NSMutableDictionary dictionary] forKey:@"_offlineRequests"];
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"mixWithClaude"];
                NSMutableArray *library = [NSMutableArray array];
                for (NSUInteger i = 0; i < 25; i++) {
                    [library addObject:@{@"id": [NSString stringWithFormat:@"id-%lu", (unsigned long)i], @"artist": @"Artist",
                                         @"title": [NSString stringWithFormat:@"Title %lu", (unsigned long)i], @"album": @"Album",
                                         @"kind": @"song", @"family": @"other"}];
                }
                [library addObject:@{@"id": @"fixture-id", @"artist": @"Test Artist", @"title": @"Fixture", @"album": @"Test Album",
                                     @"kind": @"song", @"family": @"other"}];
                [retry setValue:library forKey:@"_mixLibrary"];
                NSDictionary *seed = @{@"key": @"song:fixture", @"kind": @"song", @"title": @"Fixture", @"subtitle": @"Test Artist",
                                       @"trackID": @"fixture-id", @"artist": @"Test Artist", @"album": @"Test Album", @"family": @"other"};
                [retry setValue:@[seed] forKey:@"mixSeeds"];
                [retry setValue:[NSMutableDictionary dictionary] forKey:@"_mixPrepared"];
                [retry setValue:@{} forKey:@"_offlineManifest"];
                [retry prepareMix:seed then:nil]; settle();
                NSDictionary *prepared = [retry valueForKey:@"_mixPrepared"];
                check(![prepared[@"song:fixture"] count], @"empty manifest leaves seed unprepared");
                NSUInteger tried = retry.mixPrepareStarts;
                [retry setValue:manifest forKey:@"_offlineManifest"];
                [retry retryUnpreparedMixSeeds]; settle();
                prepared = [retry valueForKey:@"_mixPrepared"];
                check(retry.mixPrepareStarts > tried && [prepared[@"song:fixture"] count],
                    @"manifest arrival retries unprepared seed");
            }
            {   // Pending New picks seeds install offline requests before promotion.
                OfflineController *pending = [OfflineController new];
                [pending setValue:@YES forKey:@"musicProbesEnabled"];
                [pending setValue:dispatch_queue_create("test.mix.next", DISPATCH_QUEUE_SERIAL) forKey:@"_mixQueue"];
                [pending setValue:[NSMutableSet set] forKey:@"_mixPreparing"];
                [pending setValue:[NSMutableDictionary dictionary] forKey:@"_offlineRequests"];
                [pending setValue:[NSMutableDictionary dictionary] forKey:@"_mixPrepared"];
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"mixWithClaude"];
                NSMutableArray *library = [NSMutableArray array];
                for (NSUInteger i = 0; i < 30; i++) {
                    [library addObject:@{@"id": [NSString stringWithFormat:@"next-%lu", (unsigned long)i], @"artist": @"A",
                                         @"title": [NSString stringWithFormat:@"T %lu", (unsigned long)i], @"album": @"Al",
                                         @"kind": @"song", @"family": @"other"}];
                }
                [library addObject:@{@"id": @"fixture-id", @"artist": @"Test Artist", @"title": @"Fixture", @"album": @"Test Album",
                                     @"kind": @"song", @"family": @"other"}];
                [pending setValue:library forKey:@"_mixLibrary"];
                NSDictionary *visible = @{@"key": @"song:old", @"kind": @"song", @"title": @"Old", @"subtitle": @"Test Artist",
                                        @"trackID": @"fixture-id", @"artist": @"Test Artist", @"album": @"Test Album", @"family": @"other"};
                NSDictionary *next = @{@"key": @"song:next", @"kind": @"song", @"title": @"Next", @"subtitle": @"Test Artist",
                                       @"trackID": @"fixture-id", @"artist": @"Test Artist", @"album": @"Test Album", @"family": @"other"};
                NSDictionary *fixture = OfflineFixture(path, @"song:old");
                [pending setValue:fixture[@"manifest"] forKey:@"_offlineManifest"];
                [pending setValue:@[visible] forKey:@"mixSeeds"];
                [pending setValue:@[next] forKey:@"mixSeedsNext"];
                [pending setValue:@1 forKey:@"mixSeedsNextGen"];
                [pending prepareMix:next then:nil];
                settle();
                check([[pending valueForKey:@"offlineRequests"][@"song:next"] count] > 0,
                      @"pending New picks seed persists an offline request before swap");
            }
            {   // Scout publish bindings flow through to offline playback.
                OfflineController *scout = [OfflineController new];
                [scout setValue:@YES forKey:@"musicProbesEnabled"];
                NSString *scoutDir = [home stringByAppendingPathComponent:@".local/state/glancebar-music-scout"];
                NSString *hot = [home stringByAppendingPathComponent:@"Music/Glancebar Lossless"];
                [fm createDirectoryAtPath:scoutDir withIntermediateDirectories:YES attributes:nil error:nil];
                [fm createDirectoryAtPath:hot withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *audio = [hot stringByAppendingPathComponent:@"scout-bound.m4a"];
                NSString *py = [NSString stringWithFormat:
                    @"import struct, pathlib, sys\n"
                    "def atom(k,b): return struct.pack('>I4s', len(b)+8, k)+b\n"
                    "tags=b''.join(atom(k,atom(b'data',b'\\0\\0\\0\\1\\0\\0\\0\\0'+v.encode()))\n"
                    "    for k,v in [(b'\\xa9nam','Scout'),(b'\\xa9ART','Artist'),(b'\\xa9alb','Published Album')])\n"
                    "sample=atom(b'mp4a',b'\\0'*28)\n"
                    "table=atom(b'stsd',b'\\0'*4+struct.pack('>I',1)+sample)\n"
                    "for p in (b'stbl',b'minf',b'mdia',b'trak'): table=atom(p,table)\n"
                    "body=(atom(b'ftyp',b'M4A '+b'\\0'*4)+atom(b'moov',table+atom(b'udta',atom(b'meta',b'\\0'*4+atom(b'ilst',tags))))\n"
                    "      +atom(b'mdat',b'scout-bytes'))\n"
                    "pathlib.Path(sys.argv[1]).write_bytes(body)\n"];
                NSTask *maker = [NSTask new];
                maker.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
                maker.arguments = @[@"-c", py, audio];
                [maker launch];
                [maker waitUntilExit];
                NSData *bytes = [NSData dataWithContentsOfFile:audio];
                uint8_t digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
                NSMutableString *hash = [NSMutableString string];
                for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
                NSDictionary *doc = @{@"tracks": @[@{@"track_key": @"scout:1", @"title": @"Scout", @"artist": @"Artist",
                                                    @"album": @"Published Album", @"duration": @200,
                                                    @"catalogue_relative_path": @"scout-bound.m4a", @"sha256": hash}]};
                NSData *scoutJSON = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
                [scoutJSON writeToFile:[scoutDir stringByAppendingPathComponent:@"new-music.json"] atomically:YES];
                NSString *mixDir = [home stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix"];
                [fm createDirectoryAtPath:mixDir withIntermediateDirectories:YES attributes:nil error:nil];
                [scout setValue:@NO forKey:@"_stationLoaded"];
                [scout ensureStation];
                NSDictionary *req = [scout valueForKey:@"offlineRequests"][@"station:triplej"];
                NSDictionary *track = req[@"tracks"][0];
                check([track[@"catalogue_relative_path"] isEqual:@"scout-bound.m4a"] && [track[@"sha256"] isEqual:hash],
                      @"scout new-music bindings reach the offline request");
                NSString *requestsPath = [mixDir stringByAppendingPathComponent:@"offline-requests.json"];
                NSString *manifestPath = [mixDir stringByAppendingPathComponent:@"offline-manifest.json"];
                NSData *reqDoc = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"playlists": @[req]} options:0 error:nil];
                [reqDoc writeToFile:requestsPath atomically:YES];
                NSTask *task = [NSTask new];
                task.currentDirectoryURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
                NSString *repo = [[NSFileManager.defaultManager currentDirectoryPath] stringByStandardizingPath];
                if (![NSFileManager.defaultManager fileExistsAtPath:[repo stringByAppendingPathComponent:@"tools/offline-cache/offline_cache.py"]])
                    repo = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
                task.arguments = @[[repo stringByAppendingPathComponent:@"tools/offline-cache/offline_cache.py"], @"prepare",
                                   @"--requests", requestsPath, @"--manifest", manifestPath, @"--root", hot];
                NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
                env[@"GLANCEBAR_HOME"] = home;
                env[@"HOME"] = home;
                task.environment = env;
                [task setStandardOutput:[NSPipe pipe]];
                [task setStandardError:[NSPipe pipe]];
                check([task launchAndReturnError:nil], @"offline-cache prepare launches");
                [task waitUntilExit];
                check(task.terminationStatus == 0 || task.terminationStatus == 2,
                      @"offline-cache prepares scout trusted binding");
                NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
                if (!manifestData.length) {
                    check(NO, @"offline-cache wrote a manifest for scout trusted binding");
                } else {
                    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
                    [scout setValue:manifest forKey:@"offlineManifest"];
                    check([OfflinePlaylistCoverage(req, manifest, [home stringByAppendingPathComponent:@"Music"], YES)[@"ready"] boolValue],
                          @"downloaded scout track is playable via trusted binding");
                }
            }
        } @finally { [fm removeItemAtPath:home error:nil]; }
        return failures ? 1 : 0;
    }
}
