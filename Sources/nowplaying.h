#import <Foundation/Foundation.h>

// MediaPlayer's headers mark keyed subscripting unavailable on macOS, which breaks every
// NSDictionary lookup in a file that imports them. These wrappers keep that import here.
void GlanceNowPlayingSet(NSString *title, NSString *artist, double rate, double elapsed);
void GlanceNowPlayingClear(void);
void GlanceRemoteCommandsEnable(id target);
void GlanceRemoteCommandsDisable(id target);
