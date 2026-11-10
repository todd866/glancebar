// Simulates a repeating sync failure (cap/unmatched) and asserts helper launches stay bounded.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

static int failures;
static void check(BOOL ok, NSString *message) {
    fprintf(stderr, "%s %s\n", ok ? "ok" : "FAIL", message.UTF8String);
    if (!ok) failures++;
}

static void pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

@interface StormController : Controller
@property NSUInteger syncLaunches, statusLaunches, cacheLaunches;
@end

@implementation StormController
- (void)prepareMusicLibrarySync {
    self.syncLaunches++;
    [self setValue:@YES forKey:@"_musiclibBusy"];
    [self setValue:@1 forKey:@"_libraryRefreshPhase"];
    NSUInteger generation = [[self valueForKey:@"offlineRequestsGeneration"] unsignedIntegerValue];
    [self setValue:@(generation) forKey:@"musiclibLastAttemptGeneration"];
    [self setValue:@(CFAbsoluteTimeGetCurrent()) forKey:@"musiclibLastSyncAttemptAt"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setValue:@NO forKey:@"_musiclibBusy"];
        NSUInteger failures = [[self valueForKey:@"_musiclibSyncFailures"] unsignedIntegerValue] + 1;
        [self setValue:@(failures) forKey:@"_musiclibSyncFailures"];
        [self setValue:@YES forKey:@"_musiclibLastAttemptTerminal"];
        [self setValue:@"cap exceeded after eviction" forKey:@"_musicLibraryLastError"];
        [self setValue:@0 forKey:@"_libraryRefreshPhase"];
        [self setValue:@YES forKey:@"_libraryRefreshWantsCache"];
        [self setValue:@YES forKey:@"_libraryRefreshWantsStatus"];
        [self libraryRefreshPump];
    });
}
- (void)prepareOfflineCache {
    self.cacheLaunches++;
    [self setValue:@YES forKey:@"_offlineCacheBusy"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setValue:@NO forKey:@"_offlineCacheBusy"];
        [self setValue:@0 forKey:@"_libraryRefreshPhase"];
        [self libraryRefreshPump];
    });
}
- (void)reloadMusicLibraryStatus {
    self.statusLaunches++;
    [self setValue:@{@"healthy": @NO, @"playlists": @[@{@"key": @"seed:mix", @"missing": @12}]} forKey:@"_musicLibraryStatus"];
    [self setValue:@(CFAbsoluteTimeGetCurrent()) forKey:@"_musicLibraryStatusAt"];
    [self setValue:@0 forKey:@"_libraryRefreshPhase"];
    [self maybeScheduleMusicLibrarySync];
    [self libraryRefreshPump];
}
@end

int main(void) {
    @autoreleasepool {
        StormController *c = [StormController new];
        [c setValue:@YES forKey:@"musicProbesEnabled"];
        [c setValue:@YES forKey:@"networkKnown"];
        [c setValue:@YES forKey:@"networkOnline"];
        [c setValue:@(1) forKey:@"offlineRequestsGeneration"];
        [c setValue:@(0) forKey:@"musiclibSyncedRequestGeneration"];
        [c setValue:@{@"healthy": @NO, @"playlists": @[@{@"key": @"seed:mix", @"missing": @40}]} forKey:@"musicLibraryStatus"];
        [c prepareMusicLibrarySync];
        pump(1.0);
        NSUInteger total = c.syncLaunches + c.statusLaunches + c.cacheLaunches;
        check(total <= 3, @"failed sync storm stays within three helper launches");
        check(c.syncLaunches == 1, @"exactly one sync attempt for the first generation");
        NSUInteger syncBefore = c.syncLaunches;
        [c setValue:@(2) forKey:@"offlineRequestsGeneration"];
        [c setValue:@YES forKey:@"musiclibLastAttemptTerminal"];
        [c maybeScheduleMusicLibrarySync];
        pump(0.5);
        check(c.syncLaunches == syncBefore + 1, @"a new request generation gets exactly one more sync");
        pump(2.0);
        check(c.syncLaunches <= 2, @"terminal failure does not re-sync without another request generation");
        return failures ? 1 : 0;
    }
}
