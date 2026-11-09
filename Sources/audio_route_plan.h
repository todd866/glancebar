// Per-app audio routing: the pure part. Owner, 6 Nov 2026: "when I play music on an external
// speaker I should *only* be sending the music to that speaker, not anything else."
//
// A rule says "this app's audio goes to that output". While any rule has its speaker
// connected, everything else (the system default and alert sounds) is held on the Mac's
// own speakers, and the previous defaults are put back when the rule stops applying.
// The Core Audio side (process taps, aggregate devices) lives in audio_route.m; this file
// only decides, so it can be tested without audio hardware.
//
// Device dictionaries are the app's usual shape: uid, name, transport (GlanceAudioTransport),
// outputChannels. Rule dictionaries: bundleID, target (a device UID, or "" for automatic),
// enabled.
#import <Foundation/Foundation.h>

extern NSString *const GBRouteDefaultsKey;          // NSUserDefaults: the rule array
extern NSString *const GBRouteSavedDefaultsKey;     // NSUserDefaults: defaults to restore
extern NSString *const GBRouteAggregateUIDPrefix;   // every aggregate Glancebar creates
extern NSString *const GBRouteTapNamePrefix;        // every tap Glancebar creates

// The apps that get a rule without being asked: Music, and Spotify when it is installed.
NSArray<NSString *> *GBRouteDefaultApps(void);

// Cleans a stored rule array (anything malformed is dropped, one rule per app) and appends
// a default rule (automatic target, on) for each default app that is installed and has none.
NSArray<NSDictionary *> *GBRouteRulesNormalized(id stored, NSArray<NSString *> *installedBundleIDs);

// Returns rules with the one for bundleID replaced by applying the given changes.
NSArray<NSDictionary *> *GBRouteRulesUpdating(NSArray<NSDictionary *> *rules, NSString *bundleID,
                                              NSDictionary *changes);

// The Mac's own speakers: a built-in output, preferring one named "Speakers".
NSString *GBRouteLocalSpeakerUID(NSArray<NSDictionary *> *devices);

// Where a rule sends its app now, or nil when that output is not connected. Automatic picks
// the first external output (Bluetooth, then USB, then display); never the built-in
// speakers, headphones/headsets, a virtual device, or one of Glancebar's own aggregates.
// An explicitly selected headphone target is still respected. (GBRoutePlan also drops
// automatic routes while headphones are the current output.)
NSString *GBRouteResolveTarget(NSDictionary *rule, NSArray<NSDictionary *> *devices);

// Whether a process with this bundle ID belongs to the app (the app or one of its helpers).
BOOL GBRouteBundleMatches(NSString *processBundleID, NSString *appBundleID);

// The routing plan: routes is [{bundleID, target}] for every enabled rule whose output is
// connected and is not the local speakers; hold is the local-speaker UID the system default
// should sit on while any route applies, or nil. defaultOutputUID is the output the Mac is
// playing on now (nil when unknown): while that is headphones the listener has chosen
// personal listening, so automatic rules stand down and the app plays there with everything
// else. (10 Nov 2026: Music was tapped away to a docked monitor while the Bose headphones
// were the output, so pressing play was silent.) An explicitly chosen target still applies.
NSDictionary *GBRoutePlan(NSArray<NSDictionary *> *rules, NSArray<NSDictionary *> *devices,
                          NSString *defaultOutputUID);

// One step of holding and restoring the system defaults.
//   hold:   the plan's hold UID, or nil
//   saved:  {output, system, hold} remembered when the hold began, or nil
//   currentOutput/currentSystem: the defaults now
//   devicesChanged: the device list just changed (a speaker arrived and the system or the
//                   app switched to it); the hold is re-asserted only then and when it begins,
//                   so a deliberate choice in between is not fought.
// Returns {setOutput?, setSystem?, saved (NSNull when cleared)}.
NSDictionary *GBRouteDefaultsStep(NSString *hold, NSDictionary *saved,
                                  NSString *currentOutput, NSString *currentSystem,
                                  BOOL devicesChanged, NSArray<NSDictionary *> *devices);

// Copies tapped audio to the output buffers. Both sides are Float32, interleaved or not;
// channel i of the output takes input channel i (a mono input fills every output channel,
// extra output channels beyond a stereo input are silent). Frames past the shorter side are
// zeroed. Returns the peak absolute sample copied.
#import <CoreAudio/CoreAudioTypes.h>
float GBRouteCopyAudio(const AudioBufferList *input, AudioBufferList *output);
