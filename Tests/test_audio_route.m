#import <Foundation/Foundation.h>
#import "audio_route_plan.h"
#import "pure.h"
static int checks;
static void Check(BOOL yes, NSString *message) { checks++; if (!yes) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); } }

static NSDictionary *Dev(NSString *uid, NSString *name, GlanceAudioTransport t, int out) {
    return @{@"uid": uid, @"name": name, @"transport": @(t), @"outputChannels": @(out)};
}

int main(void) { @autoreleasepool {
    NSDictionary *speakers = Dev(@"BuiltInSpeakerDevice", @"MacBook Air Speakers", GlanceAudioTransportBuiltIn, 2);
    NSDictionary *mic = Dev(@"BuiltInMicrophoneDevice", @"MacBook Air Microphone", GlanceAudioTransportBuiltIn, 0);
    NSDictionary *bose = Dev(@"AC-BF-71-00-00-01:output", @"Bose Flex SE SoundLink", GlanceAudioTransportBluetooth, 2);
    NSDictionary *iphone = Dev(@"iPhoneMic", @"Ian's iPhone Microphone", GlanceAudioTransportOther, 0);
    NSDictionary *teams = Dev(@"MSLoopbackDriverDevice_UID", @"Microsoft Teams Audio", GlanceAudioTransportVirtual, 2);
    NSDictionary *ours = Dev(@"com.iantodd.glancebar.route.com.apple.Music.1", @"Glancebar Music", GlanceAudioTransportAggregate, 2);
    NSDictionary *usb = Dev(@"usbdac", @"USB DAC", GlanceAudioTransportUSB, 2);
    NSArray *home = @[mic, speakers, iphone, teams];
    NSArray *withBose = @[mic, speakers, bose, iphone, teams, ours];

    // Rules: defaults and cleaning.
    NSArray *rules = GBRouteRulesNormalized(nil, @[@"com.apple.Music"]);
    Check(rules.count == 1, @"no stored rules: one default rule for Music");
    Check([rules[0][@"bundleID"] isEqual:@"com.apple.Music"], @"default rule is Music");
    Check([rules[0][@"enabled"] boolValue], @"default rule is on");
    Check([rules[0][@"target"] isEqual:@""], @"default rule target is automatic");
    rules = GBRouteRulesNormalized(nil, @[@"com.apple.Music", @"com.spotify.client"]);
    Check(rules.count == 2 && [rules[1][@"bundleID"] isEqual:@"com.spotify.client"], @"Spotify gets a default rule once installed");
    rules = GBRouteRulesNormalized(@[@{@"bundleID": @"com.apple.Music", @"target": @"x", @"enabled": @NO}], @[@"com.apple.Music"]);
    Check(rules.count == 1 && ![rules[0][@"enabled"] boolValue] && [rules[0][@"target"] isEqual:@"x"], @"stored rule survives as stored");
    rules = GBRouteRulesNormalized(@[@"junk", @{@"bundleID": @3}, @{@"bundleID": @"com.apple.Music", @"enabled": @YES},
                                      @{@"bundleID": @"com.apple.Music", @"enabled": @NO}], @[]);
    Check(rules.count == 1 && [rules[0][@"enabled"] boolValue] && [rules[0][@"target"] isEqual:@""],
          @"malformed rules dropped, duplicates keep the first, missing target means automatic");
    rules = GBRouteRulesNormalized(@[@{@"bundleID": @"com.apple.Music", @"target": @"x", @"targetName": @"Bose", @"enabled": @YES}], @[]);
    Check([rules[0][@"targetName"] isEqual:@"Bose"], @"the chosen output's name is kept for while it is away");
    rules = GBRouteRulesNormalized(@"not an array", @[@"com.apple.Music"]);
    Check(rules.count == 1, @"non-array storage falls back to defaults");
    rules = GBRouteRulesNormalized(nil, @[]);
    Check(rules.count == 0, @"no default app installed: no rules");
    NSArray *base = GBRouteRulesNormalized(nil, @[@"com.apple.Music"]);
    NSArray *updated = GBRouteRulesUpdating(base, @"com.apple.Music", @{@"target": @"usbdac"});
    Check([updated[0][@"target"] isEqual:@"usbdac"] && [updated[0][@"enabled"] boolValue], @"update changes only the given key");
    Check([GBRouteRulesUpdating(base, @"com.other", @{@"enabled": @NO}) isEqual:base], @"update of an unknown app changes nothing");

    // Devices.
    Check([GBRouteLocalSpeakerUID(withBose) isEqual:@"BuiltInSpeakerDevice"], @"local speakers found");
    Check(GBRouteLocalSpeakerUID(@[bose, mic]) == nil, @"a microphone is not a speaker");
    NSDictionary *autoRule = base[0];
    Check([GBRouteResolveTarget(autoRule, withBose) isEqual:bose[@"uid"]], @"automatic picks the Bluetooth speaker");
    Check(GBRouteResolveTarget(autoRule, home) == nil, @"automatic: no external output, no target (Teams and iPhone are not speakers)");
    Check([GBRouteResolveTarget(autoRule, @[speakers, usb, bose]) isEqual:bose[@"uid"]], @"Bluetooth before USB");
    Check(GBRouteResolveTarget(autoRule, @[speakers, ours]) == nil, @"never one of our own aggregates");
    NSDictionary *pinned = @{@"bundleID": @"com.apple.Music", @"target": @"usbdac", @"enabled": @YES};
    Check([GBRouteResolveTarget(pinned, @[speakers, usb, bose]) isEqual:@"usbdac"], @"a chosen output wins");
    Check(GBRouteResolveTarget(pinned, withBose) == nil, @"a chosen output that is absent is no target, not a fallback");
    Check(GBRouteResolveTarget(@{@"bundleID": @"a", @"target": @"iPhoneMic", @"enabled": @YES}, withBose) == nil,
          @"an input-only device is never a target");

    Check(GBRouteBundleMatches(@"com.apple.Music", @"com.apple.Music"), @"the app itself");
    Check(GBRouteBundleMatches(@"com.google.Chrome.helper", @"com.google.Chrome"), @"a helper of the app");
    Check(!GBRouteBundleMatches(@"com.apple.MusicRecognition", @"com.apple.Music"), @"a prefix that is not a helper");
    Check(!GBRouteBundleMatches(nil, @"com.apple.Music"), @"no bundle ID");

    // Plan.
    NSDictionary *plan = GBRoutePlan(base, withBose);
    Check([plan[@"routes"] count] == 1 && [plan[@"routes"][0][@"target"] isEqual:bose[@"uid"]], @"Music routed to the Bose");
    Check([plan[@"hold"] isEqual:@"BuiltInSpeakerDevice"], @"everything else held on the speakers");
    plan = GBRoutePlan(base, home);
    Check([plan[@"routes"] count] == 0 && plan[@"hold"] == nil, @"speaker gone: no route, no hold");
    plan = GBRoutePlan(GBRouteRulesUpdating(base, @"com.apple.Music", @{@"enabled": @NO}), withBose);
    Check([plan[@"routes"] count] == 0 && plan[@"hold"] == nil, @"rule off: no route, no hold");
    plan = GBRoutePlan(GBRouteRulesUpdating(base, @"com.apple.Music", @{@"target": @"BuiltInSpeakerDevice"}), withBose);
    Check([plan[@"routes"] count] == 0 && plan[@"hold"] == nil, @"routing to the speakers is no route");
    plan = GBRoutePlan(base, @[bose]);
    Check([plan[@"routes"] count] == 1 && plan[@"hold"] == nil, @"no local speakers: route, but nothing to hold on");

    // Defaults: hold begins.
    NSDictionary *step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", nil, bose[@"uid"], bose[@"uid"], YES, withBose);
    Check([step[@"setOutput"] isEqual:@"BuiltInSpeakerDevice"] && [step[@"setSystem"] isEqual:@"BuiltInSpeakerDevice"], @"hold begins: both defaults to the speakers");
    NSDictionary *saved = step[@"saved"];
    Check([saved[@"output"] isEqual:bose[@"uid"]] && [saved[@"system"] isEqual:bose[@"uid"]] && [saved[@"hold"] isEqual:@"BuiltInSpeakerDevice"], @"previous defaults saved");
    // Held, nothing changed: no action.
    step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", saved, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", NO, withBose);
    Check(!step[@"setOutput"] && !step[@"setSystem"] && [step[@"saved"] isEqual:saved], @"steady hold: nothing to do");
    // A deliberate change while held is not fought.
    step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", saved, @"usbdac", @"BuiltInSpeakerDevice", NO, withBose);
    Check(!step[@"setOutput"], @"user choice between device changes is left alone");
    // A device change while held re-asserts (macOS switched to the reconnected speaker).
    step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", saved, bose[@"uid"], @"BuiltInSpeakerDevice", YES, withBose);
    Check([step[@"setOutput"] isEqual:@"BuiltInSpeakerDevice"] && !step[@"setSystem"], @"device change re-asserts the hold");
    // Hold ends with the speaker still here (rule turned off): restore.
    step = GBRouteDefaultsStep(nil, saved, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", NO, withBose);
    Check([step[@"setOutput"] isEqual:bose[@"uid"]] && [step[@"setSystem"] isEqual:bose[@"uid"]], @"rule off: previous defaults restored");
    Check(step[@"saved"] == NSNull.null, @"restore clears the saved defaults");
    // Hold ends because the speaker left: its saved default is gone, nothing to restore.
    step = GBRouteDefaultsStep(nil, saved, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", YES, home);
    Check(!step[@"setOutput"] && !step[@"setSystem"] && step[@"saved"] == NSNull.null, @"speaker gone: nothing to restore, saved cleared");
    // Hold ends but the user moved the default meanwhile: leave their choice.
    NSDictionary *savedUSB = @{@"output": @"usbdac", @"system": @"usbdac", @"hold": @"BuiltInSpeakerDevice"};
    step = GBRouteDefaultsStep(nil, savedUSB, bose[@"uid"], @"BuiltInSpeakerDevice", NO, @[speakers, usb, bose]);
    Check(!step[@"setOutput"] && [step[@"setSystem"] isEqual:@"usbdac"], @"restore only what is still where the hold put it");
    // Hold already in place before (a relaunch after a crash): the saved defaults are kept.
    step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", saved, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", YES, withBose);
    Check([step[@"saved"] isEqual:saved], @"existing saved defaults are not overwritten by the held ones");
    // No hold, nothing saved.
    step = GBRouteDefaultsStep(nil, nil, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", YES, home);
    Check(!step[@"setOutput"] && !step[@"setSystem"] && !step[@"saved"], @"idle: nothing");
    // Hold begins with the defaults already on the speakers.
    step = GBRouteDefaultsStep(@"BuiltInSpeakerDevice", nil, @"BuiltInSpeakerDevice", @"BuiltInSpeakerDevice", NO, withBose);
    Check(!step[@"setOutput"] && !step[@"setSystem"] && step[@"saved"], @"already held: saves, sets nothing");

    // Audio copy.
    float inL[4] = {0.1f, 0.2f, -0.9f, 0.4f}, inR[4] = {0.5f, 0.6f, 0.7f, 0.8f};
    float interleaved[8] = {0.1f, 0.5f, 0.2f, 0.6f, -0.9f, 0.7f, 0.4f, 0.8f};
    float out[8] = {0}, outL[4] = {0}, outR[4] = {0};
    AudioBufferList inI = {1, {{2, sizeof interleaved, interleaved}}};
    AudioBufferList outI = {1, {{2, sizeof out, out}}};
    float peak = GBRouteCopyAudio(&inI, &outI);
    Check(memcmp(out, interleaved, sizeof out) == 0 && fabsf(peak - 0.9f) < 1e-6f, @"interleaved stereo to interleaved stereo, with peak");
    struct { UInt32 n; AudioBuffer b[2]; } inN = {2, {{1, sizeof inL, inL}, {1, sizeof inR, inR}}};
    memset(out, 0, sizeof out);
    GBRouteCopyAudio((AudioBufferList *)&inN, &outI);
    Check(memcmp(out, interleaved, sizeof out) == 0, @"planar stereo to interleaved stereo");
    struct { UInt32 n; AudioBuffer b[2]; } outN = {2, {{1, sizeof outL, outL}, {1, sizeof outR, outR}}};
    GBRouteCopyAudio(&inI, (AudioBufferList *)&outN);
    Check(memcmp(outL, inL, sizeof inL) == 0 && memcmp(outR, inR, sizeof inR) == 0, @"interleaved stereo to planar stereo");
    float mono[4] = {0.3f, 0.3f, 0.3f, 0.3f};
    AudioBufferList inM = {1, {{1, sizeof mono, mono}}};
    GBRouteCopyAudio(&inM, (AudioBufferList *)&outN);
    Check(outL[2] == 0.3f && outR[2] == 0.3f, @"mono fills both output channels");
    float quad[16]; for (int i = 0; i < 16; i++) quad[i] = 9;
    AudioBufferList outQ = {1, {{4, sizeof quad, quad}}};
    GBRouteCopyAudio(&inI, &outQ);
    Check(quad[0] == 0.1f && quad[1] == 0.5f && quad[2] == 0 && quad[3] == 0 && quad[12] == 0.4f && quad[15] == 0, @"extra output channels silent");
    float longOut[16]; for (int i = 0; i < 16; i++) longOut[i] = 9;
    AudioBufferList outL8 = {1, {{2, sizeof longOut, longOut}}};
    GBRouteCopyAudio(&inI, &outL8);
    Check(longOut[7] == 0.8f && longOut[8] == 0 && longOut[15] == 0, @"frames past the input are zeroed");
    AudioBufferList empty = {0};
    for (int i = 0; i < 8; i++) out[i] = 9;
    Check(GBRouteCopyAudio(&empty, &outI) == 0 && out[0] == 0 && out[7] == 0, @"no input: silence");
    Check(GBRouteCopyAudio(NULL, &outI) == 0, @"NULL input: silence");

    printf("audio route tests: %d checks passed\n", checks);
    return 0;
} }
