// Renders a generic Glancebar mockup PNG (example data, no real disk/battery info)
// showing the compact Storage + Battery + System + AI Status popover. Output: docs/screenshot.png
#import <Cocoa/Cocoa.h>

static const CGFloat kW = 320, kPad = 16;

@interface Gauge : NSView
@property double fraction; @property (strong) NSColor *color;
@end
@implementation Gauge
- (void)drawRect:(NSRect)d {
    NSRect r = self.bounds; CGFloat rad = r.size.height/2;
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    NSRect f = r; f.size.width = MAX(r.size.height, r.size.width*MIN(1.0,self.fraction));
    [(self.color ?: NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
}
@end

@interface Flip : NSView @end
@implementation Flip - (BOOL)isFlipped { return YES; } @end
@interface Grad : NSView @end
@implementation Grad
- (void)drawRect:(NSRect)d {
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.20 green:0.34 blue:0.52 alpha:1]
                                                  endingColor:[NSColor colorWithRed:0.10 green:0.16 blue:0.30 alpha:1]];
    [g drawInRect:self.bounds angle:-90];
}
@end
@interface Pill : NSView @end
@implementation Pill
- (void)drawRect:(NSRect)d {
    [[NSColor colorWithWhite:0.12 alpha:0.92] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:7 yRadius:7] fill];
}
@end

static NSColor *Disk(double f){ return f>=0.95?NSColor.systemRedColor:f>=0.85?NSColor.systemOrangeColor:NSColor.controlAccentColor; }
static NSColor *Pressure(double f){ return f>=0.35?NSColor.systemOrangeColor:f>=0.15?[NSColor.systemYellowColor colorWithAlphaComponent:0.9]:[NSColor.systemGreenColor colorWithAlphaComponent:0.85]; }
static NSTextField *L(NSString *s, NSFont *f, NSColor *c, NSRect fr, NSTextAlignment a){
    NSTextField *t=[NSTextField labelWithString:s]; t.font=f; if(c)t.textColor=c; t.alignment=a; t.frame=fr;
    t.lineBreakMode=NSLineBreakByTruncatingTail; return t;
}

@interface App : NSObject <NSApplicationDelegate> @end
@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    Flip *card = [[Flip alloc] initWithFrame:NSMakeRect(0,0,kW,820)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = [NSColor colorWithWhite:0.98 alpha:1].CGColor;
    card.layer.cornerRadius = 12; card.layer.borderWidth = 0.5;
    card.layer.borderColor = [NSColor colorWithWhite:0 alpha:0.12].CGColor;
    card.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    CGFloat inner = kW-2*kPad;
    __block CGFloat y = kPad;

    void (^hdr)(NSString *) = ^(NSString *s){
        [card addSubview:L(s.uppercaseString, [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                           NSColor.tertiaryLabelColor, NSMakeRect(kPad, y, inner, 14), NSTextAlignmentLeft)];
    };
    void (^vol)(NSString *, NSString *, double, BOOL) = ^(NSString *name, NSString *cap, double frac, BOOL internalDrive){
        NSImage *ic = [NSImage imageWithSystemSymbolName:(internalDrive?@"internaldrive":@"externaldrive") accessibilityDescription:nil];
        NSImageView *iv = [NSImageView imageViewWithImage:ic]; iv.contentTintColor=NSColor.secondaryLabelColor;
        iv.frame = NSMakeRect(kPad, y+1, 17, 15); [card addSubview:iv];
        [card addSubview:L(name, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], nil,
                           NSMakeRect(kPad+23, y+1, inner-23-46, 16), NSTextAlignmentLeft)];
        [card addSubview:L([NSString stringWithFormat:@"%.0f%%",frac*100],
                           [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.secondaryLabelColor,
                           NSMakeRect(kW-kPad-46, y+1, 46, 16), NSTextAlignmentRight)];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, y+19, inner, 5)]; g.fraction=frac; g.color=Disk(frac);
        [card addSubview:g];
        [card addSubview:L(cap, [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor,
                           NSMakeRect(kPad, y+28, inner, 14), NSTextAlignmentLeft)];
        y += 50;
    };

    hdr(@"Storage"); y += 22;
    vol(@"Macintosh HD", @"540 GB of 1 TB used · 460 GB free", 0.54, YES);
    vol(@"T7 Shield",    @"1.76 TB of 2 TB used · 240 GB free", 0.88, NO);
    y += 4;
    NSBox *d1=[[NSBox alloc] initWithFrame:NSMakeRect(kPad,y,inner,1)]; d1.boxType=NSBoxSeparator; [card addSubview:d1]; y+=13;

    hdr(@"Battery"); y += 22;
    [card addSubview:L(@"3:14 until 20%", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], nil,
                       NSMakeRect(kPad, y, inner, 20), NSTextAlignmentLeft)];
    [card addSubview:L(@"76% remaining", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor,
                       NSMakeRect(kPad, y+19, inner, 14), NSTextAlignmentLeft)];
    y += 44;
    [card addSubview:L(@"Battery pressure", [NSFont systemFontOfSize:11], NSColor.tertiaryLabelColor,
                       NSMakeRect(kPad, y, inner, 14), NSTextAlignmentLeft)]; y += 20;
    NSView *pressureRow = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 28)];
    [pressureRow addSubview:L(@"Google Chrome", [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], nil,
                              NSMakeRect(kPad, 11, inner-82, 15), NSTextAlignmentLeft)];
    [pressureRow addSubview:L(@"48%", [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                              NSColor.secondaryLabelColor, NSMakeRect(kW-kPad-82, 11, 82, 15), NSTextAlignmentRight)];
    Gauge *pg=[[Gauge alloc] initWithFrame:NSMakeRect(kPad, 3, inner, 4)]; pg.fraction=0.48; pg.color=Pressure(0.48);
    [pressureRow addSubview:pg]; [card addSubview:pressureRow]; y += 32;
    [card addSubview:L(@"Drawing 12.4 W · Health 94%", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor,
                       NSMakeRect(kPad, y, inner, 14), NSTextAlignmentLeft)]; y+=18;

    y += 4;
    NSBox *d2=[[NSBox alloc] initWithFrame:NSMakeRect(kPad,y,inner,1)]; d2.boxType=NSBoxSeparator; [card addSubview:d2]; y+=13;
    hdr(@"System"); y += 22;
    [card addSubview:L(@"Medium system pressure", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.systemOrangeColor,
                       NSMakeRect(kPad, y, inner, 18), NSTextAlignmentLeft)];
    [card addSubview:L(@"CPU 38% · Memory Low · 10.7 GB available · Swap 0 B",
                       [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor,
                       NSMakeRect(kPad, y+18, inner, 14), NSTextAlignmentLeft)];
    Gauge *cpu=[[Gauge alloc] initWithFrame:NSMakeRect(kPad, y+36, inner, 4)];
    cpu.fraction=0.38; cpu.color=[NSColor.systemYellowColor colorWithAlphaComponent:0.9]; [card addSubview:cpu];
    y += 50;

    void (^proc)(NSString *, NSString *, double, NSColor *) = ^(NSString *name, NSString *right, double frac, NSColor *color){
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 28)];
        [row addSubview:L(name, [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], nil,
                          NSMakeRect(kPad, 11, inner-82, 15), NSTextAlignmentLeft)];
        [row addSubview:L(right, [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                          NSColor.secondaryLabelColor, NSMakeRect(kW-kPad-82, 11, 82, 15), NSTextAlignmentRight)];
        Gauge *g=[[Gauge alloc] initWithFrame:NSMakeRect(kPad, 3, inner, 4)]; g.fraction=frac; g.color=color;
        [row addSubview:g]; [card addSubview:row]; y += 30;
    };
    proc(@"Google Chrome", @"CPU 32%", 0.32, NSColor.systemYellowColor);
    proc(@"Adobe Acrobat", @"2.4 GB", 0.15, NSColor.systemGreenColor);

    y += 4;
    NSBox *d3=[[NSBox alloc] initWithFrame:NSMakeRect(kPad,y,inner,1)]; d3.boxType=NSBoxSeparator; [card addSubview:d3]; y+=13;
    hdr(@"AI Status"); y += 22;
    void (^ai)(NSString *, NSString *, NSString *, double, NSColor *) = ^(NSString *name, NSString *right, NSString *detail, double frac, NSColor *color){
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 44)];
        CGFloat titleW=74, rightW=54, barX=kPad+titleW+8, barW=inner-titleW-rightW-18;
        [row addSubview:L(name, [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], nil,
                          NSMakeRect(kPad, 25, titleW, 15), NSTextAlignmentLeft)];
        [row addSubview:L(right, [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
                          color, NSMakeRect(kW-kPad-rightW, 23, rightW, 17), NSTextAlignmentRight)];
        Gauge *g=[[Gauge alloc] initWithFrame:NSMakeRect(barX, 28, barW, 7)]; g.fraction=frac; g.color=color;
        [row addSubview:g];
        [row addSubview:L(detail, [NSFont systemFontOfSize:10.5], NSColor.secondaryLabelColor,
                          NSMakeRect(kPad, 7, inner, 14), NSTextAlignmentLeft)];
        [card addSubview:row]; y += 44;
    };
    ai(@"Claude", @"42%", @"Reset 7:00 PM", 0.42, NSColor.systemYellowColor);
    ai(@"Codex", @"—", @"No limit status", 0.0, NSColor.tertiaryLabelColor);

    y += 4;
    NSBox *d4=[[NSBox alloc] initWithFrame:NSMakeRect(kPad,y,inner,1)]; d4.boxType=NSBoxSeparator; [card addSubview:d4]; y+=9;
    NSImageView *opts=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil]];
    opts.contentTintColor=NSColor.secondaryLabelColor; opts.frame=NSMakeRect(kPad-1, y+3, 17, 15); [card addSubview:opts];
    [card addSubview:L(@"Details…", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor,
                       NSMakeRect(kPad+28, y+3, 76, 16), NSTextAlignmentLeft)];
    [card addSubview:L(@"Quit", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor,
                       NSMakeRect(kW-kPad-50, y+3, 50, 16), NSTextAlignmentRight)];
    y += 26;

    y += kPad - 6;
    CGFloat cardH = y; card.frame = NSMakeRect(0,0,kW,cardH);

    // pill: storage + battery + optional system + optional AI status
    CGFloat pillW=262, pillH=24;
    Pill *pill=[[Pill alloc] initWithFrame:NSMakeRect(0,0,pillW,pillH)];
    pill.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSImageView *di=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"internaldrive" accessibilityDescription:nil]];
    di.contentTintColor=NSColor.whiteColor; di.frame=NSMakeRect(10,5,16,14); [pill addSubview:di];
    [pill addSubview:L(@"61%", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.whiteColor,
                       NSMakeRect(28,4,38,16), NSTextAlignmentLeft)];
    NSImageView *bi=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"battery.100percent" variableValue:0.76 accessibilityDescription:nil]];
    bi.contentTintColor=NSColor.whiteColor; bi.frame=NSMakeRect(66,5,26,14); [pill addSubview:bi];
    [pill addSubview:L(@"76%", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.whiteColor,
                       NSMakeRect(96,4,38,16), NSTextAlignmentLeft)];
    NSImageView *ci=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"cpu" accessibilityDescription:nil]];
    ci.contentTintColor=NSColor.whiteColor; ci.frame=NSMakeRect(136,5,16,14); [pill addSubview:ci];
    [pill addSubview:L(@"38%", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.whiteColor,
                       NSMakeRect(154,4,38,16), NSTextAlignmentLeft)];
    NSImageView *aii=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:nil]];
    aii.contentTintColor=NSColor.whiteColor; aii.frame=NSMakeRect(192,5,16,14); [pill addSubview:aii];
    [pill addSubview:L(@"AI 42%", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSColor.whiteColor,
                       NSMakeRect(210,4,52,16), NSTextAlignmentLeft)];

    CGFloat margin=34, gap=10, W=kW+2*margin, H=pillH+gap+cardH+2*margin;
    Grad *canvas=[[Grad alloc] initWithFrame:NSMakeRect(0,0,W,H)];
    card.frame=NSMakeRect(margin,margin,kW,cardH);
    card.shadow=({ NSShadow *s=[NSShadow new]; s.shadowBlurRadius=24; s.shadowColor=[NSColor colorWithWhite:0 alpha:0.35]; s.shadowOffset=NSMakeSize(0,-6); s; });
    pill.frame=NSMakeRect(margin,margin+cardH+gap,pillW,pillH);
    [canvas addSubview:card]; [canvas addSubview:pill];

    NSBitmapImageRep *rep=[canvas bitmapImageRepForCachingDisplayInRect:canvas.bounds];
    [canvas cacheDisplayInRect:canvas.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:(NSProcessInfo.processInfo.arguments.count>1?NSProcessInfo.processInfo.arguments[1]:@"screenshot.png") atomically:YES];
    NSLog(@"wrote (%.0fx%.0f pt)", W, H);
    exit(0);
}
@end
int main(void){ @autoreleasepool { NSApplication *a=NSApplication.sharedApplication; App *d=[App new]; a.delegate=d; [a run]; } return 0; }
