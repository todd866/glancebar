#import "audio_route_plan.h"
#import "pure.h"

NSString *const GBRouteDefaultsKey = @"audioRoutes";
NSString *const GBRouteSavedDefaultsKey = @"audioRouteSavedDefaults";
NSString *const GBRouteAggregateUIDPrefix = @"com.iantodd.glancebar.route.";
NSString *const GBRouteTapNamePrefix = @"Glancebar route";

NSArray<NSString *> *GBRouteDefaultApps(void) {
    return @[@"com.apple.Music", @"com.spotify.client"];
}

static NSString *Str(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSInteger Channels(NSDictionary *device) {
    id channels = device[@"outputChannels"];
    return [channels respondsToSelector:@selector(integerValue)] ? [channels integerValue] : 0;
}
static BOOL IsOurs(NSDictionary *device) {
    return [Str(device[@"uid"]) hasPrefix:GBRouteAggregateUIDPrefix];
}

NSArray<NSDictionary *> *GBRouteRulesNormalized(id stored, NSArray<NSString *> *installedBundleIDs) {
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if ([stored isKindOfClass:NSArray.class]) {
        for (id item in stored) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *bundle = Str(item[@"bundleID"]);
            if (!bundle.length || [seen containsObject:bundle]) continue;
            id enabled = item[@"enabled"];
            [rules addObject:@{
                @"bundleID": bundle,
                @"target": Str(item[@"target"]) ?: @"",
                @"targetName": Str(item[@"targetName"]) ?: @"",   // shown while that output is away
                @"enabled": @([enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES),
            }];
            [seen addObject:bundle];
        }
    }
    for (NSString *bundle in GBRouteDefaultApps()) {
        if ([seen containsObject:bundle] || ![installedBundleIDs containsObject:bundle]) continue;
        [rules addObject:@{@"bundleID": bundle, @"target": @"", @"targetName": @"", @"enabled": @YES}];
        [seen addObject:bundle];
    }
    return rules;
}

NSArray<NSDictionary *> *GBRouteRulesUpdating(NSArray<NSDictionary *> *rules, NSString *bundleID,
                                              NSDictionary *changes) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:rules.count];
    for (NSDictionary *rule in rules) {
        if (![rule[@"bundleID"] isEqual:bundleID]) { [out addObject:rule]; continue; }
        NSMutableDictionary *changed = [rule mutableCopy];
        [changed addEntriesFromDictionary:changes];
        [out addObject:changed];
    }
    return out;
}

NSString *GBRouteLocalSpeakerUID(NSArray<NSDictionary *> *devices) {
    NSString *fallback = nil;
    for (NSDictionary *device in devices) {
        if ([device[@"transport"] integerValue] != GlanceAudioTransportBuiltIn || Channels(device) <= 0) continue;
        NSString *uid = Str(device[@"uid"]);
        if (!uid) continue;
        if ([Str(device[@"name"]).lowercaseString containsString:@"speaker"]) return uid;
        if (!fallback) fallback = uid;
    }
    return fallback;
}

NSString *GBRouteResolveTarget(NSDictionary *rule, NSArray<NSDictionary *> *devices) {
    NSString *chosen = Str(rule[@"target"]);
    if (chosen.length) {
        for (NSDictionary *device in devices)
            if ([device[@"uid"] isEqual:chosen] && Channels(device) > 0 && !IsOurs(device)) return chosen;
        return nil;
    }
    for (NSNumber *transport in @[@(GlanceAudioTransportBluetooth), @(GlanceAudioTransportUSB), @(GlanceAudioTransportDisplay)]) {
        for (NSDictionary *device in devices) {
            if ([device[@"transport"] integerValue] != transport.integerValue) continue;
            if (Channels(device) <= 0 || IsOurs(device) || !Str(device[@"uid"])) continue;
            // Automatic isolation is for shared speakers, not personal listening. Reuse
            // the output menu's name/data-source classifier; explicit targets above remain valid.
            if ([AudioOutputSymbol((GlanceAudioTransport)[device[@"transport"] integerValue],
                                   Str(device[@"name"]), Str(device[@"dataSource"])) isEqual:@"headphones"]) continue;
            return device[@"uid"];
        }
    }
    return nil;
}

BOOL GBRouteBundleMatches(NSString *processBundleID, NSString *appBundleID) {
    if (!processBundleID.length || !appBundleID.length) return NO;
    if ([processBundleID isEqualToString:appBundleID]) return YES;
    return [processBundleID hasPrefix:[appBundleID stringByAppendingString:@"."]];
}

NSDictionary *GBRoutePlan(NSArray<NSDictionary *> *rules, NSArray<NSDictionary *> *devices) {
    NSString *local = GBRouteLocalSpeakerUID(devices);
    NSMutableArray *routes = [NSMutableArray array];
    for (NSDictionary *rule in rules) {
        if (![rule[@"enabled"] boolValue]) continue;
        NSString *target = GBRouteResolveTarget(rule, devices);
        if (!target || [target isEqual:local]) continue;
        [routes addObject:@{@"bundleID": rule[@"bundleID"], @"target": target}];
    }
    NSMutableDictionary *plan = [@{@"routes": routes} mutableCopy];
    if (routes.count && local) plan[@"hold"] = local;
    return plan;
}

static BOOL Present(NSString *uid, NSArray<NSDictionary *> *devices) {
    if (!uid.length) return NO;
    for (NSDictionary *device in devices)
        if ([device[@"uid"] isEqual:uid] && Channels(device) > 0) return YES;
    return NO;
}

NSDictionary *GBRouteDefaultsStep(NSString *hold, NSDictionary *saved,
                                  NSString *currentOutput, NSString *currentSystem,
                                  BOOL devicesChanged, NSArray<NSDictionary *> *devices) {
    NSMutableDictionary *step = [NSMutableDictionary dictionary];
    if (hold) {
        BOOL begins = ![saved isKindOfClass:NSDictionary.class];
        if (begins) {
            NSMutableDictionary *fresh = [@{@"hold": hold} mutableCopy];
            if (currentOutput) fresh[@"output"] = currentOutput;
            if (currentSystem) fresh[@"system"] = currentSystem;
            saved = fresh;
        }
        step[@"saved"] = saved;
        if (begins || devicesChanged) {
            if (![currentOutput isEqual:hold]) step[@"setOutput"] = hold;
            if (begins && ![currentSystem isEqual:hold]) step[@"setSystem"] = hold;
        }
        return step;
    }
    if (![saved isKindOfClass:NSDictionary.class]) return step;
    step[@"saved"] = NSNull.null;
    NSString *held = Str(saved[@"hold"]);
    NSString *output = Str(saved[@"output"]), *system = Str(saved[@"system"]);
    if ([currentOutput isEqual:held] && ![output isEqual:held] && Present(output, devices)) step[@"setOutput"] = output;
    if ([currentSystem isEqual:held] && ![system isEqual:held] && Present(system, devices)) step[@"setSystem"] = system;
    return step;
}

// Sample (frame, channel) of a buffer list, whether interleaved or planar.
static inline float SampleAt(const AudioBufferList *list, UInt32 frame, UInt32 channel, UInt32 frames) {
    UInt32 base = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        UInt32 n = buffer->mNumberChannels ?: 1;
        if (channel < base + n) {
            if (!buffer->mData || frame >= frames) return 0;
            UInt32 available = buffer->mDataByteSize / (UInt32)(sizeof(float) * n);
            if (frame >= available) return 0;
            return ((const float *)buffer->mData)[frame * n + (channel - base)];
        }
        base += n;
    }
    return 0;
}
static UInt32 ChannelCount(const AudioBufferList *list) {
    UInt32 total = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) total += list->mBuffers[b].mNumberChannels ?: 1;
    return total;
}
static UInt32 FrameCount(const AudioBufferList *list) {
    UInt32 frames = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        UInt32 n = list->mBuffers[b].mNumberChannels ?: 1;
        UInt32 f = list->mBuffers[b].mDataByteSize / (UInt32)(sizeof(float) * n);
        if (b == 0 || f < frames) frames = f;
    }
    return frames;
}

float GBRouteCopyAudio(const AudioBufferList *input, AudioBufferList *output) {
    if (!output) return 0;
    UInt32 inChannels = input ? ChannelCount(input) : 0;
    UInt32 inFrames = input && inChannels ? FrameCount(input) : 0;
    float peak = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mData) continue;
        UInt32 n = buffer->mNumberChannels ?: 1;
        UInt32 frames = buffer->mDataByteSize / (UInt32)(sizeof(float) * n);
        float *data = buffer->mData;
        UInt32 firstChannel = 0;
        for (UInt32 p = 0; p < b; p++) firstChannel += output->mBuffers[p].mNumberChannels ?: 1;
        for (UInt32 f = 0; f < frames; f++) {
            for (UInt32 c = 0; c < n; c++) {
                UInt32 channel = firstChannel + c;
                float v = 0;
                if (f < inFrames && inChannels) {
                    if (inChannels == 1) v = SampleAt(input, f, 0, inFrames);
                    else if (channel < inChannels) v = SampleAt(input, f, channel, inFrames);
                }
                data[f * n + c] = v;
                float a = v < 0 ? -v : v;
                if (a > peak) peak = a;
            }
        }
    }
    return peak;
}
