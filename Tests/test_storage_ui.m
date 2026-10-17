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
@property NSUInteger scans, operations, reviews;
@property NSModalResponse choice;
@property dispatch_semaphore_t gate;
@property NSAlert *lastReview;
@end
@implementation TestStorageController
- (void)refreshVisibleSurfaces {}
- (BOOL)storageTabSelected { return YES; }
- (NSString *)storageHomeDirectory { return self.testHome; }
- (NSString *)storageOpenFileReason:(NSString *)path { (void)path; return nil; }
- (NSDictionary *)performStorageScan:(GBStorageScan *)scan path:(NSString *)path {
    self.scans++;
    if (self.gate) dispatch_semaphore_wait(self.gate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    // Real filesystem fixtures get scheduling room under shared disk load.
    // Production uses six seconds; budget/cancellation behavior is covered separately.
    return [scan scanPath:path entryLimit:100 seconds:15];
}
- (void)presentStorageReview:(NSAlert *)alert completion:(void (^)(NSModalResponse))completion {
    self.lastReview=alert; self.reviews++; completion(self.choice);
}
- (NSDictionary *)performStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress progress:(NSProgress *)progress {
    (void)entry; (void)compress; (void)progress; self.operations++; return @{@"message":@"Fixture transport only"};
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
    return @{@"capturedAt":@(NSDate.date.timeIntervalSince1970),@"entries":@12450,@"skipped":@12,@"errors":@2,@"partial":@YES,@"rows":@[
        @{@"name":@"Movies",@"path":@"/fixture/Movies",@"isDirectory":@YES,@"allocatedBytes":@182500000000ULL,@"logicalBytes":@183200000000ULL,@"partial":@YES},
        @{@"name":@"Downloads",@"path":@"/fixture/Downloads",@"isDirectory":@YES,@"allocatedBytes":@13200000000ULL,@"logicalBytes":@13200000000ULL},
        @{@"name":@"Long named export of flight records and instruments.csv",@"path":@"/fixture/records.csv",@"allocatedBytes":@8900000000ULL,@"logicalBytes":@8900000000ULL},
        @{@"name":@"Projects",@"path":@"/fixture/Projects",@"isDirectory":@YES,@"protectedReason":@"Repository or worktree"},
        @{@"name":@"Photos Library.photoslibrary",@"path":@"/fixture/Photos Library.photoslibrary",@"isDirectory":@YES,@"protectedReason":@"Application or library package"},
        @{@"name":@"Cloud archive",@"path":@"/fixture/cloud",@"problem":@"Cloud placeholder"}
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
    TestStorageController *c=[TestStorageController new]; c.testHome=home;
    [c setValue:downloads forKey:@"storagePath"]; c.gate=dispatch_semaphore_create(0);
    [c requestStorageScan]; [c requestStorageScan]; Await(^BOOL { return c.scans==1; });
    [c cancelStorage]; dispatch_semaphore_signal(c.gate); Await(^BOOL { return ![c storageBusy]; });
    Check(![c valueForKey:@"storageResult"] && ![c valueForKey:@"detailsWindow"],@"cancelled scan cannot publish or reopen window");
    c.gate=nil; [c requestStorageScan]; Await(^BOOL { return ![c storageBusy]; });
    [c requestStorageScanIfNeeded]; Check(c.scans==2,@"cached navigation does not rescan");
    NSDictionary *result=[c valueForKey:@"storageResult"];
    TestStorageWindow *window=[[TestStorageWindow alloc] initWithContentRect:NSMakeRect(0,0,600,420) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    [c setValue:window forKey:@"detailsWindow"];
    NSButton *button=[NSButton new]; button.identifier=file;
    c.choice=NSAlertFirstButtonReturn; [c reviewStorage:button]; Await(^BOOL { return c.reviews==1; });
    Check(c.operations==0 && [c.lastReview.buttons.firstObject.title isEqual:@"Cancel"] && [c.lastReview.buttons.firstObject.keyEquivalent isEqual:@"\r"],@"Cancel and Return never authorize cleanup");
    Check(c.lastReview.buttons.count==3 && [c.lastReview.informativeText containsString:file],@"review includes full path and both eligible choices");
    if (argc>1) {
        [c.lastReview layout];
        Check(Render(c.lastReview.window.contentView,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:@"storage-review.png"],NSAppearanceNameAqua),@"review sheet rendered without presentation");
    }
    c.choice=NSAlertSecondButtonReturn; [c reviewStorage:button]; Await(^BOOL { return c.operations==1 && ![c storageBusy]; });
    [c setValue:result forKey:@"storageResult"];
    c.choice=NSAlertThirdButtonReturn; [c reviewStorage:button]; Await(^BOOL { return c.operations==2 && ![c storageBusy]; });
    Check([NSFileManager.defaultManager fileExistsAtPath:file],@"UI tests never touch real Trash or delete fixtures");
    [c setValue:nil forKey:@"detailsWindow"];
    Controller *ui=[Controller new]; [ui setValue:Fixture() forKey:@"storageResult"];
    [ui setValue:NSHomeDirectory().stringByResolvingSymlinksInPath forKey:@"storagePath"];
    Volume *volume=[Volume new]; volume.name=@"Macintosh HD"; volume.path=@"/"; volume.total=2000000000000LL; volume.available=234000000000LL; volume.isInternal=YES;
    [ui setValue:@[volume] forKey:@"vols"];
    if (argc>2) {
        NSDictionary *live=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]] options:0 error:NULL];
        [ui setValue:live forKey:@"storageResult"]; [ui setValue:live[@"path"] forKey:@"storagePath"];
    }
    for (NSNumber *width in @[@600,@840]) for (NSNumber *dark in @[@NO,@YES]) {
        kDetailW=width.doubleValue; NSScrollView *scroll=[ui storageDetailsView]; Geometry(scroll.documentView);
        Check(NSMaxX(Find(scroll,@"details.storage.up").frame) < NSMinX(Find(scroll,@"details.storage.scan").frame),@"toolbar controls fit");
        if (argc>1) Check(Render(scroll,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@-%@.png",width,dark.boolValue?@"dark":@"light"]],dark.boolValue?NSAppearanceNameDarkAqua:NSAppearanceNameAqua),@"native screenshot saved");
    }
    kDetailW=600;
    NSPopUpButton *old=(id)Find([ui storageDetailsView],@"details.storage.scope");
    [ui setValue:@"/Applications" forKey:@"storagePath"];
    NSPopUpButton *fresh=(id)Find([ui storageDetailsView],@"details.storage.scope"); ApplyFreshViewState(old,fresh);
    Check([old.selectedItem.representedObject isEqual:@"/Applications"],@"folder picker survives reconciliation");
    for (NSString *state in @[@"empty",@"error",@"loading"]) {
        [ui setValue:[state isEqual:@"error"] ? @{@"error":@"Folder unavailable with current access."} : @{@"rows":@[],@"capturedAt":@(NSDate.date.timeIntervalSince1970)} forKey:@"storageResult"];
        [ui setValue:[state isEqual:@"loading"] ? [GBStorageScan new] : nil forKey:@"storageScan"];
        NSScrollView *scroll=[ui storageDetailsView]; Geometry(scroll.documentView);
        if (argc>1) Check(Render(scroll,[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@.png",state]],NSAppearanceNameAqua),@"state screenshot saved");
    }
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
    fprintf(stderr,"Storage UI: %d checks passed\n",checks);
} return 0; }
