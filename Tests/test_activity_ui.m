// Production UI and request-policy coverage. Never presents a window or changes power settings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

static int checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Await(BOOL (^ready)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!ready() && until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(ready(), @"asynchronous completion arrives");
}
static NSDictionary *Fixture(void) {
    return @{@"capturedAt": @(NSDate.date.timeIntervalSince1970), @"intervalSeconds": @3.1,
        @"networkAvailable": @YES, @"cpuAvailable": @YES, @"rows": @[
            @{@"group": @"app:Compiler", @"name": @"Compiler", @"pids": @[@10, @11], @"cpu": @1234.5, @"download": @1500000, @"upload": @0},
            @{@"group": @"app:Long", @"name": @"An application with a deliberately long display name", @"pids": @[@12], @"cpu": @42.15, @"cpuPartial": @YES, @"download": @15899, @"upload": @1234567890, @"networkPartial": @YES},
            @{@"group": @"app:Unknown", @"name": @"Unavailable network", @"pids": @[@13], @"cpu": @0},
            @{@"group": @"app:Network", @"name": @"Network only", @"pids": @[@14], @"download": @40000, @"upload": @2500}
        ]};
}
@interface SurveyController : Controller
@property dispatch_semaphore_t gate;
@property (atomic) NSUInteger calls;
@property NSUInteger reveals, refreshes;
@end
@implementation SurveyController
- (NSDictionary *)performActivitySurvey {
    self.calls++;
    if (self.gate) dispatch_semaphore_wait(self.gate, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    return Fixture();
}
- (void)refreshVisibleSurfaces { self.refreshes++; }
- (void)showDetailsTab:(NSString *)tab sender:(id)sender { (void)tab; (void)sender; self.reveals++; }
@end
@interface ShownPopover : NSPopover @end
@implementation ShownPopover
- (BOOL)isShown { return YES; }
@end
@interface NoNetworkSession : NSObject
@property NSUInteger requests;
@end
@implementation NoNetworkSession
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(id)handler {
    (void)request; (void)handler; self.requests++; return nil;
}
@end
@interface LocalMeter : MeteredMonitor
@property NSUInteger samples, accountRequests;
@end
@implementation LocalMeter
- (void)sample { self.samples++; }
- (NSString *)primaryRouter { return @"192.168.1.1"; }
- (NSString *)primaryInterface { return @"en0"; }
- (void)refreshAccount:(NSDate *)date { (void)date; self.accountRequests++; }
@end
static NSView *Find(NSView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqual:identifier]) return root;
    for (NSView *child in root.subviews) { NSView *hit = Find(child, identifier); if (hit) return hit; }
    return nil;
}
static void CheckGeometry(NSView *root) {
    Check(!root.toolTip.length || ([root isKindOfClass:NSTextField.class] && [root.toolTip isEqual:((NSTextField *)root).stringValue]), @"Activity hover only recovers full text");
    for (NSView *view in root.subviews) {
        Check(!view.toolTip.length || ([view isKindOfClass:NSTextField.class] && [view.toolTip isEqual:((NSTextField *)view).stringValue]), @"Activity hover only recovers full text");
        Check(NSContainsRect(root.bounds, view.frame), @"all Activity elements fit the document");
        if ([view isKindOfClass:NSTextField.class] && [view.accessibilityIdentifier hasPrefix:@"details.activity.row."] &&
            ![view.accessibilityIdentifier hasSuffix:@".0"]) {
            NSTextField *field = (NSTextField *)view;
            Check([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width + 4 <= NSWidth(field.bounds), @"numeric columns fit at actual font size");
        }
    }
    NSView *sort = Find(root, @"details.activity.sort"), *low = Find(root, @"details.activity.low-data"), *survey = Find(root, @"details.activity.survey");
    Check(NSMaxX(sort.frame) + 8 <= NSMinX(low.frame) && NSMaxX(low.frame) <= NSMinX(survey.frame), @"top controls do not overlap");
}
static BOOL Render(NSView *view, NSString *path, NSAppearanceName appearance) {
    PopoverRootView *host = [[PopoverRootView alloc] initWithFrame:view.bounds];
    host.appearance = [NSAppearance appearanceNamed:appearance]; view.appearance = host.appearance;
    view.frame = host.bounds; [host addSubview:view]; [host layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:NSWidth(host.bounds)
        pixelsHigh:NSHeight(host.bounds) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"glancebar-activity-ui-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("GLANCEBAR_HOME", home.UTF8String, 1);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *previous = [defaults volatileDomainForName:NSArgumentDomain];
    [defaults setVolatileDomain:@{@"lowData": @YES} forName:NSArgumentDomain];
    Check(GBLowDataEnabled(), @"Low Data test override active");
    Check(!HTTPJSON(@"unused", @"GET", @"https://invalid.invalid", @"invalid.invalid", @{}, nil, @"unused"), @"HTTP requests stop before creating transport");
    NSInteger status = 99;
    Check(![[StarlinkAccount new] get:@"/unused" cookies:@"unused" status:&status] && status == 0, @"Starlink requests stop before transport");
    AIReader *reader = [AIReader new]; NSDictionary *usage = @{@"cached": @YES};
    NSString *accountStatus = nil, *skip = nil;
    double success = 123, next = 0; BOOL fetched = NO, abandoned = NO; NSUInteger streak = 2;
    __block NSUInteger tokens = 0, fetches = 0;
    [reader refreshAccountNamed:"test" use:YES allow:YES now:1000 usageJSON:&usage lastSuccessAt:&success nextFetch:&next
        accountStatus:&accountStatus fetchedThisRun:&fetched cacheAbandoned:&abandoned skipReason:&skip rateLimitStreak:&streak
        token:^NSString *{ tokens++; return @"unused"; } fetcher:^NSDictionary *(NSString *token) { (void)token; fetches++; return @{}; } onError:^(NSDictionary *error) { (void)error; }];
    Check(tokens == 0 && fetches == 0 && [usage[@"cached"] boolValue] && success == 123 && next == 0 && !fetched, @"Low Data preserves cache and bypasses token/fetch work");
    LocalMeter *meter = [LocalMeter new]; NoNetworkSession *transport = [NoNetworkSession new];
    [meter setValue:transport forKey:@"session"]; [meter setValue:@YES forKey:@"onStarlink"];
    [meter tick]; dispatch_sync([meter valueForKey:@"queue"], ^{});
    Check(meter.samples == 1 && meter.accountRequests == 0 && transport.requests == 0, @"Low Data keeps local counters but skips account and dish requests");
    [defaults setVolatileDomain:@{@"lowData": @NO} forName:NSArgumentDomain];
    Check(!GBLowDataEnabled(), @"Low Data can turn off without changing stored preferences");

    SurveyController *c = [SurveyController new]; c.gate = dispatch_semaphore_create(0);
    [c requestActivitySurvey]; [c requestActivitySurvey]; Await(^BOOL { return c.calls == 1; });
    Check([[c valueForKey:@"activityLoading"] boolValue], @"one survey in flight");
    dispatch_semaphore_signal(c.gate); Await(^BOOL { return ![[c valueForKey:@"activityLoading"] boolValue]; });
    Check(c.calls == 1 && [c valueForKey:@"activitySurvey"] && ![c valueForKey:@"detailsWindow"] && c.reveals == 0, @"completion caches result without reopening dismissed UI");
    [c requestActivitySurveyIfNeeded]; Check(c.calls == 1 && ![[c valueForKey:@"activityLoading"] boolValue], @"fresh cached survey does not restart");
    [c requestActivitySurvey]; Await(^BOOL { return c.calls == 2; }); [c meteredWillSleep:nil];
    dispatch_semaphore_signal(c.gate); Await(^BOOL { return ![[c valueForKey:@"activityLoading"] boolValue]; });
    Check(![c valueForKey:@"activitySurvey"], @"sleep invalidates an in-flight sample");
    [c lowPowerFinishedEnabling:NO active:YES reveal:YES]; [c lowPowerFinishedEnabling:YES active:NO reveal:YES];
    Check(![[c valueForKey:@"activityLoading"] boolValue], @"disabled or unsuccessful Low Power changes do not sample");
    [c setValue:[ShownPopover new] forKey:@"popover"];
    [c lowPowerFinishedEnabling:YES active:YES reveal:YES]; Await(^BOOL { return c.calls == 3; });
    Check(c.reveals == 1, @"successful Low Power from an open surface reveals Activity once");
    dispatch_semaphore_signal(c.gate); Await(^BOOL { return ![[c valueForKey:@"activityLoading"] boolValue]; });
    [c setValue:nil forKey:@"popover"]; [c lowPowerFinishedEnabling:YES active:YES reveal:YES]; Await(^BOOL { return c.calls == 4; });
    dispatch_semaphore_signal(c.gate); Await(^BOOL { return ![[c valueForKey:@"activityLoading"] boolValue]; });
    Check(c.reveals == 1, @"dismissal while Low Power is applying prevents a later reveal");

    NSDictionary *data = Fixture();
    if (argc > 2) {
        NSData *json = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        data = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
        Check([data[@"rows"] isKindOfClass:NSArray.class], @"live sampler JSON loaded");
    }
    Controller *ui = [Controller new]; [ui setValue:data forKey:@"activitySurvey"];
    for (NSNumber *width in @[@600, @840]) {
        kDetailW = width.doubleValue;
        for (NSNumber *dark in @[@NO, @YES]) {
            NSScrollView *scroll = [ui activityDetailsView]; CheckGeometry(scroll.documentView);
            if (argc > 1) {
                NSString *path = [[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"activity-%@-%@.png", width, dark.boolValue ? @"dark" : @"light"]];
                Check(Render(scroll, path, dark.boolValue ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua), @"native 1x Activity render saved");
            }
        }
    }
    kDetailW = 600;
    [defaults setVolatileDomain:@{@"lowData": @YES} forName:NSArgumentDomain];
    PillButton *enabled = (id)Find([ui activityDetailsView], @"details.activity.low-data");
    Check(enabled.state == NSControlStateValueOn && enabled.onColor != nil, @"Low Data on has an explicit visible state");
    if (argc > 1) for (NSNumber *dark in @[@NO, @YES]) {
        NSString *path = [[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"activity-low-data-%@.png", dark.boolValue ? @"dark" : @"light"]];
        Check(Render([ui activityDetailsView], path, dark.boolValue ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua), @"Low Data on render saved");
    }
    [defaults setVolatileDomain:@{@"lowData": @NO} forName:NSArgumentDomain];
    NSSegmentedControl *old = (id)Find([ui activityDetailsView], @"details.activity.sort");
    [ui setValue:@2 forKey:@"activitySort"];
    NSSegmentedControl *fresh = (id)Find([ui activityDetailsView], @"details.activity.sort");
    ApplyFreshViewState(old, fresh);
    Check(old.selectedSegment == 2, @"reconciliation preserves requested metric selection");
    [ui setValue:nil forKey:@"activitySurvey"]; [ui setValue:@YES forKey:@"activityLoading"];
    NSScrollView *empty = [ui activityDetailsView];
    Check(![(NSButton *)Find(empty, @"details.activity.survey") isEnabled] &&
        [[(NSTextField *)Find(empty, @"details.activity.empty") stringValue] isEqual:@"Sampling…"], @"loading is explicit and resampling is disabled");
    [defaults setVolatileDomain:previous ?: @{} forName:NSArgumentDomain];
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
    fprintf(stderr, "Activity UI and policy: %d checks passed\n", checks);
} return 0; }
