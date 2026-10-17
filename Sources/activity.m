#import "activity.h"
#import <libproc.h>
#import <mach/mach_time.h>
#import <signal.h>
#import <errno.h>
#import <limits.h>
#import <unistd.h>

static double NanosecondsPerTick(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return tb.denom ? (double)tb.numer / tb.denom : NAN;
}
static double MonotonicSeconds(void) {
    // Continuous time includes sleep: an interval crossing sleep cannot look short.
    return mach_continuous_time() * NanosecondsPerTick() / 1e9;
}
static NSString *StartIdentity(struct proc_bsdinfo info) {
    return [NSString stringWithFormat:@"%llu:%llu", info.pbi_start_tvsec, info.pbi_start_tvusec];
}
static NSDictionary *Processes(void) {
    int requested = proc_listallpids(NULL, 0);
    if (requested <= 0 || requested > INT_MAX / (int)sizeof(pid_t) / 2) return @{};
    int capacity = requested * 2;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return @{};
    int count = MIN(capacity, proc_listallpids(pids, capacity * (int)sizeof(pid_t)));
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        struct proc_bsdinfo info = {0};
        if (pid <= 0 || pid == getpid() || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
        NSString *name = [NSString stringWithUTF8String:info.pbi_name] ?: @"Process";
        if ([name isEqual:@"nettop"]) continue;
        NSString *identity = StartIdentity(info);
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        NSString *executable = proc_pidpath(pid, path, sizeof(path)) > 0 ? [NSString stringWithUTF8String:path] : nil;
        NSString *group = [NSString stringWithFormat:@"pid:%d:%@", pid, identity];
        if (executable.length) {
            NSRange app = [executable rangeOfString:@".app/"];
            if (app.location != NSNotFound) {
                NSString *bundle = [executable substringToIndex:app.location + 4];
                group = [@"app:" stringByAppendingString:bundle];
                name = bundle.lastPathComponent.stringByDeletingPathExtension;
            } else {
                group = [@"executable:" stringByAppendingString:executable];
                name = executable.lastPathComponent;
                if ([name isEqual:@"transmission-daemon"]) name = @"Transmission";
            }
        }
        NSMutableDictionary *row = [@{@"pid": @(pid), @"start": identity, @"name": name,
                                      @"group": group} mutableCopy];
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
            // XNU bsd_kern.c fill_task_rusage copies task_power_info's Mach times.
            row[@"user"] = @(usage.ri_user_time);
            row[@"system"] = @(usage.ri_system_time);
        }
        // Also reject a process that was recycled while reading its metadata.
        struct proc_bsdinfo check = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &check, sizeof(check)) == sizeof(check) &&
            [StartIdentity(check) isEqual:identity]) rows[@(pid)] = row;
    }
    free(pids);
    return rows;
}

// A watchdog owns only this nettop child; start identity prevents recycled-PID signals.
@interface GBActivityDeadline : NSObject
- (instancetype)initWithPID:(pid_t)pid;
- (void)cancel;
@property (readonly) BOOL expired;
@end
@implementation GBActivityDeadline {
    pid_t _pid;
    NSString *_start;
    BOOL _cancelled, _expired;
}
- (instancetype)initWithPID:(pid_t)pid {
    if (!(self = [super init])) return nil;
    _pid = pid;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) _start = StartIdentity(info);
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), q, ^{ [self signal:SIGTERM]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), q, ^{ [self signal:SIGKILL]; });
    return self;
}
- (void)signal:(int)signal {
    @synchronized (self) {
        if (_cancelled) return;
        _expired = YES;
        struct proc_bsdinfo info = {0};
        if (_start && proc_pidinfo(_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
            [_start isEqual:StartIdentity(info)]) kill(_pid, signal);
    }
}
- (void)cancel { @synchronized (self) { _cancelled = YES; } }
- (BOOL)expired { @synchronized (self) { return _expired; } }
@end
static NSString *RunNetworkSnapshot(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/nettop"];
    task.arguments = @[@"-P", @"-n", @"-x", @"-L", @"1", @"-J", @"bytes_in,bytes_out"];
    task.environment = @{@"LC_ALL": @"C"};
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return nil;
    GBActivityDeadline *deadline = [[GBActivityDeadline alloc] initWithPID:task.processIdentifier];
    // Drain while the process runs, so a full pipe cannot deadlock the child.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    [deadline cancel];
    if (deadline.expired || task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static NSArray *CSVFields(NSString *line) {
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableString *field = [NSMutableString string];
    BOOL quoted = NO, closed = NO;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar ch = [line characterAtIndex:i];
        if (ch == '"') {
            if (quoted && i + 1 < line.length && [line characterAtIndex:i + 1] == '"') { [field appendString:@"\""]; i++; }
            else if (quoted) { quoted = NO; closed = YES; }
            else if (!field.length && !closed) quoted = YES;
            else return nil;
        } else if (ch == ',' && !quoted) {
            [fields addObject:field.copy]; [field setString:@""]; closed = NO;
        } else {
            if (closed) return nil;
            [field appendFormat:@"%C", ch];
        }
    }
    if (quoted) return nil;
    [fields addObject:field.copy];
    return fields;
}
static NSNumber *UnsignedNumber(NSString *text) {
    if (!text.length || text.length > 20) return nil;
    for (NSUInteger i = 0; i < text.length; i++) { unichar c = [text characterAtIndex:i]; if (c < '0' || c > '9') return nil; }
    errno = 0;
    unsigned long long number = strtoull(text.UTF8String, NULL, 10);
    return errno == ERANGE ? nil : @(number);
}
NSDictionary *GBActivityParseNetwork(NSString *csv) {
    if (!csv.length) return nil;
    NSArray *lines = [csv componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    BOOL header = NO;
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    for (NSString *line in lines) {
        if (!line.length) continue;
        NSArray *fields = CSVFields(line);
        if (fields.count == 4 && [fields.lastObject isEqual:@""]) fields = [fields subarrayWithRange:NSMakeRange(0, 3)];
        if (fields.count != 3) return nil;
        if (!header) {
            if (![fields[0] isEqual:@""] || ![fields[1] isEqual:@"bytes_in"] || ![fields[2] isEqual:@"bytes_out"]) return nil;
            header = YES; continue;
        }
        NSString *process = fields[0];
        NSRange dot = [process rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location == NSNotFound || dot.location == 0) return nil;
        NSNumber *pid = UnsignedNumber([process substringFromIndex:dot.location + 1]);
        NSNumber *input = UnsignedNumber(fields[1]), *output = UnsignedNumber(fields[2]);
        if (!pid || pid.unsignedLongLongValue == 0 || pid.unsignedLongLongValue > INT_MAX || !input || !output || rows[pid]) return nil;
        rows[pid] = @{@"in": input, @"out": output};
    }
    return header ? rows : nil;
}
static NSDictionary *Snapshot(void) {
    NSDictionary *before = Processes();
    double networkStart = MonotonicSeconds();
    NSString *csv = RunNetworkSnapshot();
    double networkEnd = MonotonicSeconds(), cpuStart = networkEnd;
    NSDictionary *after = Processes();
    double cpuEnd = MonotonicSeconds();
    NSMutableDictionary *stable = [NSMutableDictionary dictionary];
    for (NSNumber *pid in after) {
        NSDictionary *a = before[pid], *b = after[pid];
        if (a && [a[@"start"] isEqual:b[@"start"]] && [a[@"group"] isEqual:b[@"group"]]) stable[pid] = b;
    }
    NSMutableDictionary *snapshot = [@{@"processes": stable, @"cpuAt": @((cpuStart + cpuEnd) / 2),
        @"networkAt": @((networkStart + networkEnd) / 2), @"capturedAt": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
    NSDictionary *network = GBActivityParseNetwork(csv);
    if (network) snapshot[@"network"] = network;
    return snapshot;
}
static BOOL CounterDelta(id before, id after, double *delta) {
    if (![before isKindOfClass:NSNumber.class] || ![after isKindOfClass:NSNumber.class] ||
        !isfinite([before doubleValue]) || !isfinite([after doubleValue]) || [before doubleValue] < 0 || [after doubleValue] < 0) return NO;
    uint64_t a = [before unsignedLongLongValue], b = [after unsignedLongLongValue];
    if (b < a) return NO;
    *delta = (double)(b - a); return YES;
}
NSDictionary *GBActivityCompute(NSDictionary *first, NSDictionary *second, double nanosecondsPerTick) {
    double cpuSeconds = [second[@"cpuAt"] doubleValue] - [first[@"cpuAt"] doubleValue];
    double netSeconds = [second[@"networkAt"] doubleValue] - [first[@"networkAt"] doubleValue];
    BOOL cpuTimeOK = isfinite(cpuSeconds) && cpuSeconds >= 1 && cpuSeconds <= 15 && isfinite(nanosecondsPerTick) && nanosecondsPerTick > 0;
    BOOL netOK = first[@"network"] && second[@"network"] && isfinite(netSeconds) && netSeconds >= 1 && netSeconds <= 15;
    NSDictionary *old = first[@"processes"] ?: @{}, *now = second[@"processes"] ?: @{};
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSNumber *pid in now) {
        NSDictionary *a = old[pid], *b = now[pid];
        NSString *group = b[@"group"];
        if (!group.length) continue;
        NSMutableDictionary *row = groups[group];
        if (!row) groups[group] = row = [@{@"name": b[@"name"] ?: @"Process", @"group": group,
                    @"pids": [NSMutableArray array], @"cpuPartial": @NO, @"networkPartial": @NO} mutableCopy];
        [row[@"pids"] addObject:pid];
        BOOL same = a && [a[@"start"] isEqual:b[@"start"]] && [a[@"group"] isEqual:group];
        double user = 0, system = 0, input = 0, output = 0;
        if (same && cpuTimeOK && CounterDelta(a[@"user"], b[@"user"], &user) && CounterDelta(a[@"system"], b[@"system"], &system))
            row[@"cpu"] = @([row[@"cpu"] doubleValue] + (user + system) * nanosecondsPerTick / (cpuSeconds * 1e9) * 100);
        else row[@"cpuPartial"] = @YES;
        NSDictionary *an = first[@"network"][pid], *bn = second[@"network"][pid];
        if (same && netOK && CounterDelta(an[@"in"], bn[@"in"], &input) && CounterDelta(an[@"out"], bn[@"out"], &output)) {
            row[@"download"] = @([row[@"download"] doubleValue] + input / netSeconds);
            row[@"upload"] = @([row[@"upload"] doubleValue] + output / netSeconds);
        } else row[@"networkPartial"] = @YES;
    }
    for (NSNumber *pid in old) {
        NSDictionary *a = old[pid], *b = now[pid];
        if (!b || ![a[@"start"] isEqual:b[@"start"]] || ![a[@"group"] isEqual:b[@"group"]]) {
            NSMutableDictionary *row = a[@"group"] ? groups[a[@"group"]] : nil;
            row[@"cpuPartial"] = @YES; row[@"networkPartial"] = @YES;
        }
    }
    NSMutableArray *rows = [NSMutableArray array]; BOOL cpuOK = NO;
    for (NSMutableDictionary *row in groups.allValues) {
        if (!row[@"cpu"] && !row[@"download"] && !row[@"upload"]) continue;
        if (row[@"cpu"]) cpuOK = YES;
        row[@"pids"] = [row[@"pids"] sortedArrayUsingSelector:@selector(compare:)];
        [rows addObject:row.copy];
    }
    double interval = cpuTimeOK ? cpuSeconds : netOK ? netSeconds : 0;
    NSMutableDictionary *result = [@{@"rows": GBActivitySortedRows(rows, @"cpu"), @"capturedAt": second[@"capturedAt"] ?: @0,
        @"intervalSeconds": @(interval), @"networkAvailable": @(netOK), @"cpuAvailable": @(cpuOK)} mutableCopy];
    if (!netOK || !cpuOK) result[@"problem"] = !netOK && !cpuOK ? @"CPU and network counters unavailable for this interval." : !netOK ? @"Network counters unavailable; CPU readings remain available." : @"CPU counters unavailable; network readings remain available.";
    return result;
}
NSDictionary *GBActivitySurvey(void) {
    @autoreleasepool {
        NSDictionary *first = Snapshot();
        [NSThread sleepForTimeInterval:3];
        return GBActivityCompute(first, Snapshot(), NanosecondsPerTick());
    }
}
NSArray *GBActivitySortedRows(NSArray *rows, NSString *metric) {
    if (![@[@"cpu", @"download", @"upload"] containsObject:metric]) metric = @"cpu";
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSNumber *x = a[metric], *y = b[metric];
        if (!x && y) return NSOrderedDescending;
        if (x && !y) return NSOrderedAscending;
        NSComparisonResult rate = [y compare:x];
        if (x && y && rate != NSOrderedSame) return rate;
        NSComparisonResult name = [a[@"name"] localizedStandardCompare:b[@"name"]];
        return name == NSOrderedSame ? [a[@"group"] compare:b[@"group"]] : name;
    }];
}
NSString *GBActivityRate(NSNumber *value, BOOL partial) {
    if (!value || !isfinite(value.doubleValue) || value.doubleValue < 0) return @"—";
    double v = value.doubleValue; NSString *unit = @"B/s";
    if (v >= 1e9) { v /= 1e9; unit = @"GB/s"; }
    else if (v >= 1e6) { v /= 1e6; unit = @"MB/s"; }
    else if (v >= 1e3) { v /= 1e3; unit = @"kB/s"; }
    if (partial) v = [unit isEqual:@"B/s"] ? floor(v) : floor(v * 10) / 10;
    return [NSString stringWithFormat:[unit isEqual:@"B/s"] ? @"%@%.0f %@" : @"%@%.1f %@", partial ? @"≥" : @"", v, unit];
}
NSString *GBActivityCPU(NSNumber *value, BOOL partial) {
    if (!value || !isfinite(value.doubleValue) || value.doubleValue < 0) return @"—";
    double v = value.doubleValue;
    if (v > 0 && v < 0.1) return partial ? @">0%" : @"<0.1%";
    if (partial) v = floor(v * 10) / 10;
    return [NSString stringWithFormat:@"%@%.1f%%", partial ? @"≥" : @"", v];
}
