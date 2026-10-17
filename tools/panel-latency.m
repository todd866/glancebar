// Measures the production click handler and native offscreen paint. No windows,
// status items, focus changes, network calls, or process samplers are launched.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop
#import "../Sources/storage_index.h"
@interface LatencyApplication : NSApplication @end
@implementation LatencyApplication
- (void)activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
@end
@interface LatencyItem : NSObject
@property NSButton *button;
@end
@implementation LatencyItem @end
@interface LatencyPopover : NSPopover
@property double start,requestMS,paintMS;
@end
@implementation LatencyPopover
- (BOOL)isShown { return NO; }
- (void)showRelativeToRect:(NSRect)r ofView:(NSView *)v preferredEdge:(NSRectEdge)e {
    (void)r;(void)v;(void)e;
    self.requestMS=(NSProcessInfo.processInfo.systemUptime-self.start)*1000;
    NSView *view=self.contentViewController.view;
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:NSWidth(view.bounds) pixelsHigh:NSHeight(view.bounds) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    self.paintMS=(NSProcessInfo.processInfo.systemUptime-self.start)*1000;
}
@end
@interface LatencyController : Controller @end
@implementation LatencyController
// The synchronous ReadBattery/ReadSystemState and full production view construction
// remain real. Suppress only side effects and async samplers outside the measured path.
- (void)refreshVolumesAsync {}
- (void)refreshAIUsageAsync {}
- (void)refreshLidAwakeAsync {}
- (void)updateBar {}
- (void)beginSampling {}
- (void)startPowerTick {}
- (void)requestStorageScanIfNeeded {}
@end
int main(int argc,const char **argv){@autoreleasepool{
    [LatencyApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    BOOL prepare=argc>1 && !strcmp(argv[1],"prepared");
    BOOL scanning=argc>2 && !strcmp(argv[2],"scanning");
    NSString *fixture=nil;GBStorageIndex *index=nil;dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    if(scanning){
        char resolved[PATH_MAX];if(!realpath(NSTemporaryDirectory().fileSystemRepresentation,resolved))return 3;
        fixture=[[NSString stringWithUTF8String:resolved] stringByAppendingPathComponent:[@"latency-scan-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        for(int folder=0;folder<80;folder++){
            NSString *path=[fixture stringByAppendingPathComponent:[NSString stringWithFormat:@"dir-%d",folder]];
            [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
            for(int file=0;file<100;file++)[NSData.data writeToFile:[path stringByAppendingPathComponent:[NSString stringWithFormat:@"file-%d",file]] atomically:NO];
            if(folder==79)chmod(path.fileSystemRepresentation,0);
        }
        index=[[GBStorageIndex alloc] initWithRoots:@[fixture] home:fixture];
    }
    LatencyController *c=[LatencyController new];
    LatencyPopover *popover=[LatencyPopover new];popover.animates=NO;popover.contentViewController=[NSViewController new];
    popover.contentViewController.view=[[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];
    [c setValue:popover forKey:@"popover"];
    LatencyItem *item=[LatencyItem new];item.button=[NSButton new];[c setValue:item forKey:@"item"];
    [c setValue:@"limit80" forKey:@"chargeMode"];[c setValue:@YES forKey:@"chargeModeLoaded"];
    [c setValue:[NSMutableArray array] forKey:@"ampHistory"];
    Volume *volume=[Volume new];volume.path=@"/";volume.name=@"Macintosh HD";volume.total=2000000000000LL;volume.available=240000000000LL;volume.isInternal=YES;[c setValue:@[volume] forKey:@"vols"];
    NSMutableArray *usage=[NSMutableArray array];
    for(NSString *name in @[@"Claude",@"Codex",@"Cursor"]){
        AIUsage *u=[AIUsage new];u.name=name;u.available=YES;u.limitStatusAvailable=YES;u.remainingFraction=.73;
        u.resetAt=[NSDate dateWithTimeIntervalSinceNow:7200];
        u.limitWindows=@[@{@"remainingFraction":@.73,@"window":@"5-hour",@"resetsAt":@(NSDate.date.timeIntervalSince1970+7200)},@{@"remainingFraction":@.33,@"window":@"weekly",@"resetsAt":@(NSDate.date.timeIntervalSince1970+86400)}];
        [usage addObject:u];
    }
    [c setValue:usage forKey:@"aiUsage"];
    [c setValue:@YES forKey:@"showWatts"];[c setValue:@YES forKey:@"showHealth"];
    [c setValue:@[@{@"uid":@"fixture",@"name":@"Bose Flex SoundLink",@"transport":@(GlanceAudioTransportBluetooth),@"outputChannels":@2,@"dataSource":@""}] forKey:@"audioDevices"];
    [c setValue:@"fixture" forKey:@"defaultOutputUID"];
    [c refresh];
    double prep=NSProcessInfo.processInfo.systemUptime;if(prepare)[c rebuildContent];
    printf("preparation_ms %.3f\n",(NSProcessInfo.processInfo.systemUptime-prep)*1000);
    if(scanning){
        dispatch_semaphore_t started=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND,0),^{
            dispatch_semaphore_signal(started);
            while(!index.finished && !index.paused){@autoreleasepool{[index advanceForSeconds:.35 entries:3000];}}
            dispatch_semaphore_signal(finished);
        });
        dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    }
    for(NSUInteger i=0;i<12;i++){
        popover.start=NSProcessInfo.processInfo.systemUptime;[c togglePopover:nil];
        printf("%s %lu request_ms %.3f offscreen_paint_ms %.3f\n",i ? "warm" : "cold",(unsigned long)i,popover.requestMS,popover.paintMS);
    }
    if(scanning){
        index.paused=YES;dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
        chmod([fixture stringByAppendingPathComponent:@"dir-79"].fileSystemRepresentation,0700);
        [NSFileManager.defaultManager removeItemAtPath:fixture error:NULL];
    }
}return 0;}
