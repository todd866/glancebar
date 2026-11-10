#import <Foundation/Foundation.h>
#import "pure.h"

static int checks;
static void Check(BOOL yes, NSString *message) {
    checks++;
    if (!yes) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static NSDictionary *Dev(NSString *uid, NSString *name) {
    return @{@"uid": uid, @"name": name, @"transport": @(GlanceAudioTransportBluetooth),
             @"outputChannels": @2, @"deviceID": @(42)};
}

int main(void) { @autoreleasepool {
    NSDictionary *builtin = Dev(@"BuiltInSpeakerDevice", @"MacBook Air Speakers");
    NSDictionary *bose = Dev(@"bose", @"Bose Flex SoundLink");

    NSDictionary *system = PlayerOutputChoice(@"", @"", @[builtin, bose], builtin[@"uid"]);
    Check([system[@"system"] boolValue] && [system[@"effectiveUID"] isEqual:builtin[@"uid"]],
          @"empty choice follows the system default");
    Check([system[@"choiceUID"] isEqual:@""], @"system choice uid stays empty");

    NSDictionary *pinned = PlayerOutputChoice(bose[@"uid"], bose[@"name"], @[builtin, bose], builtin[@"uid"]);
    Check(![pinned[@"system"] boolValue] && [pinned[@"effectiveUID"] isEqual:bose[@"uid"]],
          @"a connected device is used directly");

    NSDictionary *missing = PlayerOutputChoice(bose[@"uid"], bose[@"name"], @[builtin], builtin[@"uid"]);
    Check([missing[@"system"] boolValue] && [missing[@"choiceUID"] isEqual:bose[@"uid"]],
          @"missing device falls back to system but remembers the choice");
    Check([missing[@"note"] containsString:@"Bose Flex"], @"absent device names the remembered speaker");

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

    fprintf(stderr, "OK: %d player output checks passed\n", checks);
    return 0;
}}
