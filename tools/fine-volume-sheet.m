// Headless render of the fine-volume HUD, light and dark, at several levels.
// Build: clang -fobjc-arc -ISources Sources/volume_step.m Sources/fine_volume.m tools/fine-volume-sheet.m \
//        -framework Cocoa -framework CoreAudio -framework AudioToolbox -o /tmp/fvsheet && /tmp/fvsheet out.png
#import <Cocoa/Cocoa.h>
#import "fine_volume.h"

int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *out = argc > 1 ? @(argv[1]) : @"fine-volume-sheet.png";
    double levels[] = {0, 0.07, 0.4766, 1.0};
    BOOL mutes[] = {YES, NO, NO, NO};
    const CGFloat pad = 16, w = 236, h = 44, colW = w + 2 * pad, rowH = h + pad;
    NSView *sheet = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 2 * colW, 4 * rowH + pad)];
    sheet.wantsLayer = YES;
    NSArray *names = @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
    for (int c = 0; c < 2; c++) {
        NSAppearance *ap = [NSAppearance appearanceNamed:names[c]];
        NSView *col = [[NSView alloc] initWithFrame:NSMakeRect(c * colW, 0, colW, sheet.frame.size.height)];
        col.wantsLayer = YES;
        col.layer.backgroundColor = (c == 0 ? [NSColor colorWithWhite:0.86 alpha:1] : [NSColor colorWithWhite:0.16 alpha:1]).CGColor;
        col.appearance = ap;
        [sheet addSubview:col];
        for (int r = 0; r < 4; r++) {
            __block NSView *hud;
            double lv = levels[r]; BOOL mu = mutes[r];
            [ap performAsCurrentDrawingAppearance:^{ hud = GBFineVolumeHUDContent(lv, mu); }];
            hud.appearance = ap;
            [hud setFrameOrigin:NSMakePoint(pad, sheet.frame.size.height - (r + 1) * rowH)];
            [col addSubview:hud];
        }
    }
    NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
    [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
    printf("wrote %s\n", out.UTF8String);
} return 0; }
