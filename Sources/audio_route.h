// Per-app audio routing: the Core Audio part. For each route (an app's bundle ID and an
// output device UID) Glancebar creates a process tap on that app's audio processes (muted
// while the tap is read, so the app is silent on its own output), an aggregate device whose
// only output is the target and whose input is the tap (drift-compensated, so a speaker on
// another clock or sample rate still plays in time), and an IOProc that copies one to the
// other. Public Core Audio only (macOS 14.2+); no driver.
//
// Crash safety: the aggregate is private (Core Audio destroys it with the process) and
// tagged with GBRouteAggregateUIDPrefix; the tap is named with GBRouteTapNamePrefix. Both
// are swept on launch in case an older build left a public one behind.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

typedef NS_ENUM(NSInteger, GBRouteStatus) {
    GBRouteStatusIdle = 0,     // the app has no audio process right now
    GBRouteStatusActive,       // tapped and playing through the target
    GBRouteStatusSilent,       // the app is playing but the tap delivers only silence (permission)
    GBRouteStatusFailed,       // Core Audio refused (see lastError)
    GBRouteStatusUnsupported,  // macOS older than 14.2
};

@interface GBAudioRouter : NSObject
// Called on the main queue whenever any route's status changes.
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, readonly) NSString *lastError;
// When set, the snapshot is written here as JSON on every change and once a second while
// routing, for tools/audio-route-status.
@property (nonatomic, copy) NSString *statusPath;
+ (BOOL)supported;
- (void)start;                                   // sweep stale objects, watch processes
- (void)applyRoutes:(NSArray<NSDictionary *> *)routes;   // [{bundleID, target}]
- (void)stop;                                    // tear everything down
- (GBRouteStatus)statusForBundleID:(NSString *)bundleID;
// The output of a route whose app is playing now, or kAudioObjectUnknown (volume keys).
- (AudioObjectID)playingTargetDevice;
// Snapshot for tools/audio-route-status: route, tap/aggregate IDs, frames forwarded, peak.
- (NSArray<NSDictionary *> *)snapshot;
@end

// Core Audio helpers shared with the controller.
NSString *GBAudioDeviceUIDForID(AudioObjectID device);
AudioObjectID GBAudioDeviceIDForUID(NSString *uid);
NSString *GBAudioDefaultUID(AudioObjectPropertySelector selector);   // DefaultOutputDevice / DefaultSystemOutputDevice
void GBAudioSetDefault(AudioObjectPropertySelector selector, NSString *uid);
