#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import "pure.h"

// Decode a local file and compute integrated LUFS (NAN when gated/silent) and sample peak dBFS.
BOOL GBMeasureLoudnessAtURL(NSURL *url, double *lufsOut, double *peakDBFSOut, NSError **errorOut);

// The level control on one player item. The tap's state is reference counted: the audio tap holds
// one reference (dropped in its finalize callback) and this handle the other (dropped in dealloc).
// The item keeps the handle alive, so the render thread never sees freed state, whatever order the
// player, the item and the controller let go in.
@interface GBLoudnessHandle : NSObject
- (void)setTargetLinear:(float)gainLinear;   // ramps over 2 s; any thread
@end

// Attach the level tap to the item's first audio track at gainLinear. Nil when the item has no
// audio track or the tap could not be made (the item then plays at unity).
GBLoudnessHandle *GBLoudnessAttachToPlayerItem(AVPlayerItem *item, float gainLinear);
GBLoudnessHandle *GBLoudnessHandleForItem(AVPlayerItem *item);
