// Focused integration coverage for the stateful local-log reader. Importing main.m
// keeps this harness honest about the private AIReader implementation without adding a
// production test API or a second copy of scanner logic.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

static int failures = 0;

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static AIUsage *UsageNamed(NSArray<AIUsage *> *usage, NSString *name) {
    for (AIUsage *item in usage) if ([item.name isEqualToString:name]) return item;
    return nil;
}

// The bounded reader is private to main.m; the harness already imports that shell.
@interface AIReader (BoundedReaderTestAccess)
- (NSData *)newLineDataAtPath:(NSString *)path record:(NSMutableDictionary *)record
                     maxBytes:(NSUInteger)maxBytes lineCap:(NSUInteger)lineCap
                    bytesRead:(NSUInteger *)bytesRead readFailed:(BOOL *)readFailed;
- (void)consumeCodexData:(NSData *)chunk record:(NSMutableDictionary *)record;
- (NSUInteger)stateWriteCount;
@end

// The detail builders are private to the app shell, which this harness already imports.
@interface Controller (DetailTestAccess)
- (void)addDetailHeading:(NSString *)title key:(NSString *)sectionKey
                      to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width;
- (void)addDetailKey:(NSString *)key value:(NSString *)value to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width;
- (void)addDetailKey:(NSString *)key value:(NSString *)value identifierKey:(NSString *)identifierKey
                  to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width;
@end

@interface Controller (BarTierTestAccess)
- (NSArray<NSDictionary *> *)barSegmentsForTier:(int)tier full:(NSArray<NSDictionary *> *)full;
@end

// Builds the Local History subtree the way aiDetailsView does, optionally giving Claude the
// conditional Models section, and reports the identifiers of Codex's provider heading, its
// Models heading, and its model row. Every one of them must be blind to whether Claude's
// section grew above it.
static NSDictionary *BuildCodexSubtree(Controller *c, BOOL claudeHasModels) {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 800)];
    root.accessibilityIdentifier = @"details.ai";
    CGFloat y = kDetailPad;
    [c addDetailHeading:@"Local History" key:@"local-history" to:root y:&y width:kDetailW];
    [c addDetailHeading:@"Claude" key:@"local-history.claude" to:root y:&y width:kDetailW];
    [c addDetailKey:@"Today" value:@"1" to:root y:&y width:kDetailW];
    if (claudeHasModels) {
        [c addDetailHeading:@"Models" key:@"local-history.claude.models" to:root y:&y width:kDetailW];
        [c addDetailKey:@"claude-opus-4-8" value:@"1" to:root y:&y width:kDetailW];
    }
    [c addDetailHeading:@"Codex" key:@"local-history.codex" to:root y:&y width:kDetailW];
    NSString *providerHeading = root.subviews.lastObject.accessibilityIdentifier;
    [c addDetailKey:@"Today" value:@"1" to:root y:&y width:kDetailW];
    [c addDetailHeading:@"Models" key:@"local-history.codex.models" to:root y:&y width:kDetailW];
    NSString *modelsHeading = root.subviews.lastObject.accessibilityIdentifier;
    [c addDetailKey:@"gpt-5.6-sol" value:@"1" to:root y:&y width:kDetailW];
    return @{ @"providerHeading": providerHeading ?: @"",
              @"modelsHeading": modelsHeading ?: @"",
              // addDetailKey adds the key label first, then the focusable value field.
              @"modelRow": root.subviews.lastObject.accessibilityIdentifier ?: @"" };
}

// A rollout line padded to an arbitrary length, so the fixture cannot accidentally align
// its newlines to a power-of-two read boundary the way fixed 4096-byte filler does.
static NSData *PaddedRolloutLine(long long tokens, NSUInteger pad) {
    NSMutableString *filler = [NSMutableString stringWithCapacity:pad];
    for (NSUInteger i = 0; i < pad; i++) [filler appendString:@"x"];
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSString *line = [NSString stringWithFormat:
        @"{\"timestamp\":\"%@\",\"pad\":\"%@\",\"payload\":{\"type\":\"token_count\","
         "\"info\":{\"last_token_usage\":{\"total_tokens\":%lld,\"input_tokens\":0,"
         "\"cached_input_tokens\":0,\"output_tokens\":%lld}}}}\n",
        [iso stringFromDate:NSDate.date], filler, tokens, tokens];
    return [line dataUsingEncoding:NSUTF8StringEncoding];
}

// Draws `view` standalone into a 40x40 bitmap under `name` and samples one pixel.
// Bitmap rows count from the top; the view is unflipped here, so its bounds fill the bottom.
static NSColor *DrawAndSample(NSView *view, NSAppearanceName name, NSInteger x, NSInteger y) {
    view.appearance = [NSAppearance appearanceNamed:name];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:40 pixelsHigh:40 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    [NSColor.clearColor set];
    NSRectFill(NSMakeRect(0, 0, 40, 40));
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        // A hostile dirty rect, far larger than the view's bounds.
        [view drawRect:NSMakeRect(-100, -100, 500, 500)];
    }];
    [NSGraphicsContext restoreGraphicsState];
    return [rep colorAtX:x y:y];
}

// Device-RGB samples must be converted before -whiteComponent is legal.
static CGFloat Brightness(NSColor *color) {
    return [color colorUsingColorSpace:NSColorSpace.genericGrayColorSpace].whiteComponent;
}

static long long TotalTokensInRecord(NSDictionary *record) {
    long long total = 0;
    NSDictionary *days = record[@"days"];
    for (NSString *day in days) {
        NSDictionary *counts = days[day];
        if ([counts isKindOfClass:NSDictionary.class] && [counts[@"t"] isKindOfClass:NSNumber.class])
            total += [counts[@"t"] longLongValue];
    }
    return total;
}

static NSData *RolloutData(NSUInteger fillerBytes, long long tokens) {
    NSMutableData *data = [NSMutableData dataWithCapacity:fillerBytes + 1024];
    char filler[4096];
    memset(filler, 'x', sizeof(filler));
    filler[sizeof(filler) - 1] = '\n';
    while (data.length + sizeof(filler) <= fillerBytes) [data appendBytes:filler length:sizeof(filler)];

    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSString *timestamp = [iso stringFromDate:NSDate.date];
    long long reset = (long long)NSDate.date.timeIntervalSince1970 + 3600;
    NSString *line = [NSString stringWithFormat:
        @"{\"timestamp\":\"%@\",\"payload\":{\"type\":\"token_count\","
         "\"info\":{\"last_token_usage\":{\"total_tokens\":%lld,\"input_tokens\":0,"
         "\"cached_input_tokens\":0,\"output_tokens\":%lld}},\"rate_limits\":{"
         "\"primary\":{\"used_percent\":25,\"window_minutes\":300,\"resets_at\":%lld},"
         "\"secondary\":{\"used_percent\":10,\"window_minutes\":10080,\"resets_at\":%lld}}}}\n",
        timestamp, tokens, tokens, reset, reset];
    [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

static void AppendClaudeEvent(NSMutableData *data, NSString *messageID, long long tokens) {
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSString *timestamp = [iso stringFromDate:NSDate.date];
    NSString *line = [NSString stringWithFormat:
        @"{\"timestamp\":\"%@\",\"message\":{\"id\":\"%@\",\"usage\":{"
         "\"input_tokens\":0,\"output_tokens\":%lld,\"cache_creation_input_tokens\":0,"
         "\"cache_read_input_tokens\":0}}}\n", timestamp, messageID, tokens];
    [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

int main(void) {
    @autoreleasepool {
        check(IsJSONBoolean(JSONBool(YES)) && IsJSONBoolean(JSONBool(NO)),
              @"JSONBool emits real JSON booleans");
        check(!IsJSONBoolean(@1) && !IsJSONBoolean(@0),
              @"schema guard rejects numeric 0/1 masquerading as booleans");

        Controller *barController = [Controller new];
        NSArray *fullBar = @[
            @{@"symbol": @"externaldrive", @"text": @"72%"},
            @{@"symbol": @"battery.100percent", @"text": @"90%",
              @"compactPriority": @YES, @"compactTextOnly": @YES},
        ];
        NSArray *compactBar = [barController barSegmentsForTier:BarTierCompact full:fullBar];
        check(compactBar.count == 1 && [compactBar[0][@"text"] isEqual:@"90%"],
              @"compact bar keeps the priority battery percentage and drops other readings");
        check(compactBar[0][@"symbol"] == nil && compactBar[0][@"image"] == nil,
              @"ordinary compact battery is text-only for the smallest useful width");
        check(compactBar[0][@"compactPriority"] == nil && compactBar[0][@"compactTextOnly"] == nil,
              @"compact bar removes its private layout metadata before rendering");
        CGFloat fullBarWidth = 0, compactBarWidth = 0;
        BarLayout(fullBar, NSColor.controlTextColor, &fullBarWidth);
        BarLayout(compactBar, NSColor.controlTextColor, &compactBarWidth);
        check(compactBarWidth < fullBarWidth,
              @"compact battery percentage is strictly narrower than the full bar");
        NSArray *iconFallback = [barController barSegmentsForTier:BarTierCompact
                                                              full:@[@{@"symbol": @"externaldrive", @"text": @"72%"}]];
        check(iconFallback.count == 1 && iconFallback[0][@"text"] == nil &&
              [iconFallback[0][@"symbol"] isEqual:@"externaldrive"],
              @"compact bar falls back to configured icons when no reading has priority");

        FlippedView *existingView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 200, 80)];
        NSTextField *existingLabel = [NSTextField labelWithString:@"CPU 10%"];
        Gauge *existingGauge = [[Gauge alloc] initWithFrame:NSMakeRect(0, 0, 100, 4)];
        existingGauge.fraction = 0.10;
        NSButton *existingButton = [NSButton buttonWithTitle:@"Reveal" target:nil action:nil];
        existingButton.identifier = @"/Volumes/Old";
        existingLabel.accessibilityLabel = @"Old heading";
        [existingView addSubview:existingLabel];
        [existingView addSubview:existingGauge];
        [existingView addSubview:existingButton];
        FlippedView *freshView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 220, 80)];
        NSTextField *freshLabel = [NSTextField labelWithString:@"CPU 25%"];
        Gauge *freshGauge = [[Gauge alloc] initWithFrame:NSMakeRect(0, 0, 120, 4)];
        freshGauge.fraction = 0.25;
        NSButton *freshButton = [NSButton buttonWithTitle:@"Reveal" target:nil action:nil];
        freshButton.identifier = @"/Volumes/New";
        freshLabel.accessibilityLabel = @"New heading";
        [freshView addSubview:freshLabel];
        [freshView addSubview:freshGauge];
        [freshView addSubview:freshButton];
        check(ReconcileViewTree(existingView, freshView),
              @"compatible live UI tree reconciles without replacement");
        check(existingView.subviews[0] == existingLabel && existingView.subviews[1] == existingGauge &&
              existingView.subviews[2] == existingButton,
              @"live UI reconciliation preserves focused accessibility object identity");
        check([existingLabel.stringValue isEqualToString:@"CPU 25%"] &&
              fabs(existingGauge.fraction - 0.25) < 0.001,
              @"live UI reconciliation updates visible and accessibility values");
        check([existingButton.identifier isEqualToString:@"/Volumes/New"],
              @"live UI reconciliation updates button action identifiers");
        check([existingLabel.accessibilityLabel isEqualToString:@"New heading"],
              @"live UI reconciliation updates semantic accessibility state");
        [freshView addSubview:[NSTextField labelWithString:@"new row"]];
        check(!ReconcileViewTree(existingView, freshView),
              @"structural UI changes use the focus-restoring replacement path");

        // The popover background is drawn, not baked into a CALayer CGColor, so it must
        // resolve differently under Light and Dark.
        PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)];
        NSColor *darkFill = DrawAndSample(panel, NSAppearanceNameDarkAqua, 20, 20);
        NSColor *lightFill = DrawAndSample(panel, NSAppearanceNameAqua, 20, 20);
        check(fabs(Brightness(darkFill) - Brightness(lightFill)) > 0.25,
              @"popover background re-resolves under a Light/Dark switch");

        // A short instance of that view must not paint outside its own bounds, or the fixed
        // footer erases the panel above it.
        PopoverRootView *shortFooter = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, 40, 10)];
        NSColor *insideFooter = DrawAndSample(shortFooter, NSAppearanceNameAqua, 20, 35);
        NSColor *aboveFooter = DrawAndSample(shortFooter, NSAppearanceNameAqua, 20, 5);
        check(insideFooter.alphaComponent > 0.9, @"footer paints its own bounds");
        check(aboveFooter.alphaComponent < 0.1, @"footer fill cannot escape its bounds");

        // Accessibility identifiers name a field, not its build order: inserting a whole
        // section must not rename the rows of an unrelated section below it.
        FlippedView *before = [[FlippedView alloc] initWithFrame:NSZeroRect];
        before.accessibilityIdentifier = @"details.ai";
        before.accessibilitySection = @"ai-status.claude";
        NSString *claudeStatusBefore = DetailIdentifier(before, @"value", @"Status");
        before.accessibilitySection = @"privacy";
        NSString *accountBefore = DetailIdentifier(before, @"value", @"Claude account");

        FlippedView *after = [[FlippedView alloc] initWithFrame:NSZeroRect];
        after.accessibilityIdentifier = @"details.ai";
        after.accessibilitySection = @"ai-status.claude";
        NSString *claudeStatusAfter = DetailIdentifier(after, @"value", @"Status");
        after.accessibilitySection = @"ai-status.codex";          // a provider appears
        DetailIdentifier(after, @"value", @"Remaining");
        NSString *codexStatus = DetailIdentifier(after, @"value", @"Status");
        after.accessibilitySection = @"privacy";
        NSString *accountAfter = DetailIdentifier(after, @"value", @"Claude account");

        check([accountBefore isEqualToString:accountAfter],
              @"a row keeps its identifier when a provider section is inserted above it");
        check([claudeStatusBefore isEqualToString:claudeStatusAfter],
              @"a row keeps its identifier across rebuilds");
        check(![codexStatus isEqualToString:claudeStatusAfter],
              @"the same key under two sections gets two identifiers");

        // The same heading text under two sections ("Claude" in AI Status and again in Local
        // History) must not collide, because the section keys differ.
        FlippedView *repeated = [[FlippedView alloc] initWithFrame:NSZeroRect];
        repeated.accessibilityIdentifier = @"details.ai";
        repeated.accessibilitySection = @"ai-status.claude";
        NSString *limitsStatus = DetailIdentifier(repeated, @"value", @"Status");
        repeated.accessibilitySection = @"local-history.claude";
        NSString *historyStatus = DetailIdentifier(repeated, @"value", @"Status");
        check(![limitsStatus isEqualToString:historyStatus],
              @"the same key under two provider sections does not collide");

        // Drive the real builders. Codex's Models rows must not be renamed by Claude
        // conditionally gaining a Models section above them, and a heading must be named by
        // the section it OPENS, not the one it happens to follow.
        Controller *builder = [Controller new];
        NSDictionary *alone = BuildCodexSubtree(builder, NO);
        NSDictionary *shifted = BuildCodexSubtree(builder, YES);
        check([alone[@"modelRow"] isEqualToString:shifted[@"modelRow"]],
              @"a conditional Models section elsewhere does not rename another provider's models");
        check([alone[@"modelsHeading"] isEqualToString:shifted[@"modelsHeading"]],
              @"a Models heading keeps its identifier when a sibling Models section appears");
        check([alone[@"providerHeading"] isEqualToString:shifted[@"providerHeading"]],
              @"a provider heading keeps its identifier when the section above it grows");
        check([shifted[@"providerHeading"] isEqualToString:@"details.ai.heading.local-history.codex"],
              @"a heading is named by the section it opens, not the one it follows");
        check([shifted[@"modelRow"] isEqualToString:@"details.ai.value.local-history.codex.models.gpt-5.6-sol"],
              @"a row is named by its section path and key");

        // ShortModelName collapses "claude-opus-4-8" and "opus-4-8" onto one display name,
        // and model rows are ordered by usage. Identify them by their raw model id, or the
        // two rows swap identifiers whenever their token counts cross.
        FlippedView *models = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 200)];
        models.accessibilityIdentifier = @"details.ai";
        models.accessibilitySection = @"local-history.claude.models";
        CGFloat my = kDetailPad;
        [builder addDetailKey:ShortModelName(@"claude-opus-4-8") value:@"9" identifierKey:@"claude-opus-4-8"
                           to:models y:&my width:kDetailW];
        NSString *firstModel = models.subviews.lastObject.accessibilityIdentifier;
        [builder addDetailKey:ShortModelName(@"opus-4-8") value:@"3" identifierKey:@"opus-4-8"
                           to:models y:&my width:kDetailW];
        NSString *secondModel = models.subviews.lastObject.accessibilityIdentifier;
        check(![firstModel isEqualToString:secondModel],
              @"models sharing a display name get distinct identifiers");
        check([firstModel containsString:@"claude-opus-4-8"] && ![firstModel hasSuffix:@"#2"],
              @"a model row is identified by its raw id, not its display name or its rank");

        // Reconciliation must not update a focused row in place when that row now means
        // something else. Equal class and subview counts are not enough.
        FlippedView *liveTree = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 100, 40)];
        NSTextField *liveRow = [NSTextField labelWithString:@"1"];
        liveRow.accessibilityIdentifier = @"details.ai.value.local-history.codex.models.gpt-5.6-sol";
        [liveTree addSubview:liveRow];
        FlippedView *renamedTree = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 100, 40)];
        NSTextField *renamedRow = [NSTextField labelWithString:@"2"];
        renamedRow.accessibilityIdentifier = @"details.ai.value.local-history.codex.source";
        [renamedTree addSubview:renamedRow];
        check(!ViewTreesCompatible(liveTree, renamedTree),
              @"a row whose identifier changed forces the focus-restoring replacement path");
        renamedRow.accessibilityIdentifier = liveRow.accessibilityIdentifier;
        check(ViewTreesCompatible(liveTree, renamedTree),
              @"an unchanged identifier still reconciles in place");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"glancebar-ai-reader-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *home = [root stringByAppendingPathComponent:@"home"];
        NSString *support = [root stringByAppendingPathComponent:@"support"];
        NSString *sessions = [home stringByAppendingPathComponent:@".codex/sessions/2026/07/10"];
        NSString *rollout = [sessions stringByAppendingPathComponent:@"rollout-test.jsonl"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:sessions withIntermediateDirectories:YES attributes:nil error:nil];

        // Larger than the 16 MiB global pass budget: the limit snapshot is at the tail,
        // while the usage event must wait for catch-up to reach it historically.
        [RolloutData(20 * 1024 * 1024, 42) writeToFile:rollout atomically:NO];
        AIReader *reader = [[AIReader alloc] initWithHomeDirectory:home
                                      applicationSupportDirectory:support];
        NSArray<AIUsage *> *first = [reader read];
        AIUsage *firstCodex = UsageNamed(first, @"Codex");
        check(reader.totalsIncomplete, @"large history reports incomplete after one bounded pass");
        check(reader.needsImmediateRescan, @"large history requests immediate follow-up");
        check(reader.catchUpProgress > 0 && reader.catchUpProgress < 1, @"catch-up progress is fractional");
        check(firstCodex.limitStatusAvailable, @"tail peek exposes a current limit before history catches up");
        check([firstCodex.statusText containsString:@"totals incomplete"], @"usage status discloses partial totals");

        // Indexing a backlog must not rewrite the whole state file once per pass. Needs a
        // history of at least three 16 MiB passes so the second pass is still mid-catch-up,
        // and its own home so the readers below see an unchanged inventory.
        NSString *coalesceHome = [root stringByAppendingPathComponent:@"home-coalesce"];
        NSString *coalesceSessions = [coalesceHome stringByAppendingPathComponent:@".codex/sessions/2026/07/10"];
        [fm createDirectoryAtPath:coalesceSessions withIntermediateDirectories:YES attributes:nil error:nil];
        [RolloutData(40 * 1024 * 1024, 3) writeToFile:
            [coalesceSessions stringByAppendingPathComponent:@"rollout-coalesce.jsonl"] atomically:NO];
        AIReader *coalescing = [[AIReader alloc] initWithHomeDirectory:coalesceHome
                                          applicationSupportDirectory:
                                              [root stringByAppendingPathComponent:@"support-coalesce"]];
        [coalescing read];
        NSUInteger writesAfterFirstPass = coalescing.stateWriteCount;
        check(writesAfterFirstPass == 1, @"the first bounded pass persists its progress");
        check(coalescing.totalsIncomplete, @"a 40 MiB history is incomplete after one pass");
        [coalescing read];
        check(coalescing.totalsIncomplete, @"and still incomplete after the second pass");
        check(coalescing.stateWriteCount == writesAfterFirstPass,
              @"a catch-up pass moments later coalesces its state write");
        [coalescing readUntilCaughtUpWithTimeLimit:10.0];
        check(coalescing.stateWriteCount > writesAfterFirstPass,
              @"the pass that finishes the backlog flushes state");
        check(!coalescing.totalsIncomplete, @"coalescing reader still completes the backlog");

        NSArray<AIUsage *> *complete = [reader readUntilCaughtUpWithTimeLimit:5.0];
        AIUsage *codex = UsageNamed(complete, @"Codex");
        check(!reader.totalsIncomplete, @"catch-up driver completes the bounded history");
        check(codex.todayTokens == 42, @"historical event is counted exactly once");

        NSString *statePath = [support stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
        check([fm fileExistsAtPath:statePath], @"scanner state is persisted in Application Support");
        NSNumber *mode = [fm attributesOfItemAtPath:statePath error:nil][NSFilePosixPermissions];
        check((mode.unsignedShortValue & 0777) == 0600, @"scanner state is owner-readable only");
        NSString *stateText = [NSString stringWithContentsOfFile:statePath encoding:NSUTF8StringEncoding error:nil];
        check(![stateText containsString:home], @"persisted state does not contain the fixture home path");

        // A fresh reader resumes the persisted offset and aggregate without re-counting.
        AIReader *resumed = [[AIReader alloc] initWithHomeDirectory:home
                                       applicationSupportDirectory:support];
        codex = UsageNamed([resumed read], @"Codex");
        check(codex.todayTokens == 42, @"restart restores totals without duplication");

        // Appends after restart advance the persisted aggregate once.
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:rollout];
        [fh seekToEndOfFile];
        [fh writeData:RolloutData(0, 5)];
        [fh closeFile];
        AIReader *appended = [[AIReader alloc] initWithHomeDirectory:home
                                        applicationSupportDirectory:support];
        codex = UsageNamed([appended readUntilCaughtUpWithTimeLimit:5.0], @"Codex");
        check(codex.todayTokens == 47, @"appended event increments the restored total");

        // Atomic replacement changes file identity; the old file contribution vanishes.
        [RolloutData(0, 7) writeToFile:rollout atomically:YES];
        AIReader *replaced = [[AIReader alloc] initWithHomeDirectory:home
                                        applicationSupportDirectory:support];
        codex = UsageNamed([replaced readUntilCaughtUpWithTimeLimit:5.0], @"Codex");
        check(codex.todayTokens == 7, @"replacement discards the replaced file's aggregate");

        // Same-inode truncate-and-regrow above the former size is caught by the offset
        // anchor even though identity and the simple size comparison both look valid.
        fh = [NSFileHandle fileHandleForWritingAtPath:rollout];
        [fh truncateFileAtOffset:0];
        [fh writeData:RolloutData(1024 * 1024, 9)];
        [fh closeFile];
        AIReader *regrown = [[AIReader alloc] initWithHomeDirectory:home
                                       applicationSupportDirectory:support];
        codex = UsageNamed([regrown readUntilCaughtUpWithTimeLimit:5.0], @"Codex");
        check(codex.todayTokens == 9, @"same-inode truncate/regrow discards the old aggregate");

        // A pass budget that runs out mid-line must not consume that line. Previously the
        // budget and the per-line cap were the same argument, so a residual budget smaller
        // than the next line advanced the offset into it and dropped its tokens for good.
        NSString *straddleDir = [home stringByAppendingPathComponent:@".codex/sessions/2026/07/11"];
        [fm createDirectoryAtPath:straddleDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *straddle = [straddleDir stringByAppendingPathComponent:@"rollout-straddle.jsonl"];
        NSMutableData *straddleData = [NSMutableData data];
        [straddleData appendData:PaddedRolloutLine(100, 1800)];   // ~2 KB line
        [straddleData appendData:PaddedRolloutLine(7, 0)];
        [straddleData writeToFile:straddle atomically:NO];

        AIReader *bounded = [[AIReader alloc] initWithHomeDirectory:home
                                        applicationSupportDirectory:support];
        NSMutableDictionary *rec = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
        NSUInteger boundedBytes = 0;
        BOOL boundedFailed = NO;
        [bounded newLineDataAtPath:straddle record:rec maxBytes:500 lineCap:kAIMaxLineBytes
                         bytesRead:&boundedBytes readFailed:&boundedFailed];
        check([rec[@"offset"] unsignedLongLongValue] == 0,
              @"a budget-truncated read leaves the offset before the unterminated line");
        check(boundedBytes == 500, @"a budget-truncated read still charges the pass budget");
        NSData *boundedChunk = [bounded newLineDataAtPath:straddle record:rec
                                                 maxBytes:16 * 1024 * 1024 lineCap:kAIMaxLineBytes
                                                bytesRead:&boundedBytes readFailed:&boundedFailed];
        [bounded consumeCodexData:boundedChunk record:rec];
        check(TotalTokensInRecord(rec) == 107,
              @"the straddled line's tokens are counted in full on the next pass");

        // A line genuinely longer than the cap is still abandoned, or one pathological row
        // would wedge the scan forever.
        NSMutableDictionary *cappedRec = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
        [bounded newLineDataAtPath:straddle record:cappedRec maxBytes:16 * 1024 * 1024 lineCap:64
                         bytesRead:&boundedBytes readFailed:&boundedFailed];
        check([cappedRec[@"offset"] unsignedLongLongValue] == 64,
              @"a line longer than the cap is abandoned so the scan makes progress");

        // Claude amendments may be far apart. Retain compact hashes for the full file
        // lifetime, and keep both project paths and provider IDs out of persisted state.
        NSString *claudeDir = [home stringByAppendingPathComponent:@".claude/projects/secret-project-name"];
        NSString *transcript = [claudeDir stringByAppendingPathComponent:@"transcript.jsonl"];
        [fm createDirectoryAtPath:claudeDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableData *claudeData = [NSMutableData data];
        AppendClaudeEvent(claudeData, @"provider-message-id-that-must-not-persist", 3);
        for (NSUInteger i = 0; i < 300; i++)
            AppendClaudeEvent(claudeData, [NSString stringWithFormat:@"unique-%lu", (unsigned long)i], 1);
        AppendClaudeEvent(claudeData, @"provider-message-id-that-must-not-persist", 3);
        [claudeData writeToFile:transcript atomically:NO];
        AIReader *claudeReader = [[AIReader alloc] initWithHomeDirectory:home
                                             applicationSupportDirectory:support];
        claudeReader.allowClaudeTranscripts = YES;
        AIUsage *claude = UsageNamed([claudeReader readUntilCaughtUpWithTimeLimit:5.0], @"Claude");
        check(claude.todayTokens == 303, @"far-apart Claude amendment is de-duplicated");
        stateText = [NSString stringWithContentsOfFile:statePath encoding:NSUTF8StringEncoding error:nil];
        check(![stateText containsString:@"secret-project-name"], @"state omits Claude project paths");
        check(![stateText containsString:@"provider-message-id-that-must-not-persist"],
              @"state stores only hashes of Claude message IDs");

        // Withdrawing transcript consent purges the index. That purge must reach the disk on
        // the same pass, even while an unrelated codex backlog keeps progress writes
        // coalesced — hiding every AI surface stops read(), so there may be no next pass.
        NSString *purgeHome = [root stringByAppendingPathComponent:@"home-purge"];
        NSString *purgeSupport = [root stringByAppendingPathComponent:@"support-purge"];
        NSString *purgeSessions = [purgeHome stringByAppendingPathComponent:@".codex/sessions/2026/07/10"];
        NSString *purgeProject = [purgeHome stringByAppendingPathComponent:@".claude/projects/p"];
        [fm createDirectoryAtPath:purgeSessions withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:purgeProject withIntermediateDirectories:YES attributes:nil error:nil];
        [RolloutData(0, 5) writeToFile:[purgeSessions stringByAppendingPathComponent:@"small.jsonl"] atomically:NO];
        NSMutableData *purgeTranscript = [NSMutableData data];
        for (NSUInteger i = 0; i < 20; i++)
            AppendClaudeEvent(purgeTranscript, [NSString stringWithFormat:@"purge-%lu", (unsigned long)i], 2);
        [purgeTranscript writeToFile:[purgeProject stringByAppendingPathComponent:@"t.jsonl"] atomically:NO];

        AIReader *purging = [[AIReader alloc] initWithHomeDirectory:purgeHome
                                        applicationSupportDirectory:purgeSupport];
        purging.allowClaudeTranscripts = YES;
        [purging readUntilCaughtUpWithTimeLimit:5.0];
        NSString *purgeStatePath = [purgeSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
        NSDictionary *indexed = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:purgeStatePath] options:0 error:nil];
        check([indexed[@"claudeFiles"] count] > 0, @"transcripts were indexed while consent was given");

        // The active session grows by a backlog, so the next pass is mid-catch-up and would
        // coalesce its progress write. (A brand-new file would sit behind the 30s inventory
        // cache; growing the live rollout is both realistic and immediately visible.)
        NSFileHandle *grow = [NSFileHandle fileHandleForWritingAtPath:
            [purgeSessions stringByAppendingPathComponent:@"small.jsonl"]];
        [grow seekToEndOfFile];
        [grow writeData:RolloutData(40 * 1024 * 1024, 1)];
        [grow closeFile];
        NSUInteger writesBeforePurge = purging.stateWriteCount;
        purging.allowClaudeTranscripts = NO;
        [purging read];
        check(purging.needsImmediateRescan, @"the backlog really does keep this pass mid-catch-up");
        check(purging.stateWriteCount > writesBeforePurge,
              @"withdrawing transcript consent is persisted immediately, not coalesced");
        NSDictionary *purged = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:purgeStatePath] options:0 error:nil];
        check([purged[@"claudeFiles"] count] == 0, @"the purge left no transcript index on disk");

        // A failed refresh may retain the last good account response, but the UI model
        // must identify it as cached/stale and keep the failure reason visible.
        double now = NSDate.date.timeIntervalSince1970;
        AIReader *cachedAccount = [[AIReader alloc] initWithHomeDirectory:home
                                              applicationSupportDirectory:support];
        cachedAccount.useClaudeAccount = YES;
        cachedAccount.allowClaudeAccountFetch = NO;
        [cachedAccount setValue:@{ @"five_hour": @{ @"utilization": @25,
                                                     @"resets_at": @(now + 3600) } }
                          forKey:@"claudeUsageJSON"];
        [cachedAccount setValue:@"Usage API unavailable" forKey:@"claudeAccountStatus"];
        [cachedAccount setValue:@(now - 120) forKey:@"claudeLastSuccessAt"];
        claude = UsageNamed([cachedAccount read], @"Claude");
        check(claude.limitStatusAvailable, @"cached Claude limit remains usable after refresh failure");
        check(claude.limitStale, @"cached Claude limit is explicitly marked stale");
        check([claude.statusReason containsString:@"Cached"] &&
              [claude.statusReason containsString:@"Usage API unavailable"],
              @"cached Claude limit preserves its refresh error");
        check(claude.limitUpdatedAt != nil, @"cached Claude limit retains last-success time");
        check([RequestedAIAccountError(@[claude], YES) isEqualToString:@"Usage API unavailable"],
              @"requested failed Claude account source is strict-partial");
        check(RequestedAIAccountError(@[claude], NO) == nil,
              @"unrequested Claude account source is optional");

        // Last-good Claude usage JSON is persisted like Codex limits, so a restart can
        // paint the gauge without a network round-trip (marked stale until a live fetch).
        NSString *persistHome = [root stringByAppendingPathComponent:@"home-persist"];
        NSString *persistSupport = [root stringByAppendingPathComponent:@"support-persist"];
        [fm createDirectoryAtPath:persistSupport withIntermediateDirectories:YES attributes:nil error:nil];
        // CursorUsage is only attached when Cursor's local session DB exists.
        NSString *cursorDBDir = [persistHome stringByAppendingPathComponent:
            @"Library/Application Support/Cursor/User/globalStorage"];
        [fm createDirectoryAtPath:cursorDBDir withIntermediateDirectories:YES attributes:nil error:nil];
        [@"" writeToFile:[cursorDBDir stringByAppendingPathComponent:@"state.vscdb"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
        AIReader *persistWriter = [[AIReader alloc] initWithHomeDirectory:persistHome
                                              applicationSupportDirectory:persistSupport];
        persistWriter.useClaudeAccount = YES;
        persistWriter.allowClaudeAccountFetch = NO;
        persistWriter.useCursorAccount = YES;
        persistWriter.allowCursorAccountFetch = NO;
        double persistNow = NSDate.date.timeIntervalSince1970;
        [persistWriter setValue:@{ @"five_hour": @{ @"utilization": @30,
                                                     @"resets_at": @(persistNow + 7200) },
                                   @"seven_day": @{ @"utilization": @70,
                                                    @"resets_at": @(persistNow + 86400) } }
                          forKey:@"claudeUsageJSON"];
        [persistWriter setValue:@(persistNow - 30) forKey:@"claudeLastSuccessAt"];
        [persistWriter setValue:@{ @"billingCycleEnd": @((persistNow + 86400) * 1000.0),
                                   @"planUsage": @{ @"remaining": @1000, @"limit": @4000 } }
                          forKey:@"cursorUsageJSON"];
        [persistWriter setValue:@(persistNow - 30) forKey:@"cursorLastSuccessAt"];
        [persistWriter setValue:@YES forKey:@"stateDirty"];
        [persistWriter flushPersistentState];
        NSString *persistStatePath = [persistSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
        NSDictionary *persisted = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:persistStatePath] options:0 error:nil];
        check([persisted[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class],
              @"Claude usage JSON was written to the state file");
        check([persisted[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class],
              @"Claude fetch timestamp was written");
        check([persisted[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class],
              @"Cursor usage JSON was written to the state file");

        AIReader *restored = [[AIReader alloc] initWithHomeDirectory:persistHome
                                         applicationSupportDirectory:persistSupport];
        restored.useClaudeAccount = YES;
        restored.allowClaudeAccountFetch = NO;
        restored.useCursorAccount = YES;
        restored.allowCursorAccountFetch = NO;
        NSArray<AIUsage *> *restoredUsage = [restored read];
        AIUsage *restoredClaude = UsageNamed(restoredUsage, @"Claude");
        AIUsage *restoredCursor = UsageNamed(restoredUsage, @"Cursor");
        check(restoredClaude.limitStatusAvailable, @"restored Claude gauge without network");
        check(restoredClaude.limitStale, @"disk-restored Claude is stale until fetch this run");
        check(fabs(restoredClaude.remainingFraction - 0.30) < 0.001,
              @"restored Claude picks the most constrained live window");
        check(restoredCursor.limitStatusAvailable, @"restored Cursor gauge without network");
        check(restoredCursor.limitStale, @"disk-restored Cursor is stale until fetch this run");

        // Rate-limit after a good cache must keep the gauge and name the last refresh.
        AIReader *rateLimited = [[AIReader alloc] initWithHomeDirectory:persistHome
                                            applicationSupportDirectory:persistSupport];
        rateLimited.useClaudeAccount = YES;
        rateLimited.allowClaudeAccountFetch = NO;
        [rateLimited setValue:@"Usage API rate-limited; retrying later" forKey:@"claudeAccountStatus"];
        AIUsage *rateLimitedClaude = UsageNamed([rateLimited read], @"Claude");
        check(rateLimitedClaude.limitStatusAvailable,
              @"rate-limited Claude still shows last-known gauge");
        check(rateLimitedClaude.limitStale, @"rate-limited Claude is marked stale");
        check([rateLimitedClaude.statusReason containsString:@"Cached limit"],
              @"rate-limited Claude status keeps Cached limit framing");
        check([rateLimitedClaude.statusReason containsString:@"rate-limited"],
              @"rate-limited Claude status keeps the refresh error");
        check([rateLimitedClaude.statusReason containsString:@"as of"],
              @"rate-limited Claude status includes known last-success time");
        check(rateLimitedClaude.resetText.length &&
              ![rateLimitedClaude.resetText isEqualToString:@"Not exposed locally"],
              @"rate-limited Claude still exposes last-known reset text");

        // A reader that indexes/saves without a Claude fetch must not wipe a sibling's
        // persisted account cache (dump/offline writers used to omit the keys).
        AIReader *indexer = [[AIReader alloc] initWithHomeDirectory:persistHome
                                        applicationSupportDirectory:persistSupport];
        indexer.useClaudeAccount = YES;
        indexer.allowClaudeAccountFetch = NO;
        // Drop the in-memory cache as if this process never fetched, then dirty+save.
        [indexer setValue:nil forKey:@"claudeUsageJSON"];
        [indexer setValue:@0 forKey:@"claudeLastSuccessAt"];
        [indexer setValue:@YES forKey:@"stateDirty"];
        [indexer flushPersistentState];
        NSDictionary *preserved = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:persistStatePath] options:0 error:nil];
        check([preserved[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class],
              @"save without an in-memory Claude cache preserves the on-disk last-known");

        // Elapsed-only Claude windows still surface last-known % + reset as stale.
        AIReader *elapsedReader = [[AIReader alloc] initWithHomeDirectory:persistHome
                                              applicationSupportDirectory:persistSupport];
        elapsedReader.useClaudeAccount = YES;
        elapsedReader.allowClaudeAccountFetch = NO;
        [elapsedReader setValue:@{ @"five_hour": @{ @"utilization": @40, @"resets_at": @(persistNow - 100) },
                                   @"seven_day": @{ @"utilization": @85, @"resets_at": @(persistNow - 10) } }
                          forKey:@"claudeUsageJSON"];
        [elapsedReader setValue:@(persistNow - 200) forKey:@"claudeLastSuccessAt"];
        AIUsage *elapsedClaude = UsageNamed([elapsedReader read], @"Claude");
        check(elapsedClaude.limitStatusAvailable, @"elapsed Claude windows still show a gauge");
        check(elapsedClaude.limitStale, @"elapsed Claude windows are marked stale");
        check(fabs(elapsedClaude.remainingFraction - 0.15) < 0.001,
              @"elapsed Claude pick keeps last-known weekly utilization");
        check([elapsedClaude.statusReason hasPrefix:@"Limit windows reset since last Claude refresh"],
              @"elapsed Claude status names the last refresh");

        // Codex meters several limit_id buckets in one session (shapes from 2026-09-07:
        // the plan bucket's weekly window at 99% in the PRIMARY slot, a side bucket at
        // 0%/0% seconds later, then "premium" with both windows null and no credits).
        // The spent plan bucket must govern even though the side bucket reported last.
        {
            NSString *bHome = [root stringByAppendingPathComponent:@"home-buckets"];
            NSString *bSupport = [root stringByAppendingPathComponent:@"support-buckets"];
            NSString *bSessions = [bHome stringByAppendingPathComponent:@".codex/sessions/2026/09/07"];
            [fm createDirectoryAtPath:bSessions withIntermediateDirectories:YES attributes:nil error:nil];
            long long nowEpoch = (long long)NSDate.date.timeIntervalSince1970;
            NSString *usage = @"\"info\":{\"last_token_usage\":{\"total_tokens\":10,\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":0}}";
            NSString *credits = @"\"credits\":{\"has_credits\":false,\"unlimited\":false,\"balance\":\"0\"}";
            NSString *lines = [NSString stringWithFormat:
                @"{\"timestamp\":\"2026-09-07T05:45:58.309Z\",\"payload\":{\"type\":\"token_count\",%@,\"rate_limits\":{\"limit_id\":\"codex\",\"plan_type\":\"pro\",\"primary\":{\"used_percent\":99.0,\"window_minutes\":10080,\"resets_at\":%lld},\"secondary\":null,%@}}}\n"
                 "{\"timestamp\":\"2026-09-07T05:53:27.384Z\",\"payload\":{\"type\":\"token_count\",%@,\"rate_limits\":{\"limit_id\":\"codex_bengalfox\",\"plan_type\":\"pro\",\"primary\":{\"used_percent\":0.0,\"window_minutes\":300,\"resets_at\":%lld},\"secondary\":{\"used_percent\":0.0,\"window_minutes\":10080,\"resets_at\":%lld},%@}}}\n"
                 "{\"timestamp\":\"2026-09-07T05:54:01.194Z\",\"payload\":{\"type\":\"token_count\",%@,\"rate_limits\":{\"limit_id\":\"premium\",\"plan_type\":\"pro\",\"primary\":null,\"secondary\":null,%@}}}\n",
                usage, nowEpoch + 5 * 86400, credits,
                usage, nowEpoch + 3600, nowEpoch + 7 * 86400, credits,
                usage, credits];
            NSString *rolloutPath = [bSessions stringByAppendingPathComponent:@"rollout-buckets.jsonl"];
            [lines writeToFile:rolloutPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
            AIReader *bucketReader = [[AIReader alloc] initWithHomeDirectory:bHome applicationSupportDirectory:bSupport];
            AIUsage *codexB = UsageNamed([bucketReader readUntilCaughtUpWithTimeLimit:5.0], @"Codex");
            check(codexB.limitStatusAvailable && fabs(codexB.remainingFraction - 0.01) < 0.001,
                  @"buckets: the spent plan window is the gauge, not the untouched side bucket");
            check(codexB.limitWindows.count == 3, @"buckets: all three current windows are listed");
            check([codexB.limitWindows[0][@"bucket"] isEqual:@"codex"], @"buckets: the plan bucket is listed first");
            check([codexB.billingNote isEqual:@"Requests now bill to credits · none available"],
                  @"buckets: the billing note says where requests go now");
            check([codexB.statusReason containsString:@"weekly window · plan bucket · pro plan"],
                  @"buckets: the status names the governing bucket");
            check([codexB.extraUsage isEqual:@"No credits (balance 0)"], @"buckets: credits still read from the newest bucket");
            check(codexB.limitRefreshError == nil, @"buckets: a null-window premium snapshot is not schema drift");
            check(codexB.resetAt && fabs(codexB.resetAt.timeIntervalSince1970 - (nowEpoch + 5 * 86400)) < 1,
                  @"buckets: the reset is the plan window's own");

            NSString *bState = [bSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
            NSDictionary *bRoot = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:bState]
                                                                   options:0 error:nil];
            check([bRoot[@"codexBuckets"] count] == 3, @"buckets: persisted per limit_id");
            check(bRoot[@"codexLimits"] == nil, @"buckets: the blended codexLimits key is retired");
            NSDictionary *bucketRecord = [bRoot[@"codexFiles"] allValues].firstObject;
            check(bucketRecord[@"latestBuckets"] != nil || bucketRecord[@"peekBuckets"] != nil,
                  @"buckets: records carry per-bucket limits");
            check(bucketRecord[@"latestLimits"] == nil, @"buckets: records no longer carry the blend");
            AIReader *bucketRestored = [[AIReader alloc] initWithHomeDirectory:bHome applicationSupportDirectory:bSupport];
            AIUsage *codexRestored = UsageNamed([bucketRestored read], @"Codex");
            check(fabs(codexRestored.remainingFraction - 0.01) < 0.001, @"buckets: restored state keeps the plan gauge");

            // Upgrade path: a pre-bucket record carries one blended latestLimits filed under
            // whichever limit_id reported last. It is not trusted; the tail is re-peeked.
            NSMutableDictionary *legacyRoot = [bRoot mutableCopy];
            NSMutableDictionary *legacyFiles = [NSMutableDictionary dictionary];
            NSDictionary *blend = @{@"limit_id": @"premium", @"plan_type": @"pro",
                                    @"primary": @{@"used_percent": @0.0, @"window_minutes": @300,
                                                  @"resets_at": @(nowEpoch + 3600)}};
            for (NSString *key in bRoot[@"codexFiles"]) {
                NSMutableDictionary *r = [bRoot[@"codexFiles"][key] mutableCopy];
                for (NSString *k in @[@"latestBuckets", @"latestNewest", @"latestNewestTs",
                                      @"peekBuckets", @"peekNewest", @"peekNewestTs"])
                    [r removeObjectForKey:k];
                r[@"latestLimits"] = blend;
                r[@"latestTs"] = @"2026-09-07T05:54:01.194Z";
                r[@"tailSize"] = r[@"size"];   // "already peeked" — the upgrade must undo this
                legacyFiles[key] = r;
            }
            legacyRoot[@"codexFiles"] = legacyFiles;
            [legacyRoot removeObjectForKey:@"codexBuckets"];
            legacyRoot[@"codexLimits"] = blend;
            legacyRoot[@"codexLimitsTs"] = @"2026-09-07T05:54:01.194Z";
            [[NSJSONSerialization dataWithJSONObject:legacyRoot options:0 error:nil] writeToFile:bState atomically:YES];
            AIReader *upgraded = [[AIReader alloc] initWithHomeDirectory:bHome applicationSupportDirectory:bSupport];
            AIUsage *codexUpgraded = UsageNamed([upgraded readUntilCaughtUpWithTimeLimit:5.0], @"Codex");
            check(fabs(codexUpgraded.remainingFraction - 0.01) < 0.001,
                  @"upgrade: a blended legacy record is re-peeked, not trusted");
            check(codexUpgraded.limitWindows.count == 3, @"upgrade: the re-peek restores every bucket");
        }

        // Claude activity comes from the transcripts themselves: per-model tokens,
        // sessions (subagent transcripts excluded), messages, tool calls, last activity.
        {
            NSString *cHome = [root stringByAppendingPathComponent:@"home-claude-activity"];
            NSString *cSupport = [root stringByAppendingPathComponent:@"support-claude-activity"];
            NSString *proj = [cHome stringByAppendingPathComponent:@".claude/projects/p"];
            NSString *subDir = [proj stringByAppendingPathComponent:@"session-1/subagents"];
            [fm createDirectoryAtPath:subDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSISO8601DateFormatter *isoNow = [NSISO8601DateFormatter new];
            NSString *(^message)(NSString *, NSString *, long long, int) = ^(NSString *msgID, NSString *model, long long out, int tools) {
                NSMutableString *content = [NSMutableString stringWithString:@"[{\"type\":\"text\",\"text\":\"x\"}"];
                for (int i = 0; i < tools; i++) [content appendFormat:@",{\"type\":\"tool_use\",\"id\":\"t%d\",\"name\":\"Bash\"}", i];
                [content appendString:@"]"];
                return [NSString stringWithFormat:
                    @"{\"type\":\"assistant\",\"timestamp\":\"%@\",\"message\":{\"id\":\"%@\",\"model\":\"%@\",\"content\":%@,"
                     "\"usage\":{\"input_tokens\":1,\"output_tokens\":%lld,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n",
                    [isoNow stringFromDate:NSDate.date], msgID, model, content, out];
            };
            NSString *main1 = [message(@"m1", @"claude-fable-5-1", 100, 1) stringByAppendingString:message(@"m2", @"claude-fable-5-1", 50, 0)];
            [main1 writeToFile:[proj stringByAppendingPathComponent:@"session-1.jsonl"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
            [message(@"m3", @"claude-sonnet-5", 30, 0) writeToFile:[proj stringByAppendingPathComponent:@"session-2.jsonl"]
                                                        atomically:NO encoding:NSUTF8StringEncoding error:nil];
            [message(@"m4", @"claude-fable-5-1", 20, 0) writeToFile:[subDir stringByAppendingPathComponent:@"agent-a.jsonl"]
                                                         atomically:NO encoding:NSUTF8StringEncoding error:nil];
            // A streamed message: three lines with one id, usage a running placeholder on the
            // first two (output 1, 1) and the real count on the last (385); blocks text /
            // tool_use / tool_use. The real shape from ~/.claude/projects on 2026-09-07.
            NSString *(^streamed)(NSString *, long long, NSString *) = ^(NSString *msgID, long long out, NSString *block) {
                return [NSString stringWithFormat:
                    @"{\"type\":\"assistant\",\"timestamp\":\"%@\",\"message\":{\"id\":\"%@\",\"model\":\"claude-fable-5-1\",\"content\":[%@],"
                     "\"usage\":{\"input_tokens\":2,\"output_tokens\":%lld,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":100}}}\n",
                    [isoNow stringFromDate:NSDate.date], msgID, block, out];
            };
            NSString *text = @"{\"type\":\"text\",\"text\":\"x\"}", *tool = @"{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"Bash\"}";
            NSString *streamedPath = [proj stringByAppendingPathComponent:@"session-3.jsonl"];
            NSString *firstTwo = [streamed(@"s1", 1, text) stringByAppendingString:streamed(@"s1", 1, tool)];
            [firstTwo writeToFile:streamedPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
            AIReader *streamReader = [[AIReader alloc] initWithHomeDirectory:cHome applicationSupportDirectory:cSupport];
            streamReader.allowClaudeTranscripts = YES;
            AIUsage *streamed1 = UsageNamed([streamReader readUntilCaughtUpWithTimeLimit:5.0], @"Claude");
            long long baseline = 204;   // the other three transcripts
            check(streamed1.todayTokens == baseline + 3, @"streamed: the first reading counts once");
            // The completing line lands in a LATER pass: only the growth is added.
            NSFileHandle *appendHandle = [NSFileHandle fileHandleForWritingAtPath:streamedPath];
            [appendHandle seekToEndOfFile];
            [appendHandle writeData:[streamed(@"s1", 385, tool) dataUsingEncoding:NSUTF8StringEncoding]];
            [appendHandle closeFile];
            AIUsage *streamed2 = UsageNamed([streamReader readUntilCaughtUpWithTimeLimit:5.0], @"Claude");
            check(streamed2.todayTokens == baseline + 387, @"streamed: the final reading replaces the placeholder, not adds to it");
            check(streamed2.todayTokensAll == baseline + 387 + 100, @"streamed: cached context is counted once per message too");
            check(streamed2.todayMessages == 5, @"streamed: one message, however many lines");
            check(streamed2.todayToolCalls == 3, @"streamed: tool_use blocks across all lines add up");
            NSString *streamState = [NSString stringWithContentsOfFile:
                [cSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"] encoding:NSUTF8StringEncoding error:nil];
            check(![streamState containsString:@"\"ids\""] && [streamState containsString:@"\"idv\""],
                  @"streamed: per-id readings replace the bare hash list");
            [fm removeItemAtPath:streamedPath error:nil];
            [fm removeItemAtPath:[cSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"] error:nil];

            AIReader *activityReader = [[AIReader alloc] initWithHomeDirectory:cHome applicationSupportDirectory:cSupport];
            activityReader.allowClaudeTranscripts = YES;
            AIUsage *activity = UsageNamed([activityReader readUntilCaughtUpWithTimeLimit:5.0], @"Claude");
            check(activity.todaySessions == 2 && activity.weekSessions == 2, @"activity: subagent transcripts are not sessions");
            check(activity.todayMessages == 4, @"activity: every assistant message counts, subagents included");
            check(activity.todayToolCalls == 1, @"activity: tool_use blocks are counted");
            check(activity.todayTokens == 4 + 200, @"activity: token totals unchanged by the new counters");
            check(activity.models.count == 2 && [activity.models[0][@"name"] isEqual:@"claude-fable-5-1"] &&
                  [activity.models[0][@"tokens"] longLongValue] == 173 && [activity.models[1][@"tokens"] longLongValue] == 31,
                  @"activity: models ranked by 7-day fresh tokens");
            check([activity.topModel isEqual:@"claude-fable-5-1"], @"activity: top model follows the ranking");
            check(activity.lastActivity && fabs(activity.lastActivity.timeIntervalSinceNow) < 120,
                  @"activity: last activity is the newest message time, not a stats-cache mtime");
            check([activity.source isEqual:@"~/.claude transcripts"], @"activity: the source no longer claims the stats cache");
            NSString *cState = [cSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
            NSString *cStateText = [NSString stringWithContentsOfFile:cState encoding:NSUTF8StringEncoding error:nil];
            check(![cStateText containsString:@"subagents"] && ![cStateText containsString:@"session-1"],
                  @"activity: the subagent flag persists without any path");

            // A record indexed before these counters existed is re-read from the start.
            NSMutableDictionary *cRoot = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:cState]
                                                                          options:0 error:nil] mutableCopy];
            NSMutableDictionary *oldFiles = [NSMutableDictionary dictionary];
            for (NSString *key in cRoot[@"claudeFiles"]) {
                NSMutableDictionary *r = [cRoot[@"claudeFiles"][key] mutableCopy];
                [r removeObjectForKey:@"v"]; [r removeObjectForKey:@"lastTs"]; [r removeObjectForKey:@"sub"];
                NSMutableDictionary *days = [NSMutableDictionary dictionary];
                for (NSString *day in r[@"days"])
                    days[day] = @{@"t": r[@"days"][day][@"t"], @"f": r[@"days"][day][@"f"]};
                r[@"days"] = days;
                oldFiles[key] = r;
            }
            cRoot[@"claudeFiles"] = oldFiles;
            [[NSJSONSerialization dataWithJSONObject:cRoot options:0 error:nil] writeToFile:cState atomically:YES];
            AIReader *reindexed = [[AIReader alloc] initWithHomeDirectory:cHome applicationSupportDirectory:cSupport];
            reindexed.allowClaudeTranscripts = YES;
            AIUsage *again = UsageNamed([reindexed readUntilCaughtUpWithTimeLimit:5.0], @"Claude");
            check(again.models.count == 2 && again.todaySessions == 2 && again.todayTokens == 204,
                  @"upgrade: a pre-schema transcript record is re-indexed once, without double counting");
        }

        // The whole account path — credential read, throttle, fetch, error handling —
        // driven through the injectable seams, so no Keychain, sqlite or network is touched.
        {
            NSString *aHome = [root stringByAppendingPathComponent:@"home-account"];
            NSString *aSupport = [root stringByAppendingPathComponent:@"support-account"];
            [fm createDirectoryAtPath:aHome withIntermediateDirectories:YES attributes:nil error:nil];
            double base = NSDate.date.timeIntervalSince1970;
            NSDictionary *(^usageBody)(double, double) = ^(double fivePct, double weeklyPct) {
                return @{@"limits": @[
                    @{@"kind": @"session", @"percent": @(fivePct), @"resets_at": @(base + 3600), @"is_active": @YES},
                    @{@"kind": @"weekly_all", @"percent": @(weeklyPct), @"resets_at": @(base + 86400), @"is_active": @NO}]};
            };

            // 1. A live credential and a good response: one fetch, gauge from the body.
            __block NSUInteger credentialReads = 0, fetches = 0;
            AIReader *live = [[AIReader alloc] initWithHomeDirectory:aHome applicationSupportDirectory:aSupport];
            live.claudeCredentialReader = ^NSDictionary *{
                credentialReads++;
                return @{@"token": @"tok-live", @"expiresAt": @(base + 3600)};
            };
            live.claudeUsageFetcher = ^NSDictionary *(NSString *token) {
                fetches++;
                check([token isEqual:@"tok-live"], @"account: the fetch gets the credential's token");
                return usageBody(40, 10);
            };
            live.useClaudeAccount = YES;
            live.allowClaudeAccountFetch = YES;
            AIUsage *fetched = UsageNamed([live read], @"Claude");
            check(fetches == 1 && credentialReads == 1, @"account: one credential read and one fetch");
            check(fetched.limitStatusAvailable && fabs(fetched.remainingFraction - 0.60) < 0.001,
                  @"account: the gauge comes from the fetched body");
            check(!fetched.limitStale && [fetched.statusSource isEqual:@"Anthropic usage API (opt-in)"],
                  @"account: a fresh fetch is not stale");
            // 2. The throttle holds for the poll interval, and the cached token is reused.
            UsageNamed([live read], @"Claude");
            check(fetches == 1 && credentialReads == 1, @"account: the 15-minute throttle blocks the next read");
            check([[NSString stringWithContentsOfFile:[aSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"]
                                             encoding:NSUTF8StringEncoding error:nil] rangeOfString:@"tok-live"].location == NSNotFound,
                  @"account: the token never reaches the state file");

            // 3. An expired credential: no fetch, and the row says what the user must do.
            AIReader *expired = [[AIReader alloc] initWithHomeDirectory:aHome applicationSupportDirectory:aSupport];
            __block NSUInteger expiredFetches = 0;
            expired.claudeCredentialReader = ^NSDictionary *{ return @{@"token": @"tok-old", @"expiresAt": @(base - 60)}; };
            expired.claudeUsageFetcher = ^NSDictionary *(NSString *__unused token) { expiredFetches++; return usageBody(0, 0); };
            expired.useClaudeAccount = YES;
            expired.allowClaudeAccountFetch = YES;
            [expired setValue:nil forKey:@"claudeUsageJSON"];
            [expired setValue:@0 forKey:@"claudeLastSuccessAt"];
            [expired setValue:@0 forKey:@"claudeNextFetch"];
            AIUsage *expiredUsage = UsageNamed([expired read], @"Claude");
            check(expiredFetches == 0, @"account: an expired token is never sent");
            check([expiredUsage.statusReason containsString:@"open Claude Code to refresh it"],
                  @"account: the row names the action, not an open-ended wait");
            check([expiredUsage.limitRefreshError containsString:@"expired"],
                  @"account: the refresh error survives to Details");

            // 4. A cached body plus a failing refresh: the old gauge stays, marked stale
            //    and dated, and a 429 pushes the next attempt past the standard throttle.
            AIReader *failing = [[AIReader alloc] initWithHomeDirectory:aHome applicationSupportDirectory:aSupport];
            failing.claudeCredentialReader = ^NSDictionary *{ return @{@"token": @"tok", @"expiresAt": @(base + 3600)}; };
            failing.claudeUsageFetcher = ^NSDictionary *(NSString *__unused token) {
                return @{@"_glancebarFetchError": @YES, @"statusCode": @429, @"rateLimited": @YES,
                         @"retryAfter": @1800, @"message": @"Too Many Requests"};
            };
            failing.useClaudeAccount = YES;
            failing.allowClaudeAccountFetch = YES;
            [failing setValue:usageBody(40, 10) forKey:@"claudeUsageJSON"];
            [failing setValue:@(base - 7200) forKey:@"claudeLastSuccessAt"];
            [failing setValue:@0 forKey:@"claudeNextFetch"];
            AIUsage *failed = UsageNamed([failing read], @"Claude");
            check(fabs(failed.remainingFraction - 0.60) < 0.001, @"account: a failed refresh keeps the last good gauge");
            check(failed.limitStale && [failed.statusReason hasPrefix:@"Cached limit · Usage API rate-limited"],
                  @"account: the failure is named beside the cached figure");
            check([failed.statusReason containsString:@"as of"], @"account: a cached figure says when it was taken");
            check([[failing valueForKey:@"claudeNextFetch"] doubleValue] >= base + 1700,
                  @"account: a 429's Retry-After defers the next attempt");

            // 5. A 401 drops the cached token so the next attempt re-reads the credential.
            __block NSUInteger reReads = 0;
            AIReader *revoked = [[AIReader alloc] initWithHomeDirectory:aHome applicationSupportDirectory:aSupport];
            revoked.claudeCredentialReader = ^NSDictionary *{
                reReads++;
                return @{@"token": @"tok", @"expiresAt": @(base + 3600)};
            };
            revoked.claudeUsageFetcher = ^NSDictionary *(NSString *__unused token) {
                return @{@"_glancebarFetchError": @YES, @"statusCode": @401, @"rateLimited": @NO,
                         @"retryAfter": @0, @"message": @"Unauthorized"};
            };
            revoked.useClaudeAccount = YES;
            revoked.allowClaudeAccountFetch = YES;
            [revoked setValue:@0 forKey:@"claudeNextFetch"];
            [revoked read];
            check(reReads == 1 && [revoked valueForKey:@"claudeAccessToken"] == nil,
                  @"account: a 401 drops the cached token");

            // 6. Cursor runs the same path through its own seams.
            NSString *cursorDir = [aHome stringByAppendingPathComponent:@"Library/Application Support/Cursor/User/globalStorage"];
            [fm createDirectoryAtPath:cursorDir withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:[cursorDir stringByAppendingPathComponent:@"state.vscdb"] atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
            AIReader *cursor = [[AIReader alloc] initWithHomeDirectory:aHome applicationSupportDirectory:aSupport];
            __block NSUInteger cursorFetches = 0;
            cursor.cursorTokenReader = ^NSString *(NSString *__unused home) { return @"cursor-tok"; };
            cursor.cursorUsageFetcher = ^NSDictionary *(NSString *__unused token) {
                cursorFetches++;
                return @{@"billingCycleEnd": @((base + 86400) * 1000),
                         @"planUsage": @{@"totalSpend": @2500, @"limit": @10000, @"totalPercentUsed": @25.0}};
            };
            cursor.useCursorAccount = YES;
            cursor.allowCursorAccountFetch = YES;
            [cursor setValue:nil forKey:@"cursorUsageJSON"];
            [cursor setValue:@0 forKey:@"cursorNextFetch"];
            AIUsage *cursorUsage = UsageNamed([cursor read], @"Cursor");
            check(cursorFetches == 1 && cursorUsage.limitStatusAvailable,
                  @"account: Cursor fetches through its own seam and gets a gauge");
            check(fabs(cursorUsage.remainingFraction - 0.75) < 0.001, @"account: Cursor plan spend drives the gauge");
            check([cursorUsage.statusSource isEqual:@"Cursor usage API (opt-in)"], @"account: Cursor names its own source");
        }

        // Two processes share the state file: a fresher account response written by one
        // (the CLI's --dump --online) must be adopted by the other, not overwritten.
        {
            NSString *sHome = [root stringByAppendingPathComponent:@"home-shared"];
            NSString *sSupport = [root stringByAppendingPathComponent:@"support-shared"];
            [fm createDirectoryAtPath:sHome withIntermediateDirectories:YES attributes:nil error:nil];
            double base = NSDate.date.timeIntervalSince1970;
            NSDictionary *(^body)(double) = ^(double pct) {
                return @{@"limits": @[@{@"kind": @"weekly_all", @"percent": @(pct), @"resets_at": @(base + 86400)}]};
            };
            AIReader *gui = [[AIReader alloc] initWithHomeDirectory:sHome applicationSupportDirectory:sSupport];
            gui.useClaudeAccount = YES;
            gui.allowClaudeAccountFetch = NO;
            [gui setValue:body(10) forKey:@"claudeUsageJSON"];
            [gui setValue:@(base - 7200) forKey:@"claudeLastSuccessAt"];
            [gui setValue:@YES forKey:@"stateDirty"];   // stand in for the fetch that would have set it
            AIUsage *old = UsageNamed([gui read], @"Claude");
            check(fabs(old.remainingFraction - 0.90) < 0.001, @"shared: the GUI starts on its own two-hour-old cache");

            AIReader *cli = [[AIReader alloc] initWithHomeDirectory:sHome applicationSupportDirectory:sSupport];
            cli.useClaudeAccount = YES;
            cli.allowClaudeAccountFetch = NO;
            [cli setValue:body(80) forKey:@"claudeUsageJSON"];
            [cli setValue:@(base - 5) forKey:@"claudeLastSuccessAt"];
            [cli setValue:@YES forKey:@"stateDirty"];
            [cli read];   // writes the fresher response to the shared file
            // The GUI's own copy is older; only an mtime change makes it look again.
            [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:1]}
                                             ofItemAtPath:[sSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"]
                                                    error:nil];

            AIUsage *adopted = UsageNamed([gui read], @"Claude");
            check(fabs(adopted.remainingFraction - 0.20) < 0.001,
                  @"shared: the GUI adopts the fresher on-disk response instead of overwriting it");
            NSDictionary *onDisk = [NSJSONSerialization JSONObjectWithData:
                [NSData dataWithContentsOfFile:[sSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"]]
                                                                    options:0 error:nil];
            check([onDisk[@"claudeUsageJSON"][@"limits"][0][@"percent"] doubleValue] == 80,
                  @"shared: the fresher response survives the next save");
        }

        // Withdrawing transcript consent purges the index immediately, without a read().
        {
            NSString *pHome = [root stringByAppendingPathComponent:@"home-consent"];
            NSString *pSupport = [root stringByAppendingPathComponent:@"support-consent"];
            NSString *pProj = [pHome stringByAppendingPathComponent:@".claude/projects/p"];
            [fm createDirectoryAtPath:pProj withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableData *transcript = [NSMutableData data];
            for (NSUInteger i = 0; i < 10; i++)
                AppendClaudeEvent(transcript, [NSString stringWithFormat:@"c-%lu", (unsigned long)i], 5);
            [transcript writeToFile:[pProj stringByAppendingPathComponent:@"t.jsonl"] atomically:NO];
            AIReader *consenting = [[AIReader alloc] initWithHomeDirectory:pHome applicationSupportDirectory:pSupport];
            consenting.allowClaudeTranscripts = YES;
            [consenting readUntilCaughtUpWithTimeLimit:5.0];
            NSString *consentState = [pSupport stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
            check([[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:consentState]
                                                   options:0 error:nil][@"claudeFiles"] count] > 0,
                  @"consent: the index exists while consent is given");
            [consenting purgeClaudeTranscriptIndex];   // the toggle's direct call — no read()
            check([[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:consentState]
                                                   options:0 error:nil][@"claudeFiles"] count] == 0,
                  @"consent: withdrawing purges the index on the spot, with no later read");
        }

        // Toggle-off clears the persisted account usage fields.
        restored.useClaudeAccount = NO;
        restored.useCursorAccount = NO;
        [restored read];
        NSDictionary *cleared = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:persistStatePath] options:0 error:nil];
        check(cleared[@"claudeUsageJSON"] == nil, @"Claude usage JSON cleared when account toggle is off");
        check(cleared[@"cursorUsageJSON"] == nil, @"Cursor usage JSON cleared when account toggle is off");

        [fm removeItemAtPath:root error:nil];
    }
    if (failures) fprintf(stderr, "%d AIReader integration test(s) failed\n", failures);
    else printf("AIReader integration tests passed\n");
    return failures ? 1 : 0;
}
