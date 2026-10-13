// Metered-link transport, detection, persistence, and sleep coverage. Importing
// main.m exposes the private monitor without adding a production test API.
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

@interface MeteredMonitor (TestAccess)
- (void)sample;
- (void)persist:(BOOL)force;
@end

@interface StubMeteredMonitor : MeteredMonitor
@property uint64_t inputBytes, outputBytes;
@property (copy) NSString *interfaceName, *router;
@end
@implementation StubMeteredMonitor
- (NSDictionary *)counterSample {
    return self.interfaceName ? @{ @"interface": self.interfaceName,
                                   @"inBytes": @(self.inputBytes),
                                   @"outBytes": @(self.outputBytes) } : nil;
}
- (NSString *)primaryInterface { return self.interfaceName; }
- (NSString *)primaryRouter { return self.router; }
- (void)tick {} // wake must not create a real NSURLSession request in this harness.
@end

static NSData *Frame(uint8_t flags, NSData *payload) {
    uint32_t length = (uint32_t)payload.length;
    uint8_t header[5] = {flags, (uint8_t)(length >> 24), (uint8_t)(length >> 16),
                         (uint8_t)(length >> 8), (uint8_t)length};
    NSMutableData *out = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [out appendData:payload];
    return out;
}

static NSHTTPURLResponse *Response(NSInteger status, NSString *mime, NSString *grpcStatus) {
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (mime) headers[@"Content-Type"] = mime;
    if (grpcStatus) headers[@"grpc-status"] = grpcStatus;
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://192.168.100.1"]
                                        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

static NSDictionary *State(StubMeteredMonitor *monitor, NSString *link) {
    return [monitor valueForKey:@"states"][link];
}

int main(void) {
    @autoreleasepool {
        NSData *payload = [@"ut41c8130c-1234-5678-9abc-def012345678" dataUsingEncoding:NSISOLatin1StringEncoding];
        NSData *trailer = [@"grpc-status: 0\r\n" dataUsingEncoding:NSISOLatin1StringEncoding];
        NSMutableData *valid = [Frame(0, payload) mutableCopy];
        [valid appendData:Frame(0x80, trailer)];
        check(StarlinkProbeSucceeded(valid, Response(200, @"application/grpc-web+proto", nil)), @"valid Starlink grpc-web device response succeeds");
        check(StarlinkProbeSucceeded(Frame(0, payload), Response(200, @"application/grpc-web+proto", @"0")), @"grpc status zero in response header succeeds");
        check(!StarlinkProbeSucceeded(valid, Response(500, @"application/grpc-web+proto", nil)), @"HTTP error response fails");
        check(!StarlinkProbeSucceeded(valid, Response(200, @"application/octet-stream", nil)), @"wrong MIME response fails");
        NSMutableData *noDish = [Frame(0, [@"device-info" dataUsingEncoding:NSISOLatin1StringEncoding]) mutableCopy];
        [noDish appendData:Frame(0x80, trailer)];
        check(!StarlinkProbeSucceeded(noDish, Response(200, @"application/grpc-web+proto", nil)), @"response without dish id fails");
        check(!StarlinkProbeSucceeded([valid subdataWithRange:NSMakeRange(0, valid.length - 1)], Response(200, @"application/grpc-web+proto", nil)), @"truncated grpc-web frame fails");
        NSMutableData *badFlags = [Frame(1, payload) mutableCopy];
        [badFlags appendData:Frame(0x80, trailer)];
        check(!StarlinkProbeSucceeded(badFlags, Response(200, @"application/grpc-web+proto", nil)), @"unknown grpc-web frame flags fail");
        NSMutableData *badStatus = [Frame(0, payload) mutableCopy];
        [badStatus appendData:Frame(0x80, [@"grpc-status: 7\r\n" dataUsingEncoding:NSISOLatin1StringEncoding])];
        check(!StarlinkProbeSucceeded([Frame(0, payload) mutableCopy], Response(200, @"application/grpc-web+proto", @"7")) && !StarlinkProbeSucceeded([Frame(0, payload) mutableCopy], Response(200, @"application/grpc-web+proto", nil)) && !StarlinkProbeSucceeded(badStatus, Response(200, @"application/grpc-web+proto", nil)), @"missing or nonzero grpc status fails");

        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"glancebar-metered-%@", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
        setenv("GLANCEBAR_HOME", home.UTF8String, 1);
        NSString *dir = [home stringByAppendingPathComponent:@"Library/Application Support/Glancebar"];
        NSString *starPath = [dir stringByAppendingPathComponent:@"starlink.json"];
        NSString *telPath = [dir stringByAppendingPathComponent:@"telstra.json"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDate *now = NSDate.date;
        NSDictionary *starSeed = @{ @"cycleStart": @(MeteredCycleStart(now, MeteredResetDay(@"starlink")).timeIntervalSince1970), @"downloadBytes": @100, @"uploadBytes": @20, @"interface": @"en0", @"inBytes": @1, @"outBytes": @2 };
        NSDictionary *telSeed = @{ @"cycleStart": @(MeteredCycleStart(now, MeteredResetDay(@"telstra")).timeIntervalSince1970), @"downloadBytes": @700, @"uploadBytes": @30, @"onLink": @YES };
        [[NSJSONSerialization dataWithJSONObject:starSeed options:0 error:NULL] writeToFile:starPath atomically:YES];
        [[NSJSONSerialization dataWithJSONObject:telSeed options:0 error:NULL] writeToFile:telPath atomically:YES];
        StubMeteredMonitor *monitor = [StubMeteredMonitor new];
        dispatch_queue_t queue = [monitor valueForKey:@"queue"];
        __block NSNumber *lastStar, *lastTel;
        dispatch_sync(queue, ^{
            NSDictionary *restoredStar = State(monitor, @"starlink");
            NSDictionary *restoredTel = State(monitor, @"telstra");
            check([restoredStar[@"downloadBytes"] unsignedLongLongValue] == 100 && !restoredStar[@"interface"], @"Starlink restores totals only");
            check([restoredTel[@"downloadBytes"] unsignedLongLongValue] == 700 && !restoredTel[@"onLink"], @"Telstra restores totals independently and drops active state");

            monitor.interfaceName = @"en0"; monitor.inputBytes = 1000; monitor.outputBytes = 2000;
            [monitor setValue:@"en0" forKey:@"detectedInterface"];
            [monitor setValue:@YES forKey:@"onStarlink"];
            [monitor sample];
            check([State(monitor, @"starlink")[@"downloadBytes"] unsignedLongLongValue] == 100, @"restored Starlink baseline does not bill reboot gap");
            monitor.inputBytes = 1100; monitor.outputBytes = 2200;
            [monitor sample];
            check([State(monitor, @"starlink")[@"downloadBytes"] unsignedLongLongValue] == 200 && [State(monitor, @"telstra")[@"downloadBytes"] unsignedLongValue] == 700, @"only active Starlink link counts");

            NSData *throttledStar = [NSData dataWithContentsOfFile:starPath];
            [monitor persist:NO];
            check([[NSData dataWithContentsOfFile:starPath] isEqual:throttledStar], @"ordinary persistence is throttled");
            monitor.router = @"172.20.10.1"; monitor.inputBytes = 1200; monitor.outputBytes = 2400;
            [monitor sample];
            check(![State(monitor, @"starlink")[@"onLink"] boolValue] && [State(monitor, @"telstra")[@"onLink"] boolValue], @"hotspot router switches exclusively to Telstra");
            monitor.inputBytes = 1300; monitor.outputBytes = 2600;
            [monitor sample];
            check([State(monitor, @"telstra")[@"downloadBytes"] unsignedLongLongValue] == 800 && [State(monitor, @"starlink")[@"downloadBytes"] unsignedLongLongValue] == 200, @"Telstra counts Mac interface deltas on hotspot");

            monitor.router = @"192.168.1.1"; monitor.inputBytes = 1400; monitor.outputBytes = 2800;
            [monitor sample];
            check(![State(monitor, @"starlink")[@"onLink"] boolValue] && ![State(monitor, @"telstra")[@"onLink"] boolValue], @"neither link shows on an ordinary router");
            monitor.interfaceName = nil;
            [monitor sample];
            check(![State(monitor, @"starlink")[@"onLink"] boolValue] && ![State(monitor, @"telstra")[@"onLink"] boolValue], @"missing primary interface keeps both links inactive");
            monitor.interfaceName = @"en0"; monitor.router = @"172.20.10.1"; monitor.inputBytes = 1500; monitor.outputBytes = 3000;
            [monitor sample];
            [monitor persist:YES];
            NSDictionary *savedStar = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:starPath] options:0 error:NULL];
            NSDictionary *savedTel = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:telPath] options:0 error:NULL];
            lastStar = savedStar[@"downloadBytes"]; lastTel = savedTel[@"downloadBytes"];
            NSSet *expectedKeys = [NSSet setWithArray:@[@"cycleStart", @"downloadBytes", @"uploadBytes"]];
            check([[NSSet setWithArray:savedStar.allKeys] isEqualToSet:expectedKeys] && [[NSSet setWithArray:savedTel.allKeys] isEqualToSet:expectedKeys], @"persisted files contain totals only");
        });
        check(lastStar.unsignedLongLongValue == 200 && lastTel.unsignedLongLongValue == 800, @"each link persists its own totals");

        dispatch_sync(queue, ^{
            monitor.inputBytes = 1600; monitor.outputBytes = 3200;
        });
        [monitor sleep];
        dispatch_sync(queue, ^{
            check(![State(monitor, @"starlink")[@"onLink"] boolValue] && ![State(monitor, @"telstra")[@"onLink"] boolValue], @"sleep clears active link state");
            check([State(monitor, @"telstra")[@"downloadBytes"] unsignedLongLongValue] == 900, @"sleep samples and flushes final on-link bytes");
        });
        [monitor wake];
        dispatch_sync(queue, ^{
            monitor.router = @"172.20.10.1"; monitor.inputBytes = 9000; monitor.outputBytes = 9000;
            [monitor sample];
            check([State(monitor, @"telstra")[@"downloadBytes"] unsignedLongLongValue] == 900, @"hotspot wake does not bill unseen gap");
            monitor.inputBytes = 9100; monitor.outputBytes = 9200;
            [monitor sample];
            check([State(monitor, @"telstra")[@"downloadBytes"] unsignedLongLongValue] == 1000, @"hotspot wake counts the next delta");
        });
        dispatch_sync(queue, ^{
            monitor.inputBytes = 9200; monitor.outputBytes = 9400;
        });
        [monitor stop];
        NSDictionary *finalTel = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:telPath] options:0 error:NULL];
        check([finalTel[@"downloadBytes"] unsignedLongLongValue] == 1100, @"quit samples and force persists final bytes");
        [[NSFileManager defaultManager] removeItemAtPath:home error:NULL];
    }
    if (failures) fprintf(stderr, "METERED TESTS FAILED (%d failures)\n", failures);
    else fprintf(stderr, "METERED TESTS PASSED\n");
    return failures ? 1 : 0;
}
