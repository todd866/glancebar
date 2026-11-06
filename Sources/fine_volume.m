#import "fine_volume.h"
#import "volume_step.h"
#import <ApplicationServices/ApplicationServices.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/hidsystem/ev_keymap.h>

#pragma mark - CoreAudio

static AudioObjectID DefaultOutput(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr) return kAudioObjectUnknown;
    return dev;
}

static AudioObjectPropertyAddress MainVolumeAddr(void) {
    return (AudioObjectPropertyAddress){kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                        kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
}

// NO when the output has no settable software volume (HDMI, some USB DACs): leave those to macOS.
static BOOL ReadVolume(AudioObjectID dev, double *out) {
    AudioObjectPropertyAddress a = MainVolumeAddr();
    Boolean settable = false;
    if (dev == kAudioObjectUnknown || !AudioObjectHasProperty(dev, &a)) return NO;
    if (AudioObjectIsPropertySettable(dev, &a, &settable) != noErr || !settable) return NO;
    Float32 v = 0; UInt32 size = sizeof(v);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &v) != noErr) return NO;
    *out = v;
    return YES;
}

static BOOL WriteVolume(AudioObjectID dev, double volume) {
    AudioObjectPropertyAddress a = MainVolumeAddr();
    Float32 v = (Float32)volume;
    return AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(v), &v) == noErr;
}

static AudioObjectPropertyAddress MuteAddr(void) {
    return (AudioObjectPropertyAddress){kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
}

static BOOL IsMuted(AudioObjectID dev) {
    AudioObjectPropertyAddress a = MuteAddr();
    UInt32 m = 0, size = sizeof(m);
    if (!AudioObjectHasProperty(dev, &a)) return NO;
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &m) == noErr && m;
}

static void SetMuted(AudioObjectID dev, BOOL muted) {
    AudioObjectPropertyAddress a = MuteAddr();
    UInt32 m = muted ? 1 : 0;
    if (AudioObjectHasProperty(dev, &a)) AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(m), &m);
}

#pragma mark - HUD (same row vocabulary as the popover: symbol · gauge · value)

@interface GBFineVolumeGauge : NSView
@property double level;
@end
@implementation GBFineVolumeGauge
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect r = NSInsetRect(self.bounds, 0, (self.bounds.size.height - 8) / 2);
    [[NSColor.labelColor colorWithAlphaComponent:0.15] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4] fill];
    NSRect f = r; f.size.width = round(r.size.width * MIN(1, MAX(0, self.level)));
    if (f.size.width < 1) return;
    [NSColor.labelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:4 yRadius:4] fill];
}
@end

static NSString *SpeakerSymbol(double volume, BOOL muted) {
    if (muted || volume <= 0) return @"speaker.slash.fill";
    if (volume < 1.0/3) return @"speaker.wave.1.fill";
    if (volume < 2.0/3) return @"speaker.wave.2.fill";
    return @"speaker.wave.3.fill";
}

NSView *GBFineVolumeHUDContent(double volume, BOOL muted) {
    const CGFloat W = 236, H = 44;
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 12;
    bg.layer.masksToBounds = YES;

    NSImage *img = [NSImage imageWithSystemSymbolName:SpeakerSymbol(volume, muted) accessibilityDescription:@"Volume"];
    NSImageView *icon = [NSImageView imageViewWithImage:img];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:17 weight:NSFontWeightRegular];
    icon.contentTintColor = NSColor.labelColor;
    icon.frame = NSMakeRect(14, (H - 22) / 2, 26, 22);
    icon.imageAlignment = NSImageAlignLeft;
    [bg addSubview:icon];

    GBFineVolumeGauge *gauge = [[GBFineVolumeGauge alloc] initWithFrame:NSMakeRect(46, (H - 16) / 2, 120, 16)];
    gauge.level = muted ? 0 : volume;
    [bg addSubview:gauge];

    NSTextField *value = [NSTextField labelWithString:muted ? @"–" : [NSString stringWithFormat:@"%.0f", volume * 100]];
    value.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
    value.alignment = NSTextAlignmentRight;
    value.textColor = NSColor.labelColor;
    value.frame = NSMakeRect(172, (H - 20) / 2, 48, 20);
    value.accessibilityLabel = [NSString stringWithFormat:@"Volume %.0f percent", volume * 100];
    [bg addSubview:value];
    return bg;
}

static NSPanel *gHUD;
static NSTimer *gHUDTimer;

static void ShowHUD(double volume, BOOL muted) {
    NSView *content = GBFineVolumeHUDContent(volume, muted);
    if (!gHUD) {
        gHUD = [[NSPanel alloc] initWithContentRect:content.frame
                                          styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                            backing:NSBackingStoreBuffered defer:NO];
        gHUD.level = NSPopUpMenuWindowLevel;
        gHUD.opaque = NO;
        gHUD.backgroundColor = NSColor.clearColor;
        gHUD.hasShadow = YES;
        gHUD.ignoresMouseEvents = YES;
        gHUD.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    gHUD.contentView = content;
    // Top right of the screen with the pointer, under the menu bar: where macOS shows its own.
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(NSEvent.mouseLocation, s.frame, NO)) screen = s;
    NSRect vis = screen.visibleFrame;
    [gHUD setFrameOrigin:NSMakePoint(NSMaxX(vis) - content.frame.size.width - 12,
                                     NSMaxY(vis) - content.frame.size.height - 10)];
    gHUD.alphaValue = 1;
    [gHUD orderFrontRegardless];
    [gHUDTimer invalidate];
    gHUDTimer = [NSTimer scheduledTimerWithTimeInterval:1.4 repeats:NO block:^(NSTimer *t) {
        (void)t;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.3; gHUD.animator.alphaValue = 0; }
                            completionHandler:^{ if (gHUD.alphaValue == 0) [gHUD orderOut:nil]; }];
    }];
}

#pragma mark - Key tap

static CFMachPortRef gTap;
static GBVolumeStepState gState;
static AudioObjectID (^gTargetProvider)(void);

void GBFineVolumeSetTargetProvider(AudioObjectID (^provider)(void)) {
    gTargetProvider = [provider copy];
}

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef cg, void *info) {
    (void)proxy; (void)info;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return cg;
    }
    if (type != NX_SYSDEFINED) return cg;
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    if (!e || e.subtype != NX_SUBTYPE_AUX_CONTROL_BUTTONS) return cg;
    int key = (int)((e.data1 & 0xFFFF0000) >> 16);
    if (key != NX_KEYTYPE_SOUND_UP && key != NX_KEYTYPE_SOUND_DOWN) return cg;   // mute etc. untouched
    NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((mods & NSEventModifierFlagOption) && (mods & NSEventModifierFlagShift)) return cg;  // system quarter steps
    AudioObjectID dev = gTargetProvider ? gTargetProvider() : kAudioObjectUnknown;
    if (!dev) dev = DefaultOutput();
    double volume = 0;
    if (!ReadVolume(dev, &volume)) return cg;                                     // macOS handles it
    BOOL down = ((e.data1 & 0xFF00) >> 8) == 0xA;
    if (!down) return NULL;                                                       // swallow key-up too
    int direction = key == NX_KEYTYPE_SOUND_UP ? 1 : -1;
    BOOL muted = IsMuted(dev);
    if (muted && direction > 0) { SetMuted(dev, NO); muted = NO; }
    double next = GBVolumeStepPress(&gState, volume, direction, CFAbsoluteTimeGetCurrent());
    WriteVolume(dev, next);
    if (next <= 0 && !muted) { SetMuted(dev, YES); muted = YES; }
    dispatch_async(dispatch_get_main_queue(), ^{ ShowHUD(next, muted); });
    return NULL;
}

static BOOL InstallTap(void) {
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            CGEventMaskBit(NX_SYSDEFINED), TapCallback, NULL);
    if (!gTap) return NO;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(gTap, true);
    return YES;
}

void GBFineVolumeStart(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"FineVolumeDisabled"]) return;
    gState = GBVolumeStepInitial();
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) && InstallTap()) return;
    // Not yet allowed: macOS has shown its prompt once. Retry quietly until the switch is on.
    [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *t) {
        if (AXIsProcessTrusted() && InstallTap()) [t invalidate];
    }];
}
