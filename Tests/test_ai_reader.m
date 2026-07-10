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

        [fm removeItemAtPath:root error:nil];
    }
    if (failures) fprintf(stderr, "%d AIReader integration test(s) failed\n", failures);
    else printf("AIReader integration tests passed\n");
    return failures ? 1 : 0;
}
