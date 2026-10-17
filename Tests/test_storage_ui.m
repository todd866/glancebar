// Native views rendered without showing a window; cleanup transport is always mocked.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop
static int checks;
static void Check(BOOL ok, NSString *message) { checks++; if (!ok) { fprintf(stderr,"FAIL %s\n",message.UTF8String); exit(1); } }
static void Await(BOOL (^done)(void)) {
    static NSUInteger sequence; sequence++;
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:30];
    while (!done() && until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(done(),[NSString stringWithFormat:@"asynchronous completion %lu",(unsigned long)sequence]);
}
@interface TestStorageWindow : NSWindow @end
@implementation TestStorageWindow
- (BOOL)isVisible { return YES; }
@end
@interface TestStorageController : Controller
@property NSString *testHome;
@property NSUInteger operations, paints;
@property BOOL permitPower;
@property dispatch_semaphore_t rootsGate;
@end
@implementation TestStorageController
- (void)refreshVisibleSurfaces {}
- (void)refreshStorageSurface { self.paints++; }
- (BOOL)storageTabSelected { return YES; }
- (BOOL)storagePowerPermitsWork { return self.permitPower; }
- (NSString *)storageHomeDirectory { return self.testHome; }
- (NSString *)storageCacheDirectory { return [self.testHome stringByAppendingPathComponent:@"cache"]; }
- (NSArray *)storageRoots { if(self.rootsGate)dispatch_semaphore_wait(self.rootsGate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));return @[self.testHome]; }
- (NSDictionary *)performStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress progress:(NSProgress *)progress {
    (void)entry;(void)compress;(void)progress;self.operations++;return @{@"message":@"Fixture transport only"};
}
@end
static NSView *Find(NSView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqual:identifier]) return root;
    for (NSView *child in root.subviews) { NSView *found=Find(child,identifier); if (found) return found; } return nil;
}
static void Geometry(NSView *view) {
    Check(!view.toolTip.length,@"no hover popups");
    for (NSView *child in view.subviews) {
        Check(NSContainsRect(view.bounds,child.frame),@"native content fits document");
        if ([child.accessibilityIdentifier hasPrefix:@"details.storage.item."] &&
            ([child.accessibilityIdentifier hasSuffix:@".1"] || [child.accessibilityIdentifier hasSuffix:@".2"])) {
            NSTextField *field=(NSTextField *)child;
            Check([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width+4 <= field.bounds.size.width,@"size figures fit");
        }
        if (![child isKindOfClass:NSControl.class] && ![child isKindOfClass:NSScrollView.class]) Geometry(child);
    }
}
static BOOL Render(NSView *view,NSString *path,NSAppearanceName appearance) {
    PopoverRootView *host=[[PopoverRootView alloc] initWithFrame:view.bounds];
    host.appearance=[NSAppearance appearanceNamed:appearance]; view.appearance=host.appearance;
    [host addSubview:view]; [host layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:NSWidth(host.bounds) pixelsHigh:NSHeight(host.bounds) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
static NSDictionary *Fixture(void) {
    return @{@"capturedAt":@(NSDate.date.timeIntervalSince1970),@"entries":@12450,@"skipped":@12,@"errors":@2,@"partial":@YES,@"folders":@[
        @{@"name":@"Movies",@"path":@"/Users/ian/Movies",@"isDirectory":@YES,@"allocatedBytes":@182500000000ULL,@"logicalBytes":@183200000000ULL,@"partial":@YES,@"action":@"reveal"}
    ],@"rows":@[
        @{@"name":@"Photos Library.photoslibrary",@"path":@"/Users/ian/Pictures/Photos Library.photoslibrary",@"isDirectory":@YES,@"allocatedBytes":@182500000000ULL,@"logicalBytes":@183200000000ULL,@"partial":@YES,@"action":@"reveal",@"protectedReason":@"Library package"},
        @{@"name":@"Trip footage.mov",@"path":@"/Users/ian/Movies/Trip footage.mov",@"allocatedBytes":@13200000000ULL,@"logicalBytes":@13200000000ULL,@"action":@"trash"},
        @{@"name":@"Long named export of flight records and instruments.csv",@"path":@"/Users/ian/Documents/Flights/records.csv",@"allocatedBytes":@8900000000ULL,@"logicalBytes":@8900000000ULL,@"action":@"trash"},
        @{@"name":@"Machine learning research",@"path":@"/Users/ian/Projects/Machine learning research",@"isDirectory":@YES,@"allocatedBytes":@4100000000ULL,@"logicalBytes":@8200000000ULL,@"protectedReason":@"Repository or worktree",@"action":@"reveal"},
        @{@"name":@"Xcode.app",@"path":@"/Applications/Xcode.app",@"isDirectory":@YES,@"allocatedBytes":@3800000000ULL,@"logicalBytes":@3800000000ULL,@"protectedReason":@"Application",@"action":@"reveal"}
    ]};
}
int main(int argc,const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    char real[PATH_MAX]; realpath(NSTemporaryDirectory().fileSystemRepresentation,real);
    NSString *home=[[NSString stringWithUTF8String:real] stringByAppendingPathComponent:[@"storage-ui-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *downloads=[home stringByAppendingPathComponent:@"Downloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *file=[downloads stringByAppendingPathComponent:@"sample.txt"];
    [@"Disposable fixture" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    TestStorageController *c=[TestStorageController new];c.testHome=home;c.permitPower=YES;
    [c requestStorageScanIfNeeded];[c requestStorageScanIfNeeded];
    Await(^BOOL{return [[c valueForKey:@"storageFinished"] boolValue];});
    NSDictionary *result=[c valueForKey:@"storageResult"];
    Check([result[@"rows"] count]==1,@"automatic global results appear without choosing folders");
    id index=[c valueForKey:@"storageIndex"];[c requestStorageScanIfNeeded];
    Check(index==[c valueForKey:@"storageIndex"],@"cached reopening does not restart complete index");
    TestStorageController *cached=[TestStorageController new];cached.testHome=home;cached.permitPower=YES;cached.rootsGate=dispatch_semaphore_create(0);
    [cached requestStorageScanIfNeeded];[cached requestStorageScanIfNeeded];
    Await(^BOOL{return [[cached valueForKey:@"storageRetainSnapshot"] boolValue];});
    Check([[[cached valueForKey:@"storageResult"] objectForKey:@"rows"] count]==1,@"cached ranking remains available while replacement begins");
    dispatch_semaphore_signal(cached.rootsGate);
    Await(^BOOL{return [[cached valueForKey:@"storageFinished"] boolValue];});
    Check(![[cached valueForKey:@"storageRetainSnapshot"] boolValue],@"replacement pass retires the cached marker");
    [cached cancelStorage];
    TestStorageWindow *window=[[TestStorageWindow alloc] initWithContentRect:NSMakeRect(0,0,600,420) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    [c setValue:window forKey:@"detailsWindow"];
    NSButton *button=[NSButton new];button.identifier=file;
    [c trashStorage:button];[c trashStorage:button];
    Await(^BOOL{return c.operations==1 && ![c storageBusy];});
    Check([NSFileManager.defaultManager fileExistsAtPath:file],@"one direct action; fixture transport never deletes user files");
    Check(![[c valueForKey:@"storageResult"][@"rows"] count],@"trashed item leaves cached ranking immediately");
    [c setValue:result forKey:@"storageResult"];
    [c setValue:@NO forKey:@"storageFinished"];[c scanStorage:nil];
    Check([[c valueForKey:@"storagePaused"] boolValue],@"Pause is explicit and does not discard result");
    [c windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:window]];
    Check([c valueForKey:@"storageResult"]!=nil,@"closing Details preserves the global result");
    [c setValue:nil forKey:@"detailsWindow"];
    [c cancelStorage];
    Controller *ui=[Controller new];
    BatteryState battery={.valid=YES,.acConnected=YES,.percent=80};
    [ui setValue:[NSValue valueWithBytes:&battery objCType:@encode(BatteryState)] forKey:@"bat"];
    [ui setValue:Fixture() forKey:@"storageResult"];
    Volume *volume=[Volume new]; volume.name=@"Macintosh HD"; volume.path=@"/"; volume.total=2000000000000LL; volume.available=234000000000LL; volume.isInternal=YES;
    [ui setValue:@[volume] forKey:@"vols"];
    if (argc>2) {
        NSDictionary *live=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]] options:0 error:NULL];
        [ui setValue:live forKey:@"storageResult"];
        [ui setValue:@([live[@"complete"] boolValue] || [live[@"limited"] boolValue]) forKey:@"storageFinished"];
        [ui setValue:ScanVolumes() forKey:@"vols"];
    }
    for (NSNumber *width in @[@600,@840]) for (NSNumber *dark in @[@NO,@YES]) {
        kDetailW=width.doubleValue; NSScrollView *scroll=[ui storageDetailsView]; Geometry(scroll.documentView);
        Check(NSMaxX(Find(scroll,@"details.storage.mode").frame) < NSMinX(Find(scroll,@"details.storage.scan").frame),@"toolbar controls fit");
        if (argc>1) Check(Render(scroll,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@-%@.png",width,dark.boolValue?@"dark":@"light"]],dark.boolValue?NSAppearanceNameDarkAqua:NSAppearanceNameAqua),@"native screenshot saved");
    }
    kDetailW=600;
    NSScrollView *items=[ui storageDetailsView];
    NSButton *trash=(id)Find(items,@"details.storage.item./Users/ian/Movies/Trip footage.mov.action");
    if(argc<=2)Check([trash.title isEqual:@"Trash"] && trash.action==@selector(trashStorage:),@"Trash is the explicit one-click action, not review navigation");
    if(argc<=2)Check([((NSButton *)Find(items,@"details.storage.item./Applications/Xcode.app.action")).title isEqual:@"Reveal"],@"protected packages have a usable safe action");
    [ui setValue:@YES forKey:@"storageFolders"];
    NSScrollView *folders=[ui storageDetailsView];Geometry(folders.documentView);
    Check([((NSTextField *)Find(folders,@"details.storage.legend")).stringValue containsString:@"overlap"],@"folder overlap semantics are visible");
    if(argc>1)Check(Render(folders,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:@"storage-folders.png"],NSAppearanceNameAqua),@"folder mode rendered");
    [ui setValue:@NO forKey:@"storageFolders"];
    for(NSString *state in @[@"empty",@"paused",@"loading",@"undo"]){
        [ui setValue:[state isEqual:@"undo"] ? Fixture() : @{@"rows":@[],@"capturedAt":@(NSDate.date.timeIntervalSince1970)} forKey:@"storageResult"];
        [ui setValue:@([state isEqual:@"paused"]) forKey:@"storagePaused"];
        [ui setValue:@([state isEqual:@"empty"]) forKey:@"storageFinished"];
        [ui setValue:[state isEqual:@"undo"] ? @{@"trashedPath":@"/fixture/Trash"} : nil forKey:@"storageUndo"];
        [ui setValue:[state isEqual:@"undo"] ? @"Moved to Trash. Space is released when Trash is emptied." : nil forKey:@"storageNotice"];
        NSScrollView *scroll=[ui storageDetailsView];Geometry(scroll.documentView);
        if(argc>1)Check(Render(scroll,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@.png",state]],NSAppearanceNameAqua),@"state screenshot saved");
    }
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
    fprintf(stderr,"Storage UI: %d checks passed\n",checks);
} return 0; }
