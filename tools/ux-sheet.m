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

static const CGFloat kCursorRowH = 32, kCursorGaugeH = 20;   // the retired two-lane geometry, for comparison sheets

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

// Lays variant panels out as a grid: one row per variant, light on the left, dark on the right.
static BOOL WriteSheet(NSArray<NSView *(^)(NSAppearanceName)> *builders, NSString *path) {
    CGFloat gap = 16, colW = 0, rowH = 0;
    NSMutableArray *panels = [NSMutableArray array];
    for (NSView *(^build)(NSAppearanceName) in builders) {
        NSView *light = build(NSAppearanceNameAqua), *dark = build(NSAppearanceNameDarkAqua);
        [panels addObject:@[light, dark]];
        rowH = MAX(rowH, NSHeight(light.frame));
        colW = MAX(colW, NSWidth(light.frame));
    }
    FlippedView *sheet = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, gap + 2 * (colW + gap), gap + panels.count * (rowH + gap))];
    sheet.wantsLayer = YES;
    sheet.layer.backgroundColor = [NSColor colorWithWhite:0.55 alpha:1].CGColor;
    for (NSUInteger i = 0; i < panels.count; i++)
        for (NSUInteger j = 0; j < 2; j++) {
            NSView *p = panels[i][j];
            p.frame = NSMakeRect(gap + j * (colW + gap), gap + i * (rowH + gap), colW, rowH);
            [sheet addSubview:p];
        }
    NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
    [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// A titled panel of rows on the popover's own background.
static NSView *TitledPanel(NSString *title, NSArray<NSView *> *rows, NSAppearanceName look, Controller *c) {
    CGFloat y = 8;
    PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, 400)];
    panel.appearance = [NSAppearance appearanceNamed:look];
    [panel addSubview:[c text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightBold] color:NSColor.secondaryLabelColor
                           at:NSMakeRect(kPad, y, kW - 2 * kPad, 16) align:NSTextAlignmentLeft]];
    y += 26;
    for (NSView *row in rows) { NSRect f = row.frame; f.origin.y = y; row.frame = f; [panel addSubview:row]; y += NSHeight(f); }
    NSRect pf = panel.frame; pf.size.height = y + 8; panel.frame = pf;
    return panel;
}

#pragma mark - Power flow sheet

typedef NS_ENUM(NSInteger, FlowStyle) { FlowText, FlowBalance, FlowSplit, FlowSplitTime, FlowLane };

// Where the Mac's power comes from, on one bar: grey is what the charger covers, orange what
// the battery covers, green the charger's surplus going into the battery. Scale is fixed.
@interface FlowSketch : NSView
@property (nonatomic) double inW, loadW, scale;
@property (nonatomic) BOOL balance;   // centre-zero: battery in (green, right) vs out (orange, left)
@end
@implementation FlowSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat h = NSHeight(r), rad = h / 2, w = NSWidth(r);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    double batt = _inW - _loadW;   // + into the battery, − out of it
    if (_balance) {
        CGFloat mid = w / 2, len = MIN(fabs(batt) / _scale, 1) * mid;
        [(batt >= 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor) setFill];
        NSRectFill(batt >= 0 ? NSMakeRect(mid, 0, len, h) : NSMakeRect(mid - len, 0, len, h));
        [NSGraphicsContext restoreGraphicsState];
        [NSColor.labelColor setFill]; NSRectFill(NSMakeRect(mid - 0.75, -2, 1.5, h + 4));
        return;
    }
    __block CGFloat x = 0;
    void (^seg)(double, NSColor *) = ^(double watts, NSColor *color) {
        if (watts <= 0) return;
        CGFloat len = MIN(watts / self->_scale * w, w - x);
        [color setFill]; NSRectFill(NSMakeRect(x, 0, MAX(len - 1, 0.5), h));
        x += len;
    };
    seg(MIN(_inW, _loadW), NSColor.systemGrayColor);               // the Mac, on the charger
    if (batt < 0) seg(-batt, NSColor.systemOrangeColor);            // the Mac, on the battery
    else seg(batt, NSColor.systemGreenColor);                       // surplus into the battery
    [NSGraphicsContext restoreGraphicsState];
}
@end

static NSView *PowerRow(Controller *c, BatteryState b, NSString *time, FlowStyle style) {
    [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    NSImage *glyph = [c liveBatteryGlyph];
    NSImageView *iv = [NSImageView imageViewWithImage:glyph];
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (glyph.template) iv.contentTintColor = PowerFlowColor(b, NSColor.labelColor);
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:iv];
    [row addSubview:[c text:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    double inW = b.systemPowerIn_mW / 1000.0, loadW = b.systemLoad_mW / 1000.0, battW = inW - loadW;
    if (style == FlowLane) {
        // Charge on the top lane, power flow on the lower lane: one instrument, two readings.
        Gauge *charge = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, kRowH / 2 + 2, kGaugeW, 6)];
        charge.fraction = b.percent / 100.0; charge.color = BattBarColor(b.percent); charge.markerFraction = 0.8;
        [row addSubview:charge];
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kGaugeX, kRowH / 2 - 7, kGaugeW, 4)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = 30;
        [row addSubview:flow];
    } else {
        Gauge *charge = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
        charge.fraction = b.percent / 100.0; charge.color = BattBarColor(b.percent); charge.markerFraction = 0.8;
        [row addSubview:charge];
    }
    [row addSubview:[c text:[NSString stringWithFormat:@"%d%%", b.percent]
                       font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:BattBarColor(b.percent) at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH)
                      align:NSTextAlignmentRight]];
    NSFont *datumFont = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
    NSColor *flowColor = battW > 0.3 ? NSColor.systemGreenColor : battW < -0.5 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    if (style == FlowText) {
        NSString *w = fabs(battW) < 0.3 ? @"held 80%" : [NSString stringWithFormat:@"%+.0f W%@", battW, time ? [@" · " stringByAppendingString:time] : @""];
        [row addSubview:[c text:w font:datumFont color:flowColor at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    } else if (style == FlowBalance || style == FlowSplit) {
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kDatumX, (kRowH - kGaugeH) / 2, kDatumW - 6, kGaugeH)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = style == FlowBalance ? 20 : 30; flow.balance = style == FlowBalance;
        [row addSubview:flow];
    } else if (style == FlowSplitTime) {
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kDatumX, (kRowH - kGaugeH) / 2, 50, kGaugeH)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = 30;
        [row addSubview:flow];
        if (time) [row addSubview:[c text:time font:datumFont color:flowColor
                                         at:NSMakeRect(kDatumX + 54, (kRowH - kDatumH) / 2, kDatumW - 54, kDatumH) align:NSTextAlignmentLeft]];
    } else if (style == FlowLane && time) {
        [row addSubview:[c text:time font:datumFont color:flowColor at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    }
    return row;
}

static BOOL PowerSheet(NSString *path) {
    Controller *c = [Controller new];
    BatteryState base = {.valid=YES, .rawCurrent_mAh=2745, .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000,
                         .cycleCount=120, .adapterWatts=30};
    // in W, load W, percent, AC, charging, time — battery W follows from in − load.
    NSArray *states = @[@[@26, @9, @42, @YES, @YES, @"0:51"],      // charging hard
                        @[@9, @9, @80, @YES, @NO, [NSNull null]],  // held at the limit
                        @[@4, @11.9, @78, @YES, @NO, [NSNull null]],  // plugged, battery carrying the rest (now)
                        @[@0, @13.2, @63, @NO, @NO, @"3:12"]];     // on battery
    NSArray *variants = @[@[@"A  today: words", @(FlowText)],
                          @[@"B  centre-zero: battery in → green, out ← orange", @(FlowBalance)],
                          @[@"C  where the power comes from: charger grey, battery orange, surplus green", @(FlowSplit)],
                          @[@"D  C plus time", @(FlowSplitTime)],
                          @[@"E  flow as a second lane under charge, time beside", @(FlowLane)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) {
                BatteryState b = base;
                b.systemPowerIn_mW = (long)([st[0] doubleValue] * 1000); b.systemLoad_mW = (long)([st[1] doubleValue] * 1000);
                b.percent = [st[2] intValue]; b.acConnected = [st[3] boolValue]; b.isCharging = [st[4] boolValue];
                b.amperage_mA = (long)(([st[0] doubleValue] - [st[1] doubleValue]) * 1000 / 12.0);
                [rows addObject:PowerRow(c, b, st[5] == [NSNull null] ? nil : st[5], [v[1] integerValue])];
            }
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - System row sheet

typedef NS_ENUM(NSInteger, SysStyle) { SysToday, SysMemBar, SysMemBarQuiet, SysLanes, SysInnerLine, SysInnerQuiet };

// Memory as a mini bar in the datum column: fill = memory in use, tinted by the kernel's
// pressure verdict; swap, when there is any, is a red overflow at the right end.
@interface MemSketch : NSView
@property (nonatomic) double used, swapFrac;
@property (nonatomic, strong) NSColor *color;
@end
@implementation MemSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat h = NSHeight(r), w = NSWidth(r);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:h / 2 yRadius:h / 2];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    CGFloat swapW = MIN(_swapFrac, 0.4) * w;
    [_color setFill]; NSRectFill(NSMakeRect(0, 0, MIN(_used, 1) * (w - swapW), h));
    if (swapW > 0) { [NSColor.systemRedColor setFill]; NSRectFill(NSMakeRect(w - swapW, 0, swapW, h)); }
    [NSGraphicsContext restoreGraphicsState];
}
@end

static NSView *SystemRow(Controller *c, double cpu, int pressure, double memUsed, double swapGB, SysStyle style) {
    SystemState sys = {.cpuValid=YES, .memValid=YES, .swapValid=YES, .cpu=cpu, .memTotal=34359738368,
        .memUsed=(uint64_t)(memUsed * 34359738368.0), .memAvailable=(uint64_t)((1 - memUsed) * 34359738368.0),
        .swapUsed=(uint64_t)(swapGB * 1073741824.0), .kernPressure=pressure};
    [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, style == SysLanes ? kCursorRowH : kRowH)];
    CGFloat h = NSHeight(row.frame);
    NSString *level = MemoryPressureLevel(sys);
    [c instrumentSymbol:@"cpu" tint:SystemPressureColor(SystemPressureLevel(sys)) identifier:@"s" in:row];
    [c instrumentName:@"System" identifier:@"n" in:row];
    if (style == SysToday) {
        [c addSystemInstrumentTo:row gauge:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)
                           value:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH)
                           datum:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH) stem:@"x" tip:@""];
        return row;
    }
    NSColor *memColor = SystemPressureColor(level);
    if (style == SysLanes) {
        // CPU above, memory below, as one instrument; both values in the value column.
        Gauge *g1 = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, h / 2 + 4, kGaugeW, 4)];
        g1.fraction = cpu; g1.color = CPUColor(cpu); [row addSubview:g1];
        MemSketch *m = [[MemSketch alloc] initWithFrame:NSMakeRect(kGaugeX, h / 2 - 8, kGaugeW, 4)];
        m.used = memUsed; m.swapFrac = swapGB / 16.0; m.color = memColor; [row addSubview:m];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                          color:CPUColor(cpu) at:NSMakeRect(kValueX, h / 2, kValueW, h / 2) align:NSTextAlignmentRight]];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", memUsed * 100] font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                          color:memColor at:NSMakeRect(kValueX, 0, kValueW, h / 2) align:NSTextAlignmentRight]];
        return row;
    }
    if (style == SysInnerLine || style == SysInnerQuiet) {
        // CPU is the bar; memory in use is the thin line inside it, as Cursor's API pool is.
        // Under memory pressure the line takes the pressure colour.
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - 10) / 2, kGaugeW, 10)];
        g.fraction = cpu; g.color = CPUColor(cpu);
        if (style == SysInnerLine || pressure > 1) g.innerFraction = memUsed;
        [row addSubview:g];
        if (pressure > 1) {   // recolour the line: draw over it
            NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(kGaugeX + 2, h / 2 - 1, MAX(2, (kGaugeW - 2) * memUsed - 2), 2)];
            line.wantsLayer = YES; line.layer.backgroundColor = memColor.CGColor; [row addSubview:line];
        }
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                          color:CPUColor(cpu) at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
        return row;
    }
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)];
    g.fraction = cpu; g.color = CPUColor(cpu); [row addSubview:g];
    [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:CPUColor(cpu) at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    if (style == SysMemBarQuiet && pressure <= 1 && swapGB == 0) return row;   // silent while memory is fine
    MemSketch *m = [[MemSketch alloc] initWithFrame:NSMakeRect(kDatumX, (h - kGaugeH) / 2, 50, kGaugeH)];
    m.used = memUsed; m.swapFrac = swapGB / 16.0; m.color = memColor;
    [row addSubview:m];
    return row;
}

static BOOL SystemSheet(NSString *path) {
    Controller *c = [Controller new];
    // cpu, kernel pressure (1 low, 2 medium, 4 high), memory in use, swap GB
    NSArray *states = @[@[@0.24, @1, @0.50, @0], @[@0.54, @1, @0.72, @0.6], @[@0.70, @2, @0.88, @3], @[@1.0, @4, @0.97, @9]];
    NSArray *variants = @[@[@"G  memory = line inside the CPU bar (Cursor's language); pressure tints it", @(SysInnerLine)],
                          @[@"H  G, but the line appears only under memory pressure", @(SysInnerQuiet)],
                          @[@"C  memory as a mini bar in the datum, only under pressure", @(SysMemBarQuiet)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states)
                [rows addObject:SystemRow(c, [st[0] doubleValue], [st[1] intValue], [st[2] doubleValue], [st[3] doubleValue], [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Battery trend sheet (quantity + flow on one bar)

typedef NS_ENUM(NSInteger, TrendStyle) { TrendGhost, TrendVector, TrendChevrons, TrendGhostChevrons };

// The charge bar carries its own flow: where the level will be in an hour at this rate.
@interface TrendSketch : NSView
@property (nonatomic) double level, perHour, limit;   // fractions; perHour signed
@property (nonatomic) TrendStyle style;
@end
@implementation TrendSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat w = NSWidth(r), h = NSHeight(r), rad = h / 2;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    double target = _perHour >= 0 ? MIN(_level + _perHour, _limit > 0 ? MAX(_limit, _level) : 1) : MAX(0, _level + _perHour);
    BOOL charging = _perHour > 0.005, draining = _perHour < -0.005;
    NSColor *base = BattBarColor((int)lround(_level * 100));
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    BOOL ghost = _style == TrendGhost || _style == TrendGhostChevrons;
    if (ghost && draining) {
        // What the next hour takes: the end of the fill turns orange.
        [base setFill]; NSRectFill(NSMakeRect(0, 0, w * target, h));
        [NSColor.systemOrangeColor setFill]; NSRectFill(NSMakeRect(w * target, 0, w * (_level - target), h));
    } else {
        [base setFill]; NSRectFill(NSMakeRect(0, 0, MAX(h, w * _level), h));
        if (ghost && charging) {   // what the next hour adds: a pale extension
            [[NSColor.systemGreenColor colorWithAlphaComponent:0.35] setFill];
            NSRectFill(NSMakeRect(w * _level, 0, w * (target - _level), h));
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    if (_limit > 0) { [NSColor.labelColor setFill]; NSRectFill(NSMakeRect(w * _limit - 0.75, 0, 1.5, h)); }
    if (_style == TrendVector && (charging || draining)) {
        // Airspeed-tape trend vector: a line from the level to where it is heading, with a head.
        CGFloat from = w * _level, to = w * target, y = h + 3;
        NSColor *ink = charging ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        [ink setFill]; NSRectFill(NSMakeRect(MIN(from, to), y - 1, fabs(to - from), 2));
        NSBezierPath *head = [NSBezierPath bezierPath];
        CGFloat dir = charging ? 1 : -1;
        [head moveToPoint:NSMakePoint(to + dir * 4, y)];
        [head lineToPoint:NSMakePoint(to - dir * 1, y + 3.5)];
        [head lineToPoint:NSMakePoint(to - dir * 1, y - 3.5)];
        [head closePath]; [head fill];
    }
    if ((_style == TrendChevrons || _style == TrendGhostChevrons) && (charging || draining)) {
        // Chevrons ride on the bar at the level, pointing the way it moves; more for faster.
        int n = fabs(_perHour) > 0.30 ? 3 : fabs(_perHour) > 0.12 ? 2 : 1;
        NSColor *ink = charging ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        CGFloat x0 = w * _level + (charging ? 4 : -4), step = 6;
        NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 1.8; p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
        for (int i = 0; i < n; i++) {
            CGFloat x = charging ? x0 + i * step : x0 - i * step, d = charging ? 3 : -3;
            [p moveToPoint:NSMakePoint(x, h / 2 + 4)]; [p lineToPoint:NSMakePoint(x + d, h / 2)]; [p lineToPoint:NSMakePoint(x, h / 2 - 4)];
        }
        [(ghost ? NSColor.labelColor : ink) setStroke]; [p stroke];
    }
}
@end

static NSView *TrendRow(Controller *c, int pct, double watts, BOOL ac, NSString *time, TrendStyle style) {
    BatteryState b = {.valid=YES, .percent=pct, .acConnected=ac, .isCharging=watts > 0.3, .rawCurrent_mAh=4500 * pct / 100,
        .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000, .amperage_mA=(long)(watts * 1000 / 12.0),
        .systemPowerIn_mW=ac ? (long)((9 + MAX(watts, -5)) * 1000) : 0, .systemLoad_mW=9000, .adapterWatts=ac ? 30 : 0};
    [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    NSImage *glyph = [c liveBatteryGlyph];
    NSImageView *iv = [NSImageView imageViewWithImage:glyph];
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (glyph.template) iv.contentTintColor = PowerFlowColor(b, NSColor.labelColor);
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:iv];
    [row addSubview:[c text:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    TrendSketch *t = [[TrendSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
    t.level = pct / 100.0; t.perHour = watts / 54.0; t.limit = ac ? 0.8 : 0; t.style = style;
    [row addSubview:t];
    [row addSubview:[c text:[NSString stringWithFormat:@"%d%%", pct] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:BattBarColor(pct) at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    if (time) [row addSubview:[c text:time font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                color:watts > 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor
                                   at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    return row;
}

static BOOL TrendSheet(NSString *path) {
    Controller *c = [Controller new];
    // percent, battery watts (+ in), on AC, time
    NSArray *states = @[@[@42, @17, @YES, @"0:51"], @[@80, @0, @YES, [NSNull null]], @[@78, @-8, @YES, [NSNull null]],
                        @[@63, @-13, @NO, @"2:30"], @[@30, @-29, @NO, @"0:11"]];
    NSArray *variants = @[@[@"A  ghost: next hour shown on the bar (pale = coming, orange = going)", @(TrendGhost)],
                          @[@"B  trend vector: arrow from the level to where it'll be in an hour", @(TrendVector)],
                          @[@"C  chevrons at the level: direction, and 1-3 for rate", @(TrendChevrons)],
                          @[@"D  ghost + chevrons", @(TrendGhostChevrons)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states)
                [rows addObject:TrendRow(c, [st[0] intValue], [st[1] doubleValue], [st[2] boolValue],
                                         st[3] == [NSNull null] ? nil : st[3], [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Net-drain sheet (plugged in, charger weaker than the load)

typedef NS_ENUM(NSInteger, NetDrainStyle) { NetDrainToday, NetDrainBoltTime, NetDrainChargerRow, NetDrainInDatum };

static NSTextField *SheetDatum(Controller *c, NSString *s, NSColor *color) {
    return [c text:s font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular] color:color
                at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft];
}

// in/load watts; battery watts = in − load. rating = charger watts (0 = on battery).
static NSArray<NSView *> *NetDrainRows(Controller *c, int pct, double inW, double loadW, long rating, NetDrainStyle style) {
    BOOL ac = rating > 0;
    double bw = ac ? inW - loadW : -loadW;
    BatteryState b = {.valid=YES, .percent=pct, .acConnected=ac, .isCharging=bw > 0.3, .rawCurrent_mAh=4232 * pct / 100,
        .rawMax_mAh=4232, .designCap_mAh=4629, .voltage_mV=11855, .amperage_mA=(long)(bw * 1e6 / 11855),
        .systemPowerIn_mW=ac ? (long)(inW * 1000) : 0, .systemLoad_mW=(long)(loadW * 1000), .adapterWatts=rating};
    [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    NSImage *glyph = [c liveBatteryGlyph];
    NSColor *tint = PowerFlowColor(b, NSColor.labelColor);
    BOOL weak = ac && bw < -0.5 && inW >= 1;   // something arrives, but less than the Mac uses
    if (weak && style != NetDrainToday) {
        NSImage *plain = [NSImage imageWithSystemSymbolName:BatterySymbolName(pct, NO) accessibilityDescription:nil];
        plain = [plain imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular]];
        tint = NSColor.systemOrangeColor;
        glyph = BatteryGlyphWithBadge(plain, PowerFlowCharging, tint);
    }
    NSImageView *iv = [NSImageView imageViewWithImage:glyph];
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (glyph.template) iv.contentTintColor = tint;
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:iv];
    [row addSubview:[c text:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    TrendSketch *t = [[TrendSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
    t.level = pct / 100.0; t.perHour = bw / 50.0; t.limit = 0; t.style = TrendVector;
    [row addSubview:t];
    [row addSubview:[c text:[NSString stringWithFormat:@"%d%%", pct] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:BattBarColor(pct) at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    NSColor *rateInk = bw > 0.3 ? NSColor.systemGreenColor : bw < -0.3 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    NSString *rate = FormatSignedWatts(bw);
    int to20 = bw < -0.5 && pct > 20 ? (int)lround((pct - 20) / 100.0 * 50.2 / -bw * 60) : -1;
    NSString *datum = rate;
    if (style == NetDrainBoltTime || style == NetDrainChargerRow) {
        if (to20 >= 0) datum = [NSString stringWithFormat:@"%@ · %@", rate, FmtDuration(to20)];
    } else if (style == NetDrainInDatum && ac) {
        datum = [NSString stringWithFormat:@"%.0f in · %@", inW, rate];
    } else if (style == NetDrainInDatum && to20 >= 0) {
        datum = [NSString stringWithFormat:@"%@ · %@", rate, FmtDuration(to20)];
    }
    [row addSubview:SheetDatum(c, datum, rateInk)];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:row];
    if (style == NetDrainChargerRow && ac) {
        // A second reading is its own plain row: what the charger delivers, of its rating.
        NSView *sub = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
        [sub addSubview:[c text:@"Charger" font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor
                             at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
        TrendSketch *bar = [[TrendSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
        double share = loadW > 0 ? MIN(1, inW / loadW) : 1;   // how much of the Mac's draw the charger covers
        bar.level = share; bar.perHour = 0; bar.style = TrendVector;
        [sub addSubview:bar];
        [sub addSubview:[c text:[NSString stringWithFormat:@"%.0f W", inW] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                          color:inW < 1 ? NSColor.systemYellowColor : NSColor.labelColor
                             at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
        [sub addSubview:SheetDatum(c, [NSString stringWithFormat:@"Mac %.0f W", loadW], NSColor.secondaryLabelColor)];
        [rows addObject:sub];
    }
    return rows;
}

static BOOL NetDrainSheet(NSString *path) {
    Controller *c = [Controller new];
    // percent, charger in W, Mac load W, charger rating (0 = unplugged)
    NSArray *states = @[@[@68, @6, @16, @8], @[@68, @0, @12, @8], @[@42, @45, @15, @70], @[@63, @0, @13, @0]];
    NSArray *variants = @[@[@"A  today: amber pause, rate only", @(NetDrainToday)],
                          @[@"B  orange bolt (charging, losing) + time to 20%", @(NetDrainBoltTime)],
                          @[@"C  B + Charger row: share of the Mac's draw it covers", @(NetDrainChargerRow)],
                          @[@"D  orange bolt + \"6 in · −10 W\" in the datum", @(NetDrainInDatum)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states)
                [rows addObjectsFromArray:NetDrainRows(c, [st[0] intValue], [st[1] doubleValue], [st[2] doubleValue],
                                                       [st[3] longValue], [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Cursor two-pool sheet

typedef NS_ENUM(NSInteger, PoolStyle) { PoolToday, PoolOverlay, PoolTight, PoolMarker, PoolTwoRows, PoolInnerLine, PoolUnderline, PoolGrokOverlay, PoolApiRow, PoolApiDatum, PoolSplit };

@interface PoolSketch : NSView
@property (nonatomic) double a, b;   // API, Grok/Composer remaining
@property (nonatomic) PoolStyle style;
@end
@implementation PoolSketch
- (void)lane:(NSRect)lane value:(double)v color:(NSColor *)color {
    CGFloat rad = NSHeight(lane) / 2;
    NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [t fill];
    [NSGraphicsContext saveGraphicsState]; [t addClip];
    [color setFill]; NSRectFill(NSMakeRect(NSMinX(lane), NSMinY(lane), MAX(NSHeight(lane), NSWidth(lane) * v), NSHeight(lane)));
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat w = NSWidth(r), mid = NSMidY(r);
    double lo = MIN(_a, _b), hi = MAX(_a, _b);
    switch (_style) {
        case PoolToday:
            [self lane:NSMakeRect(0, mid + 4, w, 4) value:_a color:AIQuotaColor(_a)];
            [self lane:NSMakeRect(0, mid - 8, w, 4) value:_b color:AIQuotaColor(_b)];
            break;
        case PoolTight:
            [self lane:NSMakeRect(0, mid + 0.5, w, 3.5) value:_a color:AIQuotaColor(_a)];
            [self lane:NSMakeRect(0, mid - 4, w, 3.5) value:_b color:AIQuotaColor(_b)];
            break;
        case PoolOverlay: {
            NSRect bar = NSMakeRect(0, mid - 4, w, 8);
            [self lane:bar value:hi color:[AIQuotaColor(hi) colorWithAlphaComponent:0.4]];
            NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4];
            [NSGraphicsContext saveGraphicsState]; [t addClip];
            [AIQuotaColor(lo) setFill]; NSRectFill(NSMakeRect(0, mid - 4, MAX(8, w * lo), 8));
            [NSGraphicsContext restoreGraphicsState];
            break;
        }
        case PoolInnerLine: {
            // Grok is the bar; API is a thin line riding inside it, centred.
            [self lane:NSMakeRect(0, mid - 4, w, 8) value:_b color:AIQuotaColor(_b)];
            [[NSColor.labelColor colorWithAlphaComponent:0.85] setFill];
            NSRectFill(NSMakeRect(2, mid - 1, MAX(2, w * _a - 2), 2));
            break;
        }
        case PoolUnderline:
            // Grok is the bar; API is a hairline lane tucked right under it.
            [self lane:NSMakeRect(0, mid - 2, w, 8) value:_b color:AIQuotaColor(_b)];
            [self lane:NSMakeRect(0, mid - 6, w, 2) value:_a color:AIQuotaColor(_a)];
            break;
        case PoolGrokOverlay: {
            // One bar to Grok's level; the API share of it is the solid, darker part.
            NSRect bar = NSMakeRect(0, mid - 4, w, 8);
            [self lane:bar value:_b color:[AIQuotaColor(_b) colorWithAlphaComponent:0.45]];
            NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4];
            [NSGraphicsContext saveGraphicsState]; [t addClip];
            [AIQuotaColor(_a) setFill]; NSRectFill(NSMakeRect(0, mid - 4, MAX(8, w * _a), 8));
            [NSGraphicsContext restoreGraphicsState];
            break;
        }
        case PoolSplit: {
            // Two separate short gauges in the one column: Grok wide on the left, API narrow on the right.
            CGFloat gw = round(w * 0.64), aw = w - gw - 6;
            [self lane:NSMakeRect(0, mid - 4, gw, 8) value:_b color:AIQuotaColor(_b)];
            [self lane:NSMakeRect(gw + 6, mid - 4, aw, 8) value:_a color:AIQuotaColor(_a)];
            break;
        }
        case PoolApiRow:
        case PoolApiDatum:
            [self lane:NSMakeRect(0, mid - 4, w, 8) value:_b color:AIQuotaColor(_b)];
            break;
        case PoolMarker:
        case PoolTwoRows:
            [self lane:NSMakeRect(0, mid - 4, w, 8) value:_a color:AIQuotaColor(_a)];
            if (_style == PoolMarker) {
                [NSColor.labelColor setFill];
                NSRectFill(NSMakeRect(round(w * _b) - 1, mid - 6, 2, 12));
            }
            break;
    }
}
@end

static NSView *QuotaRowSketch(Controller *c, NSString *name, NSString *label, double a, double b, NSString *datum, PoolStyle style) {
    BOOL pair = b >= 0 && (style == PoolToday || style == PoolTight);
    CGFloat h = style == PoolToday && b >= 0 ? kCursorRowH : kRowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, h)];
    if (name) {
        NSImageView *logo = [NSImageView imageViewWithImage:AIProviderLogo(name, kLeadSymbol) ?: [NSImage new]];
        logo.frame = NSMakeRect(kPad, (h - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
        [row addSubview:logo];
    }
    [row addSubview:[c text:label font:[NSFont systemFontOfSize:(name ? 13 : 12) weight:(name ? NSFontWeightSemibold : NSFontWeightMedium)]
                      color:(name ? NSColor.labelColor : NSColor.secondaryLabelColor)
                         at:NSMakeRect(kAINameX, (h - 16) / 2, kAINameW + 4, 16) align:NSTextAlignmentLeft]];
    PoolSketch *g = [[PoolSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (h - 20) / 2, kGaugeW, 20)];
    g.a = a; g.b = b < 0 ? a : b; g.style = b < 0 ? PoolTwoRows : style;
    [row addSubview:g];
    NSFont *big = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
    if (pair) {
        NSFont *small = [NSFont monospacedDigitSystemFontOfSize:(style == PoolTight ? 11 : 13) weight:NSFontWeightSemibold];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", a * 100] font:small color:AIQuotaColor(a)
                             at:NSMakeRect(kValueX, h / 2 - (style == PoolTight ? 1 : 0), kValueW, h / 2) align:NSTextAlignmentRight]];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", b * 100] font:small color:AIQuotaColor(b)
                             at:NSMakeRect(kValueX, (style == PoolTight ? 1 : 0), kValueW, h / 2) align:NSTextAlignmentRight]];
    } else {
        BOOL grokFirst = style == PoolInnerLine || style == PoolUnderline || style == PoolGrokOverlay ||
                         style == PoolApiDatum || style == PoolSplit;
        double shown = b < 0 ? a : style == PoolMarker ? a : grokFirst ? b : MIN(a, b);
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", shown * 100] font:big color:AIQuotaColor(shown)
                             at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    }
    if (style == PoolApiDatum && b >= 0)
        [row addSubview:[c text:[NSString stringWithFormat:@"API %.0f%%", a * 100] font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                          color:AIQuotaColor(a) at:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    else if (datum) [row addSubview:[c text:datum font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                 color:NSColor.secondaryLabelColor at:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    return row;
}

static BOOL CursorSheet(NSString *path) {
    Controller *c = [Controller new];
    NSArray *variants = getenv("SHEET_ALL") ? @[@[@"A  today: two thin lanes, two numbers", @(PoolToday)],
                          @[@"B  one bar: solid = tighter pool, pale = the other", @(PoolOverlay)],
                          @[@"C  two lanes squeezed into one bar's height", @(PoolTight)],
                          @[@"D  API bar, Grok as a tick", @(PoolMarker)],
                          @[@"E  a second plain row for Grok/Composer", @(PoolTwoRows)]]
                        : @[@[@"P  two plain rows: Cursor (Grok), then API", @(PoolTwoRows)],
                          @[@"Q  Grok bar; the datum says API 17%", @(PoolApiDatum)],
                          @[@"R  split column: Grok bar, then a short API bar", @(PoolSplit)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        PoolStyle style = [v[1] integerValue];
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray arrayWithObjects:
                QuotaRowSketch(c, @"Claude", @"Claude", 0.44, -1, @"resets Tue", style),
                QuotaRowSketch(c, @"Codex", @"Codex", 0.51, -1, @"resets Wed", style), nil];
            if (style == PoolTwoRows) {
                [rows addObject:QuotaRowSketch(c, @"Cursor", @"Cursor", 0.17, -1, @"resets 3 Nov", style)];
                [rows removeLastObject];
                [rows addObject:QuotaRowSketch(c, @"Cursor", @"Cursor", 0.41, -1, @"resets 3 Nov", style)];
                [rows addObject:QuotaRowSketch(c, nil, @"API", 0.17, -1, nil, style)];
            } else {
                [rows addObject:QuotaRowSketch(c, @"Cursor", @"Cursor", 0.17, 0.41, @"resets 3 Nov", style)];
            }
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Energybar coherence sheet (Energybar geometry: panel 400, gauge 68, value 74, datum 122)

typedef NS_ENUM(NSInteger, EnergyStyle) { EnergyToday, EnergyMerged, EnergyMergedTrue };
static const CGFloat ebW = 400, ebGaugeX = 110, ebGaugeW = 68, ebValueX = 182, ebValueW = 74, ebDatumX = 262, ebDatumW = 122;

static NSView *EnergyRow(Controller *c, NSString *symbol, NSColor *tint, NSString *name, double fraction, NSColor *barColor,
                         double signedFlow, NSString *value, NSColor *valueInk, NSString *datum,
                         double arrowFrom, double arrowTo, NSAppearanceName __unused look) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, ebW, kRowH)];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kLeadSymbol weight:NSFontWeightRegular];
    NSImageView *iv = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:cfg]];
    iv.imageScaling = NSImageScaleProportionallyDown; iv.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol); [row addSubview:iv];
    [row addSubview:[c text:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(48, (kRowH - 16) / 2, 60, 16) align:NSTextAlignmentLeft]];
    NSRect gf = NSMakeRect(ebGaugeX, (kRowH - kGaugeH) / 2, ebGaugeW, kGaugeH);
    if (!isnan(signedFlow)) {
        // Energybar today: centre-zero, import left, export right.
        PowerFlowGauge *dummy = nil; (void)dummy;
        FlowSketch *f = [[FlowSketch alloc] initWithFrame:gf];
        f.balance = YES; f.scale = 1; f.inW = MAX(signedFlow, 0); f.loadW = MAX(-signedFlow, 0);
        [row addSubview:f];
    } else if (fraction >= 0) {
        Gauge *g = [[Gauge alloc] initWithFrame:gf]; g.fraction = fraction; g.color = barColor; [row addSubview:g];
        if (arrowFrom >= 0 && fabs(arrowTo - arrowFrom) > 0.001) {
            TrendArrow *a = [[TrendArrow alloc] initWithFrame:NSMakeRect(NSMinX(gf) - 5, NSMidY(gf) - 5, NSWidth(gf) + 10, 10)];
            a.from = arrowFrom; a.to = arrowTo; [row addSubview:a];
        }
    }
    [row addSubview:[c text:value font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold] color:valueInk ?: NSColor.labelColor
                         at:NSMakeRect(ebValueX, (kRowH - kValueH) / 2, ebValueW, kValueH) align:NSTextAlignmentRight]];
    [row addSubview:[c text:datum font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor
                         at:NSMakeRect(ebDatumX + 6, (kRowH - kDatumH) / 2, ebDatumW - 6, kDatumH) align:NSTextAlignmentLeft]];
    return row;
}

static NSView *EnergyPanel(Controller *c, NSString *title, NSArray<NSView *> *rows, NSAppearanceName look) {
    CGFloat y = 8;
    PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, ebW, 400)];
    panel.appearance = [NSAppearance appearanceNamed:look];
    [panel addSubview:[c text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightBold] color:NSColor.secondaryLabelColor
                           at:NSMakeRect(kPad, y, ebW - 2 * kPad, 16) align:NSTextAlignmentLeft]];
    y += 22;
    NSFont *cap = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [panel addSubview:[c text:@"Now" font:cap color:NSColor.secondaryLabelColor at:NSMakeRect(ebValueX, y, ebValueW, 14) align:NSTextAlignmentRight]];
    [panel addSubview:[c text:@"Today" font:cap color:NSColor.secondaryLabelColor at:NSMakeRect(ebDatumX + 6, y, 60, 14) align:NSTextAlignmentLeft]];
    y += 16;
    for (NSView *row in rows) { NSRect f = row.frame; f.origin.y = y; row.frame = f; [panel addSubview:row]; y += NSHeight(f); }
    NSRect pf = panel.frame; pf.size.height = y + 8; panel.frame = pf;
    return panel;
}

static BOOL EnergySheet(NSString *path) {
    Controller *c = [Controller new];
    NSColor *orange = NSColor.systemOrangeColor, *green = NSColor.systemGreenColor, *red = NSColor.systemRedColor, *blue = NSColor.systemBlueColor;
    double scale = 5.0, packKWh = 57.5;
    // situation: solar kW, grid kW (+ export), car kW, SoC %, solar today, grid today, car today
    NSArray *situations = @[@[@"charging on solar", @4.8, @0.1, @2.6, @62, @"8.2 kWh", @"0.0 kWh", @"1.9 kWh"],
                            @[@"big export", @4.6, @3.4, @0.0, @80, @"18.4 kWh", @"9.6 kWh", @"—"],
                            @[@"night, importing", @0.0, @-0.6, @0.0, @71, @"24.9 kWh", @"2.1 kWh", @"—"]];
    NSArray *variants = @[@[@"A  today: grid centre-zero, car kW and battery % as two rows", @(EnergyToday)],
                          @[@"B  car = battery bar + trend arrow (1 h, min 10 pt), grid = plain bar", @(EnergyMerged)],
                          @[@"C  B with the arrow at true 1 h length", @(EnergyMergedTrue)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        EnergyStyle style = [v[1] integerValue];
        for (NSArray *st in situations) {
            [builders addObject:^NSView *(NSAppearanceName look) {
                double pv = [st[1] doubleValue], grid = [st[2] doubleValue], car = [st[3] doubleValue], soc = [st[4] doubleValue] / 100.0;
                BOOL exporting = grid > 0.05, importing = grid < -0.05;
                NSString *gridName = importing ? @"Import" : @"Export";
                NSColor *gridInk = importing ? red : exporting ? green : nil;
                NSMutableArray *rows = [NSMutableArray array];
                [rows addObject:EnergyRow(c, @"sun.max.fill", pv > 0.05 ? orange : nil, @"Solar", pv / scale, orange, NAN,
                                          [NSString stringWithFormat:@"%.1f kW", pv], pv > 0.05 ? orange : nil, st[5], -1, -1, look)];
                if (style == EnergyToday)
                    [rows addObject:EnergyRow(c, @"powerplug", gridInk, gridName, -1, nil, grid / scale,
                                              [NSString stringWithFormat:@"%.1f kW", fabs(grid)], gridInk, st[6], -1, -1, look)];
                else
                    [rows addObject:EnergyRow(c, @"powerplug", gridInk, gridName, fabs(grid) / scale, gridInk ?: NSColor.secondaryLabelColor, NAN,
                                              [NSString stringWithFormat:@"%.1f kW", fabs(grid)], gridInk, st[6], -1, -1, look)];
                if (style == EnergyToday) {
                    [rows addObject:EnergyRow(c, @"car.fill", car > 0.05 ? blue : nil, @"Car", car / scale, blue, NAN,
                                              [NSString stringWithFormat:@"%.1f kW", car], car > 0.05 ? blue : nil, st[7], -1, -1, look)];
                    [rows addObject:EnergyRow(c, @"battery.75", soc >= 0.5 ? green : orange, @"Battery", soc, soc >= 0.5 ? green : orange, NAN,
                                              [NSString stringWithFormat:@"%.0f%%", soc * 100], nil, @"", -1, -1, look)];
                } else {
                    double perHour = car / packKWh;
                    double to = soc + perHour;
                    if (style == EnergyMerged && car > 0.05) to = MAX(to, soc + 10.0 / ebGaugeW);
                    [rows addObject:EnergyRow(c, @"car.fill", car > 0.05 ? blue : nil, @"Car", soc, soc >= 0.5 ? green : orange, NAN,
                                              [NSString stringWithFormat:@"%.1f kW", car], car > 0.05 ? blue : nil, st[7],
                                              car > 0.05 ? soc : -1, MIN(to, 1.0), look)];
                }
                return EnergyPanel(c, [NSString stringWithFormat:@"%@ — %@", v[0], st[0]], rows, look);
            }];
        }
    }
    // three situations per variant: lay them out light-only for compactness
    return WriteSheet(builders, path);
}

#pragma mark - Burn attribution sheet

// Only the sheet's arrow changes: retain the production head, halo and geometry.
@interface BurnTailArrow : TrendArrow
@property (nonatomic) double appShare;
@end
@implementation BurnTailArrow
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    CGFloat w = NSWidth(self.bounds) - 10, a = 5 + w * self.from;
    CGFloat length = w * (self.from - self.to) * self.appShare;
    [[NSColor colorWithSRGBRed:0.90 green:0.22 blue:0.06 alpha:1] setFill];
    NSRectFill(NSMakeRect(a - length, NSMidY(self.bounds) - 1, length, 2));
}
@end

static double BurnMinutes(double draw) { return 60 * 54 * (0.61 - 0.20) / draw; }
static NSString *BurnGain(double draw, double appW) {
    return [NSString stringWithFormat:@"quit +%.0fm", BurnMinutes(draw - appW) - BurnMinutes(draw)];
}
static NSImage *BurnIcon(NSString *name) {
    NSDictionary *bundles = @{@"Chrome": @"com.google.Chrome", @"Codex": @"com.openai.codex",
                              @"Mail": @"com.apple.mail", @"Finder": @"com.apple.finder"};
    NSDictionary *paths = @{@"Chrome": @"/Applications/Google Chrome.app",
                            @"Codex": @"/Applications/Codex.app", @"Mail": @"/System/Applications/Mail.app",
                            @"Finder": @"/System/Library/CoreServices/Finder.app"};
    NSImage *icon = bundles[name] ? CachedBundleIcon(bundles[name], paths[name]) : nil;
    // iconForFile can return an empty placeholder without an IconServices session.
    // Decode the installed bundle's icon directly for this offscreen-only harness.
    NSBundle *bundle = paths[name] ? [NSBundle bundleWithPath:paths[name]] : nil;
    NSString *iconFile = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
    if (iconFile.length) {
        NSString *resource = [bundle.resourcePath stringByAppendingPathComponent:iconFile];
        if (!resource.pathExtension.length) resource = [resource stringByAppendingPathExtension:@"icns"];
        NSImage *decoded = [[NSImage alloc] initWithContentsOfFile:resource];
        if (decoded) icon = decoded;
    }
    return icon ?: [NSImage imageWithSystemSymbolName:[name isEqualToString:@"node"] ? @"terminal" : @"app"
                           accessibilityDescription:name];
}
static NSView *BurnBaseRow(Controller *c, NSString *symbol, NSString *name, double fraction,
                           NSColor *color, NSString *value, NSString *datum) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    [c instrumentSymbol:symbol tint:color identifier:nil in:row];
    [c instrumentName:name identifier:nil in:row];
    Gauge *bar = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
    bar.fraction = fraction; bar.color = color; bar.markerFraction = -1;
    [row addSubview:bar];
    [c instrumentValue:value color:color identifier:nil in:row];
    [c instrumentDatum:datum color:nil identifier:nil in:row];
    return row;
}

static NSView *BurnPanel(NSInteger variant, NSDictionary *situation, NSAppearanceName look) {
    Controller *c = [Controller new];
    double draw = [situation[@"draw"] doubleValue];
    NSArray *apps = situation[@"apps"];
    NSString *name = apps[0][@"name"];
    double appW = [apps[0][@"watts"] doubleValue], share = appW / draw;
    BatteryState bat = {.valid=YES, .percent=61, .rawMax_mAh=4500, .rawCurrent_mAh=2745,
                        .designCap_mAh=4500, .voltage_mV=12000, .amperage_mA=(long)lround(-draw * 1e6 / 12000),
                        .systemLoad_mW=(long)lround(draw * 1000)};
    [c setValue:[NSValue valueWithBytes:&bat objCType:@encode(BatteryState)] forKey:@"bat"];
    [c setValue:apps forKey:@"burnRows"];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:BurnBaseRow(c, @"internaldrive", @"Storage", 0.42, DiskColor(0.42), @"42%", @"290 GB free")];
    NSView *battery = BurnBaseRow(c, @"battery.75", @"Battery", 0.61, BattBarColor(61), @"61%", @"");
    NSImageView *batteryIcon = (NSImageView *)battery.subviews[0];
    batteryIcon.image = [c liveBatteryGlyph];
    batteryIcon.contentTintColor = batteryIcon.image.template ? [c batteryRateColor] : nil;
    Gauge *gauge = (Gauge *)battery.subviews[2];
    // Use the real arrow configuration, including the low-level lift above the bar.
    TrendArrow *arrow = variant == 3 ? [BurnTailArrow new] : [TrendArrow new];
    [c configureTrend:arrow over:gauge];
    if (variant == 3) ((BurnTailArrow *)arrow).appShare = share;
    [battery addSubview:arrow];
    [c instrumentDatum:FormatSignedWatts(-draw) color:NSColor.systemOrangeColor identifier:nil in:battery];
    NSString *tip = [NSString stringWithFormat:@"%@ %.1f W · %@ · %@ to 20%%", name, appW,
                     BurnGain(draw, appW), FmtDuration((int)lround(BurnMinutes(draw)))];
    battery.toolTip = tip;
    [rows addObject:battery];
    if (variant == 0) {
        NSView *holder = [NSView new];
        [c addBurnRowTo:holder at:0];
        [rows addObject:holder.subviews.firstObject];
    } else if (variant == 1 || (variant == 2 && share >= 0.25 && appW >= 2)) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
        NSImageView *icon = [c instrumentLogo:BurnIcon(name) identifier:nil in:row];
        if (icon.image.template) icon.contentTintColor = NSColor.secondaryLabelColor;
        [c instrumentName:name identifier:nil in:row];
        Gauge *bar = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
        bar.fraction = share; bar.color = NSColor.systemOrangeColor; bar.markerFraction = -1;
        [row addSubview:bar];
        // Match the app's rate precision rule so two-digit watts fit the 48pt value column.
        NSString *watts = [NSString stringWithFormat:appW >= 10 ? @"%.0f W" : @"%.1f W", appW];
        [c instrumentValue:watts color:variant == 2 && share >= 0.5 ? NSColor.systemRedColor : NSColor.labelColor
               identifier:nil in:row];
        [c instrumentDatum:BurnGain(draw, appW) color:nil identifier:nil in:row];
        row.toolTip = tip;
        [rows addObject:row];
    } else if (variant == 4) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
        [c instrumentSymbol:@"flame" tint:NSColor.systemOrangeColor identifier:nil in:row];
        [c instrumentName:@"Burn" identifier:nil in:row];
        if (appW <= 0.3) {
            [row addSubview:[c text:@"—" font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                             color:NSColor.secondaryLabelColor at:NSMakeRect(kGaugeX, (kRowH-kValueH)/2, 30, kValueH)
                             align:NSTextAlignmentLeft]];
        } else {
            CGFloat pairW = (kDatumX + kDatumW - kGaugeX) / 3;
            for (NSUInteger i = 0; i < MIN((NSUInteger)3, apps.count); i++) {
                CGFloat x = kGaugeX + i * pairW;
                NSImageView *icon = [NSImageView imageViewWithImage:BurnIcon(apps[i][@"name"])];
                icon.frame = NSMakeRect(x, (kRowH-16)/2, 16, 16);
                icon.imageScaling = NSImageScaleProportionallyUpOrDown;
                if (icon.image.template) icon.contentTintColor = NSColor.secondaryLabelColor;
                [row addSubview:icon];
                NSString *watts = [NSString stringWithFormat:@"%.1f", [apps[i][@"watts"] doubleValue]];
                [row addSubview:[c text:watts font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                                 color:NSColor.labelColor at:NSMakeRect(x+20, (kRowH-kValueH)/2, 44, kValueH)
                                 align:NSTextAlignmentRight]];
            }
        }
        [rows addObject:row];
    }
    double cpu = [situation[@"cpu"] doubleValue];
    [rows addObject:BurnBaseRow(c, @"cpu", @"System", cpu, CPUColor(cpu),
                               [NSString stringWithFormat:@"%.0f%%", cpu * 100], @"")];
    NSArray *titles = @[@"A  today", @"B  top app", @"C  hog-only", @"D  battery tail", @"E  icon strip"];
    NSView *panel = TitledPanel(titles[variant], rows, look, c);
    if (variant == 3) {
        // Review-only tooltip caption, outside the three-row popover group.
        NSRect f = panel.frame; CGFloat y = NSHeight(f) + 2; f.size.height += 20; panel.frame = f;
        NSTextField *caption = [c text:tip font:[NSFont systemFontOfSize:10] color:NSColor.secondaryLabelColor
                                   at:NSMakeRect(kPad, y, kW - 2*kPad, 14) align:NSTextAlignmentLeft];
        caption.maximumNumberOfLines = 1;
        [panel addSubview:caption];
    }
    return panel;
}

static BOOL BurnSheet(NSString *path) {
    NSArray *situations = @[
        @{@"name": @"normal", @"draw": @9.4, @"cpu": @0.18, @"apps": @[
            @{@"name": @"Chrome", @"watts": @2.1}, @{@"name": @"node", @"watts": @1.3},
            @{@"name": @"Codex", @"watts": @0.6}, @{@"name": @"Mail", @"watts": @0.2}]},
        @{@"name": @"runaway", @"draw": @21, @"cpu": @0.87, @"apps": @[
            @{@"name": @"node", @"watts": @14.0}, @{@"name": @"Chrome", @"watts": @2.0},
            @{@"name": @"Codex", @"watts": @0.5}]},
        @{@"name": @"idle", @"draw": @4.1, @"cpu": @0.03, @"apps": @[
            @{@"name": @"Finder", @"watts": @0.2}]}];
    NSArray *looks = @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua];
    NSString *darkPath = [[[path stringByDeletingPathExtension] stringByAppendingString:@"-dark"]
                          stringByAppendingPathExtension:@"png"];
    Controller *c = [Controller new];
    BOOL ok = YES;
    for (NSUInteger appearance = 0; appearance < looks.count; appearance++) {
        // Like WriteSheet, cache an offscreen view hierarchy; here columns are situations.
        CGFloat gap = 16, headerH = 36, cellH = 162;
        FlippedView *sheet = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, gap + 3*(kW+gap), headerH + 5*(cellH+gap))];
        sheet.appearance = [NSAppearance appearanceNamed:looks[appearance]];
        sheet.wantsLayer = YES;
        sheet.layer.backgroundColor = [NSColor colorWithWhite:appearance ? 0.16 : 0.88 alpha:1].CGColor;
        for (NSUInteger col = 0; col < situations.count; col++) {
            NSDictionary *s = situations[col];
            NSString *heading = [NSString stringWithFormat:@"%@ · %@ to 20%%", s[@"name"],
                                  FmtDuration((int)lround(BurnMinutes([s[@"draw"] doubleValue])))];
            [sheet addSubview:[c text:heading font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                               color:NSColor.labelColor at:NSMakeRect(gap+col*(kW+gap)+kPad, 10, kW-2*kPad, 16)
                               align:NSTextAlignmentLeft]];
            for (NSInteger variant = 0; variant < 5; variant++) {
                NSView *panel = BurnPanel(variant, s, looks[appearance]);
                NSRect f = panel.frame; f.origin = NSMakePoint(gap+col*(kW+gap), headerH+variant*(cellH+gap));
                panel.frame = f; [sheet addSubview:panel];
            }
        }
        NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
        [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
        BOOL written = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                         writeToFile:appearance ? darkPath : path atomically:YES];
        ok = written && ok;
    }
    return ok;
}

#pragma mark - Thermal sheet

typedef NS_ENUM(NSInteger, ThermStyle) { ThermDatum, ThermRowBar, ThermRowSegments };

// state: 0 nominal, 1 fair (near the limit), 2 serious (throttling), 3 critical.
static NSColor *ThermSketchColor(int state) {
    return state >= 2 ? NSColor.systemRedColor : state == 1 ? NSColor.systemOrangeColor
                      : [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
}
static NSString *ThermSketchWord(int state) { return state >= 2 ? @"throttling" : state == 1 ? @"near limit" : @""; }

// Four lamps, lit up to the current state: cool · warm · near limit · throttling.
@interface ThermSegments : NSView
@property (nonatomic) int state;
@end
@implementation ThermSegments
- (void)drawRect:(NSRect)dirty {
    CGFloat gap = 3, w = (NSWidth(self.bounds) - 3 * gap) / 4, h = NSHeight(self.bounds);
    for (int i = 0; i < 4; i++) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(i * (w + gap), 0, w, h) xRadius:h / 2 yRadius:h / 2];
        [(i <= _state ? ThermSketchColor(_state) : [NSColor.labelColor colorWithAlphaComponent:0.12]) setFill];
        [p fill];
    }
}
@end

static NSView *ThermRow(Controller *c, double cpu, double temp, int state, ThermStyle style, BOOL systemRow) {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    CGFloat h = kRowH;
    NSColor *tc = ThermSketchColor(state);
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
    if (systemRow) {
        [c instrumentSymbol:@"cpu" tint:CPUColor(cpu) identifier:@"s" in:row];
        [c instrumentName:@"System" identifier:@"n" in:row];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)];
        g.fraction = cpu; g.color = CPUColor(cpu); [row addSubview:g];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:valueFont color:CPUColor(cpu)
                             at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
        if (style == ThermDatum)   // the datum column was empty; the word appears only when it matters
            [row addSubview:SheetDatum(c, state >= 2 ? [NSString stringWithFormat:@"%.0f° slowed", temp] : [NSString stringWithFormat:@"%.0f °C", temp],
                                       state ? tc : NSColor.secondaryLabelColor)];
        return row;
    }
    [c instrumentSymbol:@"thermometer.medium" tint:tc identifier:@"s" in:row];
    [c instrumentName:@"Temp" identifier:@"n" in:row];
    if (style == ThermRowBar) {
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)];
        g.fraction = MAX(0, MIN(1, (temp - 30) / 75.0)); g.color = tc; [row addSubview:g];
    } else {
        ThermSegments *s = [[ThermSegments alloc] initWithFrame:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)];
        s.state = MIN(state, 3); [row addSubview:s];
    }
    [row addSubview:[c text:[NSString stringWithFormat:@"%.0f°", temp] font:valueFont color:tc
                         at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    [row addSubview:SheetDatum(c, ThermSketchWord(state), state ? tc : NSColor.secondaryLabelColor)];
    return row;
}

static BOOL ThermalSheet(NSString *path) {
    Controller *c = [Controller new];
    // cpu, die °C, OS thermal state
    NSArray *states = @[@[@0.12, @46, @0], @[@0.55, @66, @1], @[@0.92, @73, @2], @[@1.0, @101, @3]];
    NSArray *variants = @[@[@"A  temp in the System row's empty datum (+0 rows)", @(ThermDatum)],
                          @[@"B  own Temp row: bar = die temp 30–105°", @(ThermRowBar)],
                          @[@"C  own Temp row: four lamps cool·warm·near·throttling", @(ThermRowSegments)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        ThermStyle style = [v[1] integerValue];
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) {
                [rows addObject:ThermRow(c, [st[0] doubleValue], [st[1] doubleValue], [st[2] intValue], style, YES)];
                if (style != ThermDatum)
                    [rows addObject:ThermRow(c, [st[0] doubleValue], [st[1] doubleValue], [st[2] intValue], style, NO)];
            }
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Always-on temperatures sheet

typedef NS_ENUM(NSInteger, TempsStyle) { TempsDatums, TempsHeatRow, TempsTwoRows };

static NSColor *CellSketchColor(double c) {
    return c >= 42 ? NSColor.systemRedColor : c >= 38 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
}

static NSArray<NSView *> *TempsRows(Controller *c, NSArray *st, TempsStyle style) {
    double cpu = [st[0] doubleValue], chip = [st[1] doubleValue], cells = [st[2] doubleValue], watts = [st[4] doubleValue];
    int state = [st[3] intValue];
    NSColor *chipColor = state ? ThermSketchColor(state) : NSColor.secondaryLabelColor;
    NSString *chipText = state >= 2 ? [NSString stringWithFormat:@"%.0f° slowed", chip] : [NSString stringWithFormat:@"%.0f °C", chip];
    NSString *wattText = fabs(watts) < 0.5 ? @"" : [NSString stringWithFormat:@"%+.0f W", watts];
    NSColor *wattColor = watts > 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor;

    NSView *system = ThermRow(c, cpu, chip, state, ThermRowBar, YES);   // System row, datum filled below
    NSMutableArray *rows = [NSMutableArray arrayWithObject:system];
    NSView *battery = BurnBaseRow(c, @"battery.75", @"Battery", 0.80, BattBarColor(80), @"80%", @"");
    [rows addObject:battery];
    // Both temperatures appear together when either is hot; while both are cool, neither shows.
    BOOL show = state > 0 || cells >= 38;
    if (!show) {
        if (wattText.length) [battery addSubview:SheetDatum(c, wattText, wattColor)];
        return rows;
    }
    if (style == TempsDatums) {
        [system addSubview:SheetDatum(c, chipText, chipColor)];
        NSString *b = wattText.length ? [NSString stringWithFormat:@"%.0f° · %@", cells, wattText] : [NSString stringWithFormat:@"%.0f °C", cells];
        [battery addSubview:SheetDatum(c, b, cells >= 38 ? CellSketchColor(cells) : wattText.length ? wattColor : NSColor.secondaryLabelColor)];
        return rows;
    }
    if (state >= 2) [system addSubview:SheetDatum(c, @"slowed", chipColor)];
    else if (state == 1) [system addSubview:SheetDatum(c, @"near limit", chipColor)];
    if (wattText.length) [battery addSubview:SheetDatum(c, wattText, wattColor)];
    NSColor *barChip = state ? chipColor : [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
    if (style == TempsHeatRow) {
        [rows addObject:BurnBaseRow(c, @"thermometer.medium", @"Heat", MAX(0, MIN(1, (chip - 30) / 75.0)), barChip,
                                    [NSString stringWithFormat:@"%.0f°", chip], @"")];
        [rows.lastObject addSubview:SheetDatum(c, [NSString stringWithFormat:@"cells %.0f°", cells], CellSketchColor(cells))];
    } else {
        [rows addObject:BurnBaseRow(c, @"cpu", @"Chip", MAX(0, MIN(1, (chip - 30) / 75.0)), barChip,
                                    [NSString stringWithFormat:@"%.0f°", chip], @"")];
        NSColor *cc = cells >= 38 ? CellSketchColor(cells) : [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
        [rows addObject:BurnBaseRow(c, @"thermometer.medium", @"Cells", MAX(0, MIN(1, (cells - 20) / 30.0)), cc,
                                    [NSString stringWithFormat:@"%.0f°", cells], @"")];
    }
    return rows;
}

static BOOL TempsSheet(NSString *path) {
    Controller *c = [Controller new];
    // cpu, chip °C, cells °C, OS pressure (0 nominal, 1 near, 2 slowed), battery W (+ in)
    NSArray *states = @[@[@0.15, @52, @29, @0, @-6], @[@0.92, @88, @31, @2, @0], @[@0.40, @60, @39, @0, @-9]];
    NSArray *variants = @[@[@"A  both in datums, either hot shows both (+0 rows)", @(TempsDatums)],
                          @[@"B  Heat row appears: chip bar, cells datum (+1 when hot)", @(TempsHeatRow)],
                          @[@"C  Chip and Cells rows appear, own bars (+2 when hot)", @(TempsTwoRows)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        TempsStyle style = [v[1] integerValue];
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) [rows addObjectsFromArray:TempsRows(c, st, style)];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Thermal row sheet

typedef NS_ENUM(NSInteger, ThermRowStyle) { TRSpeedBar, TRTempBar, TRCeilingBar, TRLamps };

// The speed bar with the lost speed drawn as a dim red ceiling above the current level.
@interface CeilingGauge : NSView
@property (nonatomic) double fraction;
@property (nonatomic, strong) NSColor *color;
@end
@implementation CeilingGauge
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds; CGFloat r = NSHeight(b) / 2;
    [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r] fill];
    NSRect lost = b; lost.origin.x = NSWidth(b) * _fraction; lost.size.width = NSWidth(b) * (1 - _fraction);
    if (_fraction < 0.98) {
        [[NSColor.systemRedColor colorWithAlphaComponent:0.25] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:lost xRadius:r yRadius:r] fill];
    }
    NSRect fill = b; fill.size.width = NSWidth(b) * _fraction;
    [_color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:r yRadius:r] fill];
}
@end

static NSView *ThermalRowSketch(Controller *c, NSArray *st, ThermRowStyle style) {
    int state = [st[0] intValue];
    double speed = [st[1] doubleValue], ghz = [st[2] doubleValue], chip = [st[3] doubleValue], cells = [st[4] doubleValue];
    NSColor *tc = state ? ThermSketchColor(state) : [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    [c instrumentSymbol:@"thermometer.medium" tint:tc identifier:nil in:row];
    [c instrumentName:@"Heat" identifier:nil in:row];
    NSRect g = NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH);
    NSString *temps = [NSString stringWithFormat:@"%.0f° · %.0f°", chip, cells];
    NSString *value = [NSString stringWithFormat:@"%.0f%%", speed * 100], *datum = temps;
    if (style == TRSpeedBar) {
        Gauge *bar = [[Gauge alloc] initWithFrame:g]; bar.fraction = speed; bar.color = tc; bar.markerFraction = -1;
        [row addSubview:bar];
    } else if (style == TRTempBar) {
        Gauge *bar = [[Gauge alloc] initWithFrame:g]; bar.fraction = MAX(0, MIN(1, (chip - 30) / 75.0)); bar.color = tc;
        bar.markerFraction = -1; [row addSubview:bar];
        value = [NSString stringWithFormat:@"%.0f°", chip];
        datum = speed > 0.97 ? [NSString stringWithFormat:@"cells %.0f°", cells] : [NSString stringWithFormat:@"−%.0f%% · %.0f°", (1 - speed) * 100, cells];
    } else if (style == TRCeilingBar) {
        CeilingGauge *bar = [[CeilingGauge alloc] initWithFrame:g]; bar.fraction = speed; bar.color = tc; [row addSubview:bar];
        value = [NSString stringWithFormat:@"%.1f", ghz];
        datum = [NSString stringWithFormat:@"GHz  %@", temps];
    } else {
        ThermSegments *lamps = [[ThermSegments alloc] initWithFrame:g]; lamps.state = state; [row addSubview:lamps];
    }
    [row addSubview:[c text:value font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold] color:tc
                         at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    [row addSubview:SheetDatum(c, datum, state ? tc : NSColor.secondaryLabelColor)];
    return row;
}

static NSView *DetailRow(Controller *c, NSString *symbol, NSString *name, double fraction, NSColor *color,
                         NSString *value, NSString *datum, NSColor *datumColor) {
    NSView *row = BurnBaseRow(c, symbol, name, fraction, color, value, @"");
    [row addSubview:SheetDatum(c, datum, datumColor ?: NSColor.secondaryLabelColor)];
    return row;
}

static BOOL ThermalRowSheet(NSString *path) {
    Controller *c = [Controller new];
    // pressure (0 nominal, 1 near, 2 slowed), fast-core speed fraction, GHz, chip °C, cells °C
    NSArray *states = @[@[@0, @1.0, @4.4, @58, @29], @[@1, @0.82, @3.7, @72, @33], @[@2, @0.52, @2.3, @78, @34]];
    NSArray *variants = @[@[@"A  bar + value = fast-core speed; datum chip · cells", @(TRSpeedBar)],
                          @[@"B  bar + value = chip temp; datum speed lost · cells", @(TRTempBar)],
                          @[@"C  speed bar, lost speed shaded red; value GHz", @(TRCeilingBar)],
                          @[@"D  pressure lamps; value speed; datum chip · cells", @(TRLamps)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) [rows addObject:ThermalRowSketch(c, st, [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    [builders addObject:^NSView *(NSAppearanceName look) {
        NSColor *red = NSColor.systemRedColor, *orange = NSColor.systemOrangeColor, *green = [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
        NSMutableArray *rows = [NSMutableArray array];
        ThermSegments *lamps = [[ThermSegments alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
        lamps.state = 2;
        NSView *pressure = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
        [c instrumentSymbol:@"gauge.with.dots.needle.67percent" tint:red identifier:nil in:pressure];
        [c instrumentName:@"State" identifier:nil in:pressure];
        [pressure addSubview:lamps];
        [pressure addSubview:SheetDatum(c, @"heavy · 41m", red)];
        [rows addObject:pressure];
        [rows addObject:DetailRow(c, @"hare", @"P-cores", 0.52, red, @"2.3", @"of 4.5 GHz", nil)];
        [rows addObject:DetailRow(c, @"tortoise", @"E-cores", 0.72, orange, @"2.2", @"of 3.0 GHz", nil)];
        [rows addObject:DetailRow(c, @"cpu", @"Chip", (78 - 30) / 75.0, red, @"78°", @"hottest core", nil)];
        [rows addObject:DetailRow(c, @"battery.75", @"Cells", (34 - 20) / 30.0, green, @"34°", @"Low Power off", nil)];
        [rows addObject:DetailRow(c, @"bolt", @"Power", 0.45, orange, @"9.1 W", @"CPU", nil)];
        return TitledPanel(@"Thermal tab (for any variant)", rows, look, c);
    }];
    return WriteSheet(builders, path);
}

#pragma mark - Speed row sheet (what does the Heat row's percent mean?)

typedef NS_ENUM(NSInteger, SpeedStyle) { SpeedToday, SpeedRenamed, SpeedCeiling, SpeedLoss };

static NSAttributedString *SketchTemps(double chip, NSColor *chipColor, double cells, NSColor *cellColor) {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSArray *parts = @[@[@"cpu", @(chip), chipColor], @[@"battery.75", @(cells), cellColor]];
    for (NSArray *part in parts) {
        if (out.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{NSFontAttributeName: font}]];
        NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:kDatumFont - 2.5 weight:NSFontWeightRegular]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[part[2]]]];
        NSTextAttachment *mark = [NSTextAttachment new];
        mark.image = [[NSImage imageWithSystemSymbolName:part[0] accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
        mark.bounds = NSMakeRect(0, (font.capHeight - mark.image.size.height) / 2, mark.image.size.width, mark.image.size.height);
        [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:mark]];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%.0f°", [part[1] doubleValue]]
                                                                     attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: part[2]}]];
    }
    return out;
}

static NSView *SpeedRowSketch(Controller *c, NSArray *st, SpeedStyle style) {
    int state = [st[0] intValue];
    double speed = [st[1] doubleValue], chip = [st[2] doubleValue], cells = [st[3] doubleValue];
    NSColor *tc = state >= 2 ? NSColor.systemRedColor : state == 1 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
    NSColor *chipColor = state ? tc : NSColor.secondaryLabelColor;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    BOOL renamed = style != SpeedToday && style != SpeedLoss;
    [c instrumentSymbol:(renamed ? @"gauge.with.dots.needle.33percent" : @"thermometer.medium") tint:tc identifier:nil in:row];
    [c instrumentName:(renamed ? @"Speed" : style == SpeedLoss ? @"Slowed" : @"Heat") identifier:nil in:row];
    NSRect g = NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH);
    NSString *value = [NSString stringWithFormat:@"%.0f%%", speed * 100];
    if (style == SpeedCeiling) {
        CeilingGauge *bar = [[CeilingGauge alloc] initWithFrame:g]; bar.fraction = speed; bar.color = tc; [row addSubview:bar];
    } else if (style == SpeedLoss) {
        Gauge *bar = [[Gauge alloc] initWithFrame:g]; bar.fraction = 1 - speed; bar.color = tc; bar.markerFraction = -1; [row addSubview:bar];
        value = speed > 0.995 ? @"0%" : [NSString stringWithFormat:@"−%.0f%%", (1 - speed) * 100];
        if (speed > 0.995) tc = NSColor.systemGreenColor;
    } else {
        Gauge *bar = [[Gauge alloc] initWithFrame:g]; bar.fraction = speed; bar.color = tc; bar.markerFraction = -1; [row addSubview:bar];
    }
    [row addSubview:[c text:value font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold] color:tc
                         at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    NSTextField *datum = SheetDatum(c, @"", NSColor.secondaryLabelColor);
    datum.attributedStringValue = SketchTemps(chip, chipColor, cells, cells >= 42 ? NSColor.systemRedColor : cells >= 38 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor);
    [row addSubview:datum];
    return row;
}

static BOOL SpeedSheet(NSString *path) {
    Controller *c = [Controller new];
    // pressure (0 none, 1 near, 2 slowed), fast-core speed fraction, chip °C, cells °C
    NSArray *states = @[@[@0, @1.0, @58, @33], @[@1, @0.82, @70, @34], @[@2, @0.39, @75, @36]];
    NSArray *variants = @[@[@"A  today: Heat, bar + 39% = speed left", @(SpeedToday)],
                          @[@"B  renamed: Speed 39%, gauge symbol", @(SpeedRenamed)],
                          @[@"C  Speed, and the lost speed shaded red", @(SpeedCeiling)],
                          @[@"D  Slowed −61%: bar and value are the loss", @(SpeedLoss)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) [rows addObject:SpeedRowSketch(c, st, [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc < 3) { fprintf(stderr, "usage: ux-sheet pace|power|system|trend|netdrain|cursor|energy|burn|thermal|temps|thermrow|speed out.png\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        if (!strcmp(argv[1], "thermal")) return ThermalSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "temps")) return TempsSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "thermrow")) return ThermalRowSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "speed")) return SpeedSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "burn")) return BurnSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "power")) return PowerSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "system")) return SystemSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "trend")) return TrendSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "netdrain")) return NetDrainSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "cursor")) return CursorSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "energy")) return EnergySheet(path) ? 0 : 1;
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
                   writeToFile:path atomically:YES] ? 0 : 1;
    }
}
