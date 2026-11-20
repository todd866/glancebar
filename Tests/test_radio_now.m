// The unified now-playing picker: every playing surface heartbeats a document; only live ones
// (≤60 s old, no far-future stamps) count and the most recent `at` wins. Pure Foundation —
// no network, no AppKit.
#import <Foundation/Foundation.h>
#import "../Sources/pure.h"

static int failures;
static void check(BOOL ok, NSString *message) {
    fprintf(stderr, "%s %s\n", ok ? "ok" : "FAIL", message.UTF8String);
    if (!ok) failures++;
}

static NSDictionary *Doc(NSString *surface, NSString *host, NSString *sha, NSString *artist,
                         NSString *title, NSDate *at) {
    static NSISO8601DateFormatter *frac = nil, *plain = nil;
    if (!frac) {
        frac = [NSISO8601DateFormatter new];
        frac.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
    }
    NSString *iso = [frac stringFromDate:at] ?: [plain stringFromDate:at];
    return @{@"surface": surface, @"host": host, @"sha": sha, @"artist": artist, @"title": title, @"at": iso};
}

int main(void) {
    @autoreleasepool {
        NSDate *now = [NSDate dateWithTimeIntervalSinceReferenceDate:800000000];
        check(RadioNowPick(@[], now) == nil, @"no documents means nothing playing");
        check(RadioNowPick(nil, now) == nil, @"nil means nothing playing");

        NSDictionary *browser = Doc(@"browser", @"tab-1", @"a", @"Aa", @"Tt",
                                    [now dateByAddingTimeInterval:-10]);
        NSDictionary *tv = Doc(@"tv", @"m2", @"b", @"Bb", @"Uu",
                               [now dateByAddingTimeInterval:-25]);
        NSDictionary *stale = Doc(@"browser", @"tab-2", @"c", @"Cc", @"Vv",
                                  [now dateByAddingTimeInterval:-90]);
        NSDictionary *future = Doc(@"tv", @"m2b", @"d", @"Dd", @"Ww",
                                   [now dateByAddingTimeInterval:600]);
        NSArray *docs = @[browser, tv, stale, future];
        check([RadioNowPick(docs, now)[@"sha"] isEqual:@"a"], @"most recent live document wins");

        NSDictionary *newer = Doc(@"tv", @"m2", @"b", @"Bb", @"Uu", [now dateByAddingTimeInterval:-5]);
        check([RadioNowPick(@[browser, newer, stale], now)[@"sha"] isEqual:@"b"], @"a fresher heartbeat on any surface takes over");
        check(RadioNowPick(@[stale], now) == nil, @"a 90 s old document is not live");
        check(RadioNowPick(@[future], now) == nil, @"a far-future stamp is not live");
        check(RadioNowPick(@[@{@"surface": @"browser"}], now) == nil, @"a document without at is ignored");
        return failures ? 1 : 0;
    }
}
