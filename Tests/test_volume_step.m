#import <Foundation/Foundation.h>
#import "volume_step.h"
static int checks;
static void Check(BOOL yes, NSString *message) { checks++; if (!yes) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
static BOOL Near(double a, double b) { return fabs(a-b) < 1e-9; }
int main(void) { @autoreleasepool {
    GBVolumeStepState s = GBVolumeStepInitial();
    const double base = 1.0/16;

    // A first press moves one standard step, like the system.
    double v = GBVolumeStepPress(&s, 0.5, +1, 100.0);
    Check(Near(v, 0.5+base), @"first press up = standard step");
    v = GBVolumeStepPress(&s, v, +1, 100.3);
    Check(Near(v, 0.5+2*base), @"same direction keeps the standard step");

    // Reversing quickly halves the step, and keeps halving on each reversal.
    v = GBVolumeStepPress(&s, v, -1, 100.6);
    Check(Near(v, 0.5+2*base-base/2), @"first reversal halves the step");
    v = GBVolumeStepPress(&s, v, +1, 100.9);
    Check(Near(v, 0.5+2*base-base/2+base/4), @"second reversal quarters it");
    double before = v;
    v = GBVolumeStepPress(&s, v, +1, 101.2);
    Check(Near(v-before, base/4), @"continuing after a reversal keeps the fine step");

    // The step never goes below the floor.
    for (int i = 0; i < 20; i++) v = GBVolumeStepPress(&s, v, (i%2)?+1:-1, 101.5+0.1*i);
    Check(Near(s.step, GBVolumeStepMin), @"repeated reversals stop at the floor");
    Check(Near(GBVolumeStepMin, 1.0/128), @"floor is 1/128");

    // A pause resets to the standard step.
    double p = v;
    v = GBVolumeStepPress(&s, v, +1, 103.6 + GBVolumeStepIdleSeconds + 0.1);
    Check(Near(v-p, base), @"after the idle gap the step is standard again");

    // A slow reversal (after the gap) is not treated as fine-tuning.
    v = GBVolumeStepPress(&s, 0.5, -1, 200.0);
    v = GBVolumeStepPress(&s, v, +1, 200.0 + GBVolumeStepIdleSeconds + 0.5);
    Check(Near(v, 0.5-base+base), @"slow reversal uses the standard step");

    // Clamped to [0,1].
    s = GBVolumeStepInitial();
    Check(Near(GBVolumeStepPress(&s, 0.98, +1, 300.0), 1.0), @"clamp at full");
    s = GBVolumeStepInitial();
    Check(Near(GBVolumeStepPress(&s, 0.02, -1, 400.0), 0.0), @"clamp at zero");

    // A press at a limit that would push past it does not count as a reversal partner:
    // at 0 pressing down then up is a real reversal and still halves.
    s = GBVolumeStepInitial();
    v = GBVolumeStepPress(&s, 0.0, -1, 500.0);
    v = GBVolumeStepPress(&s, v, +1, 500.2);
    Check(Near(v, base/2), @"reversal from the bottom halves");

    // Bad clock (time going backwards) resets rather than misbehaving.
    s = GBVolumeStepInitial();
    v = GBVolumeStepPress(&s, 0.5, +1, 600.0);
    v = GBVolumeStepPress(&s, v, -1, 599.0);
    Check(Near(v, 0.5+base-base), @"time going backwards uses the standard step");

    printf("volume_step: %d checks passed\n", checks);
} return 0; }
