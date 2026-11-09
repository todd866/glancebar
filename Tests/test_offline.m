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
@end
@implementation OfflineController
- (void)playLocalPaths:(NSArray<NSString *> *)paths { self.received = paths; self.playerCalls++; }
- (void)prepareOfflineCache { self.preparations++; }
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
            stale[@"tracks"] = @[request[@"tracks"][0], retag];
            check([OfflinePlaylistCoverage(stale, manifest, root, NO)[@"paths"] count] == 0, @"partial playlist never supplies a playable queue");
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
            check([[c valueForKey:@"localMode"] boolValue], @"online refresh retains paused saved offline queue");
            [c setValue:@NO forKey:@"localMode"];
            [c setValue:@YES forKey:@"amLoaded"];
            [c playOfflinePlaylist:@"song:test"]; settle();
            check(!c.received, @"loaded Music cannot be overlapped or paused implicitly");
            [c setValue:@NO forKey:@"amLoaded"];
            [c playOfflinePlaylist:@"song:test"];
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
            [c playStation:nil]; settle();
            check(!c.received, @"partial station cannot reach player");
            [c setOfflineRequest:@"test:invalid" title:@"Invalid" tracks:request[@"tracks"]];
            [c setOfflineRequest:@"test:invalid" title:@"Invalid" tracks:@[@{@"title": @"Missing ID"}]];
            check([[c valueForKey:@"offlineRequests"][@"test:invalid"][@"tracks"] count] == 0, @"invalid newer request clears stale ready track list");
            [c setValue:@YES forKey:@"amStatusInFlight"]; [c setValue:@42 forKey:@"amGen"];
            __block BOOL called = NO, result = YES;
            [c runAppleMusicCommand:@"" followUp:NO done:^(BOOL success) { called = YES; result = success; }];
            check(called && !result && [[c valueForKey:@"amGen"] integerValue] == 42 && [[c valueForKey:@"amStatusInFlight"] boolValue], @"background Music probe cannot supersede active command or launch a script");
            [c setValue:@NO forKey:@"amStatusInFlight"]; [c setValue:@YES forKey:@"amLoaded"];
            [c setValue:@YES forKey:@"playbackKnown"]; [c setValue:@YES forKey:@"playbackPlaying"]; [c setValue:@123 forKey:@"trackSampledAt"];
            [c noteAppleMusicUnavailable:kAppleMusicUnresponsiveNote];
            check(![[c valueForKey:@"playbackKnown"] boolValue] && ![[c valueForKey:@"playbackPlaying"] boolValue] && [[c valueForKey:@"trackSampledAt"] doubleValue] == 0 && [[c valueForKey:@"musicNote"] isEqual:kAppleMusicUnresponsiveNote], @"Music timeout stops stale playing state and fake progress");
            [c applyAppleMusicStatus:@{@"loaded": @YES, @"playing": @NO, @"title": @"Recovered", @"artist": @"Fixture", @"album": @"Fixture", @"trackID": @"", @"playlist": @"Fixture"}];
            check([[c valueForKey:@"playbackKnown"] boolValue] && ![c valueForKey:@"musicNote"], @"fresh Music status clears stale warning without playback");
        } @finally { [fm removeItemAtPath:home error:nil]; }
        return failures ? 1 : 0;
    }
}
