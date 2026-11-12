#import <Foundation/Foundation.h>
#import "pure.h"

static int checks;
static void Check(BOOL yes, NSString *message) {
    checks++;
    if (!yes) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static NSDictionary *Dev(NSString *uid, NSString *name, GlanceAudioTransport transport, BOOL volumeControllable) {
    return @{@"uid": uid, @"name": name, @"transport": @(transport),
             @"outputChannels": @2, @"deviceID": @(42), @"volumeControllable": @(volumeControllable)};
}

int main(void) { @autoreleasepool {
    NSDictionary *builtin = Dev(@"BuiltInSpeakerDevice", @"MacBook Air Speakers", GlanceAudioTransportBuiltIn, YES);
    NSDictionary *bose = Dev(@"bose", @"Bose Flex SoundLink", GlanceAudioTransportBluetooth, YES);
    NSDictionary *display = Dev(@"dell", @"DELL U2424HE", GlanceAudioTransportDisplay, NO);

    Check(AudioOutputKind(builtin) == GlanceAudioOutputKindAudibleControllable, @"built-in is controllable");
    Check(AudioOutputKind(bose) == GlanceAudioOutputKindAudibleControllable, @"Bluetooth is controllable");
    Check(AudioOutputKind(display) == GlanceAudioOutputKindUncontrolled, @"display without volume is uncontrolled");

    NSDictionary *system = PlayerOutputChoice(@"", @"", @[builtin, bose], builtin[@"uid"]);
    Check([system[@"system"] boolValue] && [system[@"effectiveUID"] isEqual:builtin[@"uid"]],
          @"empty choice follows the system default");
    Check([system[@"followsSystemDefault"] boolValue], @"controllable default follows system");
    Check(![system[@"diverged"] boolValue], @"no divergence on built-in default");

    NSDictionary *silentDefault = PlayerOutputChoice(@"", @"", @[builtin, display], display[@"uid"]);
    Check([silentDefault[@"effectiveUID"] isEqual:builtin[@"uid"]],
          @"System skips an uncontrolled default to built-in speakers");
    Check(![silentDefault[@"followsSystemDefault"] boolValue], @"must pin built-in when default is silent");
    Check([silentDefault[@"diverged"] boolValue], @"diverged from silent default");

    NSDictionary *pinned = PlayerOutputChoice(bose[@"uid"], bose[@"name"], @[builtin, bose], builtin[@"uid"]);
    Check(![pinned[@"system"] boolValue] && [pinned[@"effectiveUID"] isEqual:bose[@"uid"]],
          @"a connected device is used directly");

    NSDictionary *pinnedDisplay = PlayerOutputChoice(display[@"uid"], display[@"name"],
                                                     @[builtin, display], builtin[@"uid"]);
    Check(![pinnedDisplay[@"volumeControllable"] boolValue], @"explicit display shows em dash volume");

    NSDictionary *missing = PlayerOutputChoice(bose[@"uid"], bose[@"name"], @[builtin], builtin[@"uid"]);
    Check([missing[@"system"] boolValue] && [missing[@"choiceUID"] isEqual:bose[@"uid"]],
          @"missing device falls back to system but remembers the choice");
    Check([missing[@"note"] containsString:@"Bose Flex"], @"absent device names the remembered speaker");

    NSDictionary *displayDev = @{@"uid": @"hdmi", @"name": @"Living Room TV", @"transport": @(GlanceAudioTransportDisplay),
                                 @"outputChannels": @2};
    NSDictionary *mac = Dev(@"mac", @"MacBook Air Speakers", GlanceAudioTransportBuiltIn, YES);
    Check(ChooseNewOutputDevice(@[mac], @[mac, displayDev], YES) == nil,
          @"switch to new outputs never adopts an uncontrolled device");

    NSArray *choices = PlayerOutputMenuChoices(@[builtin, bose], builtin[@"uid"]);
    Check(choices.count == 3, @"menu is System plus each output");
    Check([choices[0][@"system"] boolValue], @"first choice is System");
    Check([PlayerOutputCycleNext(choices, @"") isEqual:builtin[@"uid"]], @"cycle leaves System for first device");
    Check([PlayerOutputCycleNext(choices, bose[@"uid"]) isEqual:@""], @"cycle wraps from last device to System");
    Check(PlayerOutputCycleNext(@[choices[0]], @"") == nil, @"one choice does not cycle");

    NSDictionary *music = ParseExternalPlayback(@{@"Name": @"Jubel", @"Artist": @"Klingande",
                                                  @"Player State": @"Playing"}, @"music");
    Check([music[@"valid"] boolValue] && [music[@"title"] isEqual:@"Jubel"], @"music notification parses");
    NSDictionary *paused = ParseExternalPlayback(@{@"Name": @"A", @"Artist": @"B",
                                                    @"Player State": @"Paused"}, @"spotify");
    Check(![paused[@"playing"] boolValue] && ![paused[@"valid"] boolValue], @"paused is not shown");

    unsetenv("GLANCEBAR_SILENT_QA");
    Check(!MusicSilentQAEnabled() || [NSUserDefaults.standardUserDefaults boolForKey:@"musicSilentQA"],
          @"silent QA defaults off without env");
    setenv("GLANCEBAR_SILENT_QA", "1", 1);
    Check(MusicSilentQAEnabled(), @"silent QA follows GLANCEBAR_SILENT_QA");
    unsetenv("GLANCEBAR_SILENT_QA");
    Check(MusicPlayerOutputVolume(YES) == 0.f && MusicPlayerOutputVolume(NO) == 1.f, @"silent QA forces zero player volume");
    NSDictionary *full = @{@"total": @4, @"available": @4, @"complete": @YES, @"ready": @YES};
    NSDictionary *ready = OfflineMixTileState(full, NO, NO);
    Check([ready[@"state"] isEqual:@"ready"] && [ready[@"enabled"] boolValue], @"full mix tile is ready");
    NSDictionary *fetching = OfflineMixTileState(@{@"total": @40, @"available": @12, @"complete": @NO, @"ready": @YES},
                                                 YES, NO);
    Check([fetching[@"state"] isEqual:@"fetching"] && ![fetching[@"enabled"] boolValue], @"incomplete mix waits while fetching");
    Check([fetching[@"tooltip"] isEqual:@"fetching 12 of 40"], @"fetch tooltip shows progress");
    NSDictionary *partial = OfflineMixTileState(@{@"total": @40, @"available": @12, @"complete": @NO, @"ready": @YES},
                                                NO, YES);
    Check([partial[@"partial"] boolValue] && [partial[@"enabled"] boolValue], @"cannot-fetch allows partial play");
    NSDictionary *idle = OfflineMixTileState(@{@"total": @40, @"available": @12, @"complete": @NO, @"ready": @YES},
                                             NO, NO);
    Check([idle[@"partial"] boolValue] && [idle[@"enabled"] boolValue], @"no fetch running: an incomplete tile plays what is on disk, never stuck dimmed");
    NSDictionary *none = OfflineMixTileState(@{@"total": @40, @"available": @0, @"complete": @NO, @"ready": @NO},
                                             NO, NO);
    Check(![none[@"enabled"] boolValue], @"nothing on disk and no fetch running: unavailable");

    // Playback event log (12 Nov 2026: pauses sent by the headphones took a system-log dig to find).
    NSString *line = PlaybackEventLine(@"rate", @{@"state": @"paused", @"cause": @"remote-pause",
                                                 @"title": @"Line one\nLine two", @"when": NSDate.date,
                                                 @"elapsed": @(12.5)}, 1794466464.25);
    Check([line hasSuffix:@"\n"] && [line componentsSeparatedByString:@"\n"].count == 2, @"event is exactly one line");
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Check([event[@"event"] isEqual:@"rate"] && [event[@"cause"] isEqual:@"remote-pause"], @"event keeps its name and cause");
    Check(fabs([event[@"epoch"] doubleValue] - 1794466464.25) < 0.01 && [event[@"t"] length] >= 19, @"event carries epoch and a readable time");
    Check([event[@"when"] isKindOfClass:NSString.class], @"values JSON cannot hold are written as text, not dropped");
    Check([PlaybackEventLine(@"x", nil, 1) hasSuffix:@"\n"], @"no fields is still a valid line");
    Check([PlaybackRateCause(@"click", 0.4) isEqual:@"click"], @"a fresh cause is used");
    Check([PlaybackRateCause(@"click", 9.0) isEqual:@"unattributed"], @"a stale cause is not blamed for a later change");
    Check([PlaybackRateCause(nil, 0) isEqual:@"unattributed"], @"no cause: unattributed");
    NSDictionary *diff = PlaybackDeviceDiff(@[builtin, bose], @[builtin]);
    Check([diff[@"removed"] isEqual:@[bose[@"name"]]] && [diff[@"added"] count] == 0, @"device diff names the output that left");
    diff = PlaybackDeviceDiff(@[builtin], @[builtin, bose]);
    Check([diff[@"added"] isEqual:@[bose[@"name"]]] && [diff[@"removed"] count] == 0, @"device diff names the output that arrived");
    Check(PlaybackDeviceDiff(@[builtin], @[builtin]) == nil, @"no change: no event");

    fprintf(stderr, "OK: %d player output checks passed\n", checks);
    return 0;
}}
