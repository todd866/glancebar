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
