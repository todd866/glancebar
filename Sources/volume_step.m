#import "volume_step.h"

const double GBVolumeStepBase = 1.0/16;
const double GBVolumeStepMin = 1.0/128;
const double GBVolumeStepIdleSeconds = 1.5;

GBVolumeStepState GBVolumeStepInitial(void) {
    GBVolumeStepState s = {GBVolumeStepBase, 0, 0};
    return s;
}

double GBVolumeStepPress(GBVolumeStepState *s, double volume, int direction, double now) {
    if (direction == 0) return volume;
    direction = direction > 0 ? 1 : -1;
    double gap = now - s->lastTime;
    BOOL recent = s->lastDirection != 0 && gap >= 0 && gap <= GBVolumeStepIdleSeconds;
    if (!recent) {
        s->step = GBVolumeStepBase;                      // a fresh adjustment
    } else if (direction != s->lastDirection) {
        s->step = MAX(s->step / 2, GBVolumeStepMin);     // reversing: home in
    }                                                    // same direction: keep the step
    s->lastDirection = direction;
    s->lastTime = now;
    double v = volume + direction * s->step;
    return MIN(1.0, MAX(0.0, v));
}
