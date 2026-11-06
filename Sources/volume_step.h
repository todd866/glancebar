// Adaptive volume step: reversing the volume keys quickly shrinks the step, so the level
// can be set finely without holding Option+Shift. Owner request, 6 Nov 2026: "If I start
// going up and down on the volume buttons, it should make the intervals smaller."
#import <Foundation/Foundation.h>

extern const double GBVolumeStepBase;          // 1/16, the system's step
extern const double GBVolumeStepMin;           // 1/128
extern const double GBVolumeStepIdleSeconds;   // gap after which the step resets

typedef struct {
    double step;       // current step size
    int lastDirection; // +1, -1, or 0 before any press
    double lastTime;   // seconds, monotonic
} GBVolumeStepState;

GBVolumeStepState GBVolumeStepInitial(void);

// Applies one key press (direction +1 up, -1 down) at time `now` to `volume` in [0,1] and
// returns the new volume, clamped. Updates the state.
double GBVolumeStepPress(GBVolumeStepState *state, double volume, int direction, double now);
