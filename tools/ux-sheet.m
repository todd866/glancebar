// Design sheet: render candidate instrument designs side by side, light and dark, at the
// real popover geometry, so options are judged as pictures before anything ships.
// Usage: ux-sheet <out.png>. Each variant is a column; rows use live-shaped data.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

typedef NS_ENUM(NSInteger, PaceStyle) { PaceNone, PaceTick, PaceDeficit, PaceTrend, PaceUsed, PaceShortfallOnly };

// One lane or a pair of lanes, drawn with one of the candidate pace treatments.
@interface PaceSketchGauge : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *fractions;   // remaining, one per lane
@property (nonatomic) double pace;                            // time remaining in the window, 0…1
@property (nonatomic) PaceStyle style;
@end
@implementation PaceSketchGauge
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds;
    NSUInteger n = self.fractions.count;
    CGFloat laneH = n == 2 ? 4 : kGaugeH, gap = n == 2 ? 12 : 0;
    CGFloat blockH = n * laneH + (n - 1) * gap, y0 = NSMidY(r) - blockH / 2;
    CGFloat w = NSWidth(r);
    double elapsed = 1 - _pace;
    for (NSUInteger i = 0; i < n; i++) {
        double left = self.fractions[i].doubleValue;
        NSRect lane = NSMakeRect(0, y0 + (n - 1 - i) * (laneH + gap), w, laneH);
        CGFloat rad = laneH / 2;
        NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:rad yRadius:rad];
        [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
        [NSGraphicsContext saveGraphicsState]; [track addClip];
        if (_style == PaceUsed) {
            // Used grows left to right; the elapsed-time line moves left to right with it.
            double used = 1 - left;
            CGFloat lineX = w * elapsed;
            [AIQuotaColor(left) setFill];
            NSRectFill(NSMakeRect(0, NSMinY(lane), MIN(w * used, lineX), laneH));
            if (w * used > lineX) {
                [NSColor.systemRedColor setFill];
                NSRectFill(NSMakeRect(lineX, NSMinY(lane), w * used - lineX, laneH));
            }
        } else {
            NSColor *color = AIQuotaColor(left);
            [color setFill]; NSRectFill(NSMakeRect(0, NSMinY(lane), MAX(laneH, w * left), laneH));
            if ((_style == PaceDeficit || _style == PaceShortfallOnly) && left < _pace) {
                // The shortfall itself: track between the fill's end and where time says it should be.
                [[NSColor.systemRedColor colorWithAlphaComponent:0.35] setFill];
                NSRectFill(NSMakeRect(w * left, NSMinY(lane), w * (_pace - left), laneH));
            }
            if (_style == PaceTrend && elapsed > 0.05 && left < 1) {
                // Trend vector: where the fill will be at the reset at this window's average burn.
                double atReset = left - (1 - left) * _pace / elapsed;
                CGFloat from = w * MAX(0, atReset), to = w * left;
                [(atReset <= 0 ? NSColor.systemRedColor : NSColor.labelColor) setFill];
                NSRectFill(NSMakeRect(from, NSMidY(lane) - 1, to - from, 2));
            }
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    BOOL behind = NO;
    for (NSNumber *f in self.fractions) if (f.doubleValue < _pace) behind = YES;
    if (_style == PaceTick || _style == PaceDeficit || _style == PaceUsed || (_style == PaceShortfallOnly && behind)) {
        // A vertical bar through the lanes, like a bug on a tape.
        CGFloat x = round(w * (_style == PaceUsed ? elapsed : _pace)) - 1;
        [NSColor.labelColor setFill];
        NSRectFill(NSMakeRect(x, y0 - 3, 2, blockH + 6));
    }
}
@end

static NSView *SheetRow(NSString *name, NSArray<NSNumber *> *fractions, double pace, NSString *datum,
                        PaceStyle style, Controller *c) {
    CGFloat h = fractions.count == 2 ? kCursorRowH : kRowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, h)];
    NSImageView *logo = [NSImageView imageViewWithImage:AIProviderLogo(name, kLeadSymbol) ?: [NSImage new]];
    logo.frame = NSMakeRect(kPad, (h - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:logo];
    [row addSubview:[c text:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (h - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    CGFloat gaugeH = fractions.count == 2 ? kCursorGaugeH : 16;
    PaceSketchGauge *g = [[PaceSketchGauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - gaugeH) / 2, kGaugeW, gaugeH)];
    g.fractions = fractions; g.pace = pace; g.style = style;
    [row addSubview:g];
    if (fractions.count == 2) {
        for (NSUInteger i = 0; i < 2; i++) {
            double f = fractions[i].doubleValue;
            [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", f * 100]
                               font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                              color:AIQuotaColor(f) at:NSMakeRect(kValueX, i == 0 ? h / 2 : 0, kValueW, h / 2)
                              align:NSTextAlignmentRight]];
        }
    } else {
        double f = fractions[0].doubleValue;
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", f * 100]
                           font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                          color:AIQuotaColor(f) at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH)
                          align:NSTextAlignmentRight]];
    }
    [row addSubview:[c text:datum font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                      color:NSColor.secondaryLabelColor at:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH)
                      align:NSTextAlignmentLeft]];
    return row;
}

static NSView *SheetPanel(NSString *title, PaceStyle style, NSAppearanceName look, Controller *c) {
    // Live readings at 08:08 Thu 8 Oct, plus one on-track row for contrast.
    NSArray *rows = @[
        @[@"Claude", @[@0.45], @0.79, @"resets Tue"],
        @[@"Codex", @[@0.52], @0.88, @"resets Wed"],
        @[@"Cursor", @[@0.17, @0.41], @0.86, @"resets 3 Nov"],
        @[@"Claude", @[@0.70], @0.40, @"resets Tue"],   // on track: Saturday at the same total
    ];
    CGFloat titleH = 26, y = 8, height = titleH + 8;
    for (NSArray *r in rows) height += [r[1] count] == 2 ? kCursorRowH : kRowH;
    height += 18;
    PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, height)];
    panel.appearance = [NSAppearance appearanceNamed:look];
    NSTextField *caption = [c text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightBold]
                             color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, kW - 2 * kPad, 16)
                             align:NSTextAlignmentLeft];
    [panel addSubview:caption];
    y += titleH;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray *r = rows[i];
        if (i == 3) {   // separate the contrast example
            NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y + 4, kW - 2 * kPad, 1)];
            rule.boxType = NSBoxSeparator; [panel addSubview:rule]; y += 10;
        }
        NSView *row = SheetRow(r[0], r[1], [r[2] doubleValue], r[3], style, c);
        NSRect f = row.frame; f.origin.y = y; row.frame = f;
        [panel addSubview:row];
        y += NSHeight(f);
    }
    NSRect pf = panel.frame; pf.size.height = y + 8; panel.frame = pf;
    return panel;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc < 2) { fprintf(stderr, "usage: ux-sheet out.png\n"); return 2; }
        Controller *c = [Controller new];
        NSArray *variants = @[@[@"A  today (no pace)", @(PaceNone)],
                              @[@"B  time bug: vertical bar at time left", @(PaceTick)],
                              @[@"C  bug + shortfall shaded red", @(PaceDeficit)],
                              @[@"F  shortfall only while behind; nothing when on track", @(PaceShortfallOnly)],
                              @[@"E  used, filling left to right", @(PaceUsed)]];
        CGFloat gap = 16, colW = kW;
        NSMutableArray *panels = [NSMutableArray array];
        CGFloat rowH = 0;
        for (NSArray *v in variants) {
            NSView *light = SheetPanel(v[0], [v[1] integerValue], NSAppearanceNameAqua, c);
            NSView *dark = SheetPanel(v[0], [v[1] integerValue], NSAppearanceNameDarkAqua, c);
            [panels addObject:@[light, dark]];
            rowH = MAX(rowH, NSHeight(light.frame));
        }
        CGFloat sheetW = gap + 2 * (colW + gap), sheetH = gap + variants.count * (rowH + gap);
        FlippedView *sheet = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, sheetW, sheetH)];
        sheet.wantsLayer = YES;
        sheet.layer.backgroundColor = [NSColor colorWithWhite:0.55 alpha:1].CGColor;
        for (NSUInteger i = 0; i < panels.count; i++) {
            for (NSUInteger j = 0; j < 2; j++) {
                NSView *p = panels[i][j];
                p.frame = NSMakeRect(gap + j * (colW + gap), gap + i * (rowH + gap), colW, rowH);
                [sheet addSubview:p];
            }
        }
        NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
        [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
        return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                   writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 1;
    }
}
