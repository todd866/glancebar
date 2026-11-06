// Fine volume: the volume keys take smaller steps when you go back and forth.
// Glancebar intercepts the keys (Accessibility permission), sets the output volume through
// CoreAudio with the adaptive step from volume_step.h, and shows its own level HUD in place
// of the system one. Option+Shift (the system's quarter steps), mute, and outputs with no
// software volume pass straight through to macOS.
// Off switch: `defaults write com.iantodd.glancebar FineVolumeDisabled -bool YES`, then relaunch.
#import <Cocoa/Cocoa.h>

void GBFineVolumeStart(void);

// While a routed app is playing (audio_route.h), the volume keys turn that app's speaker,
// not the system default the rest of the Mac is held on. The provider returns that device,
// or kAudioObjectUnknown for the default output.
#import <CoreAudio/CoreAudio.h>
void GBFineVolumeSetTargetProvider(AudioObjectID (^provider)(void));

// The HUD's content, exposed so a headless render can check it (tools/fine-volume-sheet.m).
NSView *GBFineVolumeHUDContent(double volume, BOOL muted);
