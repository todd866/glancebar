#import "pure.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static void check(int ok, const char *msg) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", msg);
        failures++;
    }
}

int main(int argc, const char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        const char *good[] = {"Glancebar", "--play", "dance"};
        GBControlCLIOutcome o = GBControlParseArgs(3, good);
        check(o.kind == 1 && [o.command isEqual:@"play dance"], "cli: play dance");

        const char *resume[] = {"Glancebar", "--play"};
        o = GBControlParseArgs(2, resume);
        check(o.kind == 1 && [o.command isEqual:@"play"], "cli: bare play");

        const char *bad[] = {"Glancebar", "--play", "jazz"};
        o = GBControlParseArgs(3, bad);
        check(o.kind == 2, "cli: bad kind → exit 2");

        const char *kindOnly[] = {"Glancebar", "--kind"};
        o = GBControlParseArgs(2, kindOnly);
        check(o.kind == 3, "cli: --kind print mode");

        const char *none[] = {"Glancebar", "--dump"};
        o = GBControlParseArgs(2, none);
        check(o.kind == 0, "cli: non-control passes through");

        const char *mixed[] = {"Glancebar", "--play", "dance", "--pause"};
        o = GBControlParseArgs(4, mixed);
        check(o.kind == 2, "cli: extra args after control → exit 2");

        const char *pause[] = {"Glancebar", "--pause"};
        o = GBControlParseArgs(2, pause);
        check(o.kind == 1 && [o.command isEqual:@"pause"], "cli: pause");

        const char *radioMood[] = {"Glancebar", "--play", "radio:station:kexp"};
        o = GBControlParseArgs(3, radioMood);
        check(o.kind == 1 && [o.command isEqual:@"play radio:station:kexp"], "cli: play radio:station:kexp");

        const char *badRadio[] = {"Glancebar", "--play", "radio:"};
        o = GBControlParseArgs(3, badRadio);
        check(o.kind == 2, "cli: bare radio: → exit 2");

        const char *prev[] = {"Glancebar", "--prev"};
        o = GBControlParseArgs(2, prev);
        check(o.kind == 1 && [o.command isEqual:@"prev"], "cli: prev");

        const char *like[] = {"Glancebar", "--like"};
        o = GBControlParseArgs(2, like);
        check(o.kind == 1 && [o.command isEqual:@"like"], "cli: like");

        const char *dislike[] = {"Glancebar", "--dislike"};
        o = GBControlParseArgs(2, dislike);
        check(o.kind == 1 && [o.command isEqual:@"dislike"], "cli: dislike");
    }
    if (failures) {
        fprintf(stderr, "%d control CLI test(s) failed\n", failures);
        return 1;
    }
    printf("OK: control CLI parser\n");
    return 0;
}