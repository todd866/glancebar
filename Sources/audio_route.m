#import "audio_route.h"
#import "audio_route_plan.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <stdatomic.h>

static AudioObjectPropertyAddress Addr(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
static NSString *StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = Addr(selector);
    CFStringRef value = NULL;
    UInt32 size = sizeof value;
    if (!AudioObjectHasProperty(object, &a) ||
        AudioObjectGetPropertyData(object, &a, 0, NULL, &size, &value) != noErr || !value) return nil;
    return (__bridge_transfer NSString *)value;
}
static NSArray<NSNumber *> *ObjectList(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = Addr(selector);
    UInt32 size = 0;
    if (!AudioObjectHasProperty(object, &a) ||
        AudioObjectGetPropertyDataSize(object, &a, 0, NULL, &size) != noErr || size < sizeof(AudioObjectID)) return @[];
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *ids = calloc(count, sizeof(AudioObjectID));
    if (!ids) return @[];
    NSMutableArray *out = [NSMutableArray array];
    if (AudioObjectGetPropertyData(object, &a, 0, NULL, &size, ids) == noErr)
        for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    free(ids);
    return out;
}
static double NominalRate(AudioObjectID device) {
    Float64 rate = 0;
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyNominalSampleRate);
    UInt32 size = sizeof rate;
    if (!device || AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &rate) != noErr) return 0;
    return rate;
}
static UInt32 UIntProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = Addr(selector);
    UInt32 value = 0, size = sizeof value;
    if (!AudioObjectHasProperty(object, &a)) return 0;
    AudioObjectGetPropertyData(object, &a, 0, NULL, &size, &value);
    return value;
}

NSString *GBAudioDeviceUIDForID(AudioObjectID device) {
    return device ? StringProperty(device, kAudioDevicePropertyDeviceUID) : nil;
}
AudioObjectID GBAudioDeviceIDForUID(NSString *uid) {
    if (!uid.length) return kAudioObjectUnknown;
    for (NSNumber *device in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyDevices))
        if ([GBAudioDeviceUIDForID(device.unsignedIntValue) isEqual:uid]) return device.unsignedIntValue;
    return kAudioObjectUnknown;
}
NSString *GBAudioDefaultUID(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = Addr(selector);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof device;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &device) != noErr) return nil;
    return GBAudioDeviceUIDForID(device);
}
void GBAudioSetDefault(AudioObjectPropertySelector selector, NSString *uid) {
    AudioObjectID device = GBAudioDeviceIDForUID(uid);
    if (!device) return;
    AudioObjectPropertyAddress a = Addr(selector);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof device, &device);
}

// Shared with the IO thread: plain C, no Objective-C, no locks.
typedef struct {
    _Atomic uint64_t frames;     // frames forwarded since the session began
    _Atomic uint32_t peakBits;   // largest |sample| since the main thread last read it (float bits)
    _Atomic bool heard;          // ever forwarded a non-zero sample
} GBRouteMeter;

@interface GBRouteSession : NSObject {
@public
    GBRouteMeter *meter;
}
@property (nonatomic, copy) NSString *bundleID, *target;
@property (nonatomic, copy) NSArray<NSNumber *> *processes;
@property (nonatomic) AudioObjectID tap, aggregate, targetDevice;
@property (nonatomic) AudioDeviceIOProcID proc;
@property (nonatomic, copy) NSString *tapUID, *aggregateUID;
@property (nonatomic) double tapRate, deviceRate;
@property (nonatomic) NSInteger quietTicks;
@property (nonatomic) float lastPeak;
@property (nonatomic) GBRouteStatus status;
@end
@implementation GBRouteSession
- (instancetype)init {
    if ((self = [super init])) meter = calloc(1, sizeof(GBRouteMeter));
    return self;
}
- (void)dealloc { free(meter); }
@end

static OSStatus RouterListener(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *);

@implementation GBAudioRouter {
    NSArray<NSDictionary *> *_routes;
    NSMutableDictionary<NSString *, GBRouteSession *> *_sessions;   // by bundle ID
    NSMutableDictionary<NSString *, NSNumber *> *_failed;           // bundle ID -> status
    // What a failure was for: it is not retried until the target or the app's processes
    // change (a relaunch), or the rule is switched off and on.
    NSMutableDictionary<NSString *, NSArray *> *_failedFor;         // bundle ID -> @[target, processes]
    NSUInteger _generation;
    BOOL _started;
    NSTimer *_meterTimer;
    NSString *_lastError;
}

+ (BOOL)supported {
    if (@available(macOS 14.2, *)) return YES;
    return NO;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sessions = [NSMutableDictionary dictionary];
        _failed = [NSMutableDictionary dictionary];
        _failedFor = [NSMutableDictionary dictionary];
        _routes = @[];
    }
    return self;
}
- (NSString *)lastError { return _lastError; }

- (void)start {
    if (_started) return;
    _started = YES;
    [self sweepStale];
    AudioObjectPropertyAddress processes = Addr(kAudioHardwarePropertyProcessObjectList);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &processes, RouterListener, (__bridge void *)self);
}

- (void)stop {
    for (GBRouteSession *session in _sessions.allValues) [self teardown:session];
    [_sessions removeAllObjects];
    [_meterTimer invalidate];
    _meterTimer = nil;
    if (_started) {
        AudioObjectPropertyAddress processes = Addr(kAudioHardwarePropertyProcessObjectList);
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &processes, RouterListener, (__bridge void *)self);
        _started = NO;
    }
    _routes = @[];
    [self writeStatus];
}

// Aggregates and taps a previous run left behind (a crash before Core Audio reclaimed them,
// or an older build that made them public).
- (void)sweepStale {
    for (NSNumber *device in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) {
        NSString *uid = GBAudioDeviceUIDForID(device.unsignedIntValue);
        if ([uid hasPrefix:GBRouteAggregateUIDPrefix]) AudioHardwareDestroyAggregateDevice(device.unsignedIntValue);
    }
    if (@available(macOS 14.2, *)) {
        for (NSNumber *tap in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyTapList)) {
            NSString *name = StringProperty(tap.unsignedIntValue, kAudioObjectPropertyName);
            if ([name hasPrefix:GBRouteTapNamePrefix]) AudioHardwareDestroyProcessTap(tap.unsignedIntValue);
        }
    }
}

- (void)processesChanged {
    NSUInteger generation = ++_generation;
    // An app launching publishes its process object, then its helpers; settle first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->_generation) [self reconcile];
    });
}

- (void)applyRoutes:(NSArray<NSDictionary *> *)routes {
    _routes = [routes copy] ?: @[];
    [self reconcile];
}

// The audio process objects (the app and its helpers) for a bundle ID.
static NSArray<NSNumber *> *ProcessesFor(NSString *bundleID) {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(macOS 14.2, *)) {
        for (NSNumber *process in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
            NSString *bundle = StringProperty(process.unsignedIntValue, kAudioProcessPropertyBundleID);
            if (GBRouteBundleMatches(bundle, bundleID)) [out addObject:process];
        }
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}
static BOOL AnyRunningOutput(NSArray<NSNumber *> *processes) {
    if (@available(macOS 14.2, *)) {
        for (NSNumber *process in processes)
            if (UIntProperty(process.unsignedIntValue, kAudioProcessPropertyIsRunningOutput)) return YES;
    }
    return NO;
}

- (void)reconcile {
    BOOL changed = NO;
    NSMutableSet<NSString *> *wanted = [NSMutableSet set];
    for (NSDictionary *route in _routes) {
        NSString *bundle = route[@"bundleID"], *target = route[@"target"];
        if (!bundle.length || !target.length) continue;
        [wanted addObject:bundle];
        NSArray<NSNumber *> *processes = ProcessesFor(bundle);
        GBRouteSession *session = _sessions[bundle];
        AudioObjectID targetDevice = GBAudioDeviceIDForUID(target);
        BOOL current = session && [session.target isEqual:target] && [session.processes isEqual:processes] &&
                       session.targetDevice == targetDevice && targetDevice != kAudioObjectUnknown &&
                       NominalRate(targetDevice) == session.deviceRate;
        if (current) continue;
        if (session) { [self teardown:session]; [_sessions removeObjectForKey:bundle]; changed = YES; }
        if (_failed[bundle] && [_failedFor[bundle] isEqual:(@[target, processes])]) continue;
        if (_failed[bundle]) { [_failed removeObjectForKey:bundle]; [_failedFor removeObjectForKey:bundle]; changed = YES; }
        if (!processes.count || !targetDevice) continue;
        if (![GBAudioRouter supported]) { [self fail:bundle status:GBRouteStatusUnsupported target:target processes:processes]; changed = YES; continue; }
        if (@available(macOS 14.2, *)) {
            GBRouteSession *fresh = [self buildSession:bundle target:target device:targetDevice processes:processes];
            if (fresh) _sessions[bundle] = fresh;
            else [self fail:bundle status:GBRouteStatusFailed target:target processes:processes];
            changed = YES;
        }
    }
    for (NSString *bundle in _sessions.allKeys) {
        if ([wanted containsObject:bundle]) continue;
        [self teardown:_sessions[bundle]];
        [_sessions removeObjectForKey:bundle];
        changed = YES;
    }
    for (NSString *bundle in _failed.allKeys)
        if (![wanted containsObject:bundle]) { [_failed removeObjectForKey:bundle]; [_failedFor removeObjectForKey:bundle]; changed = YES; }
    if (_sessions.count && !_meterTimer) {
        __weak GBAudioRouter *weakSelf = self;
        _meterTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            (void)t;
            [weakSelf meterTick];
        }];
    } else if (!_sessions.count) {
        [_meterTimer invalidate];
        _meterTimer = nil;
    }
    if (changed) [self notifyChange];
    [self writeStatus];
}

- (void)fail:(NSString *)bundle status:(GBRouteStatus)status target:(NSString *)target processes:(NSArray *)processes {
    _failed[bundle] = @(status);
    _failedFor[bundle] = @[target ?: @"", processes ?: @[]];
}

- (void)notifyChange {
    void (^block)(void) = self.onChange;
    // Never re-entrantly: the listener applies routes, which reconciles again.
    if (block) dispatch_async(dispatch_get_main_queue(), block);
}

- (GBRouteSession *)buildSession:(NSString *)bundle target:(NSString *)target device:(AudioObjectID)device
                       processes:(NSArray<NSNumber *> *)processes API_AVAILABLE(macos(14.2)) {
    GBRouteSession *session = [GBRouteSession new];
    session.bundleID = bundle;
    session.target = target;
    session.targetDevice = device;
    session.processes = processes;

    CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    NSString *short_ = [bundle componentsSeparatedByString:@"."].lastObject ?: bundle;
    description.name = [NSString stringWithFormat:@"%@ %@", GBRouteTapNamePrefix, short_];
    description.UUID = [NSUUID UUID];
    description.privateTap = NO;   // visible to tools/audio-route-status; swept on launch
    description.muteBehavior = CATapMutedWhenTapped;
    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus err = AudioHardwareCreateProcessTap(description, &tap);
    if (err != noErr || !tap) {
        _lastError = [NSString stringWithFormat:@"tap %d", (int)err];
        return nil;
    }
    session.tap = tap;
    session.tapUID = description.UUID.UUIDString;
    AudioStreamBasicDescription format = {0};
    AudioObjectPropertyAddress fa = Addr(kAudioTapPropertyFormat);
    UInt32 size = sizeof format;
    if (AudioObjectGetPropertyData(tap, &fa, 0, NULL, &size, &format) == noErr) session.tapRate = format.mSampleRate;
    session.deviceRate = NominalRate(device);
    // A Bluetooth speaker drops to a call-quality rate when its microphone opens; rebuild then.
    AudioObjectPropertyAddress ra = Addr(kAudioDevicePropertyNominalSampleRate);
    AudioObjectAddPropertyListener(device, &ra, RouterListener, (__bridge void *)self);

    session.aggregateUID = [NSString stringWithFormat:@"%@%@.%@", GBRouteAggregateUIDPrefix, bundle,
                            [[NSUUID UUID].UUIDString substringToIndex:8]];
    NSDictionary *aggregate = @{
        @kAudioAggregateDeviceNameKey: [NSString stringWithFormat:@"Glancebar %@", short_],
        @kAudioAggregateDeviceUIDKey: session.aggregateUID,
        @kAudioAggregateDeviceMainSubDeviceKey: target,
        @kAudioAggregateDeviceClockDeviceKey: target,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: target}],
        // Drift compensation resamples the tap onto the speaker's clock: a Bluetooth speaker
        // at 44.1 kHz behind a tap at the Mac's 48 kHz still plays in time and in tune.
        @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: session.tapUID,
                                              @kAudioSubTapDriftCompensationKey: @YES}],
    };
    AudioObjectID aggregateID = kAudioObjectUnknown;
    err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &aggregateID);
    if (err != noErr || !aggregateID) {
        _lastError = [NSString stringWithFormat:@"aggregate %d", (int)err];
        [self teardown:session];
        return nil;
    }
    session.aggregate = aggregateID;

    GBRouteMeter *meter = session->meter;
    AudioDeviceIOProcID proc = NULL;
    err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
          AudioBufferList *output, const AudioTimeStamp *outputTime) {
            (void)now; (void)inputTime; (void)outputTime;
            float peak = GBRouteCopyAudio(input, output);
            UInt32 frames = 0;
            if (output && output->mNumberBuffers && output->mBuffers[0].mNumberChannels)
                frames = output->mBuffers[0].mDataByteSize / (UInt32)(sizeof(float) * output->mBuffers[0].mNumberChannels);
            atomic_fetch_add_explicit(&meter->frames, frames, memory_order_relaxed);
            if (peak > 0) {
                atomic_store_explicit(&meter->heard, true, memory_order_relaxed);
                uint32_t bits; memcpy(&bits, &peak, sizeof bits);
                uint32_t old = atomic_load_explicit(&meter->peakBits, memory_order_relaxed);
                while (bits > old && !atomic_compare_exchange_weak_explicit(&meter->peakBits, &old, bits,
                                                                             memory_order_relaxed, memory_order_relaxed)) {}
            }
        });
    if (err != noErr || !proc) {
        _lastError = [NSString stringWithFormat:@"ioproc %d", (int)err];
        [self teardown:session];
        return nil;
    }
    session.proc = proc;
    // Reading the tap is what asks for (and needs) the audio-capture permission.
    err = AudioDeviceStart(aggregateID, proc);
    if (err != noErr) {
        _lastError = [NSString stringWithFormat:@"start %d", (int)err];
        [self teardown:session];
        return nil;
    }
    session.status = GBRouteStatusActive;
    _lastError = nil;
    return session;
}

- (void)teardown:(GBRouteSession *)session {
    if (session.targetDevice && session.deviceRate > 0) {
        AudioObjectPropertyAddress ra = Addr(kAudioDevicePropertyNominalSampleRate);
        AudioObjectRemovePropertyListener(session.targetDevice, &ra, RouterListener, (__bridge void *)self);
    }
    if (session.aggregate && session.proc) {
        AudioDeviceStop(session.aggregate, session.proc);
        AudioDeviceDestroyIOProcID(session.aggregate, session.proc);
    }
    session.proc = NULL;
    if (session.aggregate) AudioHardwareDestroyAggregateDevice(session.aggregate);
    session.aggregate = kAudioObjectUnknown;
    if (@available(macOS 14.2, *)) {
        if (session.tap) AudioHardwareDestroyProcessTap(session.tap);
    }
    session.tap = kAudioObjectUnknown;
}

// Once a second: a session whose app is playing but which has never forwarded a non-zero
// sample after 8 s of play is reading silence, which is what a refused audio-capture
// permission looks like (the tap still opens). Anything audible clears it for good.
- (void)meterTick {
    BOOL changed = NO;
    for (GBRouteSession *session in _sessions.allValues) {
        uint32_t bits = atomic_exchange_explicit(&session->meter->peakBits, 0, memory_order_relaxed);
        float peak; memcpy(&peak, &bits, sizeof peak);
        session.lastPeak = peak;
        GBRouteStatus status = session.status;
        if (atomic_load_explicit(&session->meter->heard, memory_order_relaxed)) {
            status = GBRouteStatusActive;
        } else if (AnyRunningOutput(session.processes)) {
            session.quietTicks++;
            if (session.quietTicks >= 8) status = GBRouteStatusSilent;
        }
        if (status != session.status) { session.status = status; changed = YES; }
        if (status == GBRouteStatusSilent) {
            // Without the permission the tap is silence and the app muted: give the app its
            // own output back rather than leave it silent everywhere.
            [self teardown:session];
            [_sessions removeObjectForKey:session.bundleID];
            [self fail:session.bundleID status:GBRouteStatusSilent target:session.target processes:session.processes];
        }
    }
    if (changed) [self notifyChange];
    [self writeStatus];
}

- (void)writeStatus {
    if (!self.statusPath.length) return;
    NSDictionary *doc = @{@"updated": @([NSDate date].timeIntervalSince1970), @"pid": @(getpid()),
                          @"routes": _routes ?: @[], @"sessions": [self snapshot]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:self.statusPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:self.statusPath atomically:YES];
}

- (GBRouteStatus)statusForBundleID:(NSString *)bundleID {
    GBRouteSession *session = _sessions[bundleID];
    if (session) return session.status;
    NSNumber *failed = _failed[bundleID];
    return failed ? (GBRouteStatus)failed.integerValue : GBRouteStatusIdle;
}

- (AudioObjectID)playingTargetDevice {
    for (GBRouteSession *session in _sessions.allValues)
        if (AnyRunningOutput(session.processes)) return session.targetDevice;
    return kAudioObjectUnknown;
}

- (NSArray<NSDictionary *> *)snapshot {
    NSMutableArray *out = [NSMutableArray array];
    for (GBRouteSession *s in _sessions.allValues) {
        [out addObject:@{
            @"bundleID": s.bundleID, @"target": s.target, @"processes": s.processes,
            @"tap": @(s.tap), @"tapUID": s.tapUID ?: @"", @"aggregate": @(s.aggregate),
            @"aggregateUID": s.aggregateUID ?: @"", @"tapRate": @(s.tapRate), @"deviceRate": @(s.deviceRate),
            @"frames": @(atomic_load_explicit(&s->meter->frames, memory_order_relaxed)),
            @"heard": @(atomic_load_explicit(&s->meter->heard, memory_order_relaxed)),
            @"peak": @(s.lastPeak), @"status": @(s.status),
            @"playing": @(AnyRunningOutput(s.processes)),
        }];
    }
    for (NSString *bundle in _failed)
        [out addObject:@{@"bundleID": bundle, @"status": _failed[bundle], @"error": _lastError ?: @""}];
    return out;
}
@end

static OSStatus RouterListener(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses, void *client) {
    (void)object; (void)count; (void)addresses;
    GBAudioRouter *router = (__bridge GBAudioRouter *)client;
    dispatch_async(dispatch_get_main_queue(), ^{ [router processesChanged]; });
    return noErr;
}
