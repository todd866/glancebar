// Prints the per-app audio routing as Core Audio sees it: the default and alert outputs,
// every output device (rate, whether something is playing on it), Glancebar's taps and any
// Glancebar aggregates still public, each audio process (bundle, playing, the devices it
// plays to), and Glancebar's own route snapshot (frames forwarded, peak level).
// Build and run: tools/audio-route-status.sh
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

static AudioObjectPropertyAddress A(AudioObjectPropertySelector s) {
    return (AudioObjectPropertyAddress){s, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
static NSString *Str(AudioObjectID o, AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a = A(s); CFStringRef v = NULL; UInt32 n = sizeof v;
    if (!AudioObjectHasProperty(o, &a) || AudioObjectGetPropertyData(o, &a, 0, NULL, &n, &v) != noErr || !v) return @"";
    return (__bridge_transfer NSString *)v;
}
static UInt32 U(AudioObjectID o, AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a = A(s); UInt32 v = 0, n = sizeof v;
    if (AudioObjectHasProperty(o, &a)) AudioObjectGetPropertyData(o, &a, 0, NULL, &n, &v);
    return v;
}
static double Rate(AudioObjectID o) {
    AudioObjectPropertyAddress a = A(kAudioDevicePropertyNominalSampleRate); Float64 v = 0; UInt32 n = sizeof v;
    AudioObjectGetPropertyData(o, &a, 0, NULL, &n, &v); return v;
}
static NSArray<NSNumber *> *List(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {s, scope, kAudioObjectPropertyElementMain}; UInt32 n = 0;
    if (!AudioObjectHasProperty(o, &a) || AudioObjectGetPropertyDataSize(o, &a, 0, NULL, &n) != noErr || !n) return @[];
    AudioObjectID *ids = calloc(n / sizeof(AudioObjectID), sizeof(AudioObjectID));
    NSMutableArray *out = [NSMutableArray array];
    if (AudioObjectGetPropertyData(o, &a, 0, NULL, &n, ids) == noErr)
        for (UInt32 i = 0; i < n / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    free(ids); return out;
}
static UInt32 DefaultDevice(AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a = A(s); AudioObjectID d = 0; UInt32 n = sizeof d;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &n, &d); return d;
}
static NSString *Name(AudioObjectID d) { return d ? [NSString stringWithFormat:@"%@ [%u]", Str(d, kAudioObjectPropertyName), d] : @"none"; }

int main(void) { @autoreleasepool {
    printf("default output : %s\n", Name(DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)).UTF8String);
    printf("alert output   : %s\n", Name(DefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)).UTF8String);
    printf("\noutput devices (id  rate  running  name  uid)\n");
    for (NSNumber *d in List(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)) {
        if (!List(d.unsignedIntValue, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count) continue;
        printf("  %-4u %6.0f  %-3s  %s  %s\n", d.unsignedIntValue, Rate(d.unsignedIntValue),
               U(d.unsignedIntValue, kAudioDevicePropertyDeviceIsRunningSomewhere) ? "yes" : "no",
               Str(d.unsignedIntValue, kAudioObjectPropertyName).UTF8String, Str(d.unsignedIntValue, kAudioDevicePropertyDeviceUID).UTF8String);
    }
    printf("\nglancebar aggregates still public: ");
    int aggs = 0;
    for (NSNumber *d in List(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal))
        if ([Str(d.unsignedIntValue, kAudioDevicePropertyDeviceUID) hasPrefix:@"com.iantodd.glancebar.route."]) { aggs++; printf("\n  %s", Name(d.unsignedIntValue).UTF8String); }
    printf(aggs ? "\n" : "none (routes use private aggregates)\n");
    if (@available(macOS 14.2, *)) {
        printf("\nprocess taps (id  name  uid  format)\n");
        NSArray *taps = List(kAudioObjectSystemObject, kAudioHardwarePropertyTapList, kAudioObjectPropertyScopeGlobal);
        if (!taps.count) printf("  none\n");
        for (NSNumber *t in taps) {
            AudioStreamBasicDescription f = {0}; AudioObjectPropertyAddress a = A(kAudioTapPropertyFormat); UInt32 n = sizeof f;
            AudioObjectGetPropertyData(t.unsignedIntValue, &a, 0, NULL, &n, &f);
            printf("  %-4u %s  %s  %.0f Hz x%u\n", t.unsignedIntValue, Str(t.unsignedIntValue, kAudioObjectPropertyName).UTF8String,
                   Str(t.unsignedIntValue, kAudioTapPropertyUID).UTF8String, f.mSampleRate, f.mChannelsPerFrame);
        }
        printf("\naudio processes playing (pid  bundle  -> devices)\n");
        int playing = 0;
        for (NSNumber *p in List(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)) {
            AudioObjectID o = p.unsignedIntValue;
            if (!U(o, kAudioProcessPropertyIsRunningOutput)) continue;
            playing++;
            AudioObjectPropertyAddress pa = A(kAudioProcessPropertyPID); pid_t pid = 0; UInt32 n = sizeof pid;
            AudioObjectGetPropertyData(o, &pa, 0, NULL, &n, &pid);
            NSMutableArray *names = [NSMutableArray array];
            for (NSNumber *d in List(o, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)) [names addObject:Name(d.unsignedIntValue)];
            printf("  %-6d %s -> %s\n", pid, Str(o, kAudioProcessPropertyBundleID).UTF8String, [names componentsJoinedByString:@", "].UTF8String);
        }
        if (!playing) printf("  none\n");
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.iantodd.glancebar/audio-route.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    printf("\nglancebar routes (%s)\n", path.UTF8String);
    NSDictionary *doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![doc isKindOfClass:NSDictionary.class]) { printf("  no snapshot\n"); return 0; }
    printf("  written %.0f s ago by pid %d\n", NSDate.date.timeIntervalSince1970 - [doc[@"updated"] doubleValue], [doc[@"pid"] intValue]);
    for (NSDictionary *r in doc[@"routes"]) printf("  rule  %s -> %s\n", [r[@"bundleID"] UTF8String], [r[@"target"] UTF8String]);
    static const char *statuses[] = {"idle", "active", "silent", "failed", "unsupported"};
    for (NSDictionary *s in doc[@"sessions"]) {
        int st = [s[@"status"] intValue];
        printf("  route %s -> %s  %s  playing=%s  tap=%u (%.0f Hz) aggregate=%u (%.0f Hz)  frames=%llu  peak=%.3f  heard=%s %s\n",
               [s[@"bundleID"] UTF8String], [s[@"target"] ?: @"" UTF8String], st >= 0 && st < 5 ? statuses[st] : "?",
               [s[@"playing"] boolValue] ? "yes" : "no", [s[@"tap"] unsignedIntValue], [s[@"tapRate"] doubleValue],
               [s[@"aggregate"] unsignedIntValue], [s[@"deviceRate"] doubleValue], [s[@"frames"] unsignedLongLongValue],
               [s[@"peak"] doubleValue], [s[@"heard"] boolValue] ? "yes" : "no", [s[@"error"] ?: @"" UTF8String]);
    }
    return 0;
} }
