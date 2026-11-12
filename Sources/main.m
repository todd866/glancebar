// Glancebar — one configurable menu bar item at a glance. Click for a native popover
// with storage, battery, system, and AI summaries plus a deeper details window.
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <DiskArbitration/DiskArbitration.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import "fine_volume.h"
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <notify.h>
#import <dlfcn.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <net/if.h>
#import <net/route.h>
#import <ServiceManagement/ServiceManagement.h>
#import <libproc.h>
#import <mach/mach.h>
#import <signal.h>
#import <stdatomic.h>
#import <sys/attr.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/log.h>
#import <math.h>
#import <Security/Security.h>
#import <sqlite3.h>
#import "pure.h"
#import "nowplaying.h"
#import "activity.h"
#import "storage_scan.h"
#import "storage_cleanup.h"
#import "storage_index.h"

// Built against a macOS 13 SDK (the M1 worker's command-line tools), NSMenuItem has no
// declaration for the macOS 14 section header; the call site checks @available at run time.
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 140000
@interface NSMenuItem (GBSectionHeader)
+ (NSMenuItem *)sectionHeaderWithTitle:(NSString *)title API_AVAILABLE(macos(14.0));
@end
#endif

// This preference governs Glancebar's optional requests only, never system networking.
static BOOL GBLowDataEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"lowData"]; }
static NSString *const GBLowDataTip = @"Glancebar only: defer account refreshes and dish discovery.\nLocal readings and cached figures remain. Other apps are unaffected.";

static NSString * const GBVersion = @"1.1.0";

// Tests and diagnostics can point Glancebar at an isolated fixture home without touching
// a real Codex/Claude installation. Normal app runs always fall back to the login home.
static NSString *GBHomeDirectory(void) {
    const char *override = getenv("GLANCEBAR_HOME");
    if (override && override[0]) {
        NSString *path = [NSString stringWithUTF8String:override];
        if (path.length) return path.stringByStandardizingPath;
    }
    return NSHomeDirectory();
}

#pragma mark - Metered links (Mac interface bytes only)

static int MeteredResetDay(NSString *link) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:[link stringByAppendingString:@"ResetDay"]];
    return value ? MAX(1, MIN(31, [value intValue])) : ([link isEqual:@"telstra"] ? 7 : 13);
}
static double MeteredCapGB(NSString *link) {
    double cap = [NSUserDefaults.standardUserDefaults doubleForKey:[link stringByAppendingString:@"CapGB"]];
    return isfinite(cap) && cap > 0 ? cap : ([link isEqual:@"telstra"] ? 180 : 100);
}
// Starlink bills in UTC; the Telstra cycle follows the local calendar.
static NSTimeZone *MeteredZone(NSString *link) {
    return [link isEqual:@"telstra"] ? nil : [NSTimeZone timeZoneForSecondsFromGMT:0];
}
static NSString *MeteredName(NSString *link) { return [link isEqual:@"telstra"] ? @"Telstra" : @"Starlink"; }
static NSString *MeteredSymbol(NSString *link) {
    if (![link isEqual:@"telstra"]) return @"antenna.radiowaves.left.and.right";
    return [NSImage imageWithSystemSymbolName:@"personalhotspot" accessibilityDescription:nil] ? @"personalhotspot" : @"iphone";
}

// SystemConfiguration publishes the primary/default-route interface. Prefer IPv4
// (the dish has an IPv4 address), falling back to IPv6-only service.
static NSString *MeteredPrimaryInterface(void) {
    for (NSString *key in @[@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6"]) {
        NSDictionary *global = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, (__bridge CFStringRef)key));
        id name = global[@"PrimaryInterface"];
        if ([name isKindOfClass:NSString.class] && [name length]) return name;
    }
    return nil;
}
static NSDictionary *MeteredCounterSample(void) {
    NSString *name = MeteredPrimaryInterface();
    unsigned int index = name ? if_nametoindex(name.UTF8String) : 0;
    if (!index) return nil;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index};
    size_t size = 0;
    if (sysctl(mib, 6, NULL, &size, NULL, 0) || !size) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctl(mib, 6, data.mutableBytes, &size, NULL, 0)) return nil;
    const uint8_t *bytes = data.bytes;
    for (size_t offset = 0; offset + sizeof(struct if_msghdr) <= size;) {
        const struct if_msghdr *header = (const void *)(bytes + offset);
        if (!header->ifm_msglen || header->ifm_msglen > size - offset) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            const struct if_msghdr2 *info = (const void *)header;
            if (info->ifm_index == index)
                return @{@"interface": name, @"inBytes": @(info->ifm_data.ifi_ibytes),
                         @"outBytes": @(info->ifm_data.ifi_obytes)};
        }
        offset += header->ifm_msglen;
    }
    return nil;
}

static BOOL StarlinkProbeSucceeded(NSData *data, NSHTTPURLResponse *response) {
    if (response.statusCode != 200 || !data.length ||
        ![[response valueForHTTPHeaderField:@"Content-Type"].lowercaseString hasPrefix:@"application/grpc-web+proto"])
        return NO;
    NSString *status = [response valueForHTTPHeaderField:@"grpc-status"];
    BOOL device = NO;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0; offset < data.length;) {
        if (data.length - offset < 5) return NO;
        uint8_t flags = bytes[offset];
        uint32_t length = ((uint32_t)bytes[offset+1] << 24) | ((uint32_t)bytes[offset+2] << 16) |
                          ((uint32_t)bytes[offset+3] << 8) | bytes[offset+4];
        offset += 5;
        if (length > data.length - offset) return NO;
        NSString *part = [[NSString alloc] initWithBytes:bytes + offset length:length encoding:NSISOLatin1StringEncoding];
        if (flags == 0x80) {
            for (NSString *line in [part componentsSeparatedByString:@"\r\n"]) {
                if ([line.lowercaseString hasPrefix:@"grpc-status:"])
                    status = [[line substringFromIndex:12] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
        } else if (flags == 0) {
            NSRange found = [part rangeOfString:@"ut[0-9a-fA-F]{8}-[0-9a-fA-F-]+" options:NSRegularExpressionSearch];
            device |= found.location != NSNotFound;
        } else return NO;
        offset += length;
    }
    return device && [status isEqualToString:@"0"];
}

#pragma mark - Starlink account usage (starlink.com, signed in via Chrome)

// The account's own cycle total, which counts every device on the dish. It is read with
// the user's Chrome session for starlink.com: cookies come from Chrome's cookie store
// (read-only) and are decrypted with the "Chrome Safe Storage" Keychain key, which macOS
// asks the user to allow once. Only starlink.com cookies are read, and only sent there.
@interface StarlinkAccount : NSObject
- (void)fetch:(void (^)(NSDictionary *usage, NSString *problem))done;
@end
@implementation StarlinkAccount {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSData *_key;
    BOOL _keyRefused, _chromeBlocked;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.iantodd.glancebar.starlink-account", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPShouldSetCookies = NO;
        config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 20;
        config.timeoutIntervalForResource = 30;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}
// One Keychain read per launch. A refusal is remembered so the dialog never repeats.
- (NSData *)key {
    if (_key || _keyRefused) return _key;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"Chrome Safe Storage",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne}, &result);
    NSData *secret = CFBridgingRelease(result);
    if (status != errSecSuccess || !secret.length) {
        os_log(OS_LOG_DEFAULT, "starlink account: Chrome Safe Storage keychain status %d", (int)status);
        _keyRefused = YES; return nil;
    }
    _key = ChromeCookieKey([[NSString alloc] initWithData:secret encoding:NSUTF8StringEncoding]);
    _keyRefused = _key == nil;
    return _key;
}
// The Chrome profile most recently signed in to starlink.com.
- (NSString *)cookieHeader:(NSString **)account {
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Google/Chrome"];
    NSString *best = nil; long long bestAccess = -1;
    NSMutableDictionary *bestJar = nil;
    // macOS App Data protection guards Chrome's folder until Glancebar is granted access.
    NSError *listError = nil;
    NSArray *profiles = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:&listError];
    _chromeBlocked = [listError.domain isEqual:NSCocoaErrorDomain] && listError.code == NSFileReadNoPermissionError;
    for (NSString *profile in profiles) {
        NSString *path = [[root stringByAppendingPathComponent:profile] stringByAppendingPathComponent:@"Cookies"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSURLComponents *uri = [NSURLComponents new];
        uri.scheme = @"file"; uri.path = path; uri.query = @"mode=ro";
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(uri.string.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
            sqlite3_close(db); continue;
        }
        sqlite3_busy_timeout(db, 1000);
        sqlite3_stmt *query = NULL;
        NSMutableDictionary *jar = [NSMutableDictionary dictionary];
        long long access = -1;
        if (sqlite3_prepare_v2(db, "SELECT name, host_key, encrypted_value, value, last_access_utc FROM cookies "
                                   "WHERE host_key IN ('starlink.com', '.starlink.com')", -1, &query, NULL) == SQLITE_OK) {
            while (sqlite3_step(query) == SQLITE_ROW) {
                const char *name = (const char *)sqlite3_column_text(query, 0);
                const char *host = (const char *)sqlite3_column_text(query, 1);
                const char *plain = (const char *)sqlite3_column_text(query, 3);
                if (!name || !host) continue;
                NSString *cookie = [NSString stringWithUTF8String:name];
                NSString *value = plain && *plain ? [NSString stringWithUTF8String:plain] : nil;
                if (!value) {
                    NSData *sealed = [NSData dataWithBytes:sqlite3_column_blob(query, 2) length:(NSUInteger)sqlite3_column_bytes(query, 2)];
                    if (!sealed.length) continue;
                    NSData *key = [self key];
                    if (!key) break;
                    value = ChromeCookieDecrypt(sealed, key, [NSString stringWithUTF8String:host]);
                }
                if (!value.length) continue;
                jar[cookie] = value;
                if ([cookie hasPrefix:@"Starlink.Com.Access"]) access = MAX(access, sqlite3_column_int64(query, 4));
            }
        }
        sqlite3_finalize(query);
        sqlite3_close(db);
        if (access > bestAccess && jar[@"Starlink.Com.Access.V1"]) { bestAccess = access; best = path; bestJar = jar; }
    }
    if (!best) return nil;
    if (account) *account = [bestJar[@"starlink.com.account_number"] stringByRemovingPercentEncoding];
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *name in bestJar) [pairs addObject:[NSString stringWithFormat:@"%@=%@", name, bestJar[name]]];
    return [pairs componentsJoinedByString:@"; "];
}
- (NSData *)get:(NSString *)path cookies:(NSString *)cookies status:(NSInteger *)status {
    if (GBLowDataEnabled()) { if (status) *status = 0; return nil; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://starlink.com" stringByAppendingString:path]]];
    [request setValue:cookies forHTTPHeaderField:@"Cookie"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __block NSData *body = nil; __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class]) { code = ((NSHTTPURLResponse *)response).statusCode; body = data; }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
    if (status) *status = code;
    return code == 200 ? body : nil;
}
- (void)fetch:(void (^)(NSDictionary *, NSString *))done {
    dispatch_async(_queue, ^{
        if (GBLowDataEnabled()) { done(nil, @"Low Data · Glancebar"); return; }
        NSString *account = nil, *problem = nil;
        NSDictionary *usage = nil;
        NSString *cookies = [self cookieHeader:&account];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *line = [defaults stringForKey:@"starlinkServiceLine"];
        NSInteger status = 0;
        if (!cookies) {
            problem = self->_chromeBlocked ? @"needs Full Disk Access"
                    : self->_keyRefused ? @"Keychain access refused" : @"sign in at starlink.com in Chrome";
        } else if (!account.length) {
            problem = @"no Starlink account number";
        } else {
            if (!line.length) {
                NSData *lines = [self get:@"/api/accounts/v1/accounts/service-line-numbers" cookies:cookies status:&status];
                id root = lines ? [NSJSONSerialization JSONObjectWithData:lines options:0 error:NULL] : nil;
                id results = [root isKindOfClass:NSDictionary.class] && [root[@"content"] isKindOfClass:NSDictionary.class]
                    ? root[@"content"][@"results"] : nil;
                if ([results isKindOfClass:NSArray.class] && [results count] && [[results firstObject] isKindOfClass:NSString.class]) {
                    line = [results firstObject];
                    [defaults setObject:line forKey:@"starlinkServiceLine"];
                }
            }
            if (line.length) {
                NSString *path = [NSString stringWithFormat:@"/api/telemetryagg/v1/data-usage/account/%@/service-line/%@/annotated",
                    [account stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet],
                    [line stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
                usage = StarlinkUsageParse([self get:path cookies:cookies status:&status], NSDate.date);
            }
            if (!usage) problem = status == 401 || status == 403 ? @"sign in at starlink.com in Chrome"
                                : status ? [NSString stringWithFormat:@"starlink.com HTTP %ld", (long)status]
                                : @"starlink.com unreachable";
        }
        os_log(OS_LOG_DEFAULT, "starlink account: %{public}s", (usage ? [NSString stringWithFormat:@"%@ GB", usage[@"usedGB"]] : problem).UTF8String);
        done(usage, problem);
    });
}
@end

@interface MeteredMonitor : NSObject <NSURLSessionTaskDelegate>
@property (copy) void (^updated)(NSDictionary *state);
- (void)tick;
- (void)sleep;
- (void)wake;
- (void)stop;
@end
@implementation MeteredMonitor {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSMutableDictionary<NSString *, NSDictionary *> *_states;
    NSString *_directory, *_detectedInterface;
    NSDate *_lastProbe, *_lastWrite;
    BOOL _onStarlink, _probing, _sleeping, _stopped, _fetchingAccount;
    NSUInteger _generation;
    StarlinkAccount *_starlinkAccount;
    NSDictionary *_account; // usedGB, cycleStart/End, fetchedAt, macBytes (Mac cycle total then), problem
    NSDate *_lastAccountFetch;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.iantodd.glancebar.metered", DISPATCH_QUEUE_SERIAL);
        _directory = [GBHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Glancebar"];
        _states = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 2;
        config.timeoutIntervalForResource = 2;
        config.URLCache = nil;
        config.connectionProxyDictionary = @{}; // the dish request stays on the LAN
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _starlinkAccount = [StarlinkAccount new];
        dispatch_async(_queue, ^{
            NSData *accountData = [NSData dataWithContentsOfFile:[self pathForLink:@"starlink-account"]];
            id account = accountData ? [NSJSONSerialization JSONObjectWithData:accountData options:0 error:NULL] : nil;
            if ([account isKindOfClass:NSDictionary.class] && [account[@"usedGB"] isKindOfClass:NSNumber.class]) self->_account = account;
            for (NSString *link in @[@"starlink", @"telstra"]) {
                NSData *data = [NSData dataWithContentsOfFile:[self pathForLink:link]];
                id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                // Restore totals only. Never bill an unobserved app/reboot/sleep interval.
                if ([saved isKindOfClass:NSDictionary.class]) {
                    NSMutableDictionary *state = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"cycleStart", @"downloadBytes", @"uploadBytes"])
                        if ([saved[key] isKindOfClass:NSNumber.class] && isfinite([saved[key] doubleValue]) && [saved[key] doubleValue] >= 0)
                            state[key] = saved[key];
                    // Totals saved under the old local-midnight Starlink cycle carry into its UTC cycle.
                    NSDate *now = NSDate.date;
                    int day = MeteredResetDay(link);
                    if (MeteredZone(link) && [state[@"cycleStart"] doubleValue] == MeteredCycleStart(now, day).timeIntervalSince1970)
                        state[@"cycleStart"] = @(MeteredCycleStartInZone(now, day, MeteredZone(link)).timeIntervalSince1970);
                    self->_states[link] = state;
                }
            }
        });
    }
    return self;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    completionHandler(nil);
}
- (NSString *)pathForLink:(NSString *)link {
    return [_directory stringByAppendingPathComponent:[link stringByAppendingString:@".json"]];
}
- (void)publish {
    NSDictionary *snapshot = @{};
    for (NSString *link in @[@"starlink", @"telstra"]) {
        if ([_states[link][@"onLink"] boolValue]) {
            NSMutableDictionary *active = [_states[link] mutableCopy];
            active[@"link"] = link;
            if ([link isEqual:@"starlink"] && _account) active[@"account"] = _account;
            snapshot = [active copy];
            break;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.updated) self.updated(snapshot); });
}
- (void)persist:(BOOL)force {
    NSDate *now = NSDate.date;
    if (!force && _lastWrite && [now timeIntervalSinceDate:_lastWrite] < 60) return;
    BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:_directory
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *link in _states) {
        NSDictionary *state = _states[link];
        NSDictionary *totals = [state dictionaryWithValuesForKeys:@[@"cycleStart", @"downloadBytes", @"uploadBytes"]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:totals options:0 error:NULL];
        success = (data && [data writeToFile:[self pathForLink:link] options:NSDataWritingAtomic error:NULL]) && success;
    }
    if (success) _lastWrite = now;
}
- (NSDictionary *)counterSample { return MeteredCounterSample(); }
- (NSString *)primaryInterface { return MeteredPrimaryInterface(); }
- (NSString *)primaryRouter {
    NSDictionary *global = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, CFSTR("State:/Network/Global/IPv4")));
    return [global[@"Router"] isKindOfClass:NSString.class] ? global[@"Router"] : nil;
}
- (void)sample {
    NSDictionary *sample = [self counterSample];
    NSString *name = sample[@"interface"];
    BOOL hotspot = sample && [[self primaryRouter] isEqual:@"172.20.10.1"];
    if (!sample || ![name isEqualToString:_detectedInterface] || hotspot) {
        _onStarlink = NO;
        // A route change invalidates any old response and triggers a fresh probe.
        if (_detectedInterface) { _generation++; _lastProbe = nil; _detectedInterface = nil; }
    }
    NSDate *now = NSDate.date;
    for (NSString *link in @[@"starlink", @"telstra"]) {
        BOOL active = [link isEqual:@"telstra"] ? hotspot : _onStarlink;
        _states[link] = MeteredAccumulateInZone(_states[link], [sample[@"inBytes"] unsignedLongLongValue],
            [sample[@"outBytes"] unsignedLongLongValue], name ?: @"", active, now, MeteredResetDay(link), MeteredZone(link));
    }
    [self publish];
    [self persist:NO];
}
- (void)tick {
    dispatch_async(_queue, ^{
        if (self->_sleeping || self->_stopped) return;
        [self sample];
        if (GBLowDataEnabled()) return;
        if ([[self primaryRouter] isEqual:@"172.20.10.1"]) return;
        NSDate *now = NSDate.date;
        if (self->_onStarlink) [self refreshAccount:now];
        if (self->_probing || (self->_lastProbe && [now timeIntervalSinceDate:self->_lastProbe] < 60)) return;
        self->_lastProbe = now;
        NSString *name = [self primaryInterface];
        if (!name) return;
        self->_probing = YES;
        NSUInteger generation = self->_generation;
        const uint8_t body[] = {0, 0, 0, 0, 3, 0x82, 0x3f, 0};
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"http://192.168.100.1:9201/SpaceX.API.Device.Device/Handle"]
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/grpc-web+proto" forHTTPHeaderField:@"content-type"];
        [request setValue:@"1" forHTTPHeaderField:@"x-grpc-web"];
        request.HTTPBody = [NSData dataWithBytes:body length:sizeof(body)];
        [[self->_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{
                self->_probing = NO;
                if (self->_stopped || self->_sleeping || generation != self->_generation) return;
                BOOL matched = [name isEqualToString:[self primaryInterface]];
                // The accumulator rejects intervals crossing detection changes.
                self->_onStarlink = matched && !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
                    StarlinkProbeSucceeded(data, (NSHTTPURLResponse *)response);
                self->_detectedInterface = matched ? name : nil;
                [self sample];
            });
        }] resume];
    });
}
// The account figure lags real use by minutes, so ten-minute polling loses nothing.
- (void)refreshAccount:(NSDate *)now {
    if (GBLowDataEnabled()) return;
    if (_fetchingAccount || (_lastAccountFetch && [now timeIntervalSinceDate:_lastAccountFetch] < 600)) return;
    _fetchingAccount = YES;
    _lastAccountFetch = now;
    [_starlinkAccount fetch:^(NSDictionary *usage, NSString *problem) {
        dispatch_async(self->_queue, ^{
            self->_fetchingAccount = NO;
            if (self->_stopped) return;
            if (!usage && GBLowDataEnabled()) { self->_lastAccountFetch = nil; return; }
            NSMutableDictionary *account = [(self->_account ?: @{}) mutableCopy];
            if (usage) {
                NSDictionary *mac = self->_states[@"starlink"];
                [account setDictionary:usage];
                account[@"fetchedAt"] = @(NSDate.date.timeIntervalSince1970);
                account[@"macCycleStart"] = mac[@"cycleStart"] ?: @0;
                account[@"macBytes"] = @([mac[@"downloadBytes"] doubleValue] + [mac[@"uploadBytes"] doubleValue]);
            } else {
                account[@"problem"] = problem ?: @"starlink.com unavailable";
                if (!account[@"usedGB"]) { self->_account = account; [self publish]; return; }
            }
            self->_account = account;
            NSData *data = [NSJSONSerialization dataWithJSONObject:account options:0 error:NULL];
            [data writeToFile:[self pathForLink:@"starlink-account"] options:NSDataWritingAtomic error:NULL];
            [self publish];
        });
    }];
}
- (void)sleep {
    dispatch_sync(_queue, ^{
        if (self->_stopped) return;
        [self sample];
        self->_sleeping = YES;
        self->_onStarlink = NO;
        self->_generation++;
        for (NSString *link in self->_states.allKeys) {
            NSMutableDictionary *state = [self->_states[link] mutableCopy];
            state[@"onLink"] = @NO;
            state[@"bytesPerSecond"] = @0;
            state[@"recentBytesPerSecond"] = @0;
            [state removeObjectForKey:@"samples"];
            self->_states[link] = state;
        }
        [self persist:YES];
        [self publish];
    });
}
- (void)wake {
    dispatch_async(_queue, ^{ self->_sleeping = NO; self->_lastProbe = nil; });
    [self tick];
}
- (void)stop {
    [self sleep];
    dispatch_sync(_queue, ^{ self->_stopped = YES; });
    [_session invalidateAndCancel];
}
@end

#pragma mark - Disk

@interface Volume : NSObject
@property (copy) NSString *path, *name, *container, *backingPath, *glanceTooltip;
@property long long total, available, physicalAvailable, containerBytes, volumeUsed, groupUsed;
@property BOOL isInternal, isLocal, isDiskImage, hasVolumeUsed, grouped;
@property (copy) NSArray<NSString *> *memberPaths, *memberNames, *hostedNames;
@end
@implementation Volume
- (long long)used { return MAX(0LL, self.total - self.available); }
// Finder-style "available" counts purgeable data (caches, staged updates, local
// snapshots) as free; this is how much of that figure macOS would first have to thin.
- (long long)purgeable { return MAX(0LL, self.available - self.physicalAvailable); }
- (double)fraction {
    if (self.grouped && self.total > 0) {
        long long used = self.groupUsed < 0 ? 0 : self.groupUsed;
        double fraction = (double)used / (double)self.total;
        if (fraction < 0) return 0;
        return fraction > 1 ? 1 : fraction;
    }
    return self.total > 0 ? (double)self.used / self.total : 0;
}
@end

static NSString *FmtBytes(long long b) {   // volumes: decimal, as Finder shows them
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile];
}
static NSString *FmtMemBytes(long long b) {   // memory, swap, footprints: binary, as Activity Monitor and top show them
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleMemory];
}

static Volume *VolumeFromURL(NSURL *url, NSArray *keys) {
    NSDictionary *v = [url resourceValuesForKeys:keys error:nil];
    NSNumber *total = v[NSURLVolumeTotalCapacityKey];
    NSString *name = v[NSURLVolumeNameKey];
    if (total.longLongValue <= 0) return nil;

    long long avail = [v[NSURLVolumeAvailableCapacityKey] longLongValue];
    // Important-usage rides in `keys` only for a local volume. A second query for it
    // stalls this serial queue when the mount is a hung network volume.
    NSNumber *important = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    // APFS reports purgeable space in the "important usage" figure, which can exceed
    // total capacity; clamp so used/free/fraction stay self-consistent.
    long long physical = MAX(0LL, MIN(avail, total.longLongValue));
    if (important.longLongValue > 0) avail = important.longLongValue;
    // Network and transient volumes can briefly report -1 or a free-space figure larger
    // than their capacity. Clamp every source, not just the APFS "important" value.
    avail = MAX(0LL, MIN(avail, total.longLongValue));

    Volume *vol = [Volume new];
    vol.path = url.path.length ? url.path : @"/";
    vol.name = name.length ? name : [NSFileManager.defaultManager displayNameAtPath:vol.path];
    if (!vol.name.length) vol.name = vol.path;
    vol.total = total.longLongValue; vol.available = avail;
    vol.physicalAvailable = MIN(physical, avail);
    vol.isInternal = [v[NSURLVolumeIsInternalKey] boolValue] || [vol.path isEqualToString:@"/"];
    vol.isLocal = [v[NSURLVolumeIsLocalKey] boolValue];
    return vol;
}

// Disk images report model "Disk Image" (or that protocol). A synthesized APFS
// volume on one still carries the model, which is how Archive stays off the glance
// while a USB SSD's volumes stay on it.
static BOOL BSDNameIsDiskImage(DASessionRef session, const char *bsd) {
    if (!session || !bsd || !bsd[0]) return NO;
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd);
    if (!disk) return NO;
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    BOOL image = NO;
    if (desc) {
        CFTypeRef model = CFDictionaryGetValue(desc, kDADiskDescriptionDeviceModelKey);
        CFTypeRef protocol = CFDictionaryGetValue(desc, kDADiskDescriptionDeviceProtocolKey);
        if (model && CFGetTypeID(model) == CFStringGetTypeID() &&
            CFStringCompare((CFStringRef)model, CFSTR("Disk Image"), 0) == kCFCompareEqualTo)
            image = YES;
        if (protocol && CFGetTypeID(protocol) == CFStringGetTypeID() &&
            CFStringCompare((CFStringRef)protocol, CFSTR("Disk Image"), 0) == kCFCompareEqualTo)
            image = YES;
        CFRelease(desc);
    }
    CFRelease(disk);
    return image;
}

static BOOL PathIsDiskImage(DASessionRef session, NSString *path) {
    struct statfs info;
    if (!path.length || statfs(path.fileSystemRepresentation, &info) != 0) return NO;
    const char *from = info.f_mntfromname;
    const char *base = strrchr(from, '/');
    return BSDNameIsDiskImage(session, base ? base + 1 : from);
}

static Volume *RootVolumeFallback(void) {
    NSURL *root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    Volume *fromURL = VolumeFromURL(root, VolumeResourceKeys(YES));
    if (fromURL) return fromURL;

    struct statfs s;
    if (statfs("/", &s) != 0 || s.f_blocks <= 0) return nil;
    Volume *vol = [Volume new];
    vol.path = @"/";
    NSString *displayName = [NSFileManager.defaultManager displayNameAtPath:@"/"];
    vol.name = displayName.length ? displayName : @"Macintosh HD";
    vol.total = (long long)s.f_blocks * (long long)s.f_bsize;
    vol.available = (long long)s.f_bavail * (long long)s.f_bsize;
    vol.physicalAvailable = vol.available;
    vol.isInternal = YES;
    vol.isLocal = YES;
    vol.isDiskImage = NO;
    return vol;
}

static NSDictionary *GlanceRecordForVolume(Volume *volume) {
    NSMutableDictionary *record = [@{
        @"name": volume.name ?: @"",
        @"path": volume.path ?: @"",
        @"boot": @([volume.path isEqualToString:@"/"]),
        @"internal": @(volume.isInternal),
        @"local": @(volume.isLocal),
        @"diskImage": @(volume.isDiskImage),
        @"totalBytes": @(volume.total),
        @"freeBytes": @(volume.available),
    } mutableCopy];
    // Container id, size and per-volume used let the pure grouping count a shared
    // APFS container once. Missing fields leave a volume as its own row.
    if (volume.container.length) {
        record[@"container"] = volume.container;
        record[@"containerFreeBytes"] = @(volume.available);
    }
    if (volume.containerBytes > 0) record[@"containerBytes"] = @(volume.containerBytes);
    if (volume.hasVolumeUsed && volume.volumeUsed >= 0) record[@"usedBytes"] = @(volume.volumeUsed);
    if (volume.backingPath.length) record[@"backingPath"] = volume.backingPath;
    return record;
}

static NSString *BSDNameAtPath(NSString *path) {
    struct statfs info;
    if (!path.length || statfs(path.fileSystemRepresentation, &info) != 0) return nil;
    const char *from = info.f_mntfromname;
    const char *base = strrchr(from, '/');
    const char *bsd = base ? base + 1 : from;
    if (!bsd || !bsd[0]) return nil;
    return [NSString stringWithUTF8String:bsd];
}

static BOOL MountIsAPFS(NSString *path) {
    struct statfs info;
    if (!path.length || statfs(path.fileSystemRepresentation, &info) != 0) return NO;
    return strcmp(info.f_fstypename, "apfs") == 0;
}

// ATTR_VOL_SPACEUSED is this volume's bytes, not the container's. The returned
// attribute sits immediately after the 4-byte length (aligned to 4, not 8).
static long long VolumeSpaceUsed(NSString *path) {
    if (!path.length) return -1;
    struct attrlist attr;
    memset(&attr, 0, sizeof(attr));
    attr.bitmapcount = ATTR_BIT_MAP_COUNT;
    attr.volattr = ATTR_VOL_SPACEUSED;
    unsigned char buf[16];
    memset(buf, 0, sizeof(buf));
    if (getattrlist(path.fileSystemRepresentation, &attr, buf, sizeof(buf), 0) != 0) return -1;
    uint32_t length = 0;
    memcpy(&length, buf, sizeof(length));
    if (length < sizeof(uint32_t) + sizeof(off_t)) return -1;
    off_t used = 0;
    memcpy(&used, buf + sizeof(uint32_t), sizeof(used));
    return used < 0 ? -1 : (long long)used;
}

static long long ContainerMediaBytes(DASessionRef session, NSString *container) {
    if (!session || !container.length) return 0;
    DADiskRef disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, container.UTF8String);
    if (!disk) return 0;
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    long long bytes = 0;
    if (desc) {
        CFTypeRef size = CFDictionaryGetValue(desc, kDADiskDescriptionMediaSizeKey);
        if (size && CFGetTypeID(size) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)size, kCFNumberLongLongType, &bytes);
        CFRelease(desc);
    }
    CFRelease(disk);
    return bytes > 0 ? bytes : 0;
}

static NSString *DiskImagePathFromRegistry(io_registry_entry_t entry) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, CFSTR("image-path"), kCFAllocatorDefault, 0);
    if (!value) return nil;
    NSString *path = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        path = [(__bridge NSString *)value copy];
    } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
        NSData *data = (__bridge NSData *)value;
        const unsigned char *bytes = data.bytes;
        NSUInteger len = data.length;
        while (len && bytes[len - 1] == 0) len--;
        path = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    }
    CFRelease(value);
    return path.length ? path : nil;
}

static void CollectDiskImageBSDNames(io_registry_entry_t entry, NSString *imagePath,
                                     NSMutableDictionary<NSString *, NSString *> *out, int depth) {
    if (!imagePath.length || depth > 12) return;
    CFTypeRef bsd = IORegistryEntryCreateCFProperty(entry, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
    if (bsd && CFGetTypeID(bsd) == CFStringGetTypeID()) {
        NSString *name = (__bridge NSString *)bsd;
        if (name.length) out[name] = imagePath;
    }
    if (bsd) CFRelease(bsd);
    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) != KERN_SUCCESS) return;
    io_registry_entry_t child;
    while ((child = IOIteratorNext(children))) {
        CollectDiskImageBSDNames(child, imagePath, out, depth + 1);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
}

// BSD name → backing file. One walk, and only when a mount is not already cached.
static NSDictionary<NSString *, NSString *> *DiskImageBackingByBSD(void) {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    io_iterator_t drives = 0;
    kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                        IOServiceMatching("IOHDIXHDDrive"), &drives);
    if (status != KERN_SUCCESS || !drives) return out;
    io_registry_entry_t drive;
    while ((drive = IOIteratorNext(drives))) {
        NSString *imagePath = DiskImagePathFromRegistry(drive);
        if (imagePath.length) CollectDiskImageBSDNames(drive, imagePath, out, 0);
        IOObjectRelease(drive);
    }
    IOObjectRelease(drives);
    return out;
}

// Container size and the disk-image backing file do not change while a volume
// stays on the same BSD name. Used and free are read every scan; this cache
// keeps DiskArbitration and the IOKit walk off the popover-open path.
static NSMutableDictionary<NSString *, NSDictionary *> *MountFactCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static void AnnotateVolumeContainer(Volume *volume, DASessionRef session,
                                    NSDictionary<NSString *, NSString *> *imagePaths,
                                    NSMutableDictionary<NSString *, NSNumber *> *containerSizes) {
    NSString *bsd = BSDNameAtPath(volume.path);
    if (!bsd.length) return;
    NSDictionary *cached = MountFactCache()[volume.path];
    NSString *container = nil;
    long long containerBytes = 0;
    NSString *backing = nil;
    if ([cached[@"bsd"] isEqual:bsd]) {
        container = cached[@"container"];
        containerBytes = [cached[@"containerBytes"] longLongValue];
        backing = cached[@"backing"];
    } else {
        container = MountIsAPFS(volume.path) ? VolumeContainerID(bsd) : nil;
        if (container.length) {
            NSNumber *known = containerSizes[container];
            containerBytes = known ? known.longLongValue : ContainerMediaBytes(session, container);
            if (containerBytes > 0) containerSizes[container] = @(containerBytes);
        }
        if (imagePaths) {
            backing = imagePaths[bsd];
            // A disk image's volume slice is usually listed; the whole disk is
            // the fallback when only the container BSD name is in the registry.
            if (!backing.length && container.length) backing = imagePaths[container];
        }
        NSMutableDictionary *facts = [NSMutableDictionary dictionary];
        facts[@"bsd"] = bsd;
        if (container.length) facts[@"container"] = container;
        if (containerBytes > 0) facts[@"containerBytes"] = @(containerBytes);
        if (backing.length) facts[@"backing"] = backing;
        MountFactCache()[volume.path] = facts;
    }
    volume.container = container;
    volume.containerBytes = containerBytes;
    volume.backingPath = backing;
}

static NSArray<Volume *> *ScanVolumes(void) {
    // Prefetch every key except important-usage. That one is added only after the
    // cached local flag says the mount is local — asking a network volume for it hangs.
    NSArray *enumKeys = VolumeResourceKeys(NO);
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager
        mountedVolumeURLsIncludingResourceValuesForKeys:enumKeys
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<Volume *> *found = [NSMutableArray array];
    BOOL hasRoot = NO;
    DASessionRef session = DASessionCreate(kCFAllocatorDefault);
    NSMutableArray<Volume *> *pending = [NSMutableArray array];
    for (NSURL *url in urls) {
        id localValue = nil;
        BOOL haveLocal = [url getResourceValue:&localValue forKey:NSURLVolumeIsLocalKey error:nil];
        BOOL isLocal = haveLocal && [localValue isKindOfClass:NSNumber.class] && [localValue boolValue];
        Volume *vol = VolumeFromURL(url, VolumeResourceKeys(isLocal));
        if (!vol) continue;
        vol.isDiskImage = PathIsDiskImage(session, vol.path);
        long long used = VolumeSpaceUsed(vol.path);
        vol.hasVolumeUsed = used >= 0;
        vol.volumeUsed = used;
        if ([vol.path isEqualToString:@"/"]) hasRoot = YES;
        [pending addObject:vol];
    }
    BOOL factsMiss = NO;
    for (Volume *vol in pending) {
        NSString *bsd = BSDNameAtPath(vol.path);
        NSDictionary *cached = bsd.length ? MountFactCache()[vol.path] : nil;
        if (!bsd.length || ![cached[@"bsd"] isEqual:bsd]) { factsMiss = YES; break; }
    }
    NSDictionary<NSString *, NSString *> *imagePaths = factsMiss ? DiskImageBackingByBSD() : nil;
    NSMutableDictionary<NSString *, NSNumber *> *containerSizes = [NSMutableDictionary dictionary];
    for (Volume *vol in pending) {
        AnnotateVolumeContainer(vol, session, imagePaths, containerSizes);
        [found addObject:vol];
    }
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (Volume *vol in found) if (vol.path.length) [live addObject:vol.path];
    for (NSString *path in MountFactCache().allKeys)
        if (![live containsObject:path]) [MountFactCache() removeObjectForKey:path];
    if (session) CFRelease(session);
    if (!hasRoot) {
        Volume *root = RootVolumeFallback();
        if (root) [found addObject:root];
    }
    [found sortUsingComparator:^NSComparisonResult(Volume *a, Volume *b) {
        BOOL ar = [a.path isEqualToString:@"/"], br = [b.path isEqualToString:@"/"];
        if (ar != br) return ar ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return found;
}

#pragma mark - Battery

static long NumFor(NSDictionary *d, NSString *k) {
    id v = d[k]; return [v isKindOfClass:NSNumber.class] ? [v longValue] : LONG_MIN;
}

// Real-time power from the SMC. The battery's IORegistry telemetry only refreshes every
// ~20 s; these sensors update every second and need no privilege. Keys: PDTR = power in
// from the adapter, PSTR = the whole system's draw, SBAP = battery power (negative while
// charging). Read with the AppleSMC user client the way every fan/power monitor does.
typedef struct { char major, minor, build, reserved; UInt16 release; } GBSMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } GBSMCPLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } GBSMCKeyInfo;
typedef struct {
    UInt32 key; GBSMCVersion vers; GBSMCPLimit pLimitData; GBSMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; char bytes[32];
} GBSMCParam;
static io_connect_t GBSMCConnection(void) {
    static io_connect_t conn = IO_OBJECT_NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (svc) { if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) conn = IO_OBJECT_NULL; IOObjectRelease(svc); }
    });
    return conn;
}
static BOOL GBSMCReadFloat(const char *key, double *out) {
    io_connect_t conn = GBSMCConnection();
    if (!conn || strlen(key) != 4) return NO;
    GBSMCParam in = {0}, res = {0};
    in.key = ((UInt32)key[0] << 24) | ((UInt32)key[1] << 16) | ((UInt32)key[2] << 8) | (UInt32)key[3];
    in.data8 = 9;   // key info
    size_t size = sizeof(GBSMCParam);
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &res, &size) != KERN_SUCCESS || res.result) return NO;
    if (res.keyInfo.dataType != (('f' << 24) | ('l' << 16) | ('t' << 8) | ' ') || res.keyInfo.dataSize != 4) return NO;
    in.keyInfo.dataSize = 4; in.data8 = 5;   // read bytes
    memset(&res, 0, sizeof res); size = sizeof(GBSMCParam);
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &res, &size) != KERN_SUCCESS || res.result) return NO;
    float f; memcpy(&f, res.bytes, 4);
    if (!isfinite(f) || fabsf(f) > 500) return NO;
    *out = f;
    return YES;
}
// The hottest CPU core, from the SMC's per-core die sensors (Tp* performance, Te* efficiency
// cores). Key names vary by chip, so they are found once from the SMC's own key index.
static NSArray<NSString *> *CPUTempKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        io_connect_t conn = GBSMCConnection();
        GBSMCParam in = {0}, res = {0};
        size_t size = sizeof(GBSMCParam);
        in.key = ('#' << 24) | ('K' << 16) | ('E' << 8) | 'Y';
        in.keyInfo.dataSize = 4; in.data8 = 5;
        UInt32 count = 0;
        if (conn && IOConnectCallStructMethod(conn, 2, &in, sizeof in, &res, &size) == KERN_SUCCESS && !res.result)
            count = ((UInt32)(UInt8)res.bytes[0] << 24) | ((UInt32)(UInt8)res.bytes[1] << 16) |
                    ((UInt32)(UInt8)res.bytes[2] << 8) | (UInt8)res.bytes[3];
        for (UInt32 i = 0; i < MIN(count, 8192u); i++) {
            GBSMCParam q = {0}, r = {0};
            q.data8 = 8; q.data32 = i;   // key at index
            size = sizeof(GBSMCParam);
            if (IOConnectCallStructMethod(conn, 2, &q, sizeof q, &r, &size) != KERN_SUCCESS || r.result) continue;
            char name[5] = {(char)(r.key >> 24), (char)(r.key >> 16), (char)(r.key >> 8), (char)r.key, 0};
            if (name[0] != 'T' || (name[1] != 'p' && name[1] != 'e')) continue;
            double v;
            if (GBSMCReadFloat(name, &v) && v > 5 && v < 130) [found addObject:@(name)];
        }
        keys = found;
    });
    return keys;
}
static BOOL ReadCPUTempC(double *out) {
    double hottest = 0;
    for (NSString *key in CPUTempKeys()) {
        double v;
        if (GBSMCReadFloat(key.UTF8String, &v) && v > 5 && v < 130) hottest = MAX(hottest, v);
    }
    if (hottest <= 0) return NO;
    *out = hottest;
    return YES;
}
static BOOL ReadThermalPressure(int *out) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check("com.apple.system.thermalpressurelevel", &token) != NOTIFY_STATUS_OK) token = -1;
    });
    uint64_t state = 0;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return NO;
    *out = (int)state;
    return YES;
}
// Core clocks from IOReport, the counters powermetrics reads, without root. The library
// is private, so it is opened at run time; anything missing leaves the clocks unread.
typedef struct {
    BOOL valid;
    double pMHz, pMaxMHz, pBusy;   // fast cores: active MHz, top clock, active share
    double eMHz, eMaxMHz, eBusy;   // efficiency cores
} CoreClocks;

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
static struct {
    CFMutableDictionaryRef (*copyChannels)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    IOReportSubscriptionRef (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*samples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*channelName)(CFDictionaryRef);
    int32_t (*stateCount)(CFDictionaryRef);
    CFStringRef (*stateName)(CFDictionaryRef, int32_t);
    int64_t (*residency)(CFDictionaryRef, int32_t);
} IOR;

// The DVFS tables live on the device tree's pmgr node; a cluster's table is the one with
// one entry per performance state (its state count less IDLE).
static NSArray<NSArray<NSNumber *> *> *DVFSTables(void) {
    static NSArray *tables;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        io_registry_entry_t pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr");
        if (pmgr) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(pmgr, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                NSDictionary *d = (__bridge_transfer NSDictionary *)props;
                for (NSString *key in d)
                    if ([key hasPrefix:@"voltage-states"] && [key hasSuffix:@"-sram"] && [d[key] isKindOfClass:NSData.class]) {
                        NSArray *mhz = DVFSTableMHz(d[key]);
                        if (mhz.count) [found addObject:mhz];
                    }
            }
            IOObjectRelease(pmgr);
        }
        tables = found;
    });
    return tables;
}

static NSArray<NSNumber *> *DVFSTableForStates(NSUInteger states, BOOL fast) {
    NSArray *best = nil;
    for (NSArray<NSNumber *> *t in DVFSTables()) {
        if (t.count + 1 != states) continue;
        if (!best || (fast ? t.lastObject.doubleValue > [best.lastObject doubleValue]
                           : t.lastObject.doubleValue < [best.lastObject doubleValue])) best = t;
    }
    return best;
}

// Clocks averaged since the previous call. The first call only sets the baseline.
static CoreClocks ReadCoreClocks(void) {
    static IOReportSubscriptionRef sub;
    static CFMutableDictionaryRef subbed;
    static CFDictionaryRef previous;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
        if (!lib) return;
        IOR.copyChannels = dlsym(lib, "IOReportCopyChannelsInGroup");
        IOR.subscribe = dlsym(lib, "IOReportCreateSubscription");
        IOR.samples = dlsym(lib, "IOReportCreateSamples");
        IOR.delta = dlsym(lib, "IOReportCreateSamplesDelta");
        IOR.channelName = dlsym(lib, "IOReportChannelGetChannelName");
        IOR.stateCount = dlsym(lib, "IOReportStateGetCount");
        IOR.stateName = dlsym(lib, "IOReportStateGetNameForIndex");
        IOR.residency = dlsym(lib, "IOReportStateGetResidency");
        if (!IOR.copyChannels || !IOR.subscribe || !IOR.samples || !IOR.delta || !IOR.channelName ||
            !IOR.stateCount || !IOR.stateName || !IOR.residency) return;
        CFMutableDictionaryRef channels = IOR.copyChannels(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
        if (!channels) return;
        sub = IOR.subscribe(NULL, channels, &subbed, 0, NULL);
        CFRelease(channels);
    });
    // Refresh fires from several sources at once; a window under two seconds is noise.
    static CoreClocks last;
    static CFAbsoluteTime lastAt;
    if (last.valid && CFAbsoluteTimeGetCurrent() - lastAt < 2) return last;
    CoreClocks out = {0};
    if (!sub) return out;
    CFDictionaryRef now = IOR.samples(sub, subbed, NULL);
    if (!now) return out;
    if (!previous) { previous = now; return out; }
    NSDictionary *delta = (__bridge_transfer NSDictionary *)IOR.delta(previous, now, NULL);
    CFRelease(previous);
    previous = now;
    // Cores in a cluster share one clock; sum their residencies per cluster.
    NSMutableArray *pNames = nil, *eNames = nil, *pRes = nil, *eRes = nil;
    for (NSDictionary *item in delta[@"IOReportChannels"]) {
        CFDictionaryRef ch = (__bridge CFDictionaryRef)item;
        NSString *name = (__bridge NSString *)IOR.channelName(ch);
        BOOL fast = [name hasPrefix:@"PCPU"], efficient = [name hasPrefix:@"ECPU"];
        if (!fast && !efficient) continue;
        int32_t n = IOR.stateCount(ch);
        NSMutableArray *names = [NSMutableArray array], *res = fast ? pRes : eRes;
        BOOL first = !res;
        if (first) res = [NSMutableArray array];
        for (int32_t i = 0; i < n; i++) {
            [names addObject:(__bridge NSString *)IOR.stateName(ch, i) ?: @""];
            double r = (double)IOR.residency(ch, i);
            if (first) [res addObject:@(r)];
            else if (i < (int32_t)res.count) res[i] = @([res[i] doubleValue] + r);
        }
        if (fast) { pNames = names; pRes = res; } else { eNames = names; eRes = res; }
    }
    NSArray *pTable = DVFSTableForStates(pNames.count, YES), *eTable = DVFSTableForStates(eNames.count, NO);
    if (!pTable) return out;
    out.pMHz = ClusterActiveMHz(pNames, pRes, pTable, &out.pBusy);
    out.pMaxMHz = [pTable.lastObject doubleValue];
    if (eTable) {
        out.eMHz = ClusterActiveMHz(eNames, eRes, eTable, &out.eBusy);
        out.eMaxMHz = [eTable.lastObject doubleValue];
    }
    out.valid = YES;
    last = out; lastAt = CFAbsoluteTimeGetCurrent();
    return out;
}

// Lay the live SMC watts over the slow IORegistry figures; anything unreadable keeps its value.
static void ApplyLivePower(BatteryState *b) {
    if (!b->valid) return;
    double in, load, batt;
    if (b->acConnected && GBSMCReadFloat("PDTR", &in) && in >= 0) b->systemPowerIn_mW = lround(in * 1000);
    if (!b->acConnected) b->systemPowerIn_mW = 0;
    if (GBSMCReadFloat("PSTR", &load) && load > 0) b->systemLoad_mW = lround(load * 1000);
    if (GBSMCReadFloat("SBAP", &batt) && b->voltage_mV > 0)
        b->amperage_mA = lround(-batt * 1e6 / b->voltage_mV);   // SBAP < 0 = into the battery
    double cell;   // TB0T…TB2T: the pack's cell sensors
    const char *cells[] = {"TB0T", "TB1T", "TB2T"};
    for (size_t i = 0; i < sizeof cells / sizeof *cells; i++)
        if (GBSMCReadFloat(cells[i], &cell) && cell > 5 && cell < 90) b->tempC = MAX(b->tempC, cell);
}

static BatteryState ReadBattery(void) {
    BatteryState b = {0};
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return b;
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
        NSDictionary *d = CFBridgingRelease(props);
        long percent = NumFor(d, @"CurrentCapacity");
        b.valid = percent >= 0 && percent <= 100;
        b.percent = b.valid ? (int)percent : 0;
        b.isCharging = [d[@"IsCharging"] boolValue];
        b.acConnected = [d[@"ExternalConnected"] boolValue];
        b.fullyCharged = [d[@"FullyCharged"] boolValue];
        BatteryApplyCapacities(&b, d);
        long amp = NumFor(d, @"Amperage");
        if (amp == LONG_MIN) amp = NumFor(d, @"InstantAmperage");
        if (amp > (1L << 40)) amp -= (1L << 48);
        b.amperage_mA = amp == LONG_MIN ? 0 : amp;
        b.voltage_mV = NumFor(d, @"Voltage");
        b.cycleCount = NumFor(d, @"CycleCount");
        NSDictionary *telemetry = [d[@"PowerTelemetryData"] isKindOfClass:NSDictionary.class] ? d[@"PowerTelemetryData"] : nil;
        b.systemPowerIn_mW = NumFor(telemetry, @"SystemPowerIn");
        b.systemLoad_mW = NumFor(telemetry, @"SystemLoad");
        NSDictionary *adapter = [d[@"AdapterDetails"] isKindOfClass:NSDictionary.class] ? d[@"AdapterDetails"] : nil;
        long adapterWatts = NumFor(adapter, @"Watts");
        b.adapterWatts = (b.acConnected && adapterWatts > 0 && adapterWatts < 1000) ? adapterWatts : 0;
        // Never reinterpret the direction-dependent TimeRemaining as time to empty.
        long empty = NumFor(d, @"AvgTimeToEmpty"), full = NumFor(d, @"AvgTimeToFull");
        b.minutesToEmpty = !b.acConnected && !b.isCharging && empty > 0 && empty <= 1440 ? empty : -1;
        b.minutesToFull = b.acConnected && b.isCharging && full > 0 && full <= 1440 ? full : -1;
        long updated = NumFor(d, @"UpdateTime");
        b.telemetryTimestamp = updated > 0 ? updated : 0;
        // Prefer the public, powerd-smoothed estimates. IOPSKeys.h defines both in
        // minutes, with -1 meaning calculating, and specifies their valid direction.
        CFTypeRef info = IOPSCopyPowerSourcesInfo();
        if (info) {
            NSArray *sources = CFBridgingRelease(IOPSCopyPowerSourcesList(info));
            for (id source in sources) {
                NSDictionary *ps = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)source);
                if (![ps[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) continue;
                BatteryState publicTimes = b;
                BatteryApplySystemTimes(&publicTimes, ps);
                // powerd may still be calculating while the registry already has a
                // valid direction-specific estimate. Keep that fallback, not -1.
                if (publicTimes.minutesToEmpty > 0) b.minutesToEmpty = publicTimes.minutesToEmpty;
                if (publicTimes.minutesToFull > 0) b.minutesToFull = publicTimes.minutesToFull;
                break;
            }
            CFRelease(info);
        }
    }
    IOObjectRelease(svc);
    ApplyLivePower(&b);
    return b;
}

#pragma mark - Process metrics

static NSString *AppGroupForPid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *p = [NSString stringWithUTF8String:path];
    if (!p) return nil;   // executable path was not valid UTF-8
    // Vendor helpers and daemons (IDrive's backup, its daemon app) group under the vendor.
    NSString *vendor = SupportVendorFromPath(p);
    if (vendor) return vendor;
    NSRange app = [p rangeOfString:@".app/"];
    // Not inside a bundle: the executable path still names it better than `top`'s
    // command column does, which prints a bare version number for Claude Code.
    if (app.location == NSNotFound) return ProcessNameFromPath(p);
    NSString *bundle = [p substringToIndex:app.location + 4];
    NSString *name = [NSFileManager.defaultManager displayNameAtPath:bundle];
    if ([name hasSuffix:@".app"]) name = [name substringToIndex:name.length - 4];
    return name.length ? name : nil;
}

// SIGTERM a child after `seconds`, SIGKILL a second later, unless disarmed first. Callers
// disarm right after waitUntilExit, so a reaped child's recycled pid is never signalled.
@interface GBWatchdog : NSObject
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds;
// hardKill SIGKILLs at the deadline. Quit uses it so a restore cannot outlive that
// second; the usual path SIGTERMs at the deadline and SIGKILLs one second later.
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds hardKill:(BOOL)hardKill;
- (void)disarm;
@end
@implementation GBWatchdog { pid_t _pid; BOOL _disarmed; }
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds {
    return [self initWithPid:pid seconds:seconds hardKill:NO];
}
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds hardKill:(BOOL)hardKill {
    if (!(self = [super init])) return nil;
    _pid = pid;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    int64_t deadline = seconds > 0 ? seconds : 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, deadline * NSEC_PER_SEC), q, ^{
        if (hardKill) {
            [self signal:SIGKILL];
            return;
        }
        [self signal:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), q, ^{ [self signal:SIGKILL]; });
    });
    return self;
}
- (void)signal:(int)sig { @synchronized (self) { if (!_disarmed) kill(_pid, sig); } }
- (void)disarm { @synchronized (self) { _disarmed = YES; } }
@end

static NSString *RunTaskOutput(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    t.environment = @{@"LC_ALL": @"C"};   // ps/top honor LC_NUMERIC; force '.' decimals
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if (![t launchAndReturnError:&launchError]) return nil;

    // `top`, `ps`, and sqlite normally complete quickly. Never let a wedged child pin the
    // sampling queue or the serial AI reader forever; terminate at 8s and force-kill at 9s.
    // Signal by pid (NSTask is not thread-safe), and judge the outcome by how the child
    // ended rather than by a flag shared across queues: a killed child is never a success.
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:t.processIdentifier seconds:8];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    [watchdog disarm];
    if (t.terminationReason != NSTaskTerminationReasonExit || t.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Reads the live SleepDisabled system power setting (no admin needed — a plain IOKit read
// surfaced by `pmset -g`). YES = Keep Awake is on (no idle or lid-close sleep).
// nil when the setting could not be read — callers must not mistake that for "normal
// sleep", or the toggle would offer to ENABLE staying awake on a Mac that already is.
static NSNumber *SleepDisabledStateViaTool(void) {
    NSString *out = RunTaskOutput(@"/usr/bin/pmset", @[@"-g"]);
    return out.length ? ParseSleepDisabled(out) : nil;
}
// The system power plist is world-readable and carries the same key pmset prints, in a
// few milliseconds and with no child process — safe on the main thread. pmset is the
// fallback for a plist that has never had the key written.
static NSNumber *SleepDisabledState(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/com.apple.PowerManagement.plist"];
    NSDictionary *settings = [plist[@"SystemPowerSettings"] isKindOfClass:NSDictionary.class]
        ? plist[@"SystemPowerSettings"] : nil;
    id value = settings[@"SleepDisabled"];
    if ([value isKindOfClass:NSNumber.class]) return @([value boolValue]);
    return SleepDisabledStateViaTool();
}

// Runs a root shell command through an osascript administrator prompt: macOS
// shows its own authentication dialog and runs pmset as root just this once — no background
// helper or LaunchDaemon is installed. Returns YES only if the change was applied (NO when
// the user cancels the prompt or authorization fails). Commands and prompts are built only
// from fixed literals (plus a validated user name) — never free input — and contain no
// double quote or backslash, so nothing can break out of the AppleScript string.
static BOOL SetPmsetShellViaAdmin(NSString *shell, NSString *prompt) {
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"%@\" with prompt \"%@\" with administrator privileges", shell, prompt];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[@"-e", script];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:NULL]) return NO;
    [t waitUntilExit];
    return t.terminationStatus == 0;
}
// Low Power Mode as the system is applying it right now (a plain in-process read, main-thread
// safe). `-a` sets it for battery and adapter alike, so an "only on battery" choice made in
// System Settings becomes plain on/off once toggled here.
static BOOL LowPowerModeEnabled(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }

// One-click pmset toggles. macOS's admin prompt only takes a typed password, so the fast
// path is a one-time sudoers rule (PmsetSudoersRule: exactly four pmset commands). The
// rule is the security boundary, and the worst it permits is toggling Low Power Mode or
// lid-close sleep. A Touch ID check in front of it guarded nothing (any process of this
// user can run the same `sudo -n`), so the switches no longer ask (2026-10-06).
static NSString *const kPmsetSudoersPath = @"/etc/sudoers.d/glancebar";
static BOOL PmsetRuleInstalled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:kPmsetSudoersPath];
}
static BOOL RunPmsetViaSudo(NSString *setting, BOOL enable) {
    return RunTaskOutput(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", setting, enable ? @"1" : @"0"]) != nil;
}
// Writes the rule from inside the root shell (never from a user-writable temp file a
// same-user process could swap before root reads it), checks it with visudo, then moves
// it into place; a rule that fails visudo never lands. The rule text is fixed apart from
// a user name PmsetSudoersRule has restricted to [A-Za-z0-9_.-].
static BOOL InstallPmsetRule(void) {
    NSString *rule = PmsetSudoersRule(NSUserName());
    if (!rule) return NO;
    NSString *shell = [NSString stringWithFormat:
        @"umask 377; f=/etc/sudoers.d/.glancebar-new; /bin/rm -f $f; "
        @"{ echo '# Installed by Glancebar for one-click power toggles. Delete this file to revoke.'; echo '%@'; } > $f "
        @"&& /usr/sbin/visudo -cqf $f && /bin/chmod 0440 $f && /usr/sbin/chown root:wheel $f "
        @"&& /bin/mv -f $f %@ || { /bin/rm -f $f; exit 1; }", rule, kPmsetSudoersPath];
    return SetPmsetShellViaAdmin(shell, @"Glancebar needs your password once so Keep Awake and Low Power can switch without asking again.");
}
static BOOL RemovePmsetRule(void) {
    return SetPmsetShellViaAdmin([@"/bin/rm -f " stringByAppendingString:kPmsetSudoersPath],
                                 @"Glancebar needs administrator access to remove its power-switch rule.");
}

static NSArray<NSDictionary *> *SampleHogs(int topN) {
    NSString *out = RunTaskOutput(@"/usr/bin/top", @[@"-l", @"2", @"-s", @"1", @"-stats",
                                                     @"pid,command,power", @"-o", @"power", @"-n", @"40"]);
    // The sampler's own `top` scores itself (12% of an idle sample on 2026-09-07). It is
    // measurement, not a hog; drop it and let the next real row up.
    NSArray<NSDictionary *> *rows = ParseHogs(out ? out : @"", topN + 1,
                                              ^NSString *(pid_t pid){ return AppGroupForPid(pid); });
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSArray *commands = [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[];
        if ([row[@"name"] isEqual:@"top"] && commands.count == 1 && [commands.firstObject isEqual:@"top"]) continue;
        if ((int)kept.count >= topN) break;
        [kept addObject:row];
    }
    return kept;
}

// Physical footprint (what Activity Monitor shows) — unlike RSS it does not count
// shared framework pages once per helper process.
static unsigned long long FootprintForPid(pid_t pid) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
        return ri.ri_phys_footprint;
    return 0;
}

// Every readable process's cumulative energy (nanojoules) from the kernel's own counter:
// no child process and no privilege, ~2 ms. Root-owned processes (WindowServer,
// kernel_task) are unreadable; their share lands in "Screen + system".
static NSDictionary<NSNumber *, NSNumber *> *SnapshotProcessEnergy(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return @{};
    pid_t *pids = calloc((size_t)count * 2, sizeof(pid_t));
    if (!pids) return @{};
    count = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)count * 2));
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)MAX(count, 0)];
    for (int i = 0; i < count; i++) {
        struct rusage_info_v6 ri;
        if (pids[i] > 0 && proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0)
            out[@(pids[i])] = @((double)ri.ri_energy_nj);
    }
    free(pids);
    return out;
}

// pid -> %CPU for every process, root's included (ps needs no privilege for this).
static NSDictionary<NSNumber *, NSNumber *> *ProcessCPUByPid(void) {
    NSString *out = RunTaskOutput(@"/bin/ps", @[@"-axo", @"pid=,pcpu="]);
    NSMutableDictionary *cpu = [NSMutableDictionary dictionary];
    for (NSString *line in [out ?: @"" componentsSeparatedByString:@"\n"]) {
        NSArray *f = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (f.count >= 2 && [f[0] intValue] > 0) cpu[@([f[0] intValue])] = @([f[1] doubleValue]);
    }
    return cpu;
}

static NSDictionary<NSString *, NSArray<NSDictionary *> *> *SampleProcessStats(int topN) {
    NSString *out = RunTaskOutput(@"/bin/ps", @[@"-axo", @"pid=,pcpu=,rss=,comm="]);
    return ParseProcessStats(out ? out : @"", topN,
                             ^NSString *(pid_t pid){ return AppGroupForPid(pid); },
                             ^unsigned long long (pid_t pid){ return FootprintForPid(pid); });
}

static NSArray<NSString *> *CommandsForHog(NSDictionary *h) {
    id commands = h[@"commands"];
    return [commands isKindOfClass:NSArray.class] ? commands : @[];
}

static NSString *CommandSummary(NSArray<NSString *> *commands) {
    if (!commands.count) return @"process";
    if (commands.count == 1) return [NSString stringWithFormat:@"%@ process", commands.firstObject];
    if (commands.count == 2) return [NSString stringWithFormat:@"%@ + %@", commands[0], commands[1]];
    return [NSString stringWithFormat:@"%@ + %@ + %lu more",
            commands[0], commands[1], (unsigned long)commands.count - 2];
}

static NSDictionary *KnownProcessInfo(NSString *name) {
    static NSDictionary *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @{
            @"WindowServer": @{@"title": @"Display Server", @"detail": @"WindowServer · macOS display compositor"},
            @"syspolicyd": @{@"title": @"System Policy", @"detail": @"syspolicyd · app security checks"},
            @"trustd": @{@"title": @"Certificate Trust", @"detail": @"trustd · certificate checks"},
            @"securityd": @{@"title": @"Security Service", @"detail": @"securityd · keychain and authorization"},
            @"kernel_task": @{@"title": @"Kernel", @"detail": @"kernel_task · macOS core system work"},
            @"launchservicesd": @{@"title": @"Launch Services", @"detail": @"launchservicesd · app launch database"},
            @"cfprefsd": @{@"title": @"Preferences Service", @"detail": @"cfprefsd · app settings cache"},
            @"distnoted": @{@"title": @"Notifications", @"detail": @"distnoted · system notification routing"},
            @"logd": @{@"title": @"Logging", @"detail": @"logd · system log service"},
            @"runningboardd": @{@"title": @"App Lifecycle", @"detail": @"runningboardd · app state management"},
            @"sysmond": @{@"title": @"System Monitor", @"detail": @"sysmond · system activity tracking"},
            @"mds": @{@"title": @"Spotlight", @"detail": @"mds · search indexing"},
            @"mds_stores": @{@"title": @"Spotlight", @"detail": @"mds_stores · search index database"},
            @"mdworker_shared": @{@"title": @"Spotlight Worker", @"detail": @"mdworker_shared · file indexing"},
            @"backupd": @{@"title": @"Time Machine", @"detail": @"backupd · backup service"},
            @"cloudd": @{@"title": @"iCloud", @"detail": @"cloudd · iCloud sync"},
            @"nsurlsessiond": @{@"title": @"Background Transfers", @"detail": @"nsurlsessiond · downloads and uploads"},
            @"locationd": @{@"title": @"Location Services", @"detail": @"locationd · location access"},
            @"bluetoothd": @{@"title": @"Bluetooth", @"detail": @"bluetoothd · Bluetooth service"},
            @"airportd": @{@"title": @"Wi-Fi", @"detail": @"airportd · wireless networking"},
            @"mediaanalysisd": @{@"title": @"Media Analysis", @"detail": @"mediaanalysisd · photo and media analysis"}
        };
    });
    return known[name];
}

static NSDictionary *ProcessDisplayInfo(NSDictionary *h) {
    NSString *name = [h[@"name"] isKindOfClass:NSString.class] ? h[@"name"] : @"Process";
    NSDictionary *known = KnownProcessInfo(name);
    if (known) return known;

    NSArray<NSString *> *commands = CommandsForHog(h);
    NSString *detail = CommandSummary(commands);
    if (commands.count == 1 && [commands.firstObject isEqualToString:name])
        detail = [name hasSuffix:@"d"] ? @"background service" : @"process";
    return @{@"title": name, @"detail": detail};
}

static NSColor *PressureColor(double share) {
    if (share >= 0.35) return NSColor.systemOrangeColor;
    if (share >= 0.15) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
}

#pragma mark - System pressure

typedef struct {
    BOOL valid;
    uint64_t user, system, idle, nice;
} CPUCounters;

typedef struct {
    BOOL cpuValid, memValid, swapValid;
    double cpu;
    uint64_t memTotal, memUsed, memAvailable, swapUsed;
    int kernPressure;   // kern.memorystatus_vm_pressure_level: 1/2/4, 0 = unknown
    BOOL tempValid, thermalValid;
    double cpuTempC;     // hottest CPU core
    int thermalPressure; // com.apple.system.thermalpressurelevel, see ThermalLevelFor
    CoreClocks clocks;
} SystemState;

// mach_host_self() returns a send right each call and the urefs are never returned;
// fetch it once.
static host_t HostPort(void) {
    static host_t port;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ port = mach_host_self(); });
    return port;
}

static int CoreCount(void) {
    static int cores;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int v = 0; size_t sz = sizeof(v);
        if (sysctlbyname("hw.logicalcpu", &v, &sz, NULL, 0) != 0 || v < 1) v = 1;
        cores = v;
    });
    return cores;
}

// ps reports %cpu per core (a busy group can exceed 100%); normalize to the same
// all-cores scale as the headline CPU% so the two are comparable.
static double GroupCPUShare(NSDictionary *h) {
    return [h[@"cpu"] doubleValue] / 100.0 / CoreCount();
}

static CPUCounters ReadCPUCounters(void) {
    CPUCounters c = {0};
    natural_t cpuCount = 0;
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t cpuInfoCount = 0;
    kern_return_t kr = host_processor_info(HostPort(), PROCESSOR_CPU_LOAD_INFO,
                                           &cpuCount, &cpuInfo, &cpuInfoCount);
    if (kr != KERN_SUCCESS || !cpuInfo) return c;
    processor_cpu_load_info_t loads = (processor_cpu_load_info_t)cpuInfo;
    for (natural_t i = 0; i < cpuCount; i++) {
        c.user += loads[i].cpu_ticks[CPU_STATE_USER];
        c.system += loads[i].cpu_ticks[CPU_STATE_SYSTEM];
        c.idle += loads[i].cpu_ticks[CPU_STATE_IDLE];
        c.nice += loads[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, cpuInfoCount * sizeof(integer_t));
    c.valid = YES;
    return c;
}

static SystemState ReadSystemState(CPUCounters *previous) {
    SystemState s = {0};

    CPUCounters now = ReadCPUCounters();
    // Per-CPU tick counters are 32-bit and can wrap on long uptimes; a wrapped delta
    // would underflow to ~2^64. Discard the sample instead.
    if (now.valid && previous && previous->valid &&
        now.user >= previous->user && now.system >= previous->system &&
        now.nice >= previous->nice && now.idle >= previous->idle) {
        uint64_t busy = (now.user - previous->user) + (now.system - previous->system) + (now.nice - previous->nice);
        uint64_t idle = now.idle - previous->idle;
        uint64_t total = busy + idle;
        if (total > 0) { s.cpu = (double)busy / (double)total; s.cpuValid = YES; }
    }
    if (previous && now.valid) *previous = now;

    uint64_t memTotal = 0;
    size_t memSize = sizeof(memTotal);
    if (sysctlbyname("hw.memsize", &memTotal, &memSize, NULL, 0) == 0 && memTotal > 0) {
        vm_size_t pageSize = 0;
        vm_statistics64_data_t vm = {0};
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        if (host_page_size(HostPort(), &pageSize) == KERN_SUCCESS &&
            host_statistics64(HostPort(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
            // Activity Monitor's "Memory Used": app memory (anonymous pages less the
            // purgeable ones) + wired + compressed. Counting every active page instead
            // read 3.5 GB low on 2026-09-07; inactive anonymous pages are still in use.
            uint64_t anonymous = vm.internal_page_count > vm.purgeable_count
                ? (uint64_t)vm.internal_page_count - vm.purgeable_count : 0;
            uint64_t usedPages = anonymous + vm.wire_count + vm.compressor_page_count;
            uint64_t used = usedPages * (uint64_t)pageSize;
            if (used > memTotal) used = memTotal;
            s.memTotal = memTotal;
            s.memUsed = used;
            s.memAvailable = memTotal - used;
            s.memValid = YES;
        }
    }

    struct xsw_usage swap = {0};
    size_t swapSize = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0) {
        s.swapUsed = swap.xsu_used;
        s.swapValid = YES;
    }

    int pressure = 0;
    size_t pressureSize = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, NULL, 0) == 0)
        s.kernPressure = pressure;

    s.tempValid = ReadCPUTempC(&s.cpuTempC);
    s.thermalValid = ReadThermalPressure(&s.thermalPressure);
    s.clocks = ReadCoreClocks();
    return s;
}

static ThermalLevel SystemThermalLevel(SystemState s) {
    return s.thermalValid ? ThermalLevelFor(s.thermalPressure) : ThermalUnknown;
}

// "Hottest core 73 °C · pressure heavy"
static NSString *ThermalStatusText(SystemState s) {
    NSMutableArray *parts = [NSMutableArray array];
    if (s.tempValid) [parts addObject:[NSString stringWithFormat:@"Hottest core %ld °C", lround(s.cpuTempC)]];
    if (s.thermalValid) [parts addObject:[NSString stringWithFormat:@"pressure %@", ThermalPressureName(s.thermalPressure)]];
    return parts.count ? [parts componentsJoinedByString:@" · "] : @"Temperature unknown";
}

static NSString *MemoryPressureLevel(SystemState s) {
    // Prefer the kernel memorystatus subsystem's own verdict: Apple Silicon swaps
    // aggressively while perfectly healthy, so fixed swap thresholds cry wolf.
    if (s.kernPressure == 4) return @"High";
    if (s.kernPressure == 2) return @"Medium";
    if (s.kernPressure == 1) return @"Low";
    // Fallback heuristic when the sysctl is unavailable:
    if (!s.memValid || s.memTotal == 0) return @"Unknown";
    double available = (double)s.memAvailable / (double)s.memTotal;
    if (available < 0.08 || (s.swapValid && s.swapUsed >= 2ULL * 1024ULL * 1024ULL * 1024ULL)) return @"High";
    if (available < 0.16 || (s.swapValid && s.swapUsed >= 512ULL * 1024ULL * 1024ULL)) return @"Medium";
    return @"Low";
}

static NSString *SystemPressureLevel(SystemState s) {
    NSString *mem = MemoryPressureLevel(s);
    if ([mem isEqualToString:@"High"] || (s.cpuValid && s.cpu >= 0.85)) return @"High";
    if ([mem isEqualToString:@"Medium"] || (s.cpuValid && s.cpu >= 0.50)) return @"Medium";
    if ([mem isEqualToString:@"Unknown"] && !s.cpuValid) return @"Unknown";
    return @"Low";
}

static NSColor *SystemPressureColor(NSString *level) {
    if ([level isEqualToString:@"High"]) return NSColor.systemRedColor;
    if ([level isEqualToString:@"Medium"]) return NSColor.systemOrangeColor;
    if ([level isEqualToString:@"Unknown"]) return NSColor.secondaryLabelColor;
    return NSColor.systemGreenColor;
}

static NSString *CPUStatusText(SystemState s) {
    return s.cpuValid ? [NSString stringWithFormat:@"CPU %d%%", (int)lround(s.cpu * 100)] : @"CPU estimating";
}

static NSString *MemoryStatusText(SystemState s) {
    if (!s.memValid) return @"Memory unknown";
    return [NSString stringWithFormat:@"Memory pressure %@ · %@ available",
            MemoryPressureLevel(s), FmtMemBytes(s.memAvailable)];
}

static NSString *SwapStatusText(SystemState s) {
    if (!s.swapValid) return @"Swap unknown";
    if (s.swapUsed == 0) return @"Swap none";   // NSByteCountFormatter renders 0 as "Zero KB"
    return [NSString stringWithFormat:@"Swap %@", FmtMemBytes(s.swapUsed)];
}

static NSString *SystemSummaryText(SystemState s) {
    NSMutableArray *parts = [NSMutableArray array];
    if (s.memValid) [parts addObject:[NSString stringWithFormat:@"RAM %@ free", FmtMemBytes(s.memAvailable)]];
    NSString *level = MemoryPressureLevel(s);
    if ([level isEqualToString:@"Medium"] || [level isEqualToString:@"High"])
        [parts addObject:[NSString stringWithFormat:@"pressure %@", level.lowercaseString]];
    if (s.swapValid) [parts addObject:s.swapUsed == 0 ? @"no swap" : [NSString stringWithFormat:@"swap %@", FmtMemBytes(s.swapUsed)]];
    if (s.thermalValid && s.thermalPressure > 0)
        [parts addObject:[NSString stringWithFormat:@"thermal %@", ThermalPressureName(s.thermalPressure)]];
    return parts.count ? [parts componentsJoinedByString:@" · "] : CPUStatusText(s);
}

static NSColor *CPUColor(double cpu) {
    if (cpu >= 0.80) return NSColor.systemRedColor;
    if (cpu >= 0.50) return NSColor.systemOrangeColor;
    if (cpu >= 0.20) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
}

#pragma mark - AI usage

@interface AIUsage : NSObject
@property (copy) NSString *name, *source, *resetText, *statusText, *statusSource, *statusReason, *topModel;
@property (copy) NSString *extraUsage;   // e.g. "9,122 of 10,000 AUD (91%)"
@property (copy) NSString *limitRefreshError;
@property (copy) NSString *billingNote;   // Codex: where requests bill when not the shown window's bucket
@property (copy) NSString *diagnostics;   // --dump only: why the gauge is or isn't shown
@property BOOL available, stale, limitStatusAvailable, limitStale, overageActive;
@property double remainingFraction;
@property long long todayTokens, weekTokens, todayMessages, todaySessions, todayToolCalls, weekSessions;
@property long long todayTokensAll, weekTokensAll;   // incl. cached context re-reads
@property (strong) NSDate *lastActivity;
@property (strong) NSDate *limitUpdatedAt;
@property (strong) NSDate *resetAt;   // the reset instant behind resetText, for countdowns
@property (copy) NSArray<NSDictionary *> *models;
@property (copy) NSArray<NSDictionary *> *limitWindows;   // all current limit windows (dual meter); bar still uses remainingFraction
@end
@implementation AIUsage @end

// How often an account limit may be re-fetched. Both endpoints rate-limit readily, so a
// cached figure younger than this is as current as a fresh fetch would have made it.
static const double kAccountPollInterval = 900;   // 15 minutes
static const double kHiddenAIRefreshInterval = 300;   // background pass while no AI surface shows
static const double kAuthFailureRetryInterval = 300;  // after a 401/403: a re-login is quick

// A future reset does not make an old observation current. Codex logs can stop
// carrying limits entirely (for example when work moves to another surface).
static BOOL CodexObservationFresh(NSDate *observed, double now) {
    if (!observed || !isfinite(now)) return NO;
    double age=now-observed.timeIntervalSince1970;
    return isfinite(age) && age>=-5 && age<=kAccountPollInterval;
}
static BOOL CodexQuotaUnavailable(AIUsage *u) {
    if (![u.name isEqualToString:@"Codex"]) return NO;
    if (u.resetAt && u.resetAt.timeIntervalSinceNow<=0) return YES;
    return u.limitUpdatedAt ? !CodexObservationFresh(u.limitUpdatedAt,NSDate.date.timeIntervalSince1970) : u.limitStale;
}

// Unified logging for the AI pipeline: transitions only, metadata only (booleans,
// HTTP codes, our own status strings — never tokens, counts, or credentials).
// View: log show --predicate 'subsystem == "com.iantodd.glancebar"' --last 12h
static os_log_t GBAILog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.iantodd.glancebar", "ai"); });
    return log;
}
#define GBLog(fmt, ...) os_log(GBAILog(), fmt, ##__VA_ARGS__)

// --- Playback event log ---
// One JSON line per play, pause, track, failure, stall and output change, each with its cause.
// On 12 Nov 2026 the headphones were sending Pause commands and nothing here recorded why the
// player stopped; finding it took a dig through the system log.
static NSString *PlaybackLogPath(void) {
    const char *override = getenv("GLANCEBAR_PLAYBACK_LOG");
    if (override && override[0]) return @(override);
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Glancebar/playback.jsonl"];
}
static dispatch_queue_t PlaybackLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.iantodd.glancebar.playback-log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static const unsigned long long kPlaybackLogMaxBytes = 2 * 1024 * 1024;   // then one older file is kept
static void PlaybackLogAppend(NSString *event, NSDictionary *fields) {
    NSString *line = PlaybackEventLine(event, fields, NSDate.date.timeIntervalSince1970);
    dispatch_async(PlaybackLogQueue(), ^{
        NSString *path = PlaybackLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > kPlaybackLogMaxBytes) {
            NSString *older = [path stringByAppendingString:@".1"];
            [fm removeItemAtPath:older error:nil];
            [fm moveItemAtPath:path toPath:older error:nil];
        }
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0600);
        if (fd < 0) return;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        (void)write(fd, data.bytes, data.length);
        close(fd);
    });
}
__attribute__((unused)) static void PlaybackLogFlush(void) { dispatch_sync(PlaybackLogQueue(), ^{}); }

// Reports every change of a player's timeControlStatus on the main thread, whoever caused it.
static void *kPlayerWatchContext = &kPlayerWatchContext;
@interface GBPlayerWatch : NSObject
- (instancetype)initWithPlayer:(AVPlayer *)player handler:(void (^)(AVPlayer *player))handler;
- (void)invalidate;
@end
@implementation GBPlayerWatch {
    AVPlayer *_player;
    void (^_handler)(AVPlayer *);
    BOOL _observing;
}
- (instancetype)initWithPlayer:(AVPlayer *)player handler:(void (^)(AVPlayer *))handler {
    if ((self = [super init])) {
        _player = player;
        _handler = [handler copy];
        [player addObserver:self forKeyPath:@"timeControlStatus" options:0 context:kPlayerWatchContext];
        _observing = YES;
    }
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context != kPlayerWatchContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayer *player = _player;
    void (^handler)(AVPlayer *) = _handler;
    if (!player || !handler) return;
    if (NSThread.isMainThread) handler(player);
    else dispatch_async(dispatch_get_main_queue(), ^{ handler(player); });
}
- (void)invalidate {
    if (_observing) [_player removeObserver:self forKeyPath:@"timeControlStatus" context:kPlayerWatchContext];
    _observing = NO;
    _handler = nil;
    _player = nil;
}
- (void)dealloc { [self invalidate]; }
@end

static NSString *FmtEpochClock(double epoch) {   // "12:12:08", or "—" when unset
    if (epoch <= 0) return @"—";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}
static NSString *FmtEpochDayClock(double epoch) {   // "12/6 04:08", or "—" when unset
    if (epoch <= 0) return @"—";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"d/M HH:mm";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}

static NSString *FmtCompact(long long n) {
    double v = (double)llabs(n);
    NSString *sign = n < 0 ? @"-" : @"";
    // Tier thresholds sit at the rounding boundary so 999.6M prints 1.0B, not 1000.0M.
    if (v >= 999500000.0) return [NSString stringWithFormat:@"%@%.1fB", sign, v / 1000000000.0];
    if (v >= 999500.0) return [NSString stringWithFormat:@"%@%.1fM", sign, v / 1000000.0];
    if (v >= 1000.0) return [NSString stringWithFormat:@"%@%.0fK", sign, v / 1000.0];
    return [NSString stringWithFormat:@"%lld", n];
}

static NSString *FmtTokenCount(long long tokens) {
    return [NSString stringWithFormat:@"%@ tokens", FmtCompact(tokens)];
}

static NSDateFormatter *DateOnlyFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd";
    });
    return fmt;
}

static NSDate *StartOfLocalDay(NSDate *date) {
    return [NSCalendar.currentCalendar startOfDayForDate:date ?: NSDate.date];
}

static NSString *LocalDateString(NSDate *date) {
    return [DateOnlyFormatter() stringFromDate:date ?: NSDate.date];
}

static NSString *ShortDateText(NSString *yyyyMMdd) {
    NSDate *date = [DateOnlyFormatter() dateFromString:yyyyMMdd ?: @""];
    if (!date) return yyyyMMdd ?: @"unknown";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"MMM d";
    return [fmt stringFromDate:date];
}

static NSString *ClockText(NSDate *date) {
    if (!date) return @"unknown";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.timeStyle = NSDateFormatterShortStyle;
    fmt.dateStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:date];
}

// Bare formatted time — callers add their own "Reset"/"Reset:" framing.
static NSString *ResetTextFromDate(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *fmt = [NSDateFormatter new];
    BOOL today = [NSCalendar.currentCalendar isDate:date inSameDayAsDate:NSDate.date];
    fmt.dateStyle = today ? NSDateFormatterNoStyle : NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [fmt stringFromDate:date];
}

static NSString *AsOfTextFromEpoch(double epoch) {
    if (epoch <= 0) return nil;
    NSString *when = ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:epoch]);
    return when.length ? [@"as of " stringByAppendingString:when] : nil;
}

static NSDictionary *JSONDictionaryAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static long long SumNumbersInDictionary(NSDictionary *d) {
    long long total = 0;
    for (id v in d.allValues) if ([v isKindOfClass:NSNumber.class]) total += [v longLongValue];
    return total;
}

static NSArray<NSDictionary *> *ModelRowsFromTokenDictionary(NSDictionary *tokensByModel) {
    if (![tokensByModel isKindOfClass:NSDictionary.class]) return @[];
    NSArray *keys = [tokensByModel keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *model in keys) {
        NSNumber *tokens = tokensByModel[model];
        if (![tokens isKindOfClass:NSNumber.class] || tokens.longLongValue <= 0) continue;
        [rows addObject:@{@"name": model, @"tokens": tokens}];
    }
    return rows;
}

static NSString *ShortModelName(NSString *model) {
    if (!model.length) return @"unknown";
    NSString *s = model;
    for (NSString *prefix in @[@"claude-", @"openai/"]) {
        if ([s hasPrefix:prefix]) s = [s substringFromIndex:prefix.length];
    }
    return s;
}

static AIUsage *UnavailableAIUsage(NSString *name, NSString *source) {
    AIUsage *u = [AIUsage new];
    u.name = name;
    u.source = source;
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusText = @"Local state not found";
    u.statusReason = @"No limit status source";
    u.models = @[];
    return u;
}

static NSNumber *StatusNumberForKeys(NSDictionary *d, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = d[key];
        if ([v isKindOfClass:NSNumber.class]) return v;
        if ([v isKindOfClass:NSString.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:v];
            double n = 0;
            if ([scanner scanDouble:&n]) return @(n);
        }
    }
    return nil;
}

static NSString *StatusStringForKeys(NSDictionary *d, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = d[key];
        if ([v isKindOfClass:NSString.class] && [v length]) return v;
    }
    return nil;
}

static NSDate *DateFromStatusString(NSString *s) {
    if (!s.length) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSDate *date = [iso dateFromString:s];
    if (!date) {
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        date = [iso dateFromString:s];
    }
    if (date) return date;

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss ZZZZZ", @"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ"]) {
        fmt.dateFormat = format;
        date = [fmt dateFromString:s];
        if (date) return date;
    }
    return nil;
}

static NSDictionary *AIStatusEntry(NSDictionary *root, NSString *name) {
    if (![root isKindOfClass:NSDictionary.class] || !name.length) return nil;
    NSString *lower = name.lowercaseString;
    for (NSString *key in @[name, lower]) {
        id entry = root[key];
        if ([entry isKindOfClass:NSDictionary.class]) return entry;
    }
    NSDictionary *providers = [root[@"providers"] isKindOfClass:NSDictionary.class] ? root[@"providers"] : nil;
    if (providers) {
        for (NSString *key in @[name, lower]) {
            id entry = providers[key];
            if ([entry isKindOfClass:NSDictionary.class]) return entry;
        }
    }
    return nil;
}

static void ApplyAIStatusFile(AIUsage *u, NSDictionary *root, NSString *source) {
    NSDictionary *entry = AIStatusEntry(root, u.name);
    if (!entry) return;

    // Validate the override's window before changing any part of the provider snapshot.
    NSString *resetAt = StatusStringForKeys(entry, @[@"resetAt", @"resetTime", @"resetsAt"]);
    NSDate *resetDate = DateFromStatusString(resetAt);
    if (resetDate && resetDate.timeIntervalSinceNow <= 0) return;

    // Interpret by key, not magnitude: a "guess the unit" heuristic misreads 0.9%
    // remaining as 90% — exactly when the number matters most.
    NSNumber *fraction = StatusNumberForKeys(entry, @[@"remainingFraction", @"fractionRemaining"]);
    NSNumber *percent = StatusNumberForKeys(entry, @[@"remainingPercent", @"percentRemaining", @"percentageRemaining"]);
    double v = fraction ? fraction.doubleValue : (percent ? percent.doubleValue / 100.0 : -1);
    BOOL replacedGauge = v >= 0;
    if (replacedGauge) {
        u.remainingFraction = MIN(1.0, MAX(0.0, v));
        u.limitStatusAvailable = YES;
    }

    NSString *reset = StatusStringForKeys(entry, @[@"resetText", @"reset", @"resets"]);
    // A dated override is a statement about one window. Once that window has reset the
    // file is stale, and the provider's own figure is the truth again.
    if (resetDate) reset = ResetTextFromDate(resetDate);
    if (reset.length && (replacedGauge || (u.limitStatusAvailable && u.remainingFraction >= 0))) {
        u.resetText = reset;
        u.resetAt = resetDate;   // nil when the override gave free text — then the string is all we have
        replacedGauge = YES;
    }

    if (replacedGauge) {
        // A status-file entry is a true override, not a third opinion layered over the
        // provider. Clear provider-specific dual meters/overage so every surface agrees.
        u.limitWindows = @[];
        u.overageActive = NO;
        u.extraUsage = nil;
        u.limitStale = NO;
        u.limitUpdatedAt = nil;
    }

    NSString *reason = StatusStringForKeys(entry, @[@"status", @"detail", @"reason"]);
    u.statusSource = source;
    u.statusReason = reason.length ? reason : @"Limit status from local status file";
}

// Keep Cursor's pools in one provider instrument. Missing pools stay unreported.
static NSDictionary *CursorPoolQuotas(AIUsage *u) {
    if (![u.name isEqual:@"Cursor"] || !u.limitStatusAvailable) return nil;
    NSMutableDictionary *pools = [NSMutableDictionary dictionary];
    for (NSDictionary *window in u.limitWindows) {
        NSString *pool = window[@"pool"];
        if ([pool isEqual:@"api"] || [pool isEqual:@"cursor"]) pools[pool] = window;
    }
    return pools.count ? pools : nil;
}
static double CursorPoolFraction(NSDictionary *pools, NSString *key) {
    NSNumber *value = pools[key][@"remainingFraction"];
    return [value isKindOfClass:NSNumber.class] ? value.doubleValue : -1;
}
// Grok + Composer (Cursor's own models) is the reading that matters; the API pool is
// secondary and lives on the tooltip and the AI tab. Falls back to the API pool when
// only that one is reported.
static double CursorPrimaryFraction(NSDictionary *pools) {
    double grok = CursorPoolFraction(pools, @"cursor");
    return grok >= 0 ? grok : CursorPoolFraction(pools, @"api");
}
static NSDate *CursorPoolReset(NSDictionary *pools) {
    NSDate *reset = nil;
    for (NSDictionary *window in pools.allValues) {
        NSNumber *epoch = window[@"resetsAt"];
        if (![epoch isKindOfClass:NSNumber.class]) continue;
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch.doubleValue];
        if (!reset || [date compare:reset] == NSOrderedAscending) reset = date;
    }
    return reset;
}

static AIUsage *ReadClaudeUsage(NSString *homeDirectory) {
    NSString *home = homeDirectory.length ? homeDirectory : GBHomeDirectory();
    NSString *path = [home stringByAppendingPathComponent:@".claude/stats-cache.json"];
    NSDictionary *root = JSONDictionaryAtPath(path);
    if (!root) return UnavailableAIUsage(@"Claude", @"~/.claude/stats-cache.json");

    AIUsage *u = [AIUsage new];
    u.name = @"Claude";
    u.source = @"~/.claude/stats-cache.json";
    u.available = YES;
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusReason = @"Claude account access is off";

    NSDate *now = NSDate.date;
    NSDate *todayStart = StartOfLocalDay(now);
    // Calendar arithmetic, not 6*86400: a DST transition makes the fixed-seconds week
    // window silently drop its oldest day.
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay
                                                               value:-6 toDate:todayStart options:0] ?: todayStart;
    NSString *today = LocalDateString(now);
    NSString *lastComputed = [root[@"lastComputedDate"] isKindOfClass:NSString.class] ? root[@"lastComputedDate"] : nil;
    u.stale = lastComputed.length && ![lastComputed isEqualToString:today];
    u.statusText = !lastComputed.length ? @"Local stats (freshness unknown)"
                 : u.stale ? [NSString stringWithFormat:@"Stats through %@", ShortDateText(lastComputed)]
                 : @"Local stats current";

    NSDictionary *latestTokensByModel = nil, *displayTokens = nil;
    NSString *latestDate = nil;
    for (NSDictionary *row in ([root[@"dailyModelTokens"] isKindOfClass:NSArray.class] ? root[@"dailyModelTokens"] : @[])) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *dateString = [row[@"date"] isKindOfClass:NSString.class] ? row[@"date"] : nil;
        NSDictionary *tokensByModel = [row[@"tokensByModel"] isKindOfClass:NSDictionary.class] ? row[@"tokensByModel"] : nil;
        NSDate *date = [DateOnlyFormatter() dateFromString:dateString ?: @""];
        if (!date || !tokensByModel) continue;
        if ([date compare:weekStart] != NSOrderedAscending && [date compare:now] != NSOrderedDescending)
            u.weekTokens += SumNumbersInDictionary(tokensByModel);
        if ([dateString isEqualToString:today]) {
            u.todayTokens = SumNumbersInDictionary(tokensByModel);
            if (u.todayTokens > 0) displayTokens = tokensByModel;
        }
        if (!latestDate || [dateString compare:latestDate] == NSOrderedDescending) {
            latestDate = dateString;
            latestTokensByModel = tokensByModel;
        }
    }

    if (!displayTokens) displayTokens = latestTokensByModel;
    u.models = ModelRowsFromTokenDictionary(displayTokens);
    if (u.models.count) u.topModel = u.models.firstObject[@"name"];

    for (NSDictionary *row in ([root[@"dailyActivity"] isKindOfClass:NSArray.class] ? root[@"dailyActivity"] : @[])) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *dateString = [row[@"date"] isKindOfClass:NSString.class] ? row[@"date"] : nil;
        NSDate *date = [DateOnlyFormatter() dateFromString:dateString ?: @""];
        if (!date) continue;
        if ([dateString isEqualToString:today]) {
            u.todayMessages = [row[@"messageCount"] longLongValue];
            u.todaySessions = [row[@"sessionCount"] longLongValue];
            u.todayToolCalls = [row[@"toolCallCount"] longLongValue];
        }
        if ([date compare:weekStart] != NSOrderedAscending && [date compare:now] != NSOrderedDescending)
            u.weekSessions += [row[@"sessionCount"] longLongValue];
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (mtime) u.lastActivity = mtime;
    return u;
}

static NSArray<NSString *> *SQLiteFields(NSString *line) {
    if (!line.length) return @[];
    return [line componentsSeparatedByString:@"\t"];
}

static NSString *RunSQLite(NSString *path, NSString *sql) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return RunTaskOutput(@"/usr/bin/sqlite3", @[@"-readonly", @"-separator", @"\t", path, sql]);
}

// Claude Code's credential item authorizes Apple's `apple-tool:` partition. Glancebar
// therefore asks the Apple-signed /usr/bin/security tool to read it; Keychain evaluates
// that tool's signature rather than Glancebar's, so the read is normally silent. This is
// an undocumented trust-boundary behavior, disclosed in-app before the opt-in is stored.
//
// This leans on undocumented partition behavior, so it is bounded and watchdogged: a hard
// deadline kills the child if `security` ever blocks (for example after an ACL change),
// so we degrade quietly instead of hanging on a dialog. The returned blob is
// a live OAuth token — callers must never log it.
static NSString *KeychainBlobViaSecurity(NSString *service, NSString *account) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    t.arguments = @[@"find-generic-password", @"-w", @"-s", service, @"-a", account.length ? account : NSUserName()];
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
    if (![t launchAndReturnError:nil]) return nil;

    // `security` normally returns instantly; if it ever wedges, terminate at 5s and
    // force-kill at 6s. Without the kill, a child that ignores SIGTERM leaves the read
    // below blocked forever and wedges the serial AI queue with it.
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:t.processIdentifier seconds:5];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];   // unblocks on exit/terminate
    [t waitUntilExit];
    [watchdog disarm];
    if (t.terminationReason != NSTaskTerminationReasonExit || t.terminationStatus != 0 || data.length == 0 || data.length > 64 * 1024) return nil;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Opt-in only (the "Claude account for limit status" toggle): Claude Code keeps no
// quota state on disk — its /usage panel fetches from the API — so the only true gauge
// source is the same OAuth endpoint, authenticated with the token Claude Code already
// maintains in the Keychain. Returns nil when the toggle is off conceptually (callers
// gate), the item is missing, the read times out, or the value is not the expected JSON.
// Expiry is judged by the caller via ClaudeKeychainOutcome (never refresh the token
// ourselves — that could rotate the refresh token out from under Claude Code).
static NSDictionary *ClaudeAccessTokenFromKeychain(void) {
    NSString *blob = KeychainBlobViaSecurity(@"Claude Code-credentials", nil);
    if (!blob.length) return nil;
    NSData *data = [blob dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *oauth = [json[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    if (!oauth) return nil;
    NSString *token = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    double expiresAt = [oauth[@"expiresAt"] doubleValue] / 1000.0;   // ms epoch
    return @{@"token": token ?: @"", @"expiresAt": @(expiresAt)};    // expiry judged by the caller
}

// Authorization headers must never follow a provider-controlled redirect. A same-host
// HTTPS redirect is acceptable; every other destination is refused.
@interface GBPinnedHostSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property (copy) NSString *host;
@end
@implementation GBPinnedHostSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                         newRequest:(NSURLRequest *)request
                  completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *url = request.URL;
    BOOL sameTrustedHost = [url.scheme.lowercaseString isEqualToString:@"https"] &&
                           [url.host.lowercaseString isEqualToString:self.host];
    completionHandler(sameTrustedHost ? request : nil);
}
@end

static NSDictionary *FetchResult(NSData *data, NSHTTPURLResponse *http, NSError *err, NSString *fallbackMessage);
static NSDictionary *HTTPJSON(NSString *token, NSString *method, NSString *urlString, NSString *host,
                              NSDictionary *headers, NSData *body, NSString *timeoutMessage);

// One GET to Anthropic's OAuth usage endpoint — the same data Claude Code's /usage
// shows. Synchronous by design: callers run on the AI queue, never the main thread.
static NSDictionary *FetchClaudeUsageJSON(NSString *token) {
    return HTTPJSON(token, @"GET", @"https://api.anthropic.com/api/oauth/usage", @"api.anthropic.com",
                    @{@"anthropic-beta": @"oauth-2025-04-20"}, nil, @"Claude usage API request timed out");
}

// Opt-in only: Cursor stores the signed-in session JWT in its VS Code state DB (not the
// Keychain). Returns the access token string, or nil when the DB/item is missing.
static NSString *CursorStateDBPath(NSString *homeDirectory) {
    NSString *home = homeDirectory.length ? homeDirectory : GBHomeDirectory();
    return [home stringByAppendingPathComponent:
        @"Library/Application Support/Cursor/User/globalStorage/state.vscdb"];
}

// Cursor only surfaces when its local app data is present — no empty "Cursor" card for
// machines that never installed it.
static BOOL CursorServicePresent(NSString *homeDirectory) {
    return [NSFileManager.defaultManager fileExistsAtPath:CursorStateDBPath(homeDirectory)];
}

static NSString *CursorAccessTokenFromStateDB(NSString *homeDirectory) {
    NSString *path = CursorStateDBPath(homeDirectory);
    NSString *sql = @"SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;";
    NSString *raw = RunSQLite(path, sql);
    if (!raw.length) return nil;
    NSString *token = [[raw componentsSeparatedByString:@"\n"].firstObject
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return token.length ? token : nil;
}

// The Cursor CLI (`agent`) keeps its own session in the Keychain, written through
// /usr/bin/security, so the same Apple-tool read is silent. Someone who only uses the CLI
// never refreshes the desktop app's state.vscdb token, which then expires and 401s
// (2026-10-04); taking the freshest of the two keeps either kind of user signed in.
// Only the real home has a Keychain session: a fixture home must never see it.
static NSString *CursorSessionToken(NSString *homeDirectory, NSString *rejected) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSString *home = homeDirectory.length ? homeDirectory.stringByStandardizingPath : GBHomeDirectory();
    if ([home isEqualToString:GBHomeDirectory().stringByStandardizingPath]) {
        NSString *cli = KeychainBlobViaSecurity(@"cursor-access-token", @"cursor-user");
        if (cli.length && cli.length < 8192) [tokens addObject:cli];
    }
    NSString *app = CursorAccessTokenFromStateDB(homeDirectory);
    if (app.length) [tokens addObject:app];
    // A token the server just refused is passed over, so a shorter-lived live session in
    // the other client still gets its turn.
    if (rejected.length && tokens.count > 1) [tokens removeObject:rejected];
    // All expired: hand back one anyway so the caller can say "signed out" precisely.
    return FreshestSessionToken(tokens, NSDate.date.timeIntervalSince1970, NULL) ?: tokens.firstObject;
}

static NSDictionary *FetchResult(NSData *data, NSHTTPURLResponse *http, NSError *err,
                                 NSString *fallbackMessage) {
    NSInteger statusCode = http.statusCode;
    NSTimeInterval retryAfter = [http.allHeaderFields[@"Retry-After"] doubleValue];
    if (!err && statusCode == 200 && data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) return obj;
    }
    NSString *errorMessage = nil;
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *dict = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        NSDictionary *error = [dict[@"error"] isKindOfClass:NSDictionary.class] ? dict[@"error"] : nil;
        NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
        if (message.length) errorMessage = message;
        else if ([dict[@"message"] isKindOfClass:NSString.class]) errorMessage = dict[@"message"];
    }
    if (!errorMessage.length && err.localizedDescription.length) errorMessage = err.localizedDescription;
    if (!errorMessage.length) {
        errorMessage = statusCode > 0 ? [NSHTTPURLResponse localizedStringForStatusCode:statusCode]
                                      : fallbackMessage;
    }
    return @{@"_glancebarFetchError": @YES,
             @"statusCode": @(statusCode),
             @"rateLimited": @(statusCode == 429),
             @"retryAfter": @(retryAfter),
             @"message": errorMessage};
}

// One bounded JSON request with a bearer token, pinned to `host` across redirects.
// Synchronous by design: callers run on the AI queue, never the main thread.
static NSDictionary *HTTPJSON(NSString *token, NSString *method, NSString *urlString, NSString *host,
                              NSDictionary *headers, NSData *body, NSString *timeoutMessage) {
    if (GBLowDataEnabled()) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = method;
    req.timeoutInterval = 10;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPBody = body;
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    for (NSString *key in headers) [req setValue:headers[key] forHTTPHeaderField:key];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil;
    cfg.HTTPCookieStorage = nil;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPShouldSetCookies = NO;
    GBPinnedHostSessionDelegate *delegate = [GBPinnedHostSessionDelegate new];
    delegate.host = host;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block BOOL completed = NO;
    [[session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)resp : nil;
            json = FetchResult(data, http, err, timeoutMessage);
            completed = YES;
            [session finishTasksAndInvalidate];
            dispatch_semaphore_signal(done);
        }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (!completed) [session invalidateAndCancel];
    if (!json) {
        return @{@"_glancebarFetchError": @YES,
                 @"statusCode": @0,
                 @"rateLimited": @NO,
                 @"retryAfter": @0,
                 @"message": timeoutMessage};
    }
    return json;
}

// Prefer GetCurrentPeriodUsage (Pro/Team included spend). Fall back to legacy /auth/usage
// request buckets when the dashboard response has no usable planUsage window.
static NSDictionary *FetchCursorUsageJSON(NSString *token) {
    double now = NSDate.date.timeIntervalSince1970;
    NSData *emptyBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *period = HTTPJSON(
        token, @"POST",
        @"https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage", @"api2.cursor.sh",
        @{@"Content-Type": @"application/json", @"Connect-Protocol-Version": @"1"},
        emptyBody, @"Cursor usage API request timed out");
    if (![period[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(period, now))
        return period;
    // A rejected token is rejected everywhere; a second request only doubles the noise.
    if (ShouldDropCachedTokenForStatus([period[@"statusCode"] integerValue])) return period;
    // An ended billing cycle is still the plan's answer; legacy request buckets would
    // pass it off as leftover quota.
    if (![period[@"_glancebarFetchError"] boolValue] && CursorStaleLimitWindows(period, now).count) return period;

    NSDictionary *auth = HTTPJSON(token, @"GET", @"https://api2.cursor.sh/auth/usage", @"api2.cursor.sh",
                                  nil, nil, @"Cursor usage API request timed out");
    if (![auth[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(auth, now))
        return auth;
    // A 401 from either call means sign in again, whatever the other one said.
    if (ShouldDropCachedTokenForStatus([auth[@"statusCode"] integerValue])) return auth;
    // Keep a successful-but-empty period body over a transport error so diagnostics stay useful.
    if (![period[@"_glancebarFetchError"] boolValue]) return period;
    if (![auth[@"_glancebarFetchError"] boolValue]) return auth;
    return period;
}

static NSDate *FileMTime(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

// Ask the installed signed-in CLI through its public app-server protocol. No token
// handling, generated turns, or foreground app activation. Bound the child lifetime.
static NSDictionary *FetchCodexAccountJSON(void) {
    if (GBLowDataEnabled()) return nil;
    NSArray *paths = @[@"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                       @"/Applications/Codex.app/Contents/Resources/codex", @"/opt/homebrew/bin/codex", @"/usr/local/bin/codex"];
    NSString *path = nil;
    for (NSString *candidate in paths)
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { path = candidate; break; }
    if (!path) return nil;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = @[@"app-server", @"--stdio"];
    NSPipe *input = NSPipe.pipe, *output = NSPipe.pipe;
    task.standardInput = input; task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:15];
    __block NSDictionary *result = nil;
    void (^send)(NSDictionary *) = ^(NSDictionary *message) {
        NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
        [data appendBytes:"\n" length:1];
        [input.fileHandleForWriting writeData:data];
    };
    @try {
        send(@{@"id": @1, @"method": @"initialize", @"params": @{@"clientInfo": @{@"name": @"glancebar", @"version": @"1.1.0"}}});
        NSMutableData *pending = NSMutableData.data;
        BOOL finished = NO;
        while (!finished) {
            NSData *chunk = output.fileHandleForReading.availableData;
            if (!chunk.length || pending.length + chunk.length > 1024 * 1024) break;
            [pending appendData:chunk];
            NSRange newline;
            while ((newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0,pending.length)]).location != NSNotFound) {
                NSData *line = [pending subdataWithRange:NSMakeRange(0,newline.location)];
                [pending replaceBytesInRange:NSMakeRange(0,newline.location+1) withBytes:NULL length:0];
                id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if (![message isKindOfClass:NSDictionary.class]) continue;
                if ([message[@"id"] isEqual:@1]) {
                    if (message[@"error"]) { finished = YES; break; }
                    send(@{@"method": @"initialized"});
                    send(@{@"id": @2, @"method": @"account/rateLimits/read", @"params": NSNull.null});
                } else if ([message[@"id"] isEqual:@2]) {
                    if ([message[@"result"] isKindOfClass:NSDictionary.class]) result = message[@"result"];
                    finished = YES; break;
                }
            }
        }
    } @catch (NSException *exception) { (void)exception; }
    @finally {
        [input.fileHandleForWriting closeFile];
        if (task.running) [task terminate];
        [task waitUntilExit];
        [watchdog disarm];
        [output.fileHandleForReading closeFile];
    }
    return result;
}

// Convert the public camelCase API to the existing independently dated buckets.
static NSDictionary *CodexAccountBuckets(NSDictionary *response, NSString *stamp) {
    if (![response isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *all = [response[@"rateLimitsByLimitId"] isKindOfClass:NSDictionary.class] ? response[@"rateLimitsByLimitId"] : nil;
    if (!all.count && [response[@"rateLimits"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *single = response[@"rateLimits"];
        NSString *key = [single[@"limitId"] isKindOfClass:NSString.class] ? single[@"limitId"] : @"codex";
        all = @{key: single};
    }
    NSDictionary *buckets = nil;
    for (NSString *key in all) {
        NSDictionary *snapshot = all[key];
        if (![snapshot isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *limits = [@{@"limit_id": key} mutableCopy];
        if ([snapshot[@"planType"] isKindOfClass:NSString.class]) limits[@"plan_type"] = snapshot[@"planType"];
        for (NSString *window in @[@"primary", @"secondary"]) {
            NSDictionary *w = snapshot[window];
            if (![w isKindOfClass:NSDictionary.class] || ![w[@"usedPercent"] isKindOfClass:NSNumber.class]) continue;
            NSMutableDictionary *mapped = [@{@"used_percent": w[@"usedPercent"]} mutableCopy];
            if ([w[@"windowDurationMins"] isKindOfClass:NSNumber.class]) mapped[@"window_minutes"] = w[@"windowDurationMins"];
            if ([w[@"resetsAt"] isKindOfClass:NSNumber.class]) mapped[@"resets_at"] = w[@"resetsAt"];
            limits[window] = mapped;
        }
        if (!limits[@"primary"] && !limits[@"secondary"]) continue;
        NSDictionary *credits = snapshot[@"credits"];
        if ([credits isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *mapped = NSMutableDictionary.dictionary;
            for (NSString *field in @[@"hasCredits", @"unlimited", @"balance"])
                if (credits[field] && credits[field] != NSNull.null)
                    mapped[[field isEqual:@"hasCredits"] ? @"has_credits" : field] = credits[field];
            limits[@"credits"] = mapped;
        }
        buckets = FoldCodexSnapshotIntoBuckets(buckets, limits, stamp);
    }
    return buckets;
}

// Reads AI usage state. Codex tokens come from the per-turn token_count events in the
// session rollout JSONLs — the only accurate per-day source (the sqlite tokens_used
// column is a lifetime counter, so windowing it attributes a resumed thread's whole
// history to "today"). Rollouts are append-only; per-file byte offsets make the steady
// state a handful of stats per tick. Stateful and not reentrant: call from one serial
// queue only (the --dump path makes its own throwaway instance).
// A single log line longer than this is abandoned rather than buffered. Distinct from the
// per-pass byte budget, which bounds work but must never abandon a line.
static const NSUInteger kAIMaxLineBytes = 4 * 1024 * 1024;

@interface AIReader : NSObject
@property BOOL allowCodexAccountFetch;
@property (copy) NSDictionary *(^codexUsageFetcher)(void);
@property BOOL useClaudeAccount;
@property BOOL allowClaudeAccountFetch;
@property BOOL allowClaudeTranscripts;
@property BOOL useCursorAccount;
@property BOOL allowCursorAccountFetch;
// A bounded pass intentionally leaves large histories unfinished. UI callers can
// immediately schedule another pass while needsImmediateRescan is true; diagnostics
// can drive catch-up without waiting for the normal 15-second refresh.
@property (readonly) BOOL needsImmediateRescan;
@property (readonly) BOOL totalsIncomplete;
@property (readonly) double catchUpProgress;
@property (readonly, copy) NSString *catchUpStatus;
// Seams for the parts that touch the Keychain, Cursor's state DB and the network,
// so the whole account path can run in a test without any of them. Defaults are the
// real readers/fetchers; replace them before the first read.
@property (copy) NSDictionary *(^claudeCredentialReader)(void);          // @{token, expiresAt} or nil
@property (copy) NSDictionary *(^claudeUsageFetcher)(NSString *token);
@property (copy) NSString *(^cursorTokenReader)(NSString *homeDirectory);
@property (copy) NSString *cursorRejectedToken;   // last token a Cursor endpoint refused
@property (copy) NSDictionary *(^cursorUsageFetcher)(NSString *token);
- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory;
- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory
           applicationSupportDirectory:(NSString *)applicationSupportDirectory;
- (NSArray<AIUsage *> *)read;
- (NSArray<AIUsage *> *)readUntilCaughtUpWithTimeLimit:(NSTimeInterval)timeLimit;
// Drops the cached credential immediately. read/claudeUsage also clears it when the
// account is off, but no read runs while every AI surface is hidden, so withdrawing
// consent from the menu must not wait for one. Call on _aiQueue.
- (void)forgetClaudeAccountCredentials;
- (void)forgetCursorAccountCredentials;
- (void)purgeClaudeTranscriptIndex;
// Writes out any state a catch-up pass left coalesced. Call on _aiQueue before quitting.
- (void)flushPersistentState;
@end

@implementation AIReader {
    NSDictionary *_codexAccountBuckets;
    double _codexNextFetch;
    NSString *_codexAccountError;
    NSString *_homeDirectory;
    NSString *_applicationSupportDirectory;
    NSString *_statePath;
    // Contributions live with their source file so truncation/replacement can remove
    // precisely the stale totals before the replacement is indexed.
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_codexFiles;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_claudeFiles;
    NSArray<NSDictionary *> *_codexInventory;
    NSArray<NSDictionary *> *_claudeInventory;
    double _codexInventoryValidUntil, _claudeInventoryValidUntil;
    NSMutableDictionary<NSString *, NSDictionary *> *_days;  // local "yyyy-MM-dd" -> @{@"t":, @"f":, ...}
    // Best known meters per limit_id — see FoldCodexSnapshotIntoBuckets. Buckets are
    // compared, never blended: on 2026-09-07 a blend read "100% left" off an untouched
    // side bucket while the plan bucket sat at 99% used.
    NSDictionary *_buckets;
    NSString *_limitsTs;            // newest snapshot's timestamp across buckets
    // The newest snapshot verbatim. A bucket is a deliberate merge of its best-known
    // meters, so asking IT whether Codex still speaks a shape we understand answers the
    // wrong question: one carried-forward window makes any merge look readable.
    NSDictionary *_limitsNewest;
    NSDate *_dbStamp;               // change detection for the sqlite extras
    NSString *_dbDay;
    long long _sessionsToday, _sessionsWeek;
    NSArray<NSDictionary *> *_models;
    NSDate *_lastActivity;
    NSMutableDictionary<NSString *, NSDictionary *> *_claudeDays;
    // Derived from the transcript index, not the stats cache (which Claude Code stopped
    // writing in June 2026): 7-day fresh tokens per model, sessions, messages, tool calls.
    NSArray<NSDictionary *> *_claudeModels;
    long long _claudeSessionsToday, _claudeSessionsWeek, _claudeMessagesToday, _claudeToolsToday;
    NSDate *_claudeLastActivity;
    NSDictionary *_claudeUsageJSON;             // last good OAuth usage response
    double _claudeNextFetch;                    // epoch; throttles the usage endpoint
    NSUInteger _claudeRateLimitStreak;          // consecutive 429s; drives the blind backoff
    NSUInteger _cursorRateLimitStreak;
    NSString *_claudeAccessToken;               // memory-only; never persisted by Glancebar
    double _claudeAccessTokenExpiresAt;
    double _claudeKeychainNextTry;
    NSString *_claudeAccountStatus;
    double _claudeLastSuccessAt;
    BOOL _claudeFetchedThisRun;                 // NO after disk restore until a live fetch succeeds
    BOOL _claudeUsageCacheAbandoned;            // YES after explicit forget; allows omitting on save
    NSDictionary *_cursorUsageJSON;             // last good Cursor usage response
    double _cursorNextFetch;
    NSString *_cursorAccessToken;               // memory-only; never persisted by Glancebar
    double _cursorStateNextTry;
    NSString *_cursorAccountStatus;
    double _cursorLastSuccessAt;
    BOOL _cursorFetchedThisRun;
    BOOL _cursorUsageCacheAbandoned;
    NSString *_claudeFetchSkipReason, *_cursorFetchSkipReason;
    BOOL _claudeStatuslineLogged;
    NSMutableDictionary<NSString *, NSString *> *_lastStatusReasons;
    NSUInteger _scanBytesRemaining;
    double _scanDeadline;
    unsigned long long _codexTotalBytes, _codexDoneBytes;
    unsigned long long _claudeTotalBytes, _claudeDoneBytes;
    BOOL _codexTotalsIncomplete, _claudeTotalsIncomplete;
    BOOL _codexBlocked, _claudeBlocked;
    BOOL _needsImmediateRescan;
    BOOL _stateDirty;
    // Set when the pending change REMOVES something (a consent withdrawal purging the
    // transcript index). Scan progress may wait for the next pass; a purge may not, because
    // there may be no next pass — hiding every AI surface stops read() entirely.
    BOOL _stateMustPersist;
    double _lastStateWrite;
    NSUInteger _stateWrites;   // diagnostic: how many times the state file was rewritten
    NSDate *_stateFileSeen;    // mtime of the state file as last read or written by us
}

- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory {
    NSString *home = (homeDirectory.length ? homeDirectory : NSHomeDirectory()).stringByStandardizingPath;
    NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/Glancebar"];
    return [self initWithHomeDirectory:home applicationSupportDirectory:support];
}

- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory
           applicationSupportDirectory:(NSString *)applicationSupportDirectory {
    if ((self = [super init])) {
        _homeDirectory = (homeDirectory.length ? homeDirectory : NSHomeDirectory()).stringByStandardizingPath;
        _applicationSupportDirectory = (applicationSupportDirectory.length
            ? applicationSupportDirectory
            : [_homeDirectory stringByAppendingPathComponent:@"Library/Application Support/Glancebar"])
            .stringByStandardizingPath;
        _statePath = [_applicationSupportDirectory stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
        _codexFiles = [NSMutableDictionary dictionary];
        _claudeFiles = [NSMutableDictionary dictionary];
        _days = [NSMutableDictionary dictionary];
        _claudeDays = [NSMutableDictionary dictionary];
        _lastStatusReasons = [NSMutableDictionary dictionary];
        _codexUsageFetcher = ^NSDictionary *{ return FetchCodexAccountJSON(); };
        _claudeCredentialReader = ^NSDictionary *{ return ClaudeAccessTokenFromKeychain(); };
        _claudeUsageFetcher = ^NSDictionary *(NSString *token){ return FetchClaudeUsageJSON(token); };
        __weak AIReader *weakSelf = self;
        _cursorTokenReader = ^NSString *(NSString *home){ return CursorSessionToken(home, weakSelf.cursorRejectedToken); };
        _cursorUsageFetcher = ^NSDictionary *(NSString *token){ return FetchCursorUsageJSON(token); };
        [self loadPersistentState];
    }
    return self;
}

// The GUI and `--dump --online` share one state file, and each process holds its own
// copy of the account responses. Whenever the file has changed under us, adopt any
// FRESHER account response it carries instead of overwriting it with our older one on
// the next save — the CLI's fetch then shows in the running app within a tick.
- (void)adoptNewerAccountCachesFromDisk {
    NSDate *mtime = FileMTime(_statePath);
    if (!mtime || (_stateFileSeen && [mtime compare:_stateFileSeen] != NSOrderedDescending)) return;
    _stateFileSeen = mtime;
    NSDictionary *root = JSONDictionaryAtPath(_statePath);
    if ([root[@"version"] integerValue] != 2) return;
    _codexAccountBuckets = MergeCodexLimitBuckets(_codexAccountBuckets, root[@"codexAccountBuckets"]);
    NSDictionary *claude = [root[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class] ? root[@"claudeUsageJSON"] : nil;
    NSDate *claudeAt = DateFromStatusString([root[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class] ? root[@"claudeUsageFetchedAt"] : nil);
    if (self.useClaudeAccount && claude && claudeAt && claudeAt.timeIntervalSince1970 > _claudeLastSuccessAt + 1) {
        _claudeUsageJSON = claude;
        _claudeLastSuccessAt = claudeAt.timeIntervalSince1970;
        _claudeNextFetch = MAX(_claudeNextFetch, _claudeLastSuccessAt + kAccountPollInterval);
        _claudeAccountStatus = nil;
        _claudeUsageCacheAbandoned = NO;
        GBLog("claude cache: adopted a newer on-disk response");
    }
    NSDictionary *cursor = [root[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class] ? root[@"cursorUsageJSON"] : nil;
    NSDate *cursorAt = DateFromStatusString([root[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class] ? root[@"cursorUsageFetchedAt"] : nil);
    if (self.useCursorAccount && cursor && cursorAt && cursorAt.timeIntervalSince1970 > _cursorLastSuccessAt + 1) {
        _cursorUsageJSON = cursor;
        _cursorLastSuccessAt = cursorAt.timeIntervalSince1970;
        _cursorNextFetch = MAX(_cursorNextFetch, _cursorLastSuccessAt + kAccountPollInterval);
        _cursorAccountStatus = nil;
        _cursorUsageCacheAbandoned = NO;
        GBLog("cursor cache: adopted a newer on-disk response");
    }
}

- (void)loadPersistentState {
    _stateFileSeen = FileMTime(_statePath);
    NSData *data = [NSData dataWithContentsOfFile:_statePath options:0 error:nil];
    NSDictionary *root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class] || [root[@"version"] integerValue] != 2) return;
    NSString *timeZone = [root[@"timeZone"] isKindOfClass:NSString.class] ? root[@"timeZone"] : nil;
    // Day totals were bucketed in the zone the index was built in. Rebuilding them for a
    // new zone means re-reading the corpus (15 GB of Codex rollouts in the 8-day window),
    // which is far worse than day boundaries a few hours off for a week of travel. Keep
    // the index; new events bucket in the current zone and the old days age out.
    if (timeZone.length && ![timeZone isEqualToString:NSTimeZone.localTimeZone.name])
        GBLog("state: time zone changed since the index was built; keeping it");
    NSDictionary *codex = [root[@"codexFiles"] isKindOfClass:NSDictionary.class] ? root[@"codexFiles"] : nil;
    NSDictionary *claude = [root[@"claudeFiles"] isKindOfClass:NSDictionary.class] ? root[@"claudeFiles"] : nil;
    for (NSString *key in codex) {
        NSDictionary *record = [codex[key] isKindOfClass:NSDictionary.class] ? codex[key] : nil;
        if (key.length && record) _codexFiles[key] = [record mutableCopy];
    }
    for (NSString *key in claude) {
        NSDictionary *record = [claude[key] isKindOfClass:NSDictionary.class] ? claude[key] : nil;
        if (key.length && record) _claudeFiles[key] = [self upgradedClaudeRecord:[record mutableCopy]];
    }
    // Records written before limit buckets existed carry `latestLimits`, a blend across
    // every limit_id the file saw, filed under whichever id reported last. Re-reading
    // 15 GB of rollouts is not an option; instead the blend is ignored and the newest
    // files are re-peeked (tailSize cleared) so the current picture returns at once.
    for (NSMutableDictionary *record in _codexFiles.allValues) {
        if (record[@"latestLimits"] || record[@"peekLimits"]) {
            [record removeObjectForKey:@"latestLimits"];
            [record removeObjectForKey:@"latestTs"];
            [record removeObjectForKey:@"peekLimits"];
            [record removeObjectForKey:@"peekTs"];
            [record removeObjectForKey:@"tailSize"];
            _stateDirty = YES;
        }
    }
    NSDictionary *buckets = [root[@"codexBuckets"] isKindOfClass:NSDictionary.class] ? root[@"codexBuckets"] : nil;
    if (buckets.count) {
        _buckets = buckets;
        _limitsTs = BucketsNewestTs(buckets);
        _limitsNewest = CodexNewestBucketLimits(buckets);
    }
    _codexAccountBuckets = [root[@"codexAccountBuckets"] isKindOfClass:NSDictionary.class] ? root[@"codexAccountBuckets"] : nil;
    NSDictionary *claudeUsage = [root[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class]
        ? root[@"claudeUsageJSON"] : nil;
    if (claudeUsage) {
        _claudeUsageJSON = claudeUsage;
        NSString *fetched = [root[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class]
            ? root[@"claudeUsageFetchedAt"] : nil;
        NSDate *when = DateFromStatusString(fetched);
        if (when) _claudeLastSuccessAt = when.timeIntervalSince1970;
        // The throttle survives restarts and --dump runs: a figure younger than the poll
        // interval is as current as a fresh fetch would make it, and the endpoint rate-limits.
        if (when) _claudeNextFetch = _claudeLastSuccessAt + kAccountPollInterval;
        _claudeFetchedThisRun = NO;
        _claudeUsageCacheAbandoned = NO;
    }
    NSDictionary *cursorUsage = [root[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class]
        ? root[@"cursorUsageJSON"] : nil;
    if (cursorUsage) {
        _cursorUsageJSON = cursorUsage;
        NSString *fetched = [root[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class]
            ? root[@"cursorUsageFetchedAt"] : nil;
        NSDate *when = DateFromStatusString(fetched);
        if (when) _cursorLastSuccessAt = when.timeIntervalSince1970;
        if (when) _cursorNextFetch = _cursorLastSuccessAt + kAccountPollInterval;
        _cursorFetchedThisRun = NO;
        _cursorUsageCacheAbandoned = NO;
    }
}

static NSString *BucketsNewestTs(NSDictionary *buckets) {
    NSString *newest = CodexNewestBucketID(buckets);
    NSDictionary *entry = newest ? buckets[newest] : nil;
    return [entry[@"ts"] isKindOfClass:NSString.class] ? entry[@"ts"] : nil;
}

// A transcript record indexed before per-model/activity counters existed knows only
// day totals. The 8-day window it can still contribute to is re-read from offset 0 (a
// few hundred MB at most, reported as "Indexing transcripts N%"); identity is kept so
// the file is not mistaken for a new one.
static const NSInteger kClaudeRecordSchema = 2;
- (NSMutableDictionary *)upgradedClaudeRecord:(NSMutableDictionary *)record {
    if ([record[@"v"] integerValue] >= kClaudeRecordSchema) return record;
    NSMutableDictionary *fresh = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
    if (record[@"dev"]) fresh[@"dev"] = record[@"dev"];
    if (record[@"ino"]) fresh[@"ino"] = record[@"ino"];
    fresh[@"v"] = @(kClaudeRecordSchema);
    _stateDirty = YES;
    return fresh;
}

// Indexing a large backlog drives read() in a tight catch-up loop, and each pass rewrote the
// whole (growing) state file. Coalesce those writes: during catch-up a lost write only costs
// a re-read of the last couple of seconds' bytes, since offsets and totals move together.
// The pass that finishes the backlog always writes, so a settled index is never stale.
static const double kAIStateWriteInterval = 2.0;

- (void)savePersistentStateCoalesced {
    [self savePersistentStateForcingWrite:NO];
}

- (void)savePersistentStateForcingWrite:(BOOL)force {
    if (!_stateDirty) return;
    if (_stateMustPersist) force = YES;
    double now = CFAbsoluteTimeGetCurrent();
    if (!force && _lastStateWrite > 0 && now - _lastStateWrite < kAIStateWriteInterval) return;
    NSDictionary *existingRoot = nil;
    {
        NSData *existingData = [NSData dataWithContentsOfFile:_statePath options:0 error:nil];
        id obj = existingData.length ? [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class]) existingRoot = obj;
    }
    NSMutableDictionary *root = [@{
        @"version": @2,
        @"timeZone": NSTimeZone.localTimeZone.name ?: @"",
        @"codexFiles": _codexFiles,
        @"claudeFiles": _claudeFiles
    } mutableCopy];
    if (_buckets.count) root[@"codexBuckets"] = _buckets;
    NSDictionary *accountBuckets = MergeCodexLimitBuckets(_codexAccountBuckets, existingRoot[@"codexAccountBuckets"]);
    if (accountBuckets.count) root[@"codexAccountBuckets"] = accountBuckets;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    if ([_claudeUsageJSON isKindOfClass:NSDictionary.class]) {
        root[@"claudeUsageJSON"] = _claudeUsageJSON;
        if (_claudeLastSuccessAt > 0)
            root[@"claudeUsageFetchedAt"] = [iso stringFromDate:
                [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt]];
    } else if (!_claudeUsageCacheAbandoned) {
        // Another process (or this one, before a successful fetch) may have the last-known
        // account snapshot on disk. Omitting the keys here would wipe it.
        if ([existingRoot[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class])
            root[@"claudeUsageJSON"] = existingRoot[@"claudeUsageJSON"];
        if ([existingRoot[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class])
            root[@"claudeUsageFetchedAt"] = existingRoot[@"claudeUsageFetchedAt"];
    }
    if ([_cursorUsageJSON isKindOfClass:NSDictionary.class]) {
        root[@"cursorUsageJSON"] = _cursorUsageJSON;
        if (_cursorLastSuccessAt > 0)
            root[@"cursorUsageFetchedAt"] = [iso stringFromDate:
                [NSDate dateWithTimeIntervalSince1970:_cursorLastSuccessAt]];
    } else if (!_cursorUsageCacheAbandoned) {
        if ([existingRoot[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class])
            root[@"cursorUsageJSON"] = existingRoot[@"cursorUsageJSON"];
        if ([existingRoot[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class])
            root[@"cursorUsageFetchedAt"] = existingRoot[@"cursorUsageFetchedAt"];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!data || err) { GBLog("AI state encode failed"); return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:_applicationSupportDirectory withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0700} error:&err]) {
        GBLog("AI state directory unavailable");
        return;
    }
    if (![data writeToFile:_statePath options:NSDataWritingAtomic error:&err]) {
        GBLog("AI state write failed");
        return;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_statePath error:nil];
    _stateFileSeen = FileMTime(_statePath);
    _stateDirty = NO;
    _stateMustPersist = NO;
    _lastStateWrite = now;
    _stateWrites++;
}

- (void)flushPersistentState { [self savePersistentStateForcingWrite:YES]; }

- (NSUInteger)stateWriteCount { return _stateWrites; }

static NSString *FNVHashBytes(const void *rawBytes, NSUInteger length) {
    const unsigned char *bytes = rawBytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger i = 0; i < length; i++) { hash ^= bytes[i]; hash *= UINT64_C(1099511628211); }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

static void StoreOffsetAnchor(NSMutableDictionary *record, NSData *data,
                              unsigned long long newOffset, NSUInteger consumed) {
    NSUInteger length = MIN((NSUInteger)64, consumed);
    if (!length) { [record removeObjectForKey:@"anchor"]; return; }
    NSRange range = NSMakeRange(consumed - length, length);
    record[@"anchor"] = FNVHashBytes((const char *)data.bytes + range.location, range.length);
    record[@"anchorOffset"] = @(newOffset);
    record[@"anchorLength"] = @(length);
}

// Reads complete appended lines within the caller's GLOBAL pass budget. A partial
// trailing line stays at the old offset and is retried only after the file grows.
//
// The two caps are not interchangeable. `lineCap` is a hard per-line ceiling: a line
// longer than it is abandoned so a pathological row cannot wedge the scan. `maxBytes` is
// the soft remaining pass budget, and a read it truncates says nothing about the line —
// the newline may sit one byte past it. Conflating them consumes an ordinary line
// whenever the budget happens to run out inside one, losing its tokens permanently.
- (NSData *)newLineDataAtPath:(NSString *)path
                       record:(NSMutableDictionary *)record
                     maxBytes:(NSUInteger)maxBytes
                      lineCap:(NSUInteger)lineCap
                    bytesRead:(NSUInteger *)bytesRead
                   readFailed:(BOOL *)readFailed {
    if (bytesRead) *bytesRead = 0;
    if (readFailed) *readFailed = NO;
    unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (readFailed) *readFailed = YES; return nil; }
    // These files belong to other tools and can be rotated/truncated mid-read; use the
    // error-returning APIs so an I/O failure skips the sample instead of raising.
    unsigned long long size = 0;
    NSError *err = nil;
    if (![fh seekToEndReturningOffset:&size error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    unsigned long long priorSize = [record[@"size"] unsignedLongLongValue];
    if (offset > size || (priorSize > 0 && size < priorSize)) {
        // Truncation after inventory refresh: throw away this file's old contribution,
        // not merely its offset, or the replacement would be counted on top of it.
        NSNumber *dev = record[@"dev"], *ino = record[@"ino"];
        [record removeAllObjects];
        if (dev) record[@"dev"] = dev;
        if (ino) record[@"ino"] = ino;
        record[@"offset"] = @0;
        record[@"size"] = @(size);
        record[@"inventoryMismatch"] = @YES;
        _codexInventoryValidUntil = 0;
        _claudeInventoryValidUntil = 0;
        offset = 0;
        _stateDirty = YES;
    }
    if (!record[@"size"]) record[@"size"] = @(size);
    NSString *anchor = [record[@"anchor"] isKindOfClass:NSString.class] ? record[@"anchor"] : nil;
    NSUInteger anchorLength = [record[@"anchorLength"] unsignedIntegerValue];
    if (offset > 0 && anchor.length && anchorLength > 0 && anchorLength <= offset &&
        [record[@"anchorOffset"] unsignedLongLongValue] == offset) {
        if (![fh seekToOffset:offset - anchorLength error:&err]) {
            [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
        }
        NSData *anchorData = [fh readDataUpToLength:anchorLength error:&err];
        if (err || anchorData.length != anchorLength) {
            [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
        }
        if (![FNVHashBytes(anchorData.bytes, anchorData.length) isEqualToString:anchor]) {
            // Same inode and a regrown size can otherwise conceal truncate-and-rewrite.
            NSNumber *dev = record[@"dev"], *ino = record[@"ino"];
            [record removeAllObjects];
            if (dev) record[@"dev"] = dev;
            if (ino) record[@"ino"] = ino;
            record[@"offset"] = @0;
            record[@"size"] = @(size);
            offset = 0;
            _stateDirty = YES;
        }
    }
    if (offset >= size || maxBytes == 0) { [fh closeAndReturnError:nil]; return nil; }
    if (![fh seekToOffset:offset error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSUInteger readCap = lineCap > 0 ? MIN(maxBytes, lineCap) : maxBytes;
    // True when the pass budget — not the line cap — is what ends this read short of EOF.
    BOOL budgetTruncated = lineCap > 0 && maxBytes < lineCap &&
                           (unsigned long long)maxBytes < size - offset;
    NSUInteger wanted = (NSUInteger)MIN((unsigned long long)readCap, size - offset);
    NSData *data = [fh readDataUpToLength:wanted error:&err];
    [fh closeAndReturnError:nil];
    if (bytesRead) *bytesRead = data.length;
    if (err) { if (readFailed) *readFailed = YES; return nil; }
    if (!data.length) return nil;
    const char *bytes = data.bytes;
    NSUInteger consume = 0;
    for (NSUInteger i = data.length; i > 0; i--) {
        if (bytes[i - 1] == '\n') { consume = i; break; }
    }
    BOOL reachedEOF = offset + data.length >= size;
    if (!consume && !reachedEOF && budgetTruncated) {
        // The budget, not the line cap, stopped this read, so the line is probably ordinary
        // and its newline sits just past the cut. Leave the offset where it is and re-read
        // the line whole on the next pass. The budget is still charged with the bytes read,
        // so the current pass still terminates.
        return nil;
    }
    if (!consume && !reachedEOF) {
        // Token-count lines are small. Skipping an overlong non-matching line bounds
        // memory and guarantees forward progress through pathological transcript rows.
        unsigned long long newOffset = offset + data.length;
        record[@"offset"] = @(newOffset);
        StoreOffsetAnchor(record, data, newOffset, data.length);
        [record removeObjectForKey:@"partialSize"];
        _stateDirty = YES;
        return nil;
    }
    if (!consume) {
        record[@"partialSize"] = @(size);
        _stateDirty = YES;
        return nil;
    }
    unsigned long long newOffset = offset + consume;
    record[@"offset"] = @(newOffset);
    StoreOffsetAnchor(record, data, newOffset, consume);
    if (reachedEOF && consume < data.length) record[@"partialSize"] = @(size);
    else [record removeObjectForKey:@"partialSize"];
    _stateDirty = YES;
    return [data subdataWithRange:NSMakeRange(0, consume)];
}

// Byte-level line iteration: transcripts run to gigabytes, so only lines containing
// `needle` are ever converted to NSString (the conversion dominates a naive scan).
static void ForEachMatchingLine(NSData *data, const char *needle, void (^block)(NSString *line)) {
    const char *bytes = data.bytes;
    size_t len = data.length, needleLen = strlen(needle), start = 0;
    while (start < len) {
        const char *nl = memchr(bytes + start, '\n', len - start);
        size_t lineLen = nl ? (size_t)(nl - (bytes + start)) : len - start;
        if (lineLen >= needleLen && memmem(bytes + start, lineLen, needle, needleLen)) {
            NSString *line = [[NSString alloc] initWithBytes:bytes + start length:lineLen
                                                    encoding:NSUTF8StringEncoding];
            if (line) block(line);
        }
        if (!nl) break;
        start += lineLen + 1;
    }
}

static NSString *WeekStartDayString(void) {
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-6
                                                              toDate:StartOfLocalDay(NSDate.date) options:0];
    return LocalDateString(weekStart);
}

static void PruneDays(NSMutableDictionary *days, NSString *weekStartDay) {
    for (NSString *day in days.allKeys)
        if ([day compare:weekStartDay] == NSOrderedAscending) [days removeObjectForKey:day];
}

static NSComparisonResult NewestCandidateFirst(NSDictionary *a, NSDictionary *b) {
    NSComparisonResult byTime = [b[@"mtime"] compare:a[@"mtime"]];
    if (byTime != NSOrderedSame) return byTime;
    return [b[@"size"] compare:a[@"size"]];
}

- (NSMutableDictionary *)recordForCandidate:(NSDictionary *)candidate
                                       files:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)files {
    NSString *key = candidate[@"key"];
    NSMutableDictionary *record = files[key];
    NSNumber *oldDev = record[@"dev"], *oldIno = record[@"ino"];
    NSNumber *newDev = candidate[@"dev"], *newIno = candidate[@"ino"];
    BOOL identityChanged = record && oldDev && oldIno && newDev && newIno &&
        (![oldDev isEqual:newDev] || ![oldIno isEqual:newIno]);
    if (!record || identityChanged) {
        record = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
        files[key] = record;
        _stateDirty = YES;
    }
    for (NSString *field in @[@"dev", @"ino", @"size", @"mtime", @"sub"]) {
        if ([field isEqualToString:@"size"] && [record[@"inventoryMismatch"] boolValue]) continue;
        id value = candidate[field];
        if (value && ![record[field] isEqual:value]) { record[field] = value; _stateDirty = YES; }
    }
    if (!record[@"offset"]) record[@"offset"] = @0;
    if (files == _claudeFiles && !record[@"v"]) { record[@"v"] = @(kClaudeRecordSchema); _stateDirty = YES; }
    return record;
}

- (NSArray<NSDictionary *> *)refreshRecentInventory:(NSArray<NSDictionary *> *)inventory
                                               files:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)files {
    NSMutableArray *updated = [inventory mutableCopy];
    NSUInteger count = MIN((NSUInteger)8, updated.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSMutableDictionary *candidate = [updated[i] mutableCopy];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:candidate[@"path"] error:nil];
        if (!attrs) {
            // A rollout may have moved to archived_sessions; force the next pass to
            // rebuild paths, while still avoiding another recursive walk in this pass.
            _codexInventoryValidUntil = 0;
            _claudeInventoryValidUntil = 0;
            continue;
        }
        NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
            ? attrs[NSFileModificationDate] : nil;
        candidate[@"size"] = @([attrs[NSFileSize] unsignedLongLongValue]);
        candidate[@"mtime"] = @(mtime ? mtime.timeIntervalSince1970 : 0);
        if (attrs[NSFileSystemNumber]) candidate[@"dev"] = attrs[NSFileSystemNumber];
        if (attrs[NSFileSystemFileNumber]) candidate[@"ino"] = attrs[NSFileSystemFileNumber];
        NSString *key = candidate[@"key"];
        NSMutableDictionary *record = files[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [files removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:files];
        updated[i] = candidate;
    }
    [updated sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    return updated;
}

- (NSArray<NSDictionary *> *)codexInventory {
    double now = CFAbsoluteTimeGetCurrent();
    if (_codexInventory && now < _codexInventoryValidUntil) {
        _codexInventory = [self refreshRecentInventory:_codexInventory files:_codexFiles];
        return _codexInventory;
    }
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];
    for (NSString *dir in @[@".codex/sessions", @".codex/archived_sessions"]) {
        NSString *base = [_homeDirectory stringByAppendingPathComponent:dir];
        NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
        for (NSString *rel in en) {
            if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
            NSDictionary *attrs = en.fileAttributes;
            NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
                ? attrs[NSFileModificationDate] : nil;
            if (mtime && [mtime compare:cutoff] == NSOrderedAscending) continue;
            NSString *key = rel.lastPathComponent;
            if (!key.length) continue;
            NSMutableDictionary *candidate = [@{
                @"key": key,
                @"path": [base stringByAppendingPathComponent:rel],
                @"size": @([attrs[NSFileSize] unsignedLongLongValue]),
                @"mtime": @(mtime ? mtime.timeIntervalSince1970 : 0)
            } mutableCopy];
            if (attrs[NSFileSystemNumber]) candidate[@"dev"] = attrs[NSFileSystemNumber];
            if (attrs[NSFileSystemFileNumber]) candidate[@"ino"] = attrs[NSFileSystemFileNumber];
            NSDictionary *prior = byKey[key];
            if (!prior || NewestCandidateFirst(candidate, prior) == NSOrderedAscending) byKey[key] = candidate;
        }
    }
    NSArray *inventory = [byKey.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    NSMutableSet *seen = [NSMutableSet setWithArray:byKey.allKeys];
    for (NSDictionary *candidate in inventory) {
        NSString *key = candidate[@"key"];
        NSMutableDictionary *record = _codexFiles[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [_codexFiles removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:_codexFiles];
    }
    for (NSString *key in _codexFiles.allKeys.copy) {
        if (![seen containsObject:key]) { [_codexFiles removeObjectForKey:key]; _stateDirty = YES; }
    }
    _codexInventory = inventory;
    _codexInventoryValidUntil = now + 30.0;   // normal ticks alternate full inventory / cheap active-file stats
    return inventory;
}

- (NSArray<NSDictionary *> *)claudeInventory {
    double now = CFAbsoluteTimeGetCurrent();
    if (_claudeInventory && now < _claudeInventoryValidUntil) {
        _claudeInventory = [self refreshRecentInventory:_claudeInventory files:_claudeFiles];
        return _claudeInventory;
    }
    NSString *base = [_homeDirectory stringByAppendingPathComponent:@".claude/projects"];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableArray<NSDictionary *> *inventory = [NSMutableArray array];
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
    for (NSString *rel in en) {
        if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
        NSDictionary *attrs = en.fileAttributes;
        NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
            ? attrs[NSFileModificationDate] : nil;
        if (mtime && [mtime compare:cutoff] == NSOrderedAscending) continue;
        NSNumber *dev = attrs[NSFileSystemNumber], *ino = attrs[NSFileSystemFileNumber];
        const char *relBytes = rel.UTF8String;
        NSString *opaqueKey = dev && ino
            ? [NSString stringWithFormat:@"%llx-%llx", dev.unsignedLongLongValue, ino.unsignedLongLongValue]
            : [@"path-" stringByAppendingString:FNVHashBytes(relBytes ?: "", relBytes ? strlen(relBytes) : 0)];
        NSMutableDictionary *candidate = [@{
            // Persisted keys are opaque filesystem identities/hashes, never project paths.
            @"key": opaqueKey,
            @"path": [base stringByAppendingPathComponent:rel],
            @"size": @([attrs[NSFileSize] unsignedLongLongValue]),
            @"mtime": @(mtime ? mtime.timeIntervalSince1970 : 0)
        } mutableCopy];
        if (dev) candidate[@"dev"] = dev;
        if (ino) candidate[@"ino"] = ino;
        // Subagent transcripts spend tokens like any other, but they are not sessions the
        // user started; the flag (never the path) lets the session count skip them.
        if ([rel.pathComponents containsObject:@"subagents"]) candidate[@"sub"] = @YES;
        [inventory addObject:candidate];
    }
    [inventory sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *candidate in inventory) {
        NSString *key = candidate[@"key"];
        [seen addObject:key];
        NSMutableDictionary *record = _claudeFiles[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [_claudeFiles removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:_claudeFiles];
    }
    for (NSString *key in _claudeFiles.allKeys.copy) {
        if (![seen containsObject:key]) { [_claudeFiles removeObjectForKey:key]; _stateDirty = YES; }
    }
    _claudeInventory = inventory;
    _claudeInventoryValidUntil = now + 30.0;
    return inventory;
}

static void AddDays(NSMutableDictionary<NSString *, NSDictionary *> *sum, NSDictionary *days) {
    for (NSString *day in days) {
        NSDictionary *add = [days[day] isKindOfClass:NSDictionary.class] ? days[day] : nil;
        if (!add) continue;
        sum[day] = MergeDayCounts(sum[day], add);
    }
}

- (void)rebuildCodexDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    NSDictionary *buckets = nil, *newestLimits = nil;
    NSString *newestTs = nil;
    for (NSMutableDictionary *record in _codexFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
        // Bucket-wise and meter-wise, not snapshot-wise: once an allowance is spent Codex
        // stops sending its windows, so the newest snapshot alone knows least — and it
        // may belong to a different bucket altogether.
        for (NSString *prefix in @[@"latest", @"peek"]) {
            NSDictionary *recordBuckets = record[[prefix stringByAppendingString:@"Buckets"]];
            if ([recordBuckets isKindOfClass:NSDictionary.class] && recordBuckets.count)
                buckets = MergeCodexLimitBuckets(buckets, recordBuckets);
            NSString *ts = record[[prefix stringByAppendingString:@"NewestTs"]];
            NSDictionary *limits = record[[prefix stringByAppendingString:@"Newest"]];
            if ([limits isKindOfClass:NSDictionary.class] && [ts isKindOfClass:NSString.class] && ts.length &&
                (!newestTs || [ts compare:newestTs] == NSOrderedDescending)) {
                newestTs = ts;
                newestLimits = limits;   // verbatim, for the drift check
            }
        }
    }
    _days = sum;
    _buckets = buckets;
    _limitsTs = newestTs ?: BucketsNewestTs(buckets);
    _limitsNewest = newestLimits ?: CodexNewestBucketLimits(buckets);
}

- (void)rebuildClaudeDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSString *today = LocalDateString(NSDate.date);
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    long long sessionsToday = 0, sessionsWeek = 0;
    NSString *lastTs = nil;
    for (NSMutableDictionary *record in _claudeFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
        // One transcript file is one session the user started; subagent transcripts are
        // not. A session counts on every local day it produced a message.
        if (![record[@"sub"] boolValue]) {
            BOOL anyDay = NO;
            for (NSString *day in recordDays) {
                if ([recordDays[day][@"n"] longLongValue] <= 0) continue;
                anyDay = YES;
                if ([day isEqualToString:today]) sessionsToday++;
            }
            if (anyDay) sessionsWeek++;
        }
        NSString *ts = [record[@"lastTs"] isKindOfClass:NSString.class] ? record[@"lastTs"] : nil;
        if (ts.length && (!lastTs || [ts compare:lastTs] == NSOrderedDescending)) lastTs = ts;
    }
    _claudeDays = sum;
    _claudeSessionsToday = sessionsToday;
    _claudeSessionsWeek = sessionsWeek;
    _claudeMessagesToday = [sum[today][@"n"] longLongValue];
    _claudeToolsToday = [sum[today][@"c"] longLongValue];
    _claudeLastActivity = lastTs ? DateFromStatusString(lastTs) : nil;
    NSMutableDictionary *models = [NSMutableDictionary dictionary];
    for (NSDictionary *day in sum.allValues) {
        NSDictionary *byModel = [day[@"m"] isKindOfClass:NSDictionary.class] ? day[@"m"] : nil;
        for (NSString *model in byModel)
            models[model] = @([models[model] longLongValue] + [byModel[model] longLongValue]);
    }
    _claudeModels = ModelRowsFromTokenDictionary(models);
}

- (void)consumeCodexData:(NSData *)chunk record:(NSMutableDictionary *)record {
    if (!chunk.length) return;
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"token_count\"", ^(NSString *line) {
        NSDictionary *event = ParseTokenCountLine(line);
        if (event) [events addObject:event];
    });
    if (!events.count) return;
    NSDictionary *acc = AccumulateTokenEvents(record[@"days"], events, nil);
    record[@"days"] = acc[@"days"] ?: @{};
    if ([acc[@"buckets"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *merged = MergeCodexLimitBuckets(record[@"latestBuckets"], acc[@"buckets"]);
        if (merged.count) record[@"latestBuckets"] = merged;
        NSString *ts = acc[@"newestTs"];
        NSString *keptTs = [record[@"latestNewestTs"] isKindOfClass:NSString.class] ? record[@"latestNewestTs"] : nil;
        if (ts.length && acc[@"newestLimits"] && (!keptTs || [ts compare:keptTs] == NSOrderedDescending)) {
            record[@"latestNewest"] = acc[@"newestLimits"];
            record[@"latestNewestTs"] = ts;
        }
    }
    _stateDirty = YES;
}

static NSString *HashedMessageID(NSString *messageID) {
    const unsigned char *bytes = (const unsigned char *)messageID.UTF8String;
    static const unsigned char empty[] = "";
    return FNVHashBytes(bytes ?: empty, bytes ? strlen((const char *)bytes) : 0);
}

- (void)consumeClaudeData:(NSData *)chunk record:(NSMutableDictionary *)record {
    if (!chunk.length) return;
    // One message arrives as several lines sharing its message.id — one per content
    // block — and the usage on the early lines is a running figure (output_tokens 1–7)
    // that only the last line completes. Keeping the first line lost about 40% of the
    // fresh output tokens (2026-09-07 audit). So remember what has been counted for each
    // id and apply only the growth; every line's content blocks are new, so tool calls
    // simply add up. Hashes are compact and carry neither content nor the provider id.
    NSMutableDictionary *counted = [([record[@"idv"] isKindOfClass:NSDictionary.class] ? record[@"idv"] : @{}) mutableCopy];
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"usage\"", ^(NSString *line) {
        NSDictionary *event = ParseClaudeUsageLine(line);
        if (!event) return;
        NSString *messageID = [event[@"id"] isKindOfClass:NSString.class] ? event[@"id"] : nil;
        if (!messageID.length) { [events addObject:event]; return; }
        NSString *hashed = HashedMessageID(messageID);
        long long fresh = [event[@"fresh"] longLongValue], tokens = [event[@"tokens"] longLongValue];
        NSArray *prev = [counted[hashed] isKindOfClass:NSArray.class] ? counted[hashed] : nil;
        if (prev.count < 2) {
            counted[hashed] = @[@(fresh), @(tokens)];
            [events addObject:event];
            return;
        }
        long long prevFresh = [prev[0] longLongValue], prevTokens = [prev[1] longLongValue];
        NSMutableDictionary *amend = [event mutableCopy];
        amend[@"amend"] = @YES;
        amend[@"fresh"] = @(MAX(0LL, fresh - prevFresh));
        amend[@"tokens"] = @(MAX(0LL, tokens - prevTokens));
        if (fresh > prevFresh || tokens > prevTokens)
            counted[hashed] = @[@(MAX(fresh, prevFresh)), @(MAX(tokens, prevTokens))];
        if ([amend[@"fresh"] longLongValue] > 0 || [amend[@"tokens"] longLongValue] > 0 ||
            [event[@"tools"] longLongValue] > 0)
            [events addObject:amend];
    });
    // Keep the per-id readings for the record's whole seven-day lifetime: a small rolling
    // window would double-count an older message amended much later.
    record[@"idv"] = counted;
    [record removeObjectForKey:@"ids"];
    if (events.count) {
        record[@"days"] = AccumulateTokenEvents(record[@"days"], events, nil)[@"days"] ?: @{};
        NSString *lastTs = [record[@"lastTs"] isKindOfClass:NSString.class] ? record[@"lastTs"] : nil;
        for (NSDictionary *event in events) {
            NSString *ts = event[@"ts"];
            if (ts.length && (!lastTs || [ts compare:lastTs] == NSOrderedDescending)) lastTs = ts;
        }
        if (lastTs.length) record[@"lastTs"] = lastTs;
    }
    _stateDirty = YES;
}

- (NSData *)tailDataAtPath:(NSString *)path maxBytes:(NSUInteger)maxBytes
                 bytesRead:(NSUInteger *)bytesRead readFailed:(BOOL *)readFailed {
    if (bytesRead) *bytesRead = 0;
    if (readFailed) *readFailed = NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (readFailed) *readFailed = YES; return nil; }
    NSError *err = nil;
    unsigned long long size = 0;
    if (![fh seekToEndReturningOffset:&size error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSUInteger wanted = (NSUInteger)MIN((unsigned long long)maxBytes, size);
    if (![fh seekToOffset:size - wanted error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSData *data = [fh readDataUpToLength:wanted error:&err];
    [fh closeAndReturnError:nil];
    if (bytesRead) *bytesRead = data.length;
    if (err && readFailed) *readFailed = YES;
    return err ? nil : data;
}

- (void)scanNewestCodexLimitFromInventory:(NSArray<NSDictionary *> *)inventory {
    NSUInteger attempts = 0;
    for (NSDictionary *candidate in inventory) {
        if (attempts >= 4 || _scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) break;
        NSMutableDictionary *record = [self recordForCandidate:candidate files:_codexFiles];
        unsigned long long size = [candidate[@"size"] unsignedLongLongValue];
        if ([record[@"tailSize"] unsignedLongLongValue] == size) continue;
        attempts++;
        // Validate the persisted offset anchor before attaching a tail snapshot to the
        // record. If the same inode was rewritten, this clears its old totals first so
        // the freshly peeked limit is not then discarded by the historical read.
        BOOL validationFailed = NO;
        NSUInteger validationBytes = 0;
        [self newLineDataAtPath:candidate[@"path"] record:record maxBytes:0 lineCap:0
                     bytesRead:&validationBytes readFailed:&validationFailed];
        if (validationFailed) { _codexBlocked = YES; continue; }
        NSUInteger bytesRead = 0;
        BOOL failed = NO;
        NSUInteger wanted = MIN((NSUInteger)(512 * 1024), _scanBytesRemaining);
        NSData *tail = [self tailDataAtPath:candidate[@"path"] maxBytes:wanted
                                 bytesRead:&bytesRead readFailed:&failed];
        _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
        if (failed) { _codexBlocked = YES; continue; }
        record[@"tailSize"] = @(size);
        _stateDirty = YES;
        __block NSDictionary *buckets = nil, *newest = nil;
        __block NSString *newestTs = nil;
        ForEachMatchingLine(tail, "\"token_count\"", ^(NSString *line) {
            NSDictionary *event = ParseTokenCountLine(line);
            NSString *ts = [event[@"ts"] isKindOfClass:NSString.class] ? event[@"ts"] : nil;
            NSDictionary *limits = [event[@"limits"] isKindOfClass:NSDictionary.class] ? event[@"limits"] : nil;
            if (limits && ts.length) {
                buckets = FoldCodexSnapshotIntoBuckets(buckets, limits, ts);
                if (!newestTs || [ts compare:newestTs] == NSOrderedDescending) { newestTs = ts; newest = limits; }
            }
        });
        if (buckets.count) {
            record[@"peekBuckets"] = buckets;
            record[@"peekNewest"] = newest;
            record[@"peekNewestTs"] = newestTs;
            break;   // newest modified file with a snapshot wins in normal Codex logs
        }
    }
}

- (void)progressForInventory:(NSArray<NSDictionary *> *)inventory
                       files:(NSDictionary<NSString *, NSMutableDictionary *> *)files
                       total:(unsigned long long *)total done:(unsigned long long *)done
                  incomplete:(BOOL *)incomplete {
    unsigned long long totalBytes = 0, doneBytes = 0;
    for (NSDictionary *candidate in inventory) {
        NSMutableDictionary *record = files[candidate[@"key"]];
        unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                      [record[@"size"] unsignedLongLongValue]);
        unsigned long long offset = MIN(size, [record[@"offset"] unsignedLongLongValue]);
        if (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size) offset = size;
        totalBytes += size;
        doneBytes += offset;
    }
    if (total) *total = totalBytes;
    if (done) *done = doneBytes;
    if (incomplete) *incomplete = doneBytes < totalBytes;
}

// Rollout files keep their unique basename when they move to archived_sessions, so
// records survive the move. Inventory is cached during immediate catch-up passes;
// historical reads share one global byte/time budget and always start newest-first.
- (void)scanRollouts {
    NSArray *inventory = [self codexInventory];
    _codexBlocked = NO;
    [self scanNewestCodexLimitFromInventory:inventory];
    NSMutableSet *failedKeys = [NSMutableSet set];
    BOOL madeProgress = NO, stopped = NO;
    do {
        BOOL roundProgress = NO, foundWork = NO;
        for (NSDictionary *candidate in inventory) {
            if (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) { stopped = YES; break; }
            NSString *key = candidate[@"key"];
            if ([failedKeys containsObject:key]) continue;
            NSMutableDictionary *record = [self recordForCandidate:candidate files:_codexFiles];
            unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                          [record[@"size"] unsignedLongLongValue]);
            unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
            if (offset >= size || (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size)) continue;
            foundWork = YES;
            NSUInteger bytesRead = 0;
            BOOL failed = NO;
            unsigned long long before = offset;
            NSData *chunk = [self newLineDataAtPath:candidate[@"path"] record:record
                                           maxBytes:_scanBytesRemaining lineCap:kAIMaxLineBytes
                                          bytesRead:&bytesRead readFailed:&failed];
            _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
            if (failed) { [failedKeys addObject:key]; _codexBlocked = YES; continue; }
            [self consumeCodexData:chunk record:record];
            if ([record[@"offset"] unsignedLongLongValue] > before) roundProgress = madeProgress = YES;
        }
        if (stopped || !foundWork || !roundProgress) break;
    } while (_scanBytesRemaining > 0 && CFAbsoluteTimeGetCurrent() < _scanDeadline);
    [self rebuildCodexDerivedState];
    [self progressForInventory:inventory files:_codexFiles total:&_codexTotalBytes
                          done:&_codexDoneBytes incomplete:&_codexTotalsIncomplete];
    if (_codexTotalsIncomplete && (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline)) stopped = YES;
    _needsImmediateRescan |= _codexTotalsIncomplete && (madeProgress || stopped);
}

// Claude transcripts use the same bounded scanner. Only short hashes of recent message
// IDs are retained for amended-line de-duplication; no transcript content is persisted.
- (void)scanClaudeTranscripts {
    NSArray *inventory = [self claudeInventory];
    _claudeBlocked = NO;
    NSMutableSet *failedKeys = [NSMutableSet set];
    BOOL madeProgress = NO, stopped = NO;
    do {
        BOOL roundProgress = NO, foundWork = NO;
        for (NSDictionary *candidate in inventory) {
            if (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) { stopped = YES; break; }
            NSString *key = candidate[@"key"];
            if ([failedKeys containsObject:key]) continue;
            NSMutableDictionary *record = [self recordForCandidate:candidate files:_claudeFiles];
            unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                          [record[@"size"] unsignedLongLongValue]);
            unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
            if (offset >= size || (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size)) continue;
            foundWork = YES;
            NSUInteger bytesRead = 0;
            BOOL failed = NO;
            unsigned long long before = offset;
            NSData *chunk = [self newLineDataAtPath:candidate[@"path"] record:record
                                           maxBytes:_scanBytesRemaining lineCap:kAIMaxLineBytes
                                          bytesRead:&bytesRead readFailed:&failed];
            _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
            if (failed) { [failedKeys addObject:key]; _claudeBlocked = YES; continue; }
            [self consumeClaudeData:chunk record:record];
            if ([record[@"offset"] unsignedLongLongValue] > before) roundProgress = madeProgress = YES;
        }
        if (stopped || !foundWork || !roundProgress) break;
    } while (_scanBytesRemaining > 0 && CFAbsoluteTimeGetCurrent() < _scanDeadline);
    [self rebuildClaudeDerivedState];
    [self progressForInventory:inventory files:_claudeFiles total:&_claudeTotalBytes
                          done:&_claudeDoneBytes incomplete:&_claudeTotalsIncomplete];
    if (_claudeTotalsIncomplete && (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline)) stopped = YES;
    _needsImmediateRescan |= _claudeTotalsIncomplete && (madeProgress || stopped);
}

- (NSString *)claudeAccessTokenForNow:(double)now {
    if (_claudeAccessToken.length && (_claudeAccessTokenExpiresAt <= 0 || _claudeAccessTokenExpiresAt > now + 60))
        return _claudeAccessToken;
    if (now < _claudeKeychainNextTry) {
        if (!_claudeAccountStatus.length) _claudeAccountStatus = @"Keychain token unavailable; retrying later";
        return nil;
    }

    // Track latency so a future Keychain/ACL behavior change is diagnosable without ever
    // logging the credential or its contents.
    double readStart = CFAbsoluteTimeGetCurrent();
    NSDictionary *cred = self.claudeCredentialReader();
    double readMs = (CFAbsoluteTimeGetCurrent() - readStart) * 1000.0;
    NSDictionary *outcome = ClaudeKeychainOutcome(cred != nil, cred[@"token"],
                                                  [cred[@"expiresAt"] doubleValue], now);
    if (![outcome[@"ok"] boolValue]) {
        _claudeAccessToken = nil;
        _claudeAccessTokenExpiresAt = 0;
        _claudeKeychainNextTry = now + [outcome[@"retryDelay"] doubleValue];
        _claudeAccountStatus = outcome[@"status"];
        GBLog("keychain read: %{public}@ (%.0f ms)", outcome[@"status"], readMs);
        return nil;
    }

    _claudeAccessToken = outcome[@"token"];
    _claudeAccessTokenExpiresAt = [outcome[@"expiresAt"] doubleValue];
    _claudeKeychainNextTry = 0;
    GBLog("keychain read: ok (%.0f ms)", readMs);
    return _claudeAccessToken;
}

// Shared by both accounts. Pointers address the provider's own ivars, so each keeps its
// state (and the tests' KVC keys) exactly as before.
- (void)rememberFetchError:(NSDictionary *)fetch now:(double)now
                     token:(NSString *__strong *)token expiresAt:(double *)expiresAt
                 nextFetch:(double *)nextFetch status:(NSString *__strong *)status
           rateLimitStreak:(NSUInteger *)streak client:(NSString *)client {
    BOOL rateLimited = [fetch[@"rateLimited"] boolValue];
    double retry = [fetch[@"retryAfter"] doubleValue];
    NSString *message = [fetch[@"message"] isKindOfClass:NSString.class] ? fetch[@"message"] : nil;
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue])) {
        *token = nil;   // revoked; re-read the credential next attempt
        if (expiresAt) *expiresAt = 0;
        *nextFetch = MIN(*nextFetch, now + kAuthFailureRetryInterval);
    }
    if (rateLimited) {
        *streak += 1;
        *nextFetch = now + RateLimitRetryDelay(retry, *streak);
        *status = @"Usage API rate-limited; retrying shortly";
    } else {
        *streak = 0;
        *status = AccountFetchFailureStatus([fetch[@"statusCode"] integerValue], message, client);
    }
}

// The usage endpoint 429s readily and every other poller of it (a statusline, a budget
// script) shares the account's allowance. When Claude Code has written its own figures in
// the last few minutes, use them and push our next request back: fresher, and no request.
- (void)adoptClaudeStatuslineCacheAt:(double)now {
    NSString *path = [_homeDirectory stringByAppendingPathComponent:@".claude/.cache/rate-limits.json"];
    NSDate *mtime = FileMTime(path);
    if (!mtime || now - mtime.timeIntervalSince1970 > kAccountPollInterval) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![cache isKindOfClass:NSDictionary.class]) return;
    double fetchedAt = [cache[@"fetchedAt"] doubleValue] / 1000.0;   // ms epoch
    if (fetchedAt <= _claudeLastSuccessAt + 1 || fetchedAt > now + 60 || now - fetchedAt > kAccountPollInterval) return;
    NSDictionary *merged = ClaudeUsageOverlayingStatusline(_claudeUsageJSON, cache);
    if (!merged) return;
    _claudeUsageJSON = merged;
    _claudeLastSuccessAt = fetchedAt;
    _claudeNextFetch = MAX(_claudeNextFetch, fetchedAt + kAccountPollInterval);
    _claudeAccountStatus = nil;
    _claudeRateLimitStreak = 0;
    _claudeFetchedThisRun = YES;
    _claudeUsageCacheAbandoned = NO;
    _stateDirty = YES;
    if (!_claudeStatuslineLogged) { GBLog("claude: using statusline cache"); _claudeStatuslineLogged = YES; }
}

- (void)rememberClaudeFetchError:(NSDictionary *)fetch now:(double)now {
    [self rememberFetchError:fetch now:now token:&_claudeAccessToken expiresAt:&_claudeAccessTokenExpiresAt
                   nextFetch:&_claudeNextFetch status:&_claudeAccountStatus rateLimitStreak:&_claudeRateLimitStreak
                      client:@"Claude Code"];
}

static NSString *ISOStringFromEpoch(double epoch) {
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}

// One account's fetch-if-due step: the throttle, the token, the request, and what to
// remember about the outcome. Shared by Claude and Cursor.
- (void)refreshAccountNamed:(const char *)label
                        use:(BOOL)use allow:(BOOL)allow now:(double)now
                  usageJSON:(NSDictionary *__strong *)usageJSON
              lastSuccessAt:(double *)lastSuccessAt nextFetch:(double *)nextFetch
              accountStatus:(NSString *__strong *)accountStatus
             fetchedThisRun:(BOOL *)fetchedThisRun cacheAbandoned:(BOOL *)cacheAbandoned
                 skipReason:(NSString *__strong *)skipReason
            rateLimitStreak:(NSUInteger *)rateLimitStreak
                      token:(NSString *(^)(void))tokenForNow
                    fetcher:(NSDictionary *(^)(NSString *))fetcher
                    onError:(void (^)(NSDictionary *))onError {
    if (GBLowDataEnabled()) return; // also guards work queued before the toggle changed
    if (ShouldFetchClaudeAccount(use, allow, *usageJSON != nil, (*accountStatus).length > 0, now, *nextFetch)) {
        *skipReason = nil;
        NSString *token = tokenForNow();
        if (GBLowDataEnabled()) return;
        // No token, no request: leave the schedule to the credential reader's own backoff
        // instead of spending the 15-minute slot on nothing.
        if (token) *nextFetch = now + kAccountPollInterval;   // the endpoints rate-limit readily
        NSDictionary *fetch = token ? fetcher(token) : nil;
        if (!fetch && GBLowDataEnabled()) { *nextFetch = now; return; }
        if ([fetch[@"_glancebarFetchError"] boolValue]) {
            onError(fetch);
            GBLog("%{public}s fetch: failed http=%ld rateLimited=%d", label,
                  (long)[fetch[@"statusCode"] integerValue], [fetch[@"rateLimited"] boolValue]);
        } else if (fetch && !fetch[@"error"]) {
            *usageJSON = fetch;
            *accountStatus = nil;
            *lastSuccessAt = now;
            *rateLimitStreak = 0;
            *fetchedThisRun = YES;
            *cacheAbandoned = NO;
            _stateDirty = _stateMustPersist = YES;
            [self savePersistentStateForcingWrite:YES];
            GBLog("%{public}s fetch: ok", label);
        } else if (token.length) {
            *accountStatus = @"Usage API unavailable";
            GBLog("%{public}s fetch: unusable response", label);
        }
    } else {
        NSString *skip = !allow ? @"hidden" : @"throttled";
        if (![skip isEqualToString:*skipReason]) {
            GBLog("%{public}s fetch: skipped (%{public}@)", label, skip);
            *skipReason = skip;
        }
    }
}

typedef NSArray<NSDictionary *> *(*GBWindowsFn)(NSDictionary *, double);
typedef NSDictionary *(*GBPickFn)(NSDictionary *, double);
typedef NSString *(*GBReasonFn)(NSDictionary *, NSString *, double);
typedef struct {
    GBWindowsFn liveWindows, staleWindows;
    GBPickFn pickLive, pickStale;
    GBReasonFn reason;
} GBAccountFunctions;

// The gauge, windows, staleness and status strings for one account response. Shared by
// Claude and Cursor; the provider supplies its pure functions and its wording.
- (void)applyAccountResponse:(NSDictionary *)usage to:(AIUsage *)u functions:(GBAccountFunctions)fns
               lastSuccessAt:(double)lastSuccessAt accountStatus:(NSString *)accountStatus
              fetchedThisRun:(BOOL)fetchedThisRun allowFetch:(BOOL)allowFetch
                  windowNoun:(NSString *)noun accountName:(NSString *)accountName
                  sourceLive:(NSString *)sourceLive sourceCached:(NSString *)sourceCached
              middleFallback:(NSString *)middleFallback
           unavailableReason:(NSString *)unavailable pausedReason:(NSString *)paused {
    double now = NSDate.date.timeIntervalSince1970;
    u.limitWindows = fns.liveWindows(usage, now);
    NSDictionary *pick = fns.pickLive(usage, now);
    BOOL usingStaleWindows = NO;
    if (!pick) {
        NSArray *staleWindows = fns.staleWindows(usage, now);
        pick = fns.pickStale(usage, now);
        if (pick) {
            u.limitWindows = staleWindows;
            usingStaleWindows = YES;
        }
    }
    NSString *fetchedAtISO = lastSuccessAt > 0 ? ISOStringFromEpoch(lastSuccessAt) : nil;
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        u.limitUpdatedAt = lastSuccessAt > 0 ? [NSDate dateWithTimeIntervalSince1970:lastSuccessAt] : nil;
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) {
            u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
            u.resetText = ResetTextFromDate(u.resetAt);
        }
        BOOL fresh = [pick[@"fresh"] boolValue];
        if (fresh) {
            // A window nobody has used yet has no reset to count down to; its clock
            // starts on the first request. Say that instead of inventing a time.
            u.resetText = @"Not started";
            u.resetAt = nil;
        }
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:noun.length ? [NSString stringWithFormat:@"%@ %@", pick[@"window"], noun] : pick[@"window"]];
        if (fresh) [parts addObject:@"nothing used yet"];
        [parts addObject:accountName];
        NSString *window = [parts componentsJoinedByString:@" · "];
        BOOL diskRestoredOnly = !fetchedThisRun && usage != nil;
        BOOL observationOld = lastSuccessAt <= 0 || now-lastSuccessAt > kAccountPollInterval || lastSuccessAt > now+5;
        if (usingStaleWindows || diskRestoredOnly || accountStatus.length || observationOld) u.limitStale = YES;
        NSString *asOf = AsOfTextFromEpoch(lastSuccessAt);
        if (accountStatus.length) {
            u.statusReason = asOf
                ? [NSString stringWithFormat:@"Cached limit · %@ · %@ · %@", accountStatus, window, asOf]
                : [NSString stringWithFormat:@"Cached limit · %@ · %@", accountStatus, window];
            u.statusSource = sourceCached;
        } else if (usingStaleWindows) {
            u.statusReason = fns.reason(usage, fetchedAtISO, now) ?: window;
            u.statusSource = sourceCached;
        } else if (diskRestoredOnly) {
            u.statusReason = asOf
                ? [NSString stringWithFormat:@"Cached limit · %@ · %@", window, asOf]
                : [@"Cached limit · " stringByAppendingString:window];
            u.statusSource = sourceCached;
        } else {
            u.statusReason = window;
            u.statusSource = sourceLive;
        }
    } else {
        NSString *fallback = fns.reason(usage, fetchedAtISO, now)
            ?: (usage ? @"Account response has no current limit window"
                : allowFetch ? unavailable : paused);
        u.statusReason = accountStatus ?: (middleFallback ?: fallback);
        if (allowFetch) u.limitRefreshError = accountStatus ?: fallback;
    }
    if (u.limitStatusAvailable && !u.limitUpdatedAt && lastSuccessAt > 0)
        u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:lastSuccessAt];
    if (accountStatus.length) u.limitRefreshError = accountStatus;
}

- (AIUsage *)claudeUsage {
    AIUsage *u = ReadClaudeUsage(_homeDirectory);   // stats-cache: sessions/messages/models (day-stale)
    if (self.allowClaudeTranscripts) {
        if (_claudeFiles.count) {
            NSString *today = LocalDateString(NSDate.date);
            u.todayTokens = [_claudeDays[today][@"f"] longLongValue];
            u.todayTokensAll = [_claudeDays[today][@"t"] longLongValue];
            long long week = 0, weekAll = 0;
            for (NSDictionary *day in _claudeDays.allValues) {
                week += [day[@"f"] longLongValue];
                weekAll += [day[@"t"] longLongValue];
            }
            u.weekTokens = week;
            u.weekTokensAll = weekAll;
            u.available = YES;
            u.stale = NO;   // token counts are live now; only the activity counts lag a day
            if (_claudeTotalsIncomplete)
                u.statusText = _claudeBlocked && !_needsImmediateRescan
                    ? @"Transcript totals incomplete · some logs unreadable"
                    : [NSString stringWithFormat:@"Indexing transcripts %.0f%% · totals incomplete",
                       _claudeTotalBytes ? 100.0 * _claudeDoneBytes / _claudeTotalBytes : 0.0];
            else u.statusText = @"Tokens live from local transcripts";
            u.source = @"~/.claude transcripts";
            // Activity comes from the same index. Claude Code stopped writing its stats
            // cache in June 2026, so the cache-derived figures above are months stale.
            u.models = _claudeModels ?: @[];
            u.topModel = u.models.count ? u.models.firstObject[@"name"] : nil;
            u.todaySessions = _claudeSessionsToday;
            u.weekSessions = _claudeSessionsWeek;
            u.todayMessages = _claudeMessagesToday;
            u.todayToolCalls = _claudeToolsToday;
            if (_claudeLastActivity) u.lastActivity = _claudeLastActivity;
        }
    } else {
        [self purgeClaudeTranscriptIndex];
        if (u.statusText.length)
            u.statusText = [u.statusText stringByAppendingString:@" · transcript totals off"];
    }

    if (self.useClaudeAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        [self adoptClaudeStatuslineCacheAt:now];
        [self refreshAccountNamed:"claude" use:self.useClaudeAccount allow:self.allowClaudeAccountFetch now:now
                        usageJSON:&_claudeUsageJSON lastSuccessAt:&_claudeLastSuccessAt nextFetch:&_claudeNextFetch
                    accountStatus:&_claudeAccountStatus fetchedThisRun:&_claudeFetchedThisRun
                   cacheAbandoned:&_claudeUsageCacheAbandoned skipReason:&_claudeFetchSkipReason
                  rateLimitStreak:&_claudeRateLimitStreak
                            token:^NSString *{ return [self claudeAccessTokenForNow:now]; }
                          fetcher:^NSDictionary *(NSString *token){ return self.claudeUsageFetcher(token); }
                          onError:^(NSDictionary *fetch){ [self rememberClaudeFetchError:fetch now:now]; }];
        NSDictionary *extraStatus = ClaudeExtraUsageStatus(_claudeUsageJSON);
        if (extraStatus[@"description"]) u.extraUsage = extraStatus[@"description"];
        GBAccountFunctions fns = { ClaudeLimitWindows, ClaudeStaleLimitWindows,
                                   PickClaudeLimitWindow, PickClaudeStaleLimitWindow, ClaudeLimitStatusReason };
        [self applyAccountResponse:_claudeUsageJSON to:u functions:fns
                     lastSuccessAt:_claudeLastSuccessAt accountStatus:_claudeAccountStatus
                    fetchedThisRun:_claudeFetchedThisRun allowFetch:self.allowClaudeAccountFetch
                        windowNoun:@"window" accountName:@"your Claude account"
                        sourceLive:@"Anthropic usage API (opt-in)"
                      sourceCached:@"Cached Anthropic usage API response (opt-in)"
                    middleFallback:extraStatus[@"statusReason"]
                 unavailableReason:@"Claude account status unavailable"
                      pausedReason:@"Claude account refresh paused until visible"];
        if ([extraStatus[@"overageActive"] boolValue]) {
            u.limitStatusAvailable = YES;
            u.remainingFraction = 0;
            u.overageActive = YES;
            u.resetText = @"Not provided";
            u.resetAt = nil;   // the window's own reset says nothing about paid overage
            // "You are being billed for overage" is the whole message here, so it stays
            // the whole reason. That the figure is cached rides on limitStale, and the
            // refresh error on limitRefreshError — both have their own place to appear.
            u.statusReason = extraStatus[@"statusReason"];
            if (_claudeAccountStatus.length) {
                u.limitStale = YES;
                u.statusSource = @"Cached Anthropic usage API response (opt-in)";
            } else {
                u.statusSource = @"Anthropic usage API (opt-in)";
            }
        }
        if (u.limitStatusAvailable && !u.limitUpdatedAt && _claudeLastSuccessAt > 0)
            u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt];   // overage path
        u.diagnostics = [NSString stringWithFormat:@"usage JSON %@ · next fetch %@ · keychain %@",
            _claudeUsageJSON ? @"cached" : @"none",
            FmtEpochClock(_claudeNextFetch),
            _claudeKeychainNextTry > now
                ? [@"backoff until " stringByAppendingString:FmtEpochClock(_claudeKeychainNextTry)]
                : _claudeAccessToken.length ? @"token cached" : @"not read"];
    } else {
        [self forgetClaudeAccountCredentials];
        // The account can be unrequested because the user's toggle is off or because online
        // access was never granted (`--dump` without `--online`). Naming only the toggle
        // contradicts the accountEnabled=true this same run reports.
        u.diagnostics = @"account status not requested";
    }
    return u;
}

// Withdrawn consent: the transcript index (message-ID hashes, per-day totals) must leave
// the disk NOW — the toggle calls this directly, because no read() runs while every AI
// surface is hidden and "on the next pass" may mean never.
- (void)purgeClaudeTranscriptIndex {
    BOOL hadIndex = _claudeFiles.count || _claudeDays.count;
    [_claudeFiles removeAllObjects];
    [_claudeDays removeAllObjects];
    _claudeInventory = nil;
    _claudeInventoryValidUntil = 0;
    _claudeTotalBytes = _claudeDoneBytes = 0;
    _claudeTotalsIncomplete = _claudeBlocked = NO;
    _claudeModels = @[];
    _claudeSessionsToday = _claudeSessionsWeek = _claudeMessagesToday = _claudeToolsToday = 0;
    _claudeLastActivity = nil;
    if (hadIndex) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
}

- (void)forgetClaudeAccountCredentials {
    BOOL hadCache = _claudeUsageJSON != nil || _claudeLastSuccessAt > 0 || !_claudeUsageCacheAbandoned;
    _claudeAccessToken = nil;
    _claudeAccessTokenExpiresAt = 0;
    _claudeUsageJSON = nil;
    _claudeAccountStatus = nil;
    _claudeLastSuccessAt = 0;
    _claudeNextFetch = 0;
    _claudeFetchedThisRun = NO;
    _claudeUsageCacheAbandoned = YES;
    if (hadCache) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
}

- (NSString *)cursorAccessTokenForNow:(double)now {
    double cachedExp = JWTExpiryEpoch(_cursorAccessToken);
    if (_cursorAccessToken.length && !(cachedExp > 0 && cachedExp <= now)) return _cursorAccessToken;
    _cursorAccessToken = nil;
    if (now < _cursorStateNextTry) {
        if (!_cursorAccountStatus.length) _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        return nil;
    }
    double readStart = CFAbsoluteTimeGetCurrent();
    NSString *token = self.cursorTokenReader(_homeDirectory);
    double readMs = (CFAbsoluteTimeGetCurrent() - readStart) * 1000.0;
    if (!token.length) {
        _cursorAccessToken = nil;
        _cursorStateNextTry = now + 3600;   // missing session: don't hammer sqlite every tick
        _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        GBLog("cursor state read: missing (%.0f ms)", readMs);
        return nil;
    }
    double exp = JWTExpiryEpoch(token);
    if (exp > 0 && exp <= now) {
        // Every session we can see has expired: no request would succeed, so say how to fix
        // it and look again soon — signing in to either client takes effect within minutes.
        _cursorStateNextTry = now + 300;
        _cursorAccountStatus = AccountFetchFailureStatus(401, nil, @"Cursor");
        GBLog("cursor state read: expired (%.0f ms)", readMs);
        return nil;
    }
    _cursorAccessToken = token;
    _cursorStateNextTry = 0;
    GBLog("cursor state read: ok (%.0f ms)", readMs);
    return _cursorAccessToken;
}

- (void)rememberCursorFetchError:(NSDictionary *)fetch now:(double)now {
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue]))
        self.cursorRejectedToken = _cursorAccessToken;
    [self rememberFetchError:fetch now:now token:&_cursorAccessToken expiresAt:NULL
                   nextFetch:&_cursorNextFetch status:&_cursorAccountStatus rateLimitStreak:&_cursorRateLimitStreak
                      client:@"Cursor"];
}

- (AIUsage *)cursorUsage {
    AIUsage *u = [AIUsage new];
    u.name = @"Cursor";
    u.source = @"Cursor session (app or CLI) + api2.cursor.sh";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusReason = @"Cursor account access is off";
    u.models = @[];
    u.available = NO;

    if (self.useCursorAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        [self refreshAccountNamed:"cursor" use:self.useCursorAccount allow:self.allowCursorAccountFetch now:now
                        usageJSON:&_cursorUsageJSON lastSuccessAt:&_cursorLastSuccessAt nextFetch:&_cursorNextFetch
                    accountStatus:&_cursorAccountStatus fetchedThisRun:&_cursorFetchedThisRun
                   cacheAbandoned:&_cursorUsageCacheAbandoned skipReason:&_cursorFetchSkipReason
                  rateLimitStreak:&_cursorRateLimitStreak
                            token:^NSString *{ return [self cursorAccessTokenForNow:now]; }
                          fetcher:^NSDictionary *(NSString *token){ return self.cursorUsageFetcher(token); }
                          onError:^(NSDictionary *fetch){ [self rememberCursorFetchError:fetch now:now]; }];
        GBAccountFunctions fns = { CursorLimitWindows, CursorStaleLimitWindows,
                                   PickCursorLimitWindow, PickCursorStaleLimitWindow, CursorLimitStatusReason };
        [self applyAccountResponse:_cursorUsageJSON to:u functions:fns
                     lastSuccessAt:_cursorLastSuccessAt accountStatus:_cursorAccountStatus
                    fetchedThisRun:_cursorFetchedThisRun allowFetch:self.allowCursorAccountFetch
                        windowNoun:nil accountName:@"your Cursor account"
                        sourceLive:@"Cursor usage API (opt-in)"
                      sourceCached:@"Cached Cursor usage API response (opt-in)"
                    middleFallback:nil
                 unavailableReason:@"Cursor account status unavailable"
                      pausedReason:@"Cursor account refresh paused until visible"];
        if (u.limitStatusAvailable) {
            u.available = YES;
            u.statusText = @"Limit status from Cursor account";
        }
        u.diagnostics = [NSString stringWithFormat:@"usage JSON %@ · next fetch %@ · session %@",
            _cursorUsageJSON ? @"cached" : @"none",
            FmtEpochClock(_cursorNextFetch),
            _cursorStateNextTry > now
                ? [@"backoff until " stringByAppendingString:FmtEpochClock(_cursorStateNextTry)]
                : _cursorAccessToken.length ? @"token cached" : @"not read"];
    } else {
        [self forgetCursorAccountCredentials];
        u.diagnostics = @"account status not requested";
    }
    return u;
}

- (void)forgetCursorAccountCredentials {
    BOOL hadCache = _cursorUsageJSON != nil || _cursorLastSuccessAt > 0 || !_cursorUsageCacheAbandoned;
    _cursorAccessToken = nil;
    _cursorUsageJSON = nil;
    _cursorAccountStatus = nil;
    _cursorLastSuccessAt = 0;
    _cursorNextFetch = 0;
    _cursorStateNextTry = 0;
    _cursorFetchedThisRun = NO;
    _cursorUsageCacheAbandoned = YES;
    if (hadCache) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
}

// Session counts, per-model split, and last activity still come from the sqlite thread
// store (the rollouts don't carry the model); re-queried only when the db changes.
- (NSString *)codexStatePath {
    NSString *dir = [_homeDirectory stringByAppendingPathComponent:@".codex"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    long bestVersion = -1;
    for (NSString *name in names) {
        if (![name hasPrefix:@"state_"] || ![name hasSuffix:@".sqlite"] || name.length <= 13) continue;
        long version = [name substringWithRange:NSMakeRange(6, name.length - 13)].integerValue;
        if (version > bestVersion) { bestVersion = version; best = name; }
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

- (void)refreshDBExtras {
    NSString *path = [self codexStatePath];
    if (!path) { _sessionsToday = _sessionsWeek = 0; _models = @[]; _lastActivity = nil; return; }
    NSDate *m1 = FileMTime(path), *m2 = FileMTime([path stringByAppendingString:@"-wal"]);
    NSDate *stamp = (m2 && (!m1 || [m2 compare:m1] == NSOrderedDescending)) ? m2 : m1;
    NSString *today = LocalDateString(NSDate.date);
    if (_dbStamp && stamp && [stamp isEqualToDate:_dbStamp] && [today isEqualToString:_dbDay]) return;
    _dbStamp = stamp;
    _dbDay = today;

    long long todayEpoch = (long long)StartOfLocalDay(NSDate.date).timeIntervalSince1970;
    NSString *todaySQL = [NSString stringWithFormat:
        @"select count(*), coalesce(max(updated_at),0) from threads where updated_at >= %lld;", todayEpoch];
    NSArray<NSString *> *fields = SQLiteFields([[RunSQLite(path, todaySQL)
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@"\n"].firstObject);
    _sessionsToday = fields.count >= 1 ? [fields[0] longLongValue] : 0;
    long long last = fields.count >= 2 ? [fields[1] longLongValue] : 0;
    _lastActivity = last > 0 ? [NSDate dateWithTimeIntervalSince1970:last] : nil;

    // Sessions per model are accurate; per-model token sums would be lifetime-inflated,
    // so deliberately don't fetch them.
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-6
                                                              toDate:StartOfLocalDay(NSDate.date) options:0];
    NSString *weekSQL = [NSString stringWithFormat:@"select count(*) from threads where updated_at >= %lld;",
                         (long long)weekStart.timeIntervalSince1970];
    _sessionsWeek = [[[RunSQLite(path, weekSQL) stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].firstObject longLongValue];
    NSString *modelsSQL = [NSString stringWithFormat:
        @"select coalesce(nullif(model,''),'unknown'), count(*) from threads "
         "where updated_at >= %lld group by 1 order by 2 desc limit 5;",
        (long long)weekStart.timeIntervalSince1970];
    NSMutableArray *models = [NSMutableArray array];
    for (NSString *line in [RunSQLite(path, modelsSQL) componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *cols = SQLiteFields([line stringByTrimmingCharactersInSet:
                                                  NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (cols.count < 2 || !cols[0].length) continue;
        [models addObject:@{@"name": cols[0], @"sessions": @([cols[1] longLongValue])}];
    }
    _models = models;
}

- (AIUsage *)codexUsage {
    [self refreshDBExtras];
    double accountNow = NSDate.date.timeIntervalSince1970;
    NSDate *accountDate = DateFromStatusString(BucketsNewestTs(_codexAccountBuckets));
    if (self.allowCodexAccountFetch && !GBLowDataEnabled() && accountNow >= _codexNextFetch &&
        (!accountDate || accountNow - accountDate.timeIntervalSince1970 >= 300)) {
        _codexNextFetch = accountNow + 300;
        NSDictionary *incoming = CodexAccountBuckets(self.codexUsageFetcher(), ISOStringFromEpoch(accountNow));
        if (incoming.count) {
            _codexAccountBuckets = incoming;
            _codexAccountError = nil;
            _stateDirty = YES;
        } else _codexAccountError = @"Codex account refresh failed; check Codex CLI sign-in";
    }
    _buckets = MergeCodexLimitBuckets(_buckets, _codexAccountBuckets);
    _limitsTs = BucketsNewestTs(_buckets);
    _limitsNewest = CodexNewestBucketLimits(_buckets);

    AIUsage *u = [AIUsage new];
    u.name = @"Codex";
    u.source = @"~/.codex session logs";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.models = _models ?: @[];
    u.available = _codexFiles.count > 0 || _codexAccountBuckets.count > 0;
    if (!u.available) {
        u.statusText = @"Local state not found";
        u.statusReason = @"No Codex session logs under ~/.codex";
        if (_codexAccountError) u.limitRefreshError = _codexAccountError;
        return u;
    }
    if (_codexTotalsIncomplete)
        u.statusText = _codexBlocked && !_needsImmediateRescan
            ? @"Totals incomplete · some session logs unreadable"
            : [NSString stringWithFormat:@"Indexing %.0f%% · totals incomplete",
               _codexTotalBytes ? 100.0 * _codexDoneBytes / _codexTotalBytes : 0.0];
    else u.statusText = @"Per-turn session logs";
    double now = NSDate.date.timeIntervalSince1970;
    NSString *today = LocalDateString(NSDate.date);
    u.todayTokens = [_days[today][@"f"] longLongValue];       // fresh = the headline
    u.todayTokensAll = [_days[today][@"t"] longLongValue];
    long long week = 0, weekAll = 0;
    for (NSDictionary *day in _days.allValues) {              // _days is pruned to 7 days
        week += [day[@"f"] longLongValue];
        weekAll += [day[@"t"] longLongValue];
    }
    u.weekTokens = week;
    u.weekTokensAll = weekAll;
    u.todaySessions = _sessionsToday;
    u.weekSessions = _sessionsWeek;
    u.lastActivity = _lastActivity;
    if (u.models.count) u.topModel = u.models.firstObject[@"name"];

    // Read drift from the newest snapshot as it arrived, not from the merged view.
    NSString *drift = CodexSchemaDriftReason(_limitsNewest);
    NSMutableArray *datedWindows=[NSMutableArray array];
    for (NSDictionary *window in CodexBucketWindows(_buckets,now)) {
        NSMutableDictionary *dated=[window mutableCopy];
        NSString *stamp=_buckets[window[@"bucket"]][@"ts"];
        if (!dated[@"observedAt"] && [stamp isKindOfClass:NSString.class]) dated[@"observedAt"]=stamp;
        [datedWindows addObject:dated];
    }
    u.limitWindows=datedWindows;
    NSDictionary *planBuckets = _buckets[@"codex"] ? @{@"codex": _buckets[@"codex"]} : @{};
    NSDictionary *pick = PickCodexBucketWindow(planBuckets, now);
    NSDictionary *freshPick=nil;
    for (NSDictionary *window in u.limitWindows) {
        if (![window[@"bucket"] isEqual:@"codex"] ||
            !CodexObservationFresh(DateFromStatusString(window[@"observedAt"]),now)) continue;
        if (!freshPick || [window[@"remainingFraction"] doubleValue]<[freshPick[@"remainingFraction"] doubleValue]) freshPick=window;
    }
    if (freshPick) pick=freshPick;
    u.billingNote = CodexBillingNote(_buckets, now);
    NSMutableSet *bucketsShown = [NSMutableSet set];
    for (NSDictionary *w in u.limitWindows) if (w[@"bucket"]) [bucketsShown addObject:w[@"bucket"]];
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) {
            u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
            u.resetText = ResetTextFromDate(u.resetAt);
        }
        NSString *plan = [pick[@"plan"] isKindOfClass:NSString.class] ? pick[@"plan"] : nil;
        // Name the bucket only when more than one is on show; with a single bucket the
        // window name says it all, as it always did.
        NSString *window = bucketsShown.count > 1
            ? [NSString stringWithFormat:@"%@ window · %@ bucket", pick[@"window"], pick[@"bucketLabel"]]
            : [NSString stringWithFormat:@"%@ window", pick[@"window"]];
        u.statusReason = plan.length ? [NSString stringWithFormat:@"%@ · %@ plan", window, plan] : window;
        u.statusSource = @"~/.codex session logs";
        // A window carried forward from an earlier snapshot is as old as its own
        // observation, not as old as the latest snapshot — and that makes it stale,
        // which is exactly what the row's "cached" marker exists to say.
        NSString *observed = [pick[@"observedAt"] isKindOfClass:NSString.class] ? pick[@"observedAt"] : nil;
        NSString *planStamp=planBuckets[@"codex"][@"ts"];
        u.limitUpdatedAt = DateFromStatusString(observed ?: ([planStamp isKindOfClass:NSString.class] ? planStamp : nil));
        if (!CodexObservationFresh(u.limitUpdatedAt,now) ||
            (observed.length && _limitsTs.length && [observed compare:_limitsTs] == NSOrderedAscending))
            u.limitStale = YES;
    }
    // With no gauge left, "the payload changed shape" beats "the windows have reset":
    // both are true, but only one tells the user why no new number is coming.
    else {
        u.statusReason = drift ?: CodexBucketsStatusReason(planBuckets, now);
        // Keep the plan's observation age even after its reset removes the gauge;
        // a newer model-specific bucket cannot refresh the general allowance.
        NSDictionary *plan=planBuckets[@"codex"];
        u.limitUpdatedAt=DateFromStatusString([plan[@"ts"] isKindOfClass:NSString.class] ? plan[@"ts"] : nil);
        u.limitStale=plan!=nil;
    }
    if (CodexQuotaUnavailable(u)) {
        u.statusReason=@"Current Codex allowance unavailable; local session limit snapshot is stale";
        u.limitRefreshError=@"No fresh Codex limit observation in local session logs";
    }
    if (!CodexObservationFresh(DateFromStatusString(_limitsTs),now)) u.billingNote=nil;

    // Context, never the gauge: a zero credit balance is normal while the plan window
    // still has room. See CodexCreditsStatus. Credits are account-level; read them from
    // whichever bucket reported them last.
    NSDictionary *credits = CodexCreditsStatus(CodexNewestBucketLimits(_buckets));
    NSString *creditsObserved=_limitsTs;
    for (NSString *bucketID in _buckets) {
        if (credits) break;
        NSDictionary *entry = _buckets[bucketID];
        credits = CodexCreditsStatus([entry[@"limits"] isKindOfClass:NSDictionary.class] ? entry[@"limits"] : nil);
        if (credits) creditsObserved=[entry[@"ts"] isKindOfClass:NSString.class] ? entry[@"ts"] : nil;
    }
    if (credits[@"description"]) {
        NSDate *observed=DateFromStatusString(credits[@"observedAt"] ?: creditsObserved);
        u.extraUsage=CodexObservationFresh(observed,now) ? credits[@"description"] : @"Credit balance unavailable · stale local snapshot";
        if (!CodexObservationFresh(observed,now)) u.billingNote=nil;
    }
    if (u.billingNote.length)
        u.statusReason = [u.statusReason stringByAppendingFormat:@" · %@", u.billingNote];
    // Say it even while a carried-forward window still reads, or the cause hides behind
    // up to a week of apparently-healthy rows. limitRefreshError is exactly "why the
    // figure above is the last-known one", and Codex never sets it otherwise.
    // (--strict consults only Claude/Cursor, so this cannot change an exit code.)
    if (drift.length) u.limitRefreshError = drift;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"limits snapshot %@",
                      _limitsTs.length ? _limitsTs : @"never seen"]];
    if (drift.length) [parts addObject:drift];
    BOOL anyCurrent = NO, anyUsable = NO;
    for (NSString *bucketID in [_buckets.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *entry = _buckets[bucketID];
        NSDictionary *limits = [entry[@"limits"] isKindOfClass:NSDictionary.class] ? entry[@"limits"] : nil;
        for (NSString *key in @[@"primary", @"secondary"]) {
            NSDictionary *w = [limits[key] isKindOfClass:NSDictionary.class] ? limits[key] : nil;
            if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
            anyUsable = YES;
            double resets = [w[@"resets_at"] isKindOfClass:NSNumber.class] ? [w[@"resets_at"] doubleValue] : 0;
            BOOL expired = resets > 0 && resets <= now;
            if (!expired) anyCurrent = YES;
            long mins = [w[@"window_minutes"] isKindOfClass:NSNumber.class] ? [w[@"window_minutes"] longValue] : 0;
            [parts addObject:[NSString stringWithFormat:@"%@ %@ %.0f%% used · reset %@%@", bucketID,
                mins == 10080 ? @"weekly" : mins == 300 ? @"5h" : @"window",
                [w[@"used_percent"] doubleValue], FmtEpochDayClock(resets), expired ? @" (expired)" : @""]];
        }
    }
    NSString *newestBucket = CodexNewestBucketID(_buckets);
    if (newestBucket.length) [parts addObject:[@"newest bucket " stringByAppendingString:newestBucket]];
    if (anyUsable && !anyCurrent) [parts addObject:@"all expired"];
    if (_codexTotalsIncomplete) [parts addObject:[NSString stringWithFormat:@"indexing %.1f%%",
        _codexTotalBytes ? 100.0 * _codexDoneBytes / _codexTotalBytes : 0.0]];
    u.diagnostics = [parts componentsJoinedByString:@" · "];
    NSString *accountStamp = _codexAccountBuckets[@"codex"][@"ts"];
    if (accountStamp && [accountStamp isEqual:_buckets[@"codex"][@"ts"]])
        u.statusSource = @"Codex app-server account/rateLimits/read";
    if (_codexAccountError) u.limitRefreshError = _codexAccountError;
    return u;
}

- (NSArray<AIUsage *> *)read {
    // One budget covers Codex and the opt-in Claude transcript reader together. Codex
    // goes first so the tail snapshot makes the live limit gauge available even while
    // historical totals are still catching up.
    _scanBytesRemaining = 16 * 1024 * 1024;
    _scanDeadline = CFAbsoluteTimeGetCurrent() + 0.35;
    _needsImmediateRescan = NO;
    [self adoptNewerAccountCachesFromDisk];
    [self scanRollouts];
    if (self.allowClaudeTranscripts) [self scanClaudeTranscripts];
    NSMutableArray<AIUsage *> *usage = [NSMutableArray arrayWithObjects:
                                        [self claudeUsage], [self codexUsage], nil];
    // Cursor is a local product, not a universal CLI — only surface it when Cursor's
    // state DB exists on this Mac (same path the opt-in session read uses).
    if (CursorServicePresent(_homeDirectory)) [usage addObject:[self cursorUsage]];
    else if (self.useCursorAccount) [self forgetCursorAccountCredentials];
    NSString *statusPath = [_homeDirectory stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    NSDictionary *status = JSONDictionaryAtPath(statusPath);
    if (status) {
        for (AIUsage *u in usage) ApplyAIStatusFile(u, status, @"~/.glancebar/ai-status.json");
    }
    for (AIUsage *u in usage) {
        NSString *prev = _lastStatusReasons[u.name];
        if (u.statusReason.length && ![u.statusReason isEqualToString:prev]) {
            // Reason strings can carry server- or status-file-sourced text, so they stay
            // private by os_log default; only the provider name is logged publicly.
            GBLog("%{public}@ status changed: %@ -> %@",
                  u.name, prev ?: @"(none)", u.statusReason);
            _lastStatusReasons[u.name] = u.statusReason;
        }
    }
    // Mid-catch-up another pass follows immediately, so coalesce. The pass that lands the
    // backlog (and every steady-state pass) flushes.
    if (_needsImmediateRescan) [self savePersistentStateCoalesced];
    else [self flushPersistentState];
    return usage;
}

- (BOOL)needsImmediateRescan { return _needsImmediateRescan; }
- (BOOL)totalsIncomplete { return _codexTotalsIncomplete ||
    (self.allowClaudeTranscripts && _claudeTotalsIncomplete); }

- (double)catchUpProgress {
    unsigned long long total = _codexTotalBytes;
    unsigned long long done = _codexDoneBytes;
    if (self.allowClaudeTranscripts) { total += _claudeTotalBytes; done += _claudeDoneBytes; }
    return total ? MIN(1.0, (double)done / (double)total) : 1.0;
}

- (NSString *)catchUpStatus {
    if (!self.totalsIncomplete) return @"Local AI totals current";
    if (!_needsImmediateRescan && (_codexBlocked || (self.allowClaudeTranscripts && _claudeBlocked)))
        return @"AI totals incomplete · some logs unreadable";
    return [NSString stringWithFormat:@"Indexing %.0f%% · totals incomplete", self.catchUpProgress * 100.0];
}

- (NSArray<AIUsage *> *)readUntilCaughtUpWithTimeLimit:(NSTimeInterval)timeLimit {
    NSArray<AIUsage *> *usage = nil;
    double deadline = CFAbsoluteTimeGetCurrent() + MAX(0.0, timeLimit);
    do {
        usage = [self read];
    } while (self.needsImmediateRescan && CFAbsoluteTimeGetCurrent() < deadline);
    return usage ?: @[];
}

@end

#pragma mark - colors / small views

static NSColor *DiskColor(double frac) {
    return frac >= 0.95 ? NSColor.systemRedColor : frac >= 0.85 ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
}
static NSColor *BattBarColor(int pct) {
    return pct <= 10 ? NSColor.systemRedColor : pct <= 20 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
}

// The battery glyph's colour says what the power is doing: green while charging (pale for a
// trickle, vivid when fast), amber when plugged in but nothing is arriving, orange to red as
// the drain gets heavy, and the ordinary ink otherwise. `ink` is the surface's normal colour.
static NSColor *PowerFlowColor(BatteryState b, NSColor *ink) {
    NSColor *base = ink ?: NSColor.labelColor;
    double k = PowerFlowIntensity(b);
    switch (PowerFlowFor(b)) {
        case PowerFlowCharging:
            // Even a trickle must read as green on a dark bar: start well into the green.
            return [base blendedColorWithFraction:0.6 + 0.4 * k ofColor:NSColor.systemGreenColor] ?: NSColor.systemGreenColor;
        case PowerFlowPaused:
            return NSColor.systemYellowColor;
        case PowerFlowShort:
            return NSColor.systemOrangeColor;
        case PowerFlowDischarging:
            if (b.percent <= 20) return BattBarColor(b.percent);
            if (k < 0.35) return base;
            return [NSColor.systemOrangeColor blendedColorWithFraction:(k - 0.35) / 0.65 ofColor:NSColor.systemRedColor]
                ?: NSColor.systemOrangeColor;
        default:
            return base;
    }
}
// SF Symbol battery.100 / .75 / .50 / .25 / .0. The live glyph stays the plain level:
// a bolt or pause badge is composited on top (BatteryGlyphWithBadge). The system bolt
// variant exists only for battery.100 and has no pause counterpart.
static NSString *BatterySymbolName(int percent, BOOL plugged) {
    int bucket = 0;
    if (percent >= 88) bucket = 100;
    else if (percent >= 63) bucket = 75;
    else if (percent >= 38) bucket = 50;
    else if (percent >= 13) bucket = 25;
    if (plugged) {
        NSString *bolt = [NSString stringWithFormat:@"battery.%d.bolt", bucket];
        if ([NSImage imageWithSystemSymbolName:bolt accessibilityDescription:nil]) return bolt;
    }
    return [NSString stringWithFormat:@"battery.%d", bucket];
}

// macOS thermal pressure as four lamps: nominal · moderate · heavy · trapping, lit up to the level.
@interface PressureLamps : NSView
@property (nonatomic) int lit;
@property (nonatomic, strong) NSColor *color;
@end
@implementation PressureLamps
- (void)drawRect:(NSRect)dirty {
    CGFloat gap = 3, h = NSHeight(self.bounds), w = (NSWidth(self.bounds) - 3 * gap) / 4, y = 0;
    for (int i = 0; i < 4; i++) {
        [(i < _lit ? _color : [NSColor.labelColor colorWithAlphaComponent:0.12]) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(i * (w + gap), y, w, h) xRadius:h / 2 yRadius:h / 2] fill];
    }
}
@end

@interface Gauge : NSView
@property (nonatomic) double fraction;
@property (nonatomic) double markerFraction; // negative: no tick. 0.8 draws the 80% charge-limit mark
@property (nonatomic) double innerFraction;  // negative: none. A secondary reading as a thin line inside the bar
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *metricLabel;
@property (nonatomic, strong) NSColor *lossColor;   // nil: plain track. Tints the track past the fill: what's missing
@end
@implementation Gauge
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _markerFraction = -1;
        _innerFraction = -1;
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityProgressIndicatorRole];
        [self setAccessibilityMinValue:@0.0];
        [self setAccessibilityMaxValue:@1.0];
        [self setAccessibilityLabel:@"Progress"];
    }
    return self;
}
- (void)setFraction:(double)fraction {
    _fraction = MIN(1.0, MAX(0.0, fraction));
    [self setAccessibilityValue:@(_fraction)];
    self.needsDisplay = YES;
}
- (void)setColor:(NSColor *)color { _color = color; self.needsDisplay = YES; }
- (void)setMarkerFraction:(double)markerFraction { _markerFraction = markerFraction; self.needsDisplay = YES; }
- (void)setInnerFraction:(double)innerFraction { _innerFraction = innerFraction; self.needsDisplay = YES; }
- (void)setLossColor:(NSColor *)lossColor { _lossColor = lossColor; self.needsDisplay = YES; }
- (void)setMetricLabel:(NSString *)metricLabel {
    _metricLabel = [metricLabel copy];
    [self setAccessibilityLabel:_metricLabel.length ? _metricLabel : @"Progress"];
    [self setAccessibilityIdentifier:_metricLabel.length
        ? [@"gauge." stringByAppendingString:_metricLabel] : @"gauge.progress"];
}
- (void)drawRect:(NSRect)d {
    NSRect r = self.bounds; CGFloat rad = r.size.height/2;
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    if (self.lossColor && self.fraction < 0.98) {
        [[self.lossColor colorWithAlphaComponent:0.3] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    }
    NSRect f = r; f.size.width = MAX(r.size.height, r.size.width*self.fraction);
    [(self.color ?: NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
    if (self.innerFraction >= 0) {
        // Cursor's API pool rides inside the Grok bar: same scale, visibly secondary.
        CGFloat inset = 2, len = MAX(2, (NSWidth(r) - inset) * MIN(self.innerFraction, 1.0) - inset);
        [[NSColor.labelColor colorWithAlphaComponent:0.85] setFill];
        NSRectFill(NSMakeRect(NSMinX(r) + inset, NSMidY(r) - 1, len, 2));
    }
    if (self.markerFraction >= 0 && self.markerFraction <= 1) {
        CGFloat tickW = 1.5;
        CGFloat x = NSMinX(r) + NSWidth(r) * self.markerFraction - tickW / 2.0;
        [NSColor.labelColor setFill];
        NSRectFill(NSMakeRect(x, NSMinY(r), tickW, NSHeight(r)));
    }
}
@end

// Where the charger's watts go, on one bar: system draw (grey), then charge into the
// battery (green). When the battery tops up a short charger, its share is orange past
// the input. The empty track is unused charger headroom.
@interface PowerFlowGauge : NSView
@property (nonatomic) double scaleWatts, systemWatts, batteryWatts, inputWatts;
@end
@implementation PowerFlowGauge
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setAccessibilityElement:YES];
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"Power flow";
    }
    return self;
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat rad = NSHeight(r) / 2;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    double scale = MAX(_scaleWatts, MAX(_systemWatts, _inputWatts));
    if (scale <= 0) return;
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    __block CGFloat x = NSMinX(r);
    void (^segment)(double, NSColor *) = ^(double watts, NSColor *color) {
        if (watts <= 0) return;
        CGFloat w = NSWidth(r) * MIN(watts / scale, 1.0);
        [color setFill]; NSRectFill(NSMakeRect(x, NSMinY(r), w, NSHeight(r)));
        x += w;
    };
    if (_batteryWatts >= 0) {
        segment(_systemWatts, NSColor.systemGrayColor);
        x += _systemWatts > 0 && _batteryWatts > 0 ? 1 : 0;   // hairline between flows
        segment(_batteryWatts, NSColor.systemGreenColor);
    } else {
        segment(MIN(_inputWatts, _systemWatts), NSColor.systemGrayColor);
        x += 1;
        segment(-_batteryWatts, NSColor.systemOrangeColor);
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

// Duration labels are centred on the actual target coordinates, including 0/100%.
// Side room belongs to the overlay, not the gauge: endpoints can overhang the bar.
static const CGFloat kBatteryForecastSideRoom = 14;
@interface BatteryForecastView : NSView
@property (nonatomic) BatteryForecast forecast;
@property (nonatomic, copy) NSString *thresholdText, *endpointText;
- (NSRect)labelRect:(BOOL)threshold;
- (NSDictionary *)labelAttributes;
@end
@implementation BatteryForecastView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (CGFloat)targetX:(BOOL)threshold {
    CGFloat gaugeWidth = NSWidth(self.bounds) - 2 * kBatteryForecastSideRoom;
    return kBatteryForecastSideRoom + gaugeWidth *
        (threshold ? _forecast.thresholdPercent : _forecast.endpointPercent) / 100.0;
}
- (NSDictionary *)labelAttributes {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium];
    NSMutableDictionary *attrs = [@{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.labelColor} mutableCopy];
    CGFloat pairWidth = ([_thresholdText sizeWithAttributes:attrs].width + [_endpointText sizeWithAttributes:attrs].width) / 2;
    CGFloat gap = fabs([self targetX:YES] - [self targetX:NO]) - pairWidth;
    // Only two long neighbouring readings need slightly tighter tracking. Keep
    // the font size and exact centres; never displace a label to make it fit.
    if (_thresholdText.length && _endpointText.length && gap < 1.5) {
        CGFloat characters = (_thresholdText.length + _endpointText.length) / 2.0;
        attrs[NSKernAttributeName] = @(-MIN(0.9, (1.5 - gap) / characters));
    }
    return attrs;
}
- (NSRect)labelRect:(BOOL)threshold {
    NSString *text = threshold ? _thresholdText : _endpointText;
    CGFloat width = MAX(1, [text sizeWithAttributes:[self labelAttributes]].width);
    return NSMakeRect([self targetX:threshold] - width / 2, 18, width, 12);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSDictionary *attrs = [self labelAttributes];
    for (int i=0; i<2; i++) {
        BOOL threshold = i == 0;
        NSString *text = threshold ? _thresholdText : _endpointText;
        CGFloat anchor = [self targetX:threshold];
        NSRect rect = [self labelRect:threshold];
        // A straight tick shares the label's centre, with no sideways leader.
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(anchor, 9)]; [tick lineToPoint:NSMakePoint(anchor, 17)];
        [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.9] setStroke]; tick.lineWidth = 3; [tick stroke];
        [NSColor.labelColor setStroke]; tick.lineWidth = 1; [tick stroke];
        [text drawInRect:rect withAttributes:attrs];
    }
}
@end

// The airspeed-tape trend vectors on the battery bar, both from the charge level: green
// right for what the charger brings in, orange left for what the Mac draws, each an
// hour's worth. Whichever is longer is winning; the forecast times sit on that side.
@interface TrendArrow : NSView
@property (nonatomic) double from, to, drawTo;   // bar fractions; to = charger in, drawTo = draw (NAN = none)
@end
@implementation TrendArrow
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) _drawTo = NAN;
    return self;
}
- (void)setFrom:(double)from { _from = from; self.needsDisplay = YES; }
- (void)setTo:(double)to { _to = to; self.needsDisplay = YES; }
- (void)setDrawTo:(double)drawTo { _drawTo = drawTo; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    // Both shown: charger in rides just above the centre line, draw just below.
    BOOL both = fabs(_to - _from) > 0.005 && isfinite(_drawTo) && fabs(_drawTo - _from) > 0.005;
    [self drawVectorTo:_to lift:both ? 2.5 : 0];
    [self drawVectorTo:_drawTo lift:both ? -2.5 : 0];
}
- (void)drawVectorTo:(double)target lift:(CGFloat)lift {
    if (!isfinite(target)) return;
    CGFloat inset = 5, w = NSWidth(self.bounds) - 2 * inset, y = NSMidY(self.bounds) + lift;
    CGFloat a = inset + w * _from, b = inset + w * target;
    if (fabs(b - a) < 1) return;
    BOOL up = b > a;
    CGFloat dir = up ? 1 : -1;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow appendBezierPathWithRect:NSMakeRect(MIN(a, b - dir), y - 1, fabs(b - dir - a), 2)];
    [arrow moveToPoint:NSMakePoint(b + dir * 4, y)];
    [arrow lineToPoint:NSMakePoint(b - dir * 1, y + 3.5)];
    [arrow lineToPoint:NSMakePoint(b - dir * 1, y - 3.5)];
    [arrow closePath];
    // Riding on the bar, a thin halo in the panel's own colour keeps it legible over
    // the green fill and the grey track alike.
    [NSGraphicsContext saveGraphicsState];
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.9] setStroke];
    arrow.lineWidth = 2; arrow.lineJoinStyle = NSLineJoinStyleRound; [arrow stroke];
    [NSGraphicsContext restoreGraphicsState];
    [(up ? NSColor.systemGreenColor : NSColor.systemOrangeColor) setFill];
    [arrow fill];
}
@end

static NSColor *AIQuotaColor(double fraction) {
    if (fraction <= 0.15) return NSColor.systemRedColor;
    if (fraction <= 0.35) return NSColor.systemOrangeColor;
    if (fraction <= 0.60) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return NSColor.systemGreenColor;
}

// Overlay distinct endpoints; use fixed lanes only when they are nearly equal.
static BOOL QuotaFractionsClose(double first, double second) {
    return first >= 0 && second >= 0 && fabs(first-second) <= 0.030000001;
}
static NSColor *ClaudeQuotaColor(double fraction) {
    return fraction > 0.35 ? NSColor.systemGreenColor : AIQuotaColor(fraction);
}
@interface QuotaPairGauge : NSView
@property (nonatomic) double firstFraction, secondFraction; // negative = not reported
@property (nonatomic, copy) NSString *firstLabel, *secondLabel;
@property (nonatomic) BOOL standardQuotaColors, fixedLanes;
@end
@implementation QuotaPairGauge
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _firstFraction = _secondFraction = -1;
        _firstLabel = @"Fable"; _secondLabel = @"Opus";
        [self setAccessibilityElement:YES];
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"Quota remaining";
    }
    return self;
}
- (void)refreshValues {
    NSString *f = _firstFraction < 0 ? @"not reported" : [NSString stringWithFormat:@"%.0f%%", _firstFraction*100];
    NSString *o = _secondFraction < 0 ? @"not reported" : [NSString stringWithFormat:@"%.0f%%", _secondFraction*100];
    self.accessibilityValue = _firstFraction < 0 && !_standardQuotaColors ? [o stringByAppendingString:@" remaining"]   // single weekly figure
        : [NSString stringWithFormat:@"%@ %@, %@ %@ remaining", _firstLabel, f, _secondLabel, o];
    self.needsDisplay = YES;
}
- (void)setFirstFraction:(double)value { _firstFraction = value < 0 ? -1 : MIN(1, MAX(0, value)); [self refreshValues]; }
- (void)setSecondFraction:(double)value { _secondFraction = value < 0 ? -1 : MIN(1, MAX(0, value)); [self refreshValues]; }
- (void)setFirstLabel:(NSString *)value { _firstLabel = [value copy]; [self refreshValues]; }
- (void)setSecondLabel:(NSString *)value { _secondLabel = [value copy]; [self refreshValues]; }
- (void)setStandardQuotaColors:(BOOL)value { _standardQuotaColors = value; [self refreshValues]; }
- (void)setFixedLanes:(BOOL)value { _fixedLanes = value; self.needsDisplay = YES; }
- (NSColor *)quotaColor:(double)value { return _standardQuotaColors ? AIQuotaColor(value) : ClaudeQuotaColor(value); }
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds;
    BOOL lanes = _fixedLanes || QuotaFractionsClose(_firstFraction, _secondFraction);
    CGFloat laneGap = _fixedLanes ? 12 : 1;
    CGFloat laneHeight = MAX(0, (r.size.height-laneGap)/2);
    NSBezierPath *wholeTrack = [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height/2 yRadius:r.size.height/2];
    if (!lanes) { [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [wholeTrack fill]; }
    for (int i=0; i<2; i++) {
        // Draw longer first in overlay mode, but keep the first pool above in lane mode.
        BOOL first = lanes ? i == 0 : (i == 0 ? _firstFraction > _secondFraction : _firstFraction <= _secondFraction);
        double value = first ? _firstFraction : _secondFraction;
        NSRect lane = lanes ? NSMakeRect(r.origin.x, r.origin.y + (first ? laneHeight+laneGap : 0), r.size.width, laneHeight) : r;
        CGFloat radius = lane.size.height/2;
        NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:radius yRadius:radius];
        if (lanes) { [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill]; }
        if (value <= 0) continue;
        [NSGraphicsContext saveGraphicsState]; [track addClip];
        NSRect fill = lane; fill.size.width *= value;
        NSColor *color = [self quotaColor:value];
        // Overlay: the longer fill is drawn first. When both fills would share one colour
        // the longer one is a lighter tint, so the solid part reads "both models have this
        // much" and the tinted extension "only the larger one does" — a one-pixel divider
        // was not legible.
        if (!lanes && i == 0 && _firstFraction > 0 && _secondFraction > 0 && [color isEqual:[self quotaColor:MIN(_firstFraction, _secondFraction)]])
            color = [color colorWithAlphaComponent:0.4];
        [color setFill]; NSRectFill(fill);
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end


// The whole instrument row is the control. hitTest returns self so the labels
// do not eat the click that opens Details.
@interface ClickRow : NSView
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end
@implementation ClickRow
- (NSView *)hitTest:(NSPoint)point {
    // `point` is in the superview's coordinates. The battery symbol is its own control
    // (charge limit). Everything else in the row, including the labels, still opens Details.
    NSPoint inRow = [self convertPoint:point fromView:self.superview];
    if (!NSPointInRect(inRow, self.bounds)) return nil;
    for (NSView *sub in self.subviews) {
        if (![sub.accessibilityIdentifier isEqualToString:@"popover.battery.symbol"]) continue;
        NSPoint inSub = [sub convertPoint:inRow fromView:self];
        if (!NSPointInRect(inSub, sub.bounds)) break;
        return [sub hitTest:inRow] ?: sub;
    }
    return self;
}
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)sendAction {
    if (!self.target || !self.action) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
}
- (void)mouseUp:(NSEvent *)event {
    if (!NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) return;
    [self sendAction];
}
- (BOOL)accessibilityPerformPress {
    [self sendAction];
    return YES;
}
@end

// Compact labels retain their full value. Show native expansion help only when
// their actual text is clipped; ordinary labels still have no hover popup.
// A seed tile. Hovering the tile or its caption shows the cover large with the full title and artist:
// the captions are one line and may clip, and tooltips don't show while a menu-bar app is inactive.
@protocol GBTileHover <NSObject>
- (void)showLarge;
- (void)hideLarge;
@end
@interface GBSeedTile : NSButton <GBTileHover>
@property (nonatomic, strong) NSImage *cover;
@property (nonatomic, copy) NSString *songTitle, *songArtist, *seedKey, *offlineStatus;
- (void)showLarge;
- (void)hideLarge;
- (NSView *)largeCard;
+ (void)closeLarge;
@end
// One large view for all tiles, keyed by seed. A refresh that rebuilds the tiles re-anchors it to the new
// tile instead of closing and reopening it, and its window ignores the mouse so it never takes the hover:
// both had made it flicker (Ian, 1 Nov 2026: "it should be rock solid").
static NSPopover *gSeedLarge;
static NSString *gSeedLargeKey;
static void GBPresentLarge(NSView *anchor, NSString *key, NSView *card) {
    if (!anchor.window || !card) return;
    if (gSeedLarge.shown && [gSeedLargeKey isEqual:key]) {   // same tile: just move it
        [gSeedLarge showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
        return;
    }
    [GBSeedTile closeLarge];
    NSViewController *vc = [NSViewController new];
    vc.view = card;
    gSeedLarge = [NSPopover new];
    gSeedLarge.contentViewController = vc;
    gSeedLarge.behavior = NSPopoverBehaviorApplicationDefined;
    gSeedLarge.animates = NO;
    gSeedLargeKey = [key copy];
    [gSeedLarge showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
    vc.view.window.ignoresMouseEvents = YES;
}
@implementation GBSeedTile
- (void)showLarge {
    if (!self.window || (!self.cover && !self.songTitle.length)) return;
    GBPresentLarge(self, self.seedKey, [self largeCard]);
}
// The cover at 220 pt over the full title and artist.
- (NSView *)largeCard {
    const CGFloat side = 220, pad = 8;
    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    CGFloat y = pad;
    if (self.offlineStatus.length) {
        NSTextField *status = [NSTextField wrappingLabelWithString:self.offlineStatus];
        status.font = [NSFont systemFontOfSize:11];
        status.textColor = NSColor.secondaryLabelColor;
        status.alignment = NSTextAlignmentCenter;
        status.preferredMaxLayoutWidth = side;
        status.frame = NSMakeRect(pad, y, side, ceil([status.cell cellSizeForBounds:NSMakeRect(0, 0, side, 400)].height));
        status.accessibilityIdentifier = @"popover.mix.large.offline";
        [content addSubview:status]; y = NSMaxY(status.frame) + 4;
    }
    NSArray *texts = @[self.songArtist ?: @"", self.songTitle ?: @""];   // built bottom-up
    for (NSUInteger i = 0; i < texts.count; i++) {
        if (![texts[i] length]) continue;
        NSTextField *t = [NSTextField wrappingLabelWithString:texts[i]];
        t.font = i ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:12];
        t.textColor = i ? NSColor.labelColor : NSColor.secondaryLabelColor;
        t.alignment = NSTextAlignmentCenter;
        t.preferredMaxLayoutWidth = side;
        NSSize fit = [t.cell cellSizeForBounds:NSMakeRect(0, 0, side, 400)];
        t.frame = NSMakeRect(pad, y, side, ceil(fit.height));
        t.accessibilityIdentifier = i ? @"popover.mix.large.title" : @"popover.mix.large.artist";
        [content addSubview:t];
        y = NSMaxY(t.frame) + 2;
    }
    if (self.cover) {
        NSImageView *view = [NSImageView imageViewWithImage:self.cover];
        view.imageScaling = NSImageScaleProportionallyUpOrDown;
        view.frame = NSMakeRect(pad, y + 4, side, side);
        view.wantsLayer = YES;
        view.layer.cornerRadius = 6;
        view.layer.masksToBounds = YES;
        view.accessibilityIdentifier = @"popover.mix.cover.large";
        [content addSubview:view];
        y = NSMaxY(view.frame);
    }
    content.frame = NSMakeRect(0, 0, side + 2 * pad, y + pad);
    return content;
}
- (void)hideLarge {
    if ([gSeedLargeKey isEqual:self.seedKey]) [GBSeedTile closeLarge];
}
+ (void)closeLarge { [gSeedLarge close]; gSeedLarge = nil; gSeedLargeKey = nil; }
@end

@class Controller;

@protocol GBMixPreloadHovering <NSObject>
- (void)schedulePreloadHover:(NSString *)key;
- (void)cancelPreloadHover;
@end

// Clicks pass through to the tile; only the hover is caught, over the tile and both caption lines.
@interface GBSeedHover : NSView
@property (nonatomic, weak) id<GBTileHover> tile;
@property (nonatomic, copy) NSString *preloadKey;
@property (nonatomic, weak) id<GBMixPreloadHovering> controller;
@end
@implementation GBSeedHover
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (BOOL)pointerInside {
    if (!self.window) return NO;
    NSPoint p = [self convertPoint:[self.window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil];
    return NSPointInRect(p, self.bounds);
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.pointerInside) [self.tile showLarge];   // rebuilt under the pointer: keep the view, re-anchored
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    [self.tile showLarge];
    if (self.preloadKey.length && self.controller) [self.controller schedulePreloadHover:self.preloadKey];
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.pointerInside) {
        [self.tile hideLarge];
        if (self.controller) [self.controller cancelPreloadHover];
    }
}
@end

// This week's count, drawn on the station tile. The digit is the instrument; "new picks" is the label.
@interface GBCountBadge : NSView
@property (nonatomic) NSInteger count;
@end
@implementation GBCountBadge
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 0.5, 0.5)] fill];
    NSString *text = [NSString stringWithFormat:@"%ld", (long)self.count];
    NSFont *font = [NSFont systemFontOfSize:self.count > 9 ? 8 : 9 weight:NSFontWeightBold];
    NSDictionary *attrs = @{NSFontAttributeName: font,
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.78 green:0.28 blue:0.02 alpha:1]};
    NSSize size = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint((NSWidth(self.bounds) - size.width) / 2.0,
                                  (NSHeight(self.bounds) - size.height) / 2.0 - 0.5) withAttributes:attrs];
}
@end

// Orange station tile. Hover lists this week's picks.
@interface GBStationTile : NSButton <GBTileHover>
@property (nonatomic, copy) NSString *seedKey, *offlineStatus;
@property (nonatomic, copy) NSArray<NSDictionary *> *picks;
- (NSView *)largeCard;
@end
@implementation GBStationTile
- (void)showLarge {
    if (!self.window) return;
    GBPresentLarge(self, self.seedKey ?: @"station", [self largeCard]);
}
- (void)hideLarge {
    if ([gSeedLargeKey isEqual:self.seedKey]) [GBSeedTile closeLarge];
}
- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [super mouseDown:event];
}
- (NSView *)largeCard {
    const CGFloat width = 220, pad = 8;
    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:@{@"text": @"New music", @"secondary": @NO, @"id": @"popover.mix.station.large.title"}];
    if (self.offlineStatus.length) [lines addObject:@{@"text": self.offlineStatus, @"secondary": @YES, @"id": @"popover.mix.station.large.offline"}];
    NSUInteger i = 0;
    for (NSDictionary *pick in self.picks) {
        if (![pick isKindOfClass:NSDictionary.class] || i >= 8) break;
        NSString *title = [pick[@"title"] isKindOfClass:NSString.class] ? pick[@"title"] : @"";
        NSString *reason = [pick[@"reason"] isKindOfClass:NSString.class] ? pick[@"reason"] : @"";
        if (!title.length) continue;
        [lines addObject:@{@"text": title, @"secondary": @NO,
                           @"id": [NSString stringWithFormat:@"popover.mix.station.pick.title.%lu", (unsigned long)i]}];
        if (reason.length)
            [lines addObject:@{@"text": reason, @"secondary": @YES,
                               @"id": [NSString stringWithFormat:@"popover.mix.station.pick.reason.%lu", (unsigned long)i]}];
        i++;
    }
    CGFloat y = pad;
    for (NSDictionary *line in lines.reverseObjectEnumerator) {
        BOOL secondary = [line[@"secondary"] boolValue];
        NSTextField *t = [NSTextField wrappingLabelWithString:line[@"text"]];
        t.font = secondary ? [NSFont systemFontOfSize:11] : [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        t.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
        t.alignment = NSTextAlignmentLeft;
        t.preferredMaxLayoutWidth = width;
        t.frame = NSMakeRect(pad, y, width, MAX(secondary ? 14 : 16, ceil([t.cell cellSizeForBounds:NSMakeRect(0, 0, width, 400)].height)));
        t.accessibilityIdentifier = line[@"id"];
        [content addSubview:t];
        y = NSMaxY(t.frame) + (secondary ? 6 : 1);
    }
    content.frame = NSMakeRect(0, 0, width + 2 * pad, y + pad);
    return content;
}
@end

static NSImage *StationTileImage(BOOL dimmed) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"dot.radiowaves.left.and.right" accessibilityDescription:nil];
    if (!symbol) symbol = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right" accessibilityDescription:nil];
    symbol = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightSemibold]] ?: symbol;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(54, 54) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4];
        if (dimmed) {
            [[NSColor colorWithWhite:0.5 alpha:0.22] setFill];
            [path fill];
        } else {
            NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.95 green:0.33 blue:0.04 alpha:1]
                                                                  endingColor:[NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.22 alpha:1]];
            [gradient drawInBezierPath:path angle:90];
        }
        if (symbol) {
            NSSize size = symbol.size.width > 1 ? symbol.size : NSMakeSize(22, 22);
            CGFloat side = MIN(26, MAX(size.width, size.height));
            NSRect box = NSMakeRect((54 - side) / 2.0, (54 - side) / 2.0, side, side);
            // Mask the symbol with a flat colour. imageWithTintColor: is not on the macOS 13 SDK.
            NSImage *mark = [NSImage imageWithSize:box.size flipped:NO drawingHandler:^BOOL(NSRect r) {
                [(dimmed ? NSColor.tertiaryLabelColor : NSColor.whiteColor) setFill];
                NSRectFill(r);
                [symbol drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationDestinationIn fraction:1];
                return YES;
            }];
            [mark drawInRect:box fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        }
        return YES;
    }];
    image.template = NO;
    return image;
}

@interface GBRecoverableTextField : NSTextField
- (void)updateClippedTextHelp;
@end
@implementation GBRecoverableTextField
- (void)updateClippedTextHelp {
    if (!self.cell) return;
    NSLineBreakMode mode = self.lineBreakMode;
    BOOL truncates = mode == NSLineBreakByTruncatingTail || mode == NSLineBreakByTruncatingMiddle ||
                     mode == NSLineBreakByTruncatingHead || mode == NSLineBreakByClipping;
    BOOL clipped = truncates && self.stringValue.length &&
        self.attributedStringValue.size.width + 4 > NSWidth(self.bounds);
    if (self.maximumNumberOfLines > 1 && self.stringValue.length && self.font)   // a wrapping label clips past its last line
        clipped = NSHeight([self.stringValue boundingRectWithSize:NSMakeSize(NSWidth(self.bounds) - 4, 1000)
                                                          options:NSStringDrawingUsesLineFragmentOrigin
                                                       attributes:@{NSFontAttributeName: self.font}]) > NSHeight(self.bounds) + 0.5;
    [super setToolTip:clipped ? self.stringValue : nil];
}
- (void)setStringValue:(NSString *)value { [super setStringValue:value]; [self updateClippedTextHelp]; }
- (void)setAttributedStringValue:(NSAttributedString *)value { [super setAttributedStringValue:value]; [self updateClippedTextHelp]; }
- (void)setFont:(NSFont *)font { [super setFont:font]; [self updateClippedTextHelp]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self updateClippedTextHelp]; }
- (void)setLineBreakMode:(NSLineBreakMode)mode { [super setLineBreakMode:mode]; [self updateClippedTextHelp]; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    if (self.selectable) return [super menuForEvent:event];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *copy = [menu addItemWithTitle:@"Copy full text" action:@selector(copyFullText:) keyEquivalent:@""];
    copy.target = self;
    return menu;
}
- (void)copyFullText:(id)sender {
    (void)sender;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.stringValue forType:NSPasteboardTypeString];
}
@end

@interface FlippedView : NSView
// The section heading the next row belongs under, and the per-identifier occurrence counts
// used to disambiguate genuine duplicates. Together these give a row a stable identity that
// does not move when another row is inserted above it.
@property (nonatomic, copy) NSString *accessibilitySection;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *accessibilityIdentifierCounts;
@end
@implementation FlippedView - (BOOL)isFlipped { return YES; } @end

@interface GBDetailsTabs : NSTabViewController
@property (copy) dispatch_block_t activitySelected;
@property (copy) dispatch_block_t otherSelected;
@property (copy) dispatch_block_t storageSelected;
@end
@implementation GBDetailsTabs
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
    [super tabView:tabView didSelectTabViewItem:item];
    if ([item.identifier isEqual:@"activity"]) { if (self.activitySelected) self.activitySelected(); }
    else if ([item.identifier isEqual:@"storage"]) { if (self.storageSelected) self.storageSelected(); }
    else if (self.otherSelected) self.otherSelected();
}
@end

// Opaque, appearance-adaptive backing for the popover. The default NSPopover material is
// translucent (behind-window vibrancy), so a dark or saturated window behind the menu bar
// bleeds through and washes out the fixed semantic text colors toward the bottom of the
// panel. Fill an opaque background so contrast holds regardless of the backdrop. Drawn in
// drawRect: — not a CALayer background color — so windowBackgroundColor re-resolves under
// the current Light/Dark appearance on every redraw instead of being frozen at assignment.
//
// AppKit does not clip drawRect: to a view's bounds unless the view is layer-backed
// (clipsToBounds itself is macOS 14+, and the deployment target is 13.0). As the full-size
// root that is harmless, but any SHORT instance of this view must set wantsLayer, or its
// fill will paint over whatever sits above it. See the popover footer.
// A pill whose own fill carries its on/off state. A push button's bezelColor draws only
// while its window is key, and the popover belongs to a background app that never
// activates — so a tinted bezel never appeared there, and Keep Awake looked dead.
@interface PillButton : NSButton
@property (nonatomic, strong) NSColor *onColor;
@end
@implementation PillButton
- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    CGFloat alpha = self.isHighlighted ? 0.16 : 0.08;
    [(on ? self.onColor : [NSColor.labelColor colorWithAlphaComponent:alpha]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    if (on && self.isHighlighted) {
        [[NSColor.blackColor colorWithAlphaComponent:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    [super drawRect:dirtyRect];
}
@end

// Left click cycles outputs. Right click (and Option-click, handled in the action)
// opens the full device menu.
// The slider keeps the UID that the user actually saw; never redirect a drag to a new device.
@interface GBOutputVolumeSlider : NSSlider
@property (nonatomic, copy) NSString *outputUID;
@end
@implementation GBOutputVolumeSlider @end
@interface GBPickerChevron : NSImageView @end
@implementation GBPickerChevron
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@interface OutputCycleButton : NSButton
@end
@implementation OutputCycleButton
- (void)rightMouseDown:(NSEvent *)event {
    (void)event;
    if (self.target && self.action) [self sendAction:self.action to:self.target];
}
@end

@interface PopoverRootView : FlippedView @end
@implementation PopoverRootView
- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor set];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
}
// A dynamic system color only re-resolves when something redraws. Nothing else marks this
// view dirty on a live Light/Dark switch.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

// NSAccessibilityHeadingRole is API_AVAILABLE(macos(26.0)), so an older SDK cannot even name
// it and the file will not compile there. Guard on the SDK as well as the runtime version,
// and speak the heading through a label wherever the role is unavailable.
static void ApplyHeadingAccessibility(NSTextField *heading, NSString *title) {
#if defined(MAC_OS_VERSION_26_0) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_26_0
    if (@available(macOS 26.0, *)) {
        heading.accessibilityRole = NSAccessibilityHeadingRole;
        return;
    }
#endif
    heading.accessibilityLabel = [NSString stringWithFormat:@"%@ section heading", title];
}

// Returns `base`, or base#2, base#3 … for repeat uses within one detail root. `namespace`
// keeps the section counter from colliding with the identifier counter.
static NSString *DisambiguatedDetailKey(FlippedView *root, NSString *ns, NSString *base) {
    if (!root) return base;
    if (!root.accessibilityIdentifierCounts) root.accessibilityIdentifierCounts = [NSMutableDictionary dictionary];
    NSString *counterKey = [NSString stringWithFormat:@"%@|%@", ns, base];
    NSInteger n = root.accessibilityIdentifierCounts[counterKey].integerValue + 1;
    root.accessibilityIdentifierCounts[counterKey] = @(n);
    return n > 1 ? [base stringByAppendingFormat:@"#%ld", (long)n] : base;
}

// An accessibility identifier must name the field, not its position. These were built from a
// running build-order counter, so inserting one row renamed every row below it and focus
// restoration — which matches identifiers exactly — landed on the wrong field. Key off the
// enclosing section instead, whose key the caller supplies as a stable semantic path
// ("local-history.codex.models"). Nothing here may depend on how many siblings were built
// first, or a conditional section appearing elsewhere would rename these rows again.
static NSString *DetailIdentifier(NSView *root, NSString *kind, NSString *label) {
    FlippedView *detailRoot = [root isKindOfClass:FlippedView.class] ? (FlippedView *)root : nil;
    NSString *scope = root.accessibilityIdentifier ?: @"details";
    NSString *section = detailRoot.accessibilitySection;
    NSString *base = section.length
        ? [NSString stringWithFormat:@"%@.%@.%@.%@", scope, kind, section, label.lowercaseString]
        : [NSString stringWithFormat:@"%@.%@.%@", scope, kind, label.lowercaseString];
    return DisambiguatedDetailKey(detailRoot, @"id", base);
}

static NSView *ViewWithAccessibilityIdentifier(NSView *root, NSString *identifier) {
    if (!root || !identifier.length) return nil;
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (NSView *child in root.subviews) {
        NSView *match = ViewWithAccessibilityIdentifier(child, identifier);
        if (match) return match;
    }
    return nil;
}

static NSView *ViewOwningAccessibilityElement(NSView *root, id element) {
    if (!root || !element) return nil;
    if (root == element) return root;
    if ([root isKindOfClass:NSControl.class] && ((NSControl *)root).cell == element) return root;
    for (NSView *child in root.subviews) {
        NSView *owner = ViewOwningAccessibilityElement(child, element);
        if (owner) return owner;
    }
    return nil;
}

static NSArray<NSNumber *> *SubviewPathToView(NSView *root, NSView *target) {
    if (!root || !target) return nil;
    if (root == target) return @[];
    for (NSUInteger i = 0; i < root.subviews.count; i++) {
        NSArray<NSNumber *> *tail = SubviewPathToView(root.subviews[i], target);
        if (!tail) continue;
        NSMutableArray<NSNumber *> *path = [NSMutableArray arrayWithObject:@(i)];
        [path addObjectsFromArray:tail];
        return path;
    }
    return nil;
}

static NSView *ViewAtSubviewPath(NSView *root, NSArray<NSNumber *> *path) {
    NSView *view = root;
    for (NSNumber *indexValue in path) {
        NSUInteger index = indexValue.unsignedIntegerValue;
        if (index >= view.subviews.count) return nil;
        view = view.subviews[index];
    }
    return view;
}

// Most refreshes change values, not structure. Updating a compatible hierarchy in
// place keeps the same AppKit/accessibility objects alive, so VoiceOver focus, keyboard
// focus, selections, and scroll state survive the 15-second live refresh. Structural
// changes (a volume/window/row appearing or disappearing) fall back to replacement plus
// the identifier-based restoration path below.
static BOOL ViewTreesCompatible(NSView *existing, NSView *fresh) {
    if (!existing || !fresh || existing.class != fresh.class) return NO;
    // Matching class and subview counts do not make two rows the same row. If one section
    // gains a row while another loses one, the flat counts still line up and an in-place
    // update would silently repoint a focused field at different data — the identifier
    // moves with it, so nothing downstream can notice. Compare identity as well as shape.
    NSString *existingIdentifier = existing.accessibilityIdentifier;
    NSString *freshIdentifier = fresh.accessibilityIdentifier;
    if (existingIdentifier != freshIdentifier && ![existingIdentifier isEqualToString:freshIdentifier])
        return NO;
    if ([existing isKindOfClass:NSScrollView.class]) {
        NSView *existingDocument = ((NSScrollView *)existing).documentView;
        NSView *freshDocument = ((NSScrollView *)fresh).documentView;
        return ViewTreesCompatible(existingDocument, freshDocument);
    }
    NSArray<NSView *> *existingSubviews = existing.subviews;
    NSArray<NSView *> *freshSubviews = fresh.subviews;
    if (existingSubviews.count != freshSubviews.count) return NO;
    for (NSUInteger i = 0; i < existingSubviews.count; i++)
        if (!ViewTreesCompatible(existingSubviews[i], freshSubviews[i])) return NO;
    return YES;
}

static void ApplyFreshViewState(NSView *existing, NSView *fresh) {
    existing.frame = fresh.frame;
    existing.autoresizingMask = fresh.autoresizingMask;
    existing.hidden = fresh.hidden;
    existing.alphaValue = fresh.alphaValue;
    existing.identifier = fresh.identifier;
    existing.accessibilityIdentifier = fresh.accessibilityIdentifier;
    existing.accessibilityLabel = fresh.accessibilityLabel;
    existing.accessibilityHelp = fresh.accessibilityHelp;
    existing.accessibilityRole = fresh.accessibilityRole;

    if ([existing isKindOfClass:NSTextField.class]) {
        NSTextField *old = (NSTextField *)existing, *new = (NSTextField *)fresh;
        old.font = new.font;
        old.textColor = new.textColor;
        // textColor paints the whole string. Put the attributed value back last so the
        // system row keeps its per-word colours across an in-place refresh.
        if (![old.attributedStringValue isEqualToAttributedString:new.attributedStringValue])
            old.attributedStringValue = new.attributedStringValue;
        else if (![old.stringValue isEqualToString:new.stringValue]) old.stringValue = new.stringValue;
        old.alignment = new.alignment;
        old.lineBreakMode = new.lineBreakMode;
        old.maximumNumberOfLines = new.maximumNumberOfLines;
        if (old.selectable != new.selectable) old.selectable = new.selectable;
    } else if ([existing isKindOfClass:NSButton.class]) {
        NSButton *old = (NSButton *)existing, *new = (NSButton *)fresh;
        old.title = new.title;
        // A pill's icon carries its state (play ↔ pause, cup vs tortoise); without these
        // an in-place refresh kept the old glyph and colour behind a new label.
        if (new.attributedTitle.length && ![old.attributedTitle isEqual:new.attributedTitle])
            old.attributedTitle = new.attributedTitle;
        old.image = new.image;
        old.imagePosition = new.imagePosition;
        old.target = new.target;
        old.action = new.action;
        old.enabled = new.enabled;
        old.state = new.state;
        if ([old isKindOfClass:NSPopUpButton.class] && [new isKindOfClass:NSPopUpButton.class]) {
            NSPopUpButton *a=(NSPopUpButton *)old, *b=(NSPopUpButton *)new;
            if (![a.itemTitles isEqual:b.itemTitles] || ![[a.itemArray valueForKey:@"representedObject"] isEqual:[b.itemArray valueForKey:@"representedObject"]]) a.menu=b.menu;
            [a selectItemAtIndex:b.indexOfSelectedItem];
        }
        old.contentTintColor = new.contentTintColor;
        old.alphaValue = new.alphaValue;
        if (new.wantsLayer && old.layer && new.layer) {   // a cover tile's outline marks the playing seed
            old.layer.borderWidth = new.layer.borderWidth;
            old.layer.borderColor = new.layer.borderColor;
            old.layer.backgroundColor = new.layer.backgroundColor;   // placeholder grey goes once the cover lands
        }
        old.imageScaling = new.imageScaling;
        if ([old isKindOfClass:GBSeedTile.class] && [new isKindOfClass:GBSeedTile.class])
        {
            ((GBSeedTile *)old).cover = ((GBSeedTile *)new).cover;
            ((GBSeedTile *)old).songTitle = ((GBSeedTile *)new).songTitle;
            ((GBSeedTile *)old).songArtist = ((GBSeedTile *)new).songArtist;
            ((GBSeedTile *)old).seedKey = ((GBSeedTile *)new).seedKey;
        }
        if ([old isKindOfClass:PillButton.class] && [new isKindOfClass:PillButton.class])
            ((PillButton *)old).onColor = ((PillButton *)new).onColor;
        old.needsDisplay = YES;
    } else if ([existing isKindOfClass:NSSlider.class]) {
        // Sliders (seek, volume) carry their reading in the value; leave it alone mid-drag.
        NSSlider *old = (NSSlider *)existing, *new = (NSSlider *)fresh;
        old.minValue = new.minValue; old.maxValue = new.maxValue;
        if (!(NSEvent.pressedMouseButtons & 1)) old.doubleValue = new.doubleValue;
        old.enabled = new.enabled;
        old.trackFillColor = new.trackFillColor;
        old.target = new.target; old.action = new.action;
        if ([old isKindOfClass:GBOutputVolumeSlider.class] && [new isKindOfClass:GBOutputVolumeSlider.class] && !(NSEvent.pressedMouseButtons & 1))
            ((GBOutputVolumeSlider *)old).outputUID = ((GBOutputVolumeSlider *)new).outputUID;
    } else if ([existing isKindOfClass:NSSwitch.class]) {
        // The routing switch (addAudioRoutesTo:): its state is the rule's.
        NSSwitch *old = (NSSwitch *)existing, *new = (NSSwitch *)fresh;
        old.state = new.state;
        old.target = new.target; old.action = new.action; old.enabled = new.enabled;
    } else if ([existing isKindOfClass:NSSegmentedControl.class]) {
        NSSegmentedControl *old = (NSSegmentedControl *)existing, *new = (NSSegmentedControl *)fresh;
        old.selectedSegment = new.selectedSegment;
        old.target = new.target; old.action = new.action; old.enabled = new.enabled;
    } else if ([existing isKindOfClass:NSImageView.class]) {
        NSImageView *old = (NSImageView *)existing, *new = (NSImageView *)fresh;
        old.image = new.image;
        old.contentTintColor = new.contentTintColor;
    } else if ([existing isKindOfClass:QuotaPairGauge.class]) {
        QuotaPairGauge *old = (QuotaPairGauge *)existing, *new = (QuotaPairGauge *)fresh;
        old.standardQuotaColors = new.standardQuotaColors;
        old.fixedLanes = new.fixedLanes;
        old.firstLabel = new.firstLabel; old.secondLabel = new.secondLabel;
        old.firstFraction = new.firstFraction; old.secondFraction = new.secondFraction;
    } else if ([existing isKindOfClass:Gauge.class]) {
        Gauge *old = (Gauge *)existing, *new = (Gauge *)fresh;
        old.fraction = new.fraction;
        old.markerFraction = new.markerFraction;
        old.innerFraction = new.innerFraction;
        old.color = new.color;
        old.metricLabel = new.metricLabel;
        old.accessibilityIdentifier = new.accessibilityIdentifier;
        [old setAccessibilityElement:new.isAccessibilityElement];
    } else if ([existing isKindOfClass:BatteryForecastView.class]) {
        BatteryForecastView *old = (BatteryForecastView *)existing, *new = (BatteryForecastView *)fresh;
        old.forecast = new.forecast; old.thresholdText = new.thresholdText; old.endpointText = new.endpointText;
        old.needsDisplay = YES;
    } else if ([existing isKindOfClass:TrendArrow.class]) {
        TrendArrow *old = (TrendArrow *)existing, *new = (TrendArrow *)fresh;
        old.from = new.from; old.to = new.to; old.drawTo = new.drawTo;
    } else if ([existing isKindOfClass:PowerFlowGauge.class]) {
        PowerFlowGauge *old = (PowerFlowGauge *)existing, *new = (PowerFlowGauge *)fresh;
        old.scaleWatts = new.scaleWatts; old.systemWatts = new.systemWatts;
        old.batteryWatts = new.batteryWatts; old.inputWatts = new.inputWatts;
        old.needsDisplay = YES;
    } else if ([existing isKindOfClass:NSBox.class]) {
        ((NSBox *)existing).boxType = ((NSBox *)fresh).boxType;
    }

    if ([existing isKindOfClass:NSScrollView.class]) {
        NSScrollView *old = (NSScrollView *)existing, *new = (NSScrollView *)fresh;
        old.hasVerticalScroller = new.hasVerticalScroller;
        old.autohidesScrollers = new.autohidesScrollers;
        old.drawsBackground = new.drawsBackground;
        old.backgroundColor = new.backgroundColor;
        ApplyFreshViewState(old.documentView, new.documentView);
        return;
    }
    NSArray<NSView *> *existingSubviews = existing.subviews;
    NSArray<NSView *> *freshSubviews = fresh.subviews;
    for (NSUInteger i = 0; i < existingSubviews.count; i++)
        ApplyFreshViewState(existingSubviews[i], freshSubviews[i]);
}

static BOOL ReconcileViewTree(NSView *existing, NSView *fresh) {
    if (!ViewTreesCompatible(existing, fresh)) return NO;
    ApplyFreshViewState(existing, fresh);
    return YES;
}

static NSScrollView *FirstScrollView(NSView *root) {
    if ([root isKindOfClass:NSScrollView.class]) return (NSScrollView *)root;
    for (NSView *child in root.subviews) {
        NSScrollView *scroll = FirstScrollView(child);
        if (scroll) return scroll;
    }
    return nil;
}

#pragma mark - bar image

// Two glyphs drawn side by side as one image, centred vertically (Keep Awake + Low Power).
static NSImage *GlyphPair(NSImage *a, NSImage *b) {
    if (!a || !b) return a ?: b;
    CGFloat gap = 3, h = MAX(a.size.height, b.size.height);
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(a.size.width + gap + b.size.width, h)];
    [out lockFocus];
    [a drawInRect:NSMakeRect(0, (h - a.size.height) / 2, a.size.width, a.size.height)];
    [b drawInRect:NSMakeRect(a.size.width + gap, (h - b.size.height) / 2, b.size.width, b.size.height)];
    [out unlockFocus];
    out.template = NO;
    return out;
}
static NSImage *TintedSymbol(NSString *name, double varValue, CGFloat pt, NSColor *color) {
    NSImage *img = varValue >= 0
        ? [NSImage imageWithSystemSymbolName:name variableValue:varValue accessibilityDescription:nil]
        : [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt
                                                                                           weight:NSFontWeightRegular]];
    if (!img) return nil;
    NSImage *out = [[NSImage alloc] initWithSize:img.size];
    [out lockFocus];
    [color set];
    NSRect r = (NSRect){.size = img.size};
    [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
    [out unlockFocus];
    out.template = NO;
    return out;
}

// Menu-bar SF Symbol at ~13pt, shrunk until it is no wider than the glyph it replaces
// (the old drive silhouette was 17pt, the old battery 24pt). The bar must not grow.
static NSImage *BarFittedSymbol(NSString *name, NSColor *color, CGFloat maxWidth) {
    NSImage *image = nil;
    for (CGFloat pt = 13; pt >= 8; pt -= 0.5) {
        image = TintedSymbol(name, -1, pt, color);
        if (!image || image.size.width <= maxWidth + 0.01) break;
    }
    return image;
}

// Largest point size whose symbol is no wider than maxWidth. The battery glyph is wider
// than the other lead symbols; drawing it at 22pt and letting the button scale it down
// smears the badge.
static CGFloat FittedSymbolPointSize(NSString *name, CGFloat maxPoint, CGFloat maxWidth) {
    CGFloat pt = maxPoint;
    for (; pt >= 8; pt -= 0.5) {
        NSImage *img = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt
                                                                                          weight:NSFontWeightRegular]];
        if (!img || img.size.width <= maxWidth + 0.01) break;
    }
    return pt;
}

// Bolt while energy is arriving (orange when the charger falls short of the load), pause
// while a plugged-in charge is stalled.
// Held and discharging keep the plain glyph. The badge is drawn in the glyph's own
// colour inside a knocked-out halo, so it reads at menu-bar size without widening the image.
static NSImage *BatteryGlyphWithBadge(NSImage *glyph, PowerFlow flow, NSColor *color) {
    if (!glyph || glyph.size.width < 1 || glyph.size.height < 1) return glyph;
    NSString *badgeName = nil;
    if (flow == PowerFlowCharging || flow == PowerFlowShort) badgeName = @"bolt.fill";
    else if (flow == PowerFlowPaused) badgeName = @"pause.fill";
    if (!badgeName) return glyph;
    NSImage *mark = [NSImage imageWithSystemSymbolName:badgeName accessibilityDescription:nil];
    if (!mark) return glyph;
    NSColor *ink = color ?: NSColor.labelColor;
    NSImage *out = [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        [glyph drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [ink set];
        NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
        CGFloat pt = MAX(4.0, dst.size.height * 0.36);
        NSImage *badge = [mark imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightBold]];
        if (!badge) return YES;
        // The positive terminal is the nub on the right; sit the mark on the body.
        CGFloat cx = dst.size.width * 0.43;
        CGFloat cy = NSMidY(dst);
        NSSize bs = badge.size;
        CGFloat knock = 1.20;
        NSRect hole = NSMakeRect(cx - bs.width * knock / 2.0, cy - bs.height * knock / 2.0,
                                 bs.width * knock, bs.height * knock);
        [badge drawInRect:hole fromRect:NSZeroRect operation:NSCompositingOperationDestinationOut fraction:1];
        NSRect slot = NSMakeRect(cx - bs.width / 2.0, cy - bs.height / 2.0, bs.width, bs.height);
        [badge drawInRect:slot fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [ink set];
        NSRectFillUsingOperation(slot, NSCompositingOperationSourceAtop);
        return YES;
    }];
    out.template = NO;
    return out;
}

// Builds the menu-bar image from selected metric segments.
// Measures segments into a draw list + total width without rendering. Split from
// BarImage so updateBar can price all three tiers per tick and draw only one.
static NSArray<NSDictionary *> *BarLayout(NSArray<NSDictionary *> *segments, NSColor *fg,
                                          CGFloat *outWidth) {
    CGFloat pt = 13, gap = 4, pad = 2;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    if (!segments.count)
        segments = @[@{@"symbol": @"gauge.with.dots.needle.50percent", @"text": @"Glancebar"}];

    CGFloat w = pad;
    NSMutableArray<NSDictionary *> *draw = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        NSString *symbol = [seg[@"symbol"] isKindOfClass:NSString.class] ? seg[@"symbol"] : nil;
        NSNumber *var = [seg[@"var"] isKindOfClass:NSNumber.class] ? seg[@"var"] : nil;
        NSString *text = [seg[@"text"] isKindOfClass:NSString.class] ? seg[@"text"] : @"";
        NSImage *customImage = [seg[@"image"] isKindOfClass:NSImage.class] ? seg[@"image"] : nil;
        NSImage *sym = customImage ?: (symbol.length ? TintedSymbol(symbol, var ? var.doubleValue : -1, pt, fg) : nil);
        // The space separates text from its icon; a text-only segment (compact battery
        // percentage) gets none, or it sits 3.5pt off-centre inside its own host.
        NSString *drawText = text.length ? (sym ? [@" " stringByAppendingString:text] : text) : @"";
        NSSize textSize = drawText.length ? [drawText sizeWithAttributes:@{NSFontAttributeName:font}] : NSZeroSize;
        CGFloat segW = (sym ? sym.size.width : 0) + textSize.width;
        if (draw.count) w += gap*2;
        w += segW;
        [draw addObject:@{@"image": sym ?: [NSNull null], @"text": drawText,
                          @"textSize": [NSValue valueWithSize:textSize],
                          @"color": seg[@"color"] ?: fg}];
    }
    w += pad;
    if (outWidth) *outWidth = ceil(w);
    return draw;
}

static NSImage *BarImageFromLayout(NSArray<NSDictionary *> *draw, CGFloat width) {
    CGFloat gap = 4, pad = 2, h = 18;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(width, h)];
    [img lockFocus];
    CGFloat x = pad;
    BOOL first = YES;
    for (NSDictionary *seg in draw) {
        if (!first) x += gap*2;
        first = NO;
        NSImage *sym = [seg[@"image"] isKindOfClass:NSImage.class] ? seg[@"image"] : nil;
        NSString *text = seg[@"text"];
        NSSize textSize = [seg[@"textSize"] sizeValue];
        if (sym) {
            [sym drawAtPoint:NSMakePoint(x, (h - sym.size.height)/2)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            x += sym.size.width;
        }
        if (text.length) {
            [text drawAtPoint:NSMakePoint(x, (h - textSize.height)/2)
               withAttributes:@{NSFontAttributeName:font,
                                NSForegroundColorAttributeName:(seg[@"color"] ?: NSColor.controlTextColor)}];
            x += textSize.width;
        }
    }
    [img unlockFocus];
    img.template = NO;  // we already used the adaptive fg color
    return img;
}

#pragma mark - Controller

static const CGFloat kW = 380, kPad = 16, kDetailMinW = 600, kDetailPad = 24;
// One instrument row. Every row has the same lead (symbol + name column), so the
// gauge, value and datum share an x. Every row names itself (Storage, Battery, Claude…):
// a blank name column read as wasted space, and the word identifies the row. The panel
// grew by that column; the gauge stayed 102pt. kDatumX + kDatumW == kW - kPad.
static const CGFloat kRowH = 30, kSoundH = 40;
static const CGFloat kLeadSymbol = 22;
static const CGFloat kFooterSymbol = 16;   // beside a 12pt label, inside the footer pill
static const CGFloat kLeadW = 28;                              // kLeadSymbol + 6
static const CGFloat kAINameX = 48, kAINameW = 56;             // kPad + kLeadW + 4; "Claude" at 13pt plus the label inset
static const CGFloat kGaugeX = 110, kGaugeW = 102, kGaugeH = 8; // kAINameX + kAINameW + 6
static const CGFloat kValueX = 216, kValueW = 48;              // "100%" at 15pt
static const CGFloat kDatumX = 272, kDatumW = 92;              // "resets 21:00"
static const CGFloat kToggleH = 28, kToggleGap = 6;
static const CGFloat kKeepW = 106, kLowW = 98, kChargeW = 96;  // 16pt glyph + 12pt "Keep Awake" / "Low Power" / "Limit 80%"
static const CGFloat kValueH = 19, kDatumH = 16, kDatumFont = 12.5;
// A volume name wider than the column grows it, and every gauge moves with it.
// The gauge stays at least this wide; a joined name that still cannot fit uses
// "First +N" instead of truncating.
static const CGFloat kMinGaugeW = 48;
static CGFloat gRowNameW = 0;
static CGFloat MaxInstrumentNameW(void) {
    return kValueX - 4 - kMinGaugeW - 6 - kAINameX;
}
static CGFloat RowNameW(void) { return gRowNameW >= kAINameW ? gRowNameW : kAINameW; }
static void SetRowNameW(CGFloat width) {
    CGFloat maxW = MaxInstrumentNameW();
    if (width < kAINameW) width = kAINameW;
    if (width > maxW) width = maxW;
    gRowNameW = width;
}
// At the short name column the gauge stays on kGaugeX. A wider volume name
// pushes it right by the same amount the column grew.
static CGFloat RowGaugeX(void) { return kGaugeX + (RowNameW() - kAINameW); }
static CGFloat RowGaugeW(void) {
    CGFloat width = kValueX - 4 - RowGaugeX();
    return width >= kMinGaugeW ? width : kGaugeW;
}
static NSRect RowGaugeRect(void) {
    return NSMakeRect(RowGaugeX(), (kRowH - kGaugeH) / 2.0, RowGaugeW(), kGaugeH);
}
static NSString *VolumeLabelThatFits(NSString *full, NSArray<NSString *> *names, NSFont *font, CGFloat fieldWidth) {
    if (![full isKindOfClass:NSString.class]) full = @"";
    NSFont *face = font ?: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSArray<NSString *> *list = [names isKindOfClass:NSArray.class] && names.count ? names : (full.length ? @[full] : @[]);
    CGFloat limit = fieldWidth - 4;
    if (limit < 1) limit = fieldWidth;
    CGFloat fullW = [full sizeWithAttributes:@{NSFontAttributeName: face}].width;
    if (full.length && fullW <= limit + 0.01) return full;
    NSString *compact = GlanceVolumeCompactName(list);
    return compact.length ? compact : (full.length ? full : @"Disk");
}
// The details document follows the resizable window. It is only touched on the
// main thread; keeping the active width here avoids threading a layout argument
// through every detail-section builder.
static CGFloat kDetailW = 600;

// Identifies our observation of the status button's effectiveAppearance.
static void *kBarAppearanceContext = &kBarAppearanceContext;
static NSString *const kShowPopoverNotification = @"com.iantodd.glancebar.show-popover";
static NSString *PopoverRequestObject(void) {
    return [NSString stringWithFormat:@"uid:%u", getuid()];
}

@interface Controller : NSObject <NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, GBMixPreloadHovering>
@property(nonatomic, copy) NSString *showDestinationOnLaunch;
@end

@interface Controller ()
- (void)rebuildContent;
- (void)rebuildDetails;
- (void)showWelcomeIfNeeded;
- (void)refreshVolumesAsync;
- (void)schedulePowerRefresh;
- (dispatch_queue_t)pmsetWorkQueue;
- (void)refreshAIUsageAsync;
- (void)refreshLidAwakeAsync;
- (void)refreshLidAwakeForced:(BOOL)force;
- (void)updateBar;
- (void)refreshVisibleSurfaces;
- (NSDictionary *)focusSnapshotForWindow:(NSWindow *)window rootView:(NSView *)root;
- (void)restoreFocus:(NSDictionary *)snapshot
             inView:(NSView *)root window:(NSWindow *)window;
- (void)audioDevicesChanged;
- (void)outputVolumeChanged;
- (void)audioDefaultChanged;
- (void)ensureMixSeeds;
- (NSUInteger)coalescedSeekApplyCount;
@end

// CoreAudio property reads. Output streams are the output scope of kAudioDevicePropertyStreams;
// a stream direction of 0 is output (AudioHardwareBase.h). Default output is
// kAudioHardwarePropertyDefaultOutputDevice; alert sounds follow
// kAudioHardwarePropertyDefaultSystemOutputDevice. Listeners are AudioObjectAddPropertyListener
// on kAudioObjectSystemObject — no polling.
// https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice
static AudioObjectPropertyAddress AudioAddr(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){ selector, scope, kAudioObjectPropertyElementMain };
}
static NSString *AudioString(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = AudioAddr(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value) != noErr || !value) return nil;
    return (__bridge_transfer NSString *)value;
}
static GlanceAudioTransport GlanceTransport(UInt32 transport) {
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn: return GlanceAudioTransportBuiltIn;
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE: return GlanceAudioTransportBluetooth;
    case kAudioDeviceTransportTypeUSB: return GlanceAudioTransportUSB;
    case kAudioDeviceTransportTypeHDMI:
    case kAudioDeviceTransportTypeDisplayPort: return GlanceAudioTransportDisplay;
    case kAudioDeviceTransportTypeAggregate: return GlanceAudioTransportAggregate;
    case kAudioDeviceTransportTypeVirtual: return GlanceAudioTransportVirtual;
    default: return GlanceAudioTransportOther;
    }
}
static NSString *AudioDataSourceName(AudioObjectID device) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
    UInt32 source = 0, size = sizeof(source);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &source) != noErr) return @"";
    CFStringRef name = NULL;
    AudioValueTranslation translation = { &source, sizeof(source), &name, sizeof(name) };
    size = sizeof(translation);
    addr.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &translation) != noErr || !name) return @"";
    return (__bridge_transfer NSString *)name;
}
static int OutputChannelCount(AudioObjectID device) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, NULL, &size) != noErr || size < sizeof(AudioObjectID))
        return 0;
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *streams = calloc(count, sizeof(AudioObjectID));
    if (!streams) return 0;
    int channels = 0;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, streams) == noErr) {
        for (UInt32 i = 0; i < count; i++) {
            AudioStreamBasicDescription format = {0};
            AudioObjectPropertyAddress formatAddr = AudioAddr(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
            UInt32 formatSize = sizeof(format);
            if (AudioObjectGetPropertyData(streams[i], &formatAddr, 0, NULL, &formatSize, &format) == noErr &&
                format.mChannelsPerFrame > 0)
                channels += (int)format.mChannelsPerFrame;
            else
                channels += 1;
        }
    }
    free(streams);
    return channels;
}
static BOOL DeviceHasVolumeControl(AudioObjectID device);
static NSArray<NSDictionary *> *ReadAudioDevices(void) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || !size)
        return @[];
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = calloc(count, sizeof(AudioObjectID));
    if (!devices) return @[];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:count];
    for (UInt32 i = 0; i < count; i++) {
        AudioObjectPropertyAddress transportAddr = AudioAddr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
        UInt32 transport = 0, transportSize = sizeof(transport);
        AudioObjectGetPropertyData(devices[i], &transportAddr, 0, NULL, &transportSize, &transport);
        NSString *uid = AudioString(devices[i], kAudioDevicePropertyDeviceUID);
        if (!uid.length) continue;
        NSString *name = AudioString(devices[i], kAudioObjectPropertyName) ?: @"Output";
        [rows addObject:@{
            @"uid": uid, @"name": name, @"transport": @(GlanceTransport(transport)),
            @"outputChannels": @(OutputChannelCount(devices[i])), @"deviceID": @(devices[i]),
            @"dataSource": AudioDataSourceName(devices[i]) ?: @"",
            @"volumeControllable": @(DeviceHasVolumeControl(devices[i]))
        }];
    }
    free(devices);
    return rows;
}
static NSString *DefaultOutputUID(NSArray<NSDictionary *> *devices) {
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &device) != noErr || !device)
        return nil;
    for (NSDictionary *row in devices)
        if ([row[@"deviceID"] unsignedIntValue] == device) return row[@"uid"];
    return AudioString(device, kAudioDevicePropertyDeviceUID);
}
static void SetOutputDevice(AudioObjectID device) {
    if (!device) return;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, size, &device);
    addr.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice;
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, size, &device);
}
static BOOL SwitchToNewOutputs(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"switchToNewOutputs": @YES}];
    return [ud boolForKey:@"switchToNewOutputs"];
}
// Output volume: the device's main volume element when it has one, else the average of its
// first two channels (built-in speakers and most Bluetooth outputs only have channels).
static NSArray<NSNumber *> *OutputVolumeElements(AudioObjectID device) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectHasProperty(device, &a)) return @[@(kAudioObjectPropertyElementMain)];
    NSMutableArray *out = [NSMutableArray array];
    for (UInt32 e = 1; e <= 2; e++) {
        a.mElement = e;
        if (AudioObjectHasProperty(device, &a)) [out addObject:@(e)];
    }
    return out;
}
static BOOL DeviceHasVolumeControl(AudioObjectID device) {
    if (!device) return NO;
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                    kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable)
        return YES;
    for (NSNumber *e in OutputVolumeElements(device)) {
        AudioObjectPropertyAddress ch = {kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, e.unsignedIntValue};
        if (AudioObjectHasProperty(device, &ch) && AudioObjectIsPropertySettable(device, &ch, &settable) == noErr && settable)
            return YES;
    }
    return NO;
}
// 0…1, or -1 when the device has no volume control; *muted from the device's mute switch.
static double ReadOutputVolume(AudioObjectID device, BOOL *muted) {
    if (muted) {
        *muted = NO;
        AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 v = 0, size = sizeof v;
        if (device && AudioObjectHasProperty(device, &m) && AudioObjectGetPropertyData(device, &m, 0, NULL, &size, &v) == noErr)
            *muted = v != 0;
    }
    if (!device) return -1;
    double sum = 0; int n = 0;
    for (NSNumber *e in OutputVolumeElements(device)) {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, e.unsignedIntValue};
        Float32 v = 0; UInt32 size = sizeof v;
        if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &v) == noErr) { sum += v; n++; }
    }
    return n ? sum / n : -1;
}
// Sets every volume element; raising it from zero also lifts mute, as the volume keys do.
static void SetOutputVolume(AudioObjectID device, double volume) {
    if (!device) return;
    Float32 v = (Float32)MIN(1, MAX(0, volume));
    for (NSNumber *e in OutputVolumeElements(device)) {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, e.unsignedIntValue};
        AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof v, &v);
    }
    AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 mute = v > 0 ? 0 : 1;
    if (AudioObjectHasProperty(device, &m)) AudioObjectSetPropertyData(device, &m, 0, NULL, sizeof mute, &mute);
}
// Loud (80% and up) in orange, muted in red; the % text and the slider's fill agree.
static NSColor *OutputVolumeColor(double volume, BOOL muted) {
    if (muted) return NSColor.systemRedColor;
    if (volume < 0) return NSColor.tertiaryLabelColor;
    return OutputVolumeLoud(volume) ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
}
static NSColor *OutputVolumeFill(double volume, BOOL muted) {
    if (muted) return NSColor.systemRedColor;
    return OutputVolumeLoud(volume) ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
}
static OSStatus OutputVolumeChanged(AudioObjectID object, UInt32 count,
                                   const AudioObjectPropertyAddress *addresses, void *client) {
    (void)object; (void)count; (void)addresses;
    Controller *controller = (__bridge Controller *)client;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller outputVolumeChanged]; });
    return noErr;
}
static OSStatus AudioHardwareChanged(AudioObjectID object, UInt32 count,
                                    const AudioObjectPropertyAddress *addresses, void *client) {
    (void)object;
    BOOL devices = NO, output = NO;
    for (UInt32 i = 0; i < count; i++) {
        if (addresses[i].mSelector == kAudioHardwarePropertyDevices) devices = YES;
        if (addresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice) output = YES;
    }
    Controller *controller = (__bridge Controller *)client;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (devices) [controller audioDevicesChanged];
        if (output) [controller audioDefaultChanged];
    });
    return noErr;
}

static NSString *AudioSymbolName(NSDictionary *device) {
    return AudioOutputSymbol((GlanceAudioTransport)[device[@"transport"] integerValue],
                             device[@"name"], device[@"dataSource"]);
}
static NSString *const kAppleMusicBundleID = @"com.apple.Music";
static NSString *const kSpotifyBundleID = @"com.spotify.client";
static NSString *const kPlayerOutputUIDKey = @"playerOutputUID";
static NSString *const kPlayerOutputNameKey = @"playerOutputName";
static BOOL AppleMusicIsRunning(void) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:kAppleMusicBundleID].count > 0;
}
static const int kVolumeScriptSec = 10;
static int RunAppleScriptBlocking(NSString *source, int seconds, BOOL hardKill,
                                 NSString **outOutput, NSString **outError) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", source ?: @""];
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = err;
    if (![task launchAndReturnError:NULL]) {
        if (outOutput) *outOutput = @"";
        if (outError) *outError = @"osascript failed to launch";
        return 1;
    }
    // osascript has no deadline. A hung Chrome, or a permission dialog nobody answers,
    // would block this queue forever; terminate at the deadline and force-kill a second later.
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:seconds hardKill:hardKill];
    NSString *output = [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
    NSString *errorText = [[NSString alloc] initWithData:[err.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
    [task waitUntilExit];
    [watchdog disarm];
    int status = task.terminationStatus;
    if (task.terminationReason != NSTaskTerminationReasonExit) {
        if (!errorText.length) errorText = @"osascript timed out";
        if (status == 0) status = 1;
    }
    if (outOutput) *outOutput = output;
    if (outError) *outError = errorText;
    return status;
}
static void RunAppleScriptTimed(NSString *source, int seconds, void (^done)(NSString *output, NSString *errorText, int status));
static void RunAppleScript(NSString *source, void (^done)(NSString *output, NSString *errorText, int status)) {
    if (getenv("GLANCEBAR_STUB_APPLESCRIPT")) {
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@"", @"", 0); });
        return;
    }
    RunAppleScriptTimed(source, kVolumeScriptSec, done);
}
static void RunAppleScriptTimed(NSString *source, int seconds, void (^done)(NSString *output, NSString *errorText, int status)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *output = nil, *errorText = nil;
        int status = RunAppleScriptBlocking(source, seconds, NO, &output, &errorText);
        if (!done) return;
        dispatch_async(dispatch_get_main_queue(), ^{ done(output ?: @"", errorText ?: @"", status); });
    });
}

// Volume sets for one target, in order, and only if `generation` is still latest.
// `readScript` (the final restore) is run once afterwards; a mismatch writes
// `setScript` one more time. A dropped apply still calls `done` — the caller's
// busy flag has to clear — with dropped YES so it is not treated as a failed set.
// `setOK` nil means status == 0. Callbacks are on the main queue. Not called on `queue`.
#pragma mark - Seed mixes (Apple Music)

// One bulk read of the library: per track, id, title, artist, album, genre, year, plays,
// days since played (-1 never), favourite, dislike; unit/record separators between.
static NSString *const kMixLibraryScript =
    @"tell application \"Music\"\n"
     "set lib to library playlist 1\n"
     "set ids to persistent ID of every track of lib\n"
     "set ns to name of every track of lib\n"
     "set ars to artist of every track of lib\n"
     "set als to album of every track of lib\n"
     "set gs to genre of every track of lib\n"
     "set ys to year of every track of lib\n"
     "set pcs to played count of every track of lib\n"
     "set pds to played date of every track of lib\n"
     "set fs to favorited of every track of lib\n"
     "set ds to disliked of every track of lib\n"
     "end tell\n"
     "set nowDate to current date\n"
     "set us to character id 31\n"
     "set out to {}\n"
     "repeat with i from 1 to count of ids\n"
     "set pd to item i of pds\n"
     "if pd is missing value then\nset daysIdle to -1\nelse\nset daysIdle to ((nowDate - pd) div 86400)\nend if\n"
     "set end of out to (item i of ids) & us & (item i of ns) & us & (item i of ars) & us & (item i of als) & us & (item i of gs) & us & ((item i of ys) as text) & us & ((item i of pcs) as text) & us & (daysIdle as text) & us & ((item i of fs) as text) & us & ((item i of ds) as text)\n"
     "end repeat\n"
     "set AppleScript's text item delimiters to (character id 30)\n"
     "return out as text\n";

static NSArray<NSDictionary *> *ParseMixLibrary(NSString *text) {
    NSMutableArray *tracks = [NSMutableArray array];
    NSString *us = [NSString stringWithFormat:@"%C", (unichar)31], *rs = [NSString stringWithFormat:@"%C", (unichar)30];
    for (NSString *record in [[text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:rs]) {
        NSArray *f = [record componentsSeparatedByString:us];
        if (f.count < 10 || ![f[0] length]) continue;
        [tracks addObject:@{@"id": f[0], @"title": f[1], @"artist": f[2], @"album": f[3], @"genre": f[4],
                            @"year": @([f[5] integerValue]), @"plays": @([f[6] integerValue]), @"idleDays": @([f[7] integerValue]),
                            @"fav": @([f[8] isEqual:@"true"]), @"dislike": @([f[9] isEqual:@"true"])}];
    }
    return tracks;
}

static NSString *MixDirectory(NSString *sub) {
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:
                     [@"Library/Application Support/Glancebar/mix" stringByAppendingPathComponent:sub ?: @""]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Claude orders the mix: `claude -p` on the owner's own subscription, a fast model, no tools.
// Runs off the main thread; nil when the CLI is missing, fails or times out.
static NSString *RunClaudeForMix(NSString *prompt) {
    NSString *claude = [GBHomeDirectory() stringByAppendingPathComponent:@".local/bin/claude"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:claude]) return nil;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:claude];
    task.arguments = @[@"-p", @"--tools", @"", @"--model", @"haiku", prompt];
    task.currentDirectoryURL = [NSURL fileURLWithPath:MixDirectory(@"work")];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PATH"] = [NSString stringWithFormat:@"%@/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin", GBHomeDirectory()];
    task.environment = env;
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:120];
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    [watchdog disarm];
    if (task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// A seed's mix: Claude's order from the candidates when it answers well, else the rule-based
// draw. Always opens with the seed (its song, or an album standout).
static NSArray<NSString *> *BuildSeedMix(NSArray<NSDictionary *> *tracks, NSDictionary *seed, BOOL useClaude, uint64_t salt) {
    const NSUInteger length = 40;
    NSArray *candidates = MixCandidates(tracks, seed, 3, 220);
    NSArray *openers = MixSeedTracks(seed, tracks);
    NSArray *ids = nil;
    if (useClaude && candidates.count >= 10) {
        NSMutableArray *offer = [candidates mutableCopy];
        if ([seed[@"kind"] isEqual:@"album"]) [offer addObjectsFromArray:openers];
        NSMutableSet *allowed = [NSMutableSet set];
        for (NSDictionary *c in offer) [allowed addObject:c[@"id"]];
        NSString *reply = RunClaudeForMix(MixPrompt(seed, offer, length));
        NSArray *picked = reply ? ParseMixReply(reply, allowed, length) : @[];
        if (picked.count >= 15) ids = picked;
    }
    if (!ids) return RuleMix(candidates, seed, tracks, length, salt);
    NSMutableArray *mix = [ids mutableCopy];
    NSString *first = [openers.firstObject objectForKey:@"id"];
    if (first) { [mix removeObject:first]; [mix insertObject:first atIndex:0]; }
    return mix;
}

static NSString *const kMusicNextTip = @"Next track — tap blends, double-tap cuts";

static _Atomic(NSUInteger) gOfflineHashLiveGeneration;

@implementation Controller {
    MeteredMonitor *_meteredMonitor;
    NSDictionary *_metered;
    NSStatusItem *_item;
    NSPopover *_popover;
    NSWindow *_detailsWindow;
    NSArray<Volume *> *_vols;
    BatteryState _bat;
    BatteryForecastTracker *_batteryForecastTracker;
    double _batteryDebugStarted, _batteryDebugLast;
    SystemState _sys;
    CPUCounters _cpuPrev;
    CFAbsoluteTime _cpuBaselineTime;
    double _lastCPU;
    BOOL _lastCPUValid;
    NSArray<AIUsage *> *_aiUsage;
    AIReader *_aiReader;            // touched only on _aiQueue
    dispatch_queue_t _aiQueue;
    dispatch_queue_t _volumeQueue;
    BOOL _aiLoading, _aiRefreshPending, _aiDraining;
    BOOL _volumesLoading, _volumesUnavailable;
    CFAbsoluteTime _volumeScanStarted;
    BOOL _powerRefreshPending;
    dispatch_queue_t _pmsetQueue;
    BOOL _pmsetInFlight;
    volatile BOOL _terminating;
    NSUInteger _volumeScanGen;
    CFAbsoluteTime _volumeAbandonedAt;
    NSString *_barCapacityKey;
    double _barCapacityCached, _barCapacityMeasuredAt;
    NSString *_aiSignature;
    NSString *_aiCatchUpStatus;
    BOOL _aiTotalsIncomplete;
    NSArray<NSDictionary *> *_hogs;
    // Battery burn by app, on battery only. The baseline is one energy snapshot taken when
    // the Mac is unplugged (or at launch on battery); live samples run only while a panel is open.
    NSDictionary<NSNumber *, NSNumber *> *_energyBaseline, *_energyPrev;
    NSDate *_energyBaselineAt;
    BOOL _energyBaselineAtUnplug, _energySampling;
    double _energyBaselineWh;
    CFAbsoluteTime _energyPrevAt;
    NSArray<NSDictionary *> *_burnRows;
    NSMutableDictionary<NSNumber *, NSString *> *_burnGroupCache;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSDictionary *_activitySurvey;
    BOOL _activityLoading, _activityPresenting;
    NSUInteger _activityGeneration;
    NSInteger _activitySort;
    BOOL _popoverPrepared, _popoverPreparePending;
    BOOL _chargerRowShown;   // the popover has a Charger row (plugged in, still draining)
    NSString *_storageNotice;
    NSDictionary *_storageResult, *_storageUndo, *_storageProgress;
    NSMutableDictionary *_storageBlocked;
    GBStorageIndex *_storageIndex;
    dispatch_queue_t _storageQueue;
    NSProgress *_storageCleanupProgress;
    BOOL _storageSliceRunning, _storagePaused, _storageSleeping, _storageFolders, _storageCacheLoaded, _storageCacheLoading;
    BOOL _storageFinished, _storageRetainSnapshot;
    NSUInteger _storageGeneration;
    double _storageLastStart, _storageLastCache;
    NSMutableArray<NSNumber *> *_ampHistory;
    NSUInteger _sampleGen;
    CFAbsoluteTime _lastSampleTime;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    HeatGuardState _heatGuard;   // Low Power switched on by the battery heat guard
    double _heatSpeed;           // fast cores' speed against their top clock; <0 unknown
    CFAbsoluteTime _pressureSince;   // when macOS last began reporting thermal pressure; 0 = none
    BOOL _barShowDisk, _barShowBattery, _barShowSystem;
    // Keep Awake IS the system SleepDisabled setting (no idle or lid-close sleep), read off-main.
    // One live state, so the bar's cup and the footer button can never disagree.
    BOOL _lidAwake, _lidAwakeReading;
    NSButton *_keepAwakeButton, *_lowPowerButton, *_chargeButton;   // footer toggles; rebuilt with the popover
    BOOL _aiGatesLogged, _lastShowAI, _lastUseAccount, _lastUseCursorAccount, _lastAllowTranscripts;
    BOOL _procStatsLoading, _procStatsUnavailable;
    CFAbsoluteTime _popoverClosedAt;   // guards the status-item click-to-dismiss race
    BarTierState _barTier;             // adaptive bar width; zero-init = full tier
    BOOL _barWasOnBar;                 // arms the eviction net only after a real sighting
    double _barCreatedAt;              // eviction grace for an item never sighted (crowded launch)
    BOOL _barSwapPending;              // a differently sized image was just installed…
    double _barFrameBeforeSwap;        // …and the host frame has not moved off this width yet
    double _lidAwakeLastRead;
    double _barChromeWidth;            // shell padding around the rendered image (16pt live)
    BOOL _barChromeKnown;
    NSDate *_lastMachineRefresh, *_lastAIRefresh;
    NSString *_chargeMode;          // "limit80" | "full"; nil until read from defaults
    NSDate *_chargeModeAt;
    BOOL _chargeModeLoaded, _chargeShortcutInFlight;
    BOOL _chargeShortcutsKnown, _chargeShortcutsPresent, _chargeShortcutsChecking;
    CFAbsoluteTime _chargeShortcutsCheckedAt;
    NSDate *_lastVolumeSuccess;
    NSScrollView *_popoverScroll;
    NSArray<NSDictionary *> *_audioDevices;    // last settled device set, including input-only
    NSArray<NSDictionary *> *_audioPrevious;   // comparison baseline for auto-switch
    NSString *_defaultOutputUID;
    NSString *_playerOutputUID;
    NSString *_playerOutputName;
    NSDictionary *_externalPlayback;
    CFAbsoluteTime _audioDevicesChangedAt;     // a default change just after this is the system adopting the new device
    double _outputVolume;          // default output's volume 0…1; <0 when it has none
    BOOL _outputMuted;
    AudioObjectID _volumeWatched;  // device whose volume and mute we listen to
    CFAbsoluteTime _volumeSetAt;   // last change from our own slider, so its echo doesn't rebuild
    BOOL _volumeRebuildPending;
    NSArray<NSDictionary *> *_mixLibrary;      // one bulk read of Music's library
    CFAbsoluteTime _mixLibraryAt;
    BOOL _mixLibraryLoading, _mixFrozen, _audioFrozen;   // frozen: tests set seeds / own the volume reading, no live reads
    NSArray<NSDictionary *> *_mixSeeds;        // the four tiles
    NSMutableDictionary<NSString *, NSArray *> *_mixPrepared;   // seed key → track ids, built ahead
    NSMutableSet<NSString *> *_mixPreparing;
    NSMutableDictionary<NSString *, NSImage *> *_mixArt;       // track id → cover
    NSMutableSet<NSString *> *_mixLiked;                       // track ids given a 👍 (mix/feedback.jsonl)
    NSString *_mixPlayingKey, *_mixStartingKey;
    NSMutableDictionary<NSString *, NSDictionary *> *_offlineRequests;
    NSDictionary *_offlineManifest;
    BOOL _offlineLoaded, _offlineCacheBusy, _offlineCacheAgain;
    NSUInteger _offlineHashGeneration;
    dispatch_queue_t _offlineHashQueue;
    NSMutableSet<NSString *> *_offlineHashOK, *_offlineHashPending;   // main thread only
    BOOL _localStartPaused;
    AVPlayerItem *_seekCoalesceItem;
    NSString *_preparedPlaylistKey;
    AVPlayerItem *_preparedFirstItem;
    NSTimer *_preloadHoverTimer;
    NSString *_preloadHoverKey;
    CFAbsoluteTime _musicTimingClick;
    NSMutableArray<NSDictionary *> *_musicTimingLog;
    BOOL _musicTimingEnabled;
    NSTimer *_seekCoalesceTimer;
    double _seekCoalesceSeconds;
    NSUInteger _coalescedSeekCount;
    double _popoverLastRebuildMs;
    BOOL _musiclibBusy, _musiclibAgain;
    CFAbsoluteTime _musiclibLastSyncAttemptAt;
    NSUInteger _musiclibSyncFailures, _offlineRequestsGeneration, _musiclibSyncedRequestGeneration;
    NSUInteger _musiclibLastAttemptGeneration;
    BOOL _musiclibLastAttemptTerminal, _musiclibSyncBypassBackoff;
    NSUInteger _libraryRefreshPhase;
    BOOL _libraryRefreshWantsCache, _libraryRefreshWantsStatus, _libraryRefreshWantsSync;
    NSMutableArray<NSNumber *> *_musiclibHelperLaunchTimes;
    BOOL _musiclibHelperLaunchLogged;
    BOOL _meteredLinkWasActive;
    NSDictionary *_musicLibraryStatus;
    NSString *_musicLibraryLastError, *_musicLibraryHotDir;
    BOOL _musicLibraryUnmatched, _musicLibraryOverflow;
    CFAbsoluteTime _musicLibraryStatusAt;
    NSArray<NSDictionary *> *_mixSeedsNext;
    NSUInteger _mixSeedsNextGen;
    CFAbsoluteTime _mixSeedsNextSince;
    BOOL _musicSilentQA;
    NSString *_playbackCause, *_playbackRateState, *_playbackLoggedOutputUID;
    CFAbsoluteTime _playbackCauseAt;
    GBPlayerWatch *_localRateWatch;
    CFAbsoluteTime _offlineExportChecked, _offlinePreparedAt;
    NSDate *_offlineExportDate;
    NSUInteger _offlinePlayGeneration;
    BOOL _stationLoaded, _stationAvailable;
    CFAbsoluteTime _stationChecked;
    NSDate *_stationDate;
    NSArray *_stationFiles, *_stationPicks, *_stationTracks;
    dispatch_queue_t _mixQueue;
    NSMutableDictionary<NSString *, NSDictionary *> *_remote;   // host → {sample, mode, free, slots, at}
    NSMutableSet<NSString *> *_remoteInFlight;
    CFAbsoluteTime _remotePolledAt;
    BOOL _fleetFocusPending;
    NSMutableSet<NSString *> *_fleetExpandedHosts; // session-only; never writes preferences
    NSUInteger _audioSettleGen;
    BOOL _musicProbesEnabled;          // app launch only; layout tests must not touch Chrome or audio
    BOOL _musicOff;                    // defaults musicEnabled = NO: no music polling (worker Macs); nothing else
    BOOL _networkKnown, _networkOnline;
    nw_path_monitor_t _pathMonitor;
    BOOL _playbackKnown, _playbackPlaying, _localMode, _localEmpty, _localTagsReady, _localLoveInFlight;
    BOOL _offlineTracksEntering;
    NSString *_localTitle, *_localArtist, *_musicNote, *_localHeartError;
    NSUInteger _localHeartEpoch;
    NSMutableSet<NSString *> *_heartedKeys;
    AVQueuePlayer *_localPlayer;
    NSArray<NSURL *> *_localURLs;
    NSArray<AVPlayerItem *> *_localObservedItems;
    NSInteger _localIndex;
    BOOL _remoteCommandsOn;
    NSString *_chargePendingName, *_chargePendingMode;
    NSTimer *_powerTickTimer;   // 1s battery/power refresh while a surface is visible
    NSUInteger _powerTicks;
    NSArray<NSString *> *_offlineTracks;
    CFAbsoluteTime _offlineTracksAt;
    BOOL _offlineTracksReady;
    BOOL _offlineTracksScanBusy;
    dispatch_queue_t _offlineTracksQueue;
    NSMutableDictionary<NSString *, NSDictionary *> *_offlineCoverageCache;
    NSInteger _localQueueEnd;
    double _trackElapsed, _trackDuration;
    CFAbsoluteTime _trackSampledAt;
    NSTimer *_trackTick;
    int _burnLatch;   // 0 undecided, 1 shown, 2 hidden: the burn row holds still while the popover is open
    double _musicNextArmedAt;
    NSTimer *_musicNextArmTimer;
    AVQueuePlayer *_localOutgoing;
    NSTimer *_localBlendTimer;
    double _localBlendStarted, _localBlendDuration;
    NSSet<NSString *> *_onDiskLibraryIDs;
    CFAbsoluteTime _onDiskLibraryAt;
}

// A catch-up pass may hold a coalesced state write. Land it before the process goes away,
// or the next launch re-reads bytes it already indexed.
//
// Never block quit on it. The AI queue is serial and a pass in flight can be parked in
// /usr/bin/security or a 15s HTTP timeout; a plain dispatch_sync would freeze the main
// thread until then. The flush is worth at most a couple of seconds of re-read, so wait
// briefly and abandon it.
- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    // Keep Awake must not outlive the app when the sudoers rule can clear it without a
    // prompt. The plist read is cheap; its pmset fallback and the sudo each sit under the
    // 8s task watchdog. Stay synchronous — the process is quitting — but don't give them
    // the main thread for longer than the shared budget.
    _terminating = YES;
    GBFineVolumeSetTargetProvider(nil);
    [self silenceMusicBlendsForQuit];
    [self cancelStorage];
    [_meteredMonitor stop];
    dispatch_semaphore_t pmsetDone = dispatch_semaphore_create(0);
    // Not behind the pmset queue: an apply waiting on a password dialog would eat the budget.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSNumber *awake = SleepDisabledState();
        if (awake.boolValue && PmsetRuleInstalled()) {
            RunPmsetViaSudo(@"disablesleep", NO);
            // A relaunch soon after (an update, an agent restarting the app) turns it back on.
            [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970
                                                    forKey:@"keepAwakeClearedAtQuit"];
        }
        dispatch_semaphore_signal(pmsetDone);
    });
    if (dispatch_semaphore_wait(pmsetDone, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kQuitPmsetBudgetSec * NSEC_PER_SEC))))
        GBLog("terminate: Keep Awake cleanup timed out");
    if (!_aiQueue || !_aiReader) return;
    dispatch_semaphore_t flushed = dispatch_semaphore_create(0);
    dispatch_async(_aiQueue, ^{
        [self->_aiReader flushPersistentState];
        dispatch_semaphore_signal(flushed);
    });
    if (dispatch_semaphore_wait(flushed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC))))
        GBLog("terminate: AI state flush timed out; indexing resumes from the last write");
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    dispatch_async(dispatch_get_main_queue(), ^{ [self registerPopoverHotKeys]; });
    dispatch_async(dispatch_get_main_queue(), ^{ GBFineVolumeStart(); });
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES,
                           @"barShowDisk": @YES, @"barShowBattery": @YES,
                           @"barShowSystem": @NO, @"starlinkCapGB": @100, @"starlinkResetDay": @13, @"telstraCapGB": @180, @"telstraResetDay": @7,
                           @"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
                           @"useCursorAccount": @NO, @"switchToNewOutputs": @YES, @"lowData": @NO,
                           @"speedAlways": @NO}];
    _bat = ReadBattery();
    [self batteryForecast];
    [self noteEnergyBaseline:NO];
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _heatGuard = (HeatGuardState)MIN(MAX([ud integerForKey:@"heatGuardState"], 0), 2);
    _heatSpeed = -1;
    _barShowDisk = [ud boolForKey:@"barShowDisk"];
    _barShowBattery = [ud boolForKey:@"barShowBattery"];
    _barShowSystem = [ud boolForKey:@"barShowSystem"];
    NSString *defaultsDomain = NSBundle.mainBundle.bundleIdentifier ?: @"com.iantodd.glancebar";
    NSDictionary *persisted = [ud persistentDomainForName:defaultsDomain];
    if (!persisted[@"barShowBattery"] && !_bat.valid) _barShowBattery = NO;
    _ampHistory = [NSMutableArray array];
    _vols = @[];
    _aiUsage = @[];
    _aiReader = [[AIReader alloc] initWithHomeDirectory:GBHomeDirectory()];
    _aiQueue = dispatch_queue_create("com.iantodd.glancebar.ai", DISPATCH_QUEUE_SERIAL);
    _volumeQueue = dispatch_queue_create("com.iantodd.glancebar.volumes", DISPATCH_QUEUE_SERIAL);
    _hogs = @[];
    _topCPU = @[];
    _topMem = @[];

    // LSUIElement apps have no visible menu bar, but key equivalents are still routed
    // through the main menu — without this, Cmd+W is dead in the details window.
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *fileItem = [mainMenu addItemWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    NSApp.mainMenu = mainMenu;

    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _barCreatedAt = CFAbsoluteTimeGetCurrent();
    // Diagnostic launch: exercise real shell placement and recovery from the glyph.
    const char *startCollapsed = getenv("GLANCEBAR_BAR_START_COLLAPSED");
    if (getenv("GLANCEBAR_BAR_DEBUG") && startCollapsed && strcmp(startCollapsed, "1") == 0)
        _barTier.tier = BarTierGlyph;
    _item.button.target = self;
    _item.button.action = @selector(togglePopover:);
    // Re-render immediately when the menu bar flips light/dark (Light/Dark toggle, or a
    // wallpaper change that re-tints the bar). Never removed: _item lives for the whole
    // process, same as this controller.
    [_item.button addObserver:self forKeyPath:@"effectiveAppearance"
                      options:0 context:kBarAppearanceContext];
    // Low Power Mode can change under us (System Settings, Control Center, pmset, the battery
    // dropping low); keep the footer toggle and the bar's yellow battery honest.
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *n) { [self syncPowerButtons]; [self updateBar]; }];

    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = NO;
    _popover.delegate = self;   // popoverWillClose: timestamps the dismiss for the toggle guard
    _popover.contentViewController = [NSViewController new];
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];

    _meteredMonitor = [MeteredMonitor new];
    _meteredLinkWasActive = [self meteredLinkActive];
    __weak Controller *weakSelf = self;
    _meteredMonitor.updated = ^(NSDictionary *state) {
        Controller *owner = weakSelf;
        if (!owner || owner->_terminating) return;
        owner->_metered = state;
        BOOL metered = [owner meteredLinkActive];
        if (owner->_meteredLinkWasActive && !metered) [owner maybeScheduleMusicLibrarySync];
        owner->_meteredLinkWasActive = metered;
        [owner refreshVisibleSurfaces];
    };
    NSNotificationCenter *workspaceNotifications = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceNotifications addObserver:self selector:@selector(meteredWillSleep:)
                                  name:NSWorkspaceWillSleepNotification object:nil];
    [workspaceNotifications addObserver:self selector:@selector(meteredDidWake:)
                                  name:NSWorkspaceDidWakeNotification object:nil];
    [self refresh];
    [self rebuildContent]; // Prepare the first click while launch work is already in progress.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self requestStorageScanIfNeeded]; });
    // The CPU figure needs two tick samples at least 2 s apart; take the second one now
    // rather than leaving "estimating" on the bar until the 15 s timer first fires.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refresh]; });
    // Diagnostic: GLANCEBAR_AUTOOPEN=1 opens the popover on launch (for screenshots).
    if (getenv("GLANCEBAR_AUTOOPEN"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self togglePopover:nil]; });
    else if (!getenv("GLANCEBAR_SKIP_WELCOME"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self showWelcomeIfNeeded]; });
    // Worker Macs can switch music off entirely: defaults write com.iantodd.glancebar musicEnabled -bool NO
    NSUserDefaults *musicPrefs = NSUserDefaults.standardUserDefaults;
    _musicProbesEnabled = YES;
    // Keep Awake cleared by a quit comes back on a relaunch within 10 minutes: a restart, not a
    // deliberate stop (Ian, 1 Nov 2026: a quit to eject a drive let a backup Mac sleep mid-copy).
    double clearedAt = [musicPrefs doubleForKey:@"keepAwakeClearedAtQuit"];
    if (clearedAt > 0) {
        [musicPrefs removeObjectForKey:@"keepAwakeClearedAtQuit"];
        double ago = NSDate.date.timeIntervalSince1970 - clearedAt;
        if (ago >= 0 && ago < 600 && _musicProbesEnabled)
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (PmsetRuleInstalled()) RunPmsetViaSudo(@"disablesleep", YES);
            });
    }
    // Only music stops: _musicProbesEnabled also gates the charge limit, remote Macs and the network
    // monitor, and folding musicEnabled into it left the M1 charging to 100% (1 Nov 2026).
    _musicOff = [musicPrefs objectForKey:@"musicEnabled"] && ![musicPrefs boolForKey:@"musicEnabled"];
    _musicSilentQA = MusicSilentQAEnabled();
    if (_musicSilentQA) GBLog("music: silent QA mode — player volume forced to 0");
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playbackItemTrouble:)
                                               name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playbackItemTrouble:)
                                               name:AVPlayerItemPlaybackStalledNotification object:nil];
    [self notePlayback:@"launch" fields:@{@"pid": @(getpid()),
        @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""}];
    if (getenv("GLANCEBAR_MIX_FROZEN")) _mixFrozen = YES;
    _outputVolume = -1;
    _mixPrepared = [NSMutableDictionary dictionary];
    _mixPreparing = [NSMutableSet set];
    _mixArt = [NSMutableDictionary dictionary];
    _mixQueue = dispatch_queue_create("glancebar.mix", DISPATCH_QUEUE_SERIAL);
    (void)[self offlineTracksWorkQueue];
    _remote = [NSMutableDictionary dictionary];
    _remoteInFlight = [NSMutableSet set];
    [self startNetworkMonitor];
    [self startAudioOutputWatch];
    [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(PSChanged, (__bridge void *)self);
    if (src) {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
    // powerd posts this whenever the adapter or its charging policy changes (PowerUIAgent
    // pausing or resuming at a limit, a charger renegotiating). The IOPS source above misses
    // some of those, so the bar sat on a stale state until the next 15s tick.
    int token = 0;
    notify_register_dispatch("com.apple.system.powermanagement.poweradapter", &token,
                             dispatch_get_main_queue(), ^(int __unused t) { [self schedulePowerRefresh]; });
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(showPopoverRequested:)
        name:kShowPopoverNotification object:PopoverRequestObject()
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if (self.showDestinationOnLaunch) [self showPopoverRequested:[NSNotification notificationWithName:kShowPopoverNotification object:PopoverRequestObject() userInfo:@{@"destination": self.showDestinationOnLaunch}]];
}

static void PSChanged(void *ctx) { [(__bridge Controller *)ctx schedulePowerRefresh]; }

- (void)schedulePowerRefresh {
    // IOPS fires on every power-source twitch. One refresh a second covers the burst;
    // the 15s timer still samples on its own cadence.
    if (!ShouldArmPowerRefresh(_powerRefreshPending)) return;
    _powerRefreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPowerRefreshCoalesceSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_powerRefreshPending = NO;
        [self refresh];
    });
}

- (dispatch_queue_t)pmsetWorkQueue {
    if (!_pmsetQueue)
        _pmsetQueue = dispatch_queue_create("com.iantodd.glancebar.pmset", DISPATCH_QUEUE_SERIAL);
    return _pmsetQueue;
}

- (void)startAudioOutputWatch {
    _audioDevices = ReadAudioDevices();
    _audioPrevious = _audioDevices;
    _defaultOutputUID = DefaultOutputUID(_audioDevices);
    AudioObjectPropertyAddress devices = AudioAddr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertyAddress output = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devices, AudioHardwareChanged, (__bridge void *)self);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &output, AudioHardwareChanged, (__bridge void *)self);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud removeObjectForKey:@"audioRoutes"];
    [ud removeObjectForKey:@"audioRouteSavedDefaults"];
    _playerOutputUID = [ud stringForKey:kPlayerOutputUIDKey];
    if (![_playerOutputUID isKindOfClass:NSString.class]) _playerOutputUID = @"";
    _playerOutputName = [ud stringForKey:kPlayerOutputNameKey];
    if (![_playerOutputName isKindOfClass:NSString.class]) _playerOutputName = @"";
    __weak Controller *weakSelf = self;
    GBFineVolumeSetTargetProvider(^AudioObjectID { return [weakSelf fineVolumeTargetDeviceID]; });
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(musicPlayerInfo:)
        name:@"com.apple.Music.playerInfo" object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(spotifyPlaybackChanged:)
        name:@"com.spotify.client.PlaybackStateChanged" object:nil];
}
- (void)audioDevicesChanged {
    _audioDevicesChangedAt = CFAbsoluteTimeGetCurrent();
    // Bluetooth often publishes an input-only entry, then the output a moment later.
    // Wait until the list stops changing so that late output is still a new device.
    NSUInteger generation = ++_audioSettleGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->_audioSettleGen) return;
        NSArray<NSDictionary *> *now = ReadAudioDevices();
        NSDictionary *deviceDiff = PlaybackDeviceDiff(self->_audioPrevious, now);
        if (deviceDiff && self->_audioPrevious) {
            [self notePlayback:@"devices" fields:deviceDiff];
            [self playbackCause:@"devices-changed"];
        }
        NSString *adopt = ChooseNewOutputDevice(self->_audioPrevious, now, SwitchToNewOutputs());
        // A routed speaker arriving is the routed app's, not everything's.
        // (Judged with the output about to be adopted: arriving headphones are still adopted,
        // and the plan then stands down for them.)
        self->_audioPrevious = now;
        self->_audioDevices = now;
        if (adopt) {
            for (NSDictionary *row in now) {
                if ([row[@"uid"] isEqual:adopt]) { SetOutputDevice((AudioObjectID)[row[@"deviceID"] unsignedIntValue]); break; }
            }
        }
        self->_defaultOutputUID = DefaultOutputUID(now);
        [self applyPlayerAudioOutput];
        [self watchOutputVolume];
        [self refreshOutputVolume];
        if (self->_popover.isShown) [self rebuildContent];
    });
}
- (void)audioDefaultChanged {
    _defaultOutputUID = DefaultOutputUID(_audioDevices ?: ReadAudioDevices());
    if (!_audioDevices) _audioDevices = ReadAudioDevices();
    if (_defaultOutputUID.length && ![_defaultOutputUID isEqual:_playbackLoggedOutputUID]) {
        BOOL first = _playbackLoggedOutputUID == nil;
        _playbackLoggedOutputUID = _defaultOutputUID;
        if (!first) {
            [self notePlayback:@"output" fields:nil];
            [self playbackCause:@"output-changed"];
        }
    }
    [self applyPlayerAudioOutput];
    [self watchOutputVolume];
    [self refreshOutputVolume];
    if (_popover.isShown) [self rebuildContent];
}
- (void)setPlayerOutputChoiceUID:(NSString *)uid name:(NSString *)name {
    _playerOutputUID = [uid isKindOfClass:NSString.class] ? uid : @"";
    _playerOutputName = [name isKindOfClass:NSString.class] ? name : @"";
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (_playerOutputUID.length) {
        [ud setObject:_playerOutputUID forKey:kPlayerOutputUIDKey];
        if (_playerOutputName.length) [ud setObject:_playerOutputName forKey:kPlayerOutputNameKey];
        else [ud removeObjectForKey:kPlayerOutputNameKey];
    } else {
        [ud removeObjectForKey:kPlayerOutputUIDKey];
        [ud removeObjectForKey:kPlayerOutputNameKey];
        _playerOutputName = @"";
    }
    [self applyPlayerAudioOutput];
    [self watchOutputVolume];
    [self refreshOutputVolume];
    if (_popover.isShown) [self rebuildContent];
}
- (AudioObjectID)fineVolumeTargetDeviceID {
    if (!_localPlayer || _localPlayer.rate <= 0) return kAudioObjectUnknown;
    NSDictionary *defaultDevice = nil;
    for (NSDictionary *row in _audioDevices)
        if ([row[@"uid"] isEqual:_defaultOutputUID]) { defaultDevice = row; break; }
    if (AudioOutputKind(defaultDevice) == GlanceAudioOutputKindAudibleControllable) return kAudioObjectUnknown;
    return [self playerOutputDeviceID];
}
- (void)applyPlayerAudioOutput {
    NSDictionary *choice = [self playerOutputChoice];
    NSString *uid = [choice[@"followsSystemDefault"] boolValue] ? nil : choice[@"effectiveUID"];
    if (!uid.length) uid = nil;
    AVQueuePlayer *lp = _localPlayer, *out = _localOutgoing;
    for (AVQueuePlayer *player in (lp && out ? @[lp, out] : lp ? @[lp] : out ? @[out] : @[])) {
        player.audioOutputDeviceUniqueID = uid;
        player.muted = _musicSilentQA;
    }
}
- (NSDictionary *)playerOutputChoice {
    [self ensureAudioDisplay];
    return PlayerOutputChoice(_playerOutputUID, _playerOutputName, _audioDevices, _defaultOutputUID);
}
- (void)musicPlayerInfo:(NSNotification *)note {
    if (_musicOff) return;
    [self updateExternalPlaybackFrom:ParseExternalPlayback(note.userInfo, @"music")];
}
- (void)spotifyPlaybackChanged:(NSNotification *)note {
    if (_musicOff) return;
    [self updateExternalPlaybackFrom:ParseExternalPlayback(note.userInfo, @"spotify")];
}
- (void)updateExternalPlaybackFrom:(NSDictionary *)parsed {
    if (_localMode && _localPlayer) {
        if (_externalPlayback) { _externalPlayback = nil; if (_popover.isShown) [self rebuildContent]; }
        return;
    }
    if (![parsed[@"source"] length]) return;
    if (![parsed[@"valid"] boolValue]) {
        if ([_externalPlayback[@"source"] isEqual:parsed[@"source"]]) _externalPlayback = nil;
    } else _externalPlayback = parsed;
    if (_popover.isShown) [self rebuildContent];
}
- (AudioObjectID)playerOutputDeviceID {
    return [[self playerOutputChoice][@"device"][@"deviceID"] unsignedIntValue];
}
- (void)writeOutputVolume:(double)value device:(AudioObjectID)device {
    if (_musicProbesEnabled && device != kAudioObjectUnknown) SetOutputVolume(device, value);
}
// Listen to the current output's volume and mute, moving the listener when the output changes.
- (void)watchOutputVolume {
    if (!_musicProbesEnabled || _audioFrozen) return;
    AudioObjectID device = [self playerOutputDeviceID];
    if (device == _volumeWatched) return;
    void (^each)(AudioObjectID, BOOL) = ^(AudioObjectID d, BOOL add) {
        NSMutableArray *addresses = [NSMutableArray array];
        for (NSNumber *e in OutputVolumeElements(d)) [addresses addObject:@[@(kAudioDevicePropertyVolumeScalar), e]];
        [addresses addObject:@[@(kAudioDevicePropertyMute), @(kAudioObjectPropertyElementMain)]];
        for (NSArray *pair in addresses) {
            AudioObjectPropertyAddress a = {[pair[0] unsignedIntValue], kAudioDevicePropertyScopeOutput, [pair[1] unsignedIntValue]};
            if (!AudioObjectHasProperty(d, &a)) continue;
            if (add) AudioObjectAddPropertyListener(d, &a, OutputVolumeChanged, (__bridge void *)self);
            else AudioObjectRemovePropertyListener(d, &a, OutputVolumeChanged, (__bridge void *)self);
        }
    };
    if (_volumeWatched != kAudioObjectUnknown) each(_volumeWatched, NO);
    if (device != kAudioObjectUnknown) each(device, YES);
    _volumeWatched = device;
}
- (void)refreshOutputVolume {
    AudioObjectID device = [self playerOutputDeviceID];
    if (!_musicProbesEnabled || _audioFrozen) return;
    if (device == kAudioObjectUnknown) { _outputVolume = -1; _outputMuted = NO; return; }
    BOOL muted = NO;
    _outputVolume = ReadOutputVolume(device, &muted);
    _outputMuted = muted;
}
// Volume keys send a burst of changes: rebuild once, and not for our own slider's echo.
- (void)outputVolumeChanged {
    [self refreshOutputVolume];
    if (!_popover.isShown || _volumeRebuildPending || CFAbsoluteTimeGetCurrent() - _volumeSetAt < 0.5) return;
    _volumeRebuildPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_volumeRebuildPending = NO;
        if (self->_popover.isShown) [self rebuildContent];
    });
}
#pragma mark Seed mixes

// The library is read in the background when the popover first needs tiles, then every 6 h.
- (void)ensureMixSeeds {
    if (_mixFrozen || _musicOff) return;
    // Today's tiles stay up when Music is closed, the Mac is offline, or the library read fails.
    // The read used to be the only place saved seeds were applied, so the row vanished (5 Nov 2026).
    if (!_mixSeeds.count) {
        NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:@"mixSeeds"];
        if ([saved isKindOfClass:NSArray.class] && saved.count) {
            _mixSeeds = saved;
            // Covers were only loaded after a library read, which needs Music open: after a
            // relaunch with Music closed the tiles showed the placeholder note (12 Nov 2026).
            for (NSDictionary *seed in saved)
                if ([seed isKindOfClass:NSDictionary.class]) [self loadMixArt:seed];
            if (_popover.isShown) [self rebuildContent];
        }
    }
    [self ensureOfflinePlaylists];
    if (!_musicProbesEnabled || !AppleMusicIsRunning()) return;
    // Scripting Music launches it: read the library only while it is already open. On a Mac with an
    // empty library this retried and relaunched Music (1 Nov 2026).
    BOOL stale = !_mixLibrary || CFAbsoluteTimeGetCurrent() - _mixLibraryAt > 6 * 3600;
    if (stale && !_mixLibraryLoading) {
        _mixLibraryLoading = YES;
        RunAppleScriptTimed(kMixLibraryScript, 90, ^(NSString *output, __unused NSString *errorText, int status) {
            self->_mixLibraryLoading = NO;
            NSArray *tracks = status == 0 ? ParseMixLibrary(output) : nil;
            if (tracks.count < 20) return;   // Music closed, or permission not given yet
            NSSet *liked = [self mixLiked];
            NSString *hist =
                [NSString stringWithContentsOfFile:[GBHomeDirectory() stringByAppendingPathComponent:
                                                   @".local/state/selector/heart-history.jsonl"]
                                        encoding:NSUTF8StringEncoding
                                           error:nil];
            NSSet *everHearted = HeartHistoryEverHeartedKeys(hist);
            NSMutableArray *marked = [NSMutableArray arrayWithCapacity:tracks.count];
            for (NSDictionary *t in tracks) {
                NSMutableDictionary *m = [t mutableCopy];
                if ([liked containsObject:t[@"id"]]) m[@"thumb"] = @YES;
                NSString *selKey = SelectorTrackKey(t[@"artist"], t[@"title"]);
                if (selKey.length && [everHearted containsObject:selKey] && ![m[@"fav"] boolValue])
                    m[@"everHeart"] = @YES;
                [marked addObject:m];
            }
            self->_mixLibrary = marked;
            self->_mixLibraryAt = CFAbsoluteTimeGetCurrent();
            [self chooseMixSeeds:NO];
        });
        return;
    }
    if (_mixLibrary && !_mixSeeds.count) [self chooseMixSeeds:NO];
}
// Four seeds a day (the same all day), or a fresh set on New picks. Recent seeds sit out.
- (void)chooseMixSeeds:(BOOL)fresh {
    if (fresh) { ++_offlinePlayGeneration; _mixStartingKey = nil; }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger day = (NSInteger)floor((NSDate.date.timeIntervalSince1970 + NSTimeZone.localTimeZone.secondsFromGMT) / 86400);
    NSArray *saved = [ud arrayForKey:@"mixSeeds"];
    if (!fresh && [ud integerForKey:@"mixSeedsDay"] == day && saved.count) {
        _mixSeeds = saved;
    } else {
        NSInteger picks = [ud integerForKey:@"mixPickCount"] + (fresh ? 1 : 0);
        [ud setInteger:picks forKey:@"mixPickCount"];
        NSArray *recent = [ud arrayForKey:@"mixRecentSeeds"] ?: @[];
        NSArray *seeds = ChooseMixSeeds(_mixLibrary, recent, 4, (uint64_t)day * 7919 + (uint64_t)picks);
        if (!seeds.count) return;
        NSMutableArray *keep = [recent mutableCopy];
        for (NSDictionary *seed in seeds) [keep addObject:seed[@"key"]];
        while (keep.count > 24) [keep removeObjectAtIndex:0];
        [ud setObject:keep forKey:@"mixRecentSeeds"];
        [ud setInteger:day forKey:@"mixSeedsDay"];
        if (fresh) {
            _mixSeedsNextGen++;
            _mixSeedsNextSince = CFAbsoluteTimeGetCurrent();
            _mixSeedsNext = seeds;
            for (NSDictionary *seed in seeds) {
                [self loadMixArt:seed];
                [self prepareMix:seed then:nil];
            }
            [self saveOfflineRequests];
        } else {
            for (NSDictionary *old in _mixSeeds) [_offlineRequests removeObjectForKey:old[@"key"]];
            _mixSeeds = seeds;
            [ud setObject:seeds forKey:@"mixSeeds"];
            [_mixPrepared removeAllObjects];
            for (NSDictionary *seed in seeds) {
                [self loadMixArt:seed];
                [self prepareMix:seed then:nil];
            }
            [self saveOfflineRequests];
        }
    }
    for (NSDictionary *seed in _mixSeeds) { [self loadMixArt:seed]; [self prepareMix:seed then:nil]; }
    if (_popover.isShown) [self rebuildContent];
}
- (void)loadMixArt:(NSDictionary *)seed {
    NSString *trackID = seed[@"trackID"];
    if (!trackID.length || _mixArt[trackID]) return;
    NSString *path = [MixDirectory(@"art") stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"jpg"]];
    NSImage *cached = [NSFileManager.defaultManager fileExistsAtPath:path] ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (cached) { _mixArt[trackID] = cached; return; }
    BOOL musicOpen = AppleMusicIsRunning();   // asking a closed Music for artwork would launch it
    void (^show)(void) = ^{
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
        if (!img) return;
        self->_mixArt[trackID] = img;
        if (self->_popover.isShown) [self rebuildContent];
    };
    // Streamed tracks have no artwork data on this Mac, so fall back to Apple's catalogue cover.
    void (^fromCatalogue)(void) = ^{
        NSURLSession *session = NSURLSession.sharedSession;
        [[session dataTaskWithURL:MixArtSearchURL(seed[@"artist"], seed[@"title"])
                completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            NSString *art = MixArtURLFromSearch(data, seed[@"artist"], 600);   // sharp at the hover size
            if (!art) return;
            [[session dataTaskWithURL:[NSURL URLWithString:art] completionHandler:^(NSData *jpg, __unused NSURLResponse *r, __unused NSError *e) {
                if (jpg.length < 1000 || ![jpg writeToFile:path atomically:YES]) return;
                dispatch_async(dispatch_get_main_queue(), show);
            }] resume];
        }] resume];
    };
    NSString *script = [NSString stringWithFormat:@"tell application \"Music\"\n"
        "set t to (first track of library playlist 1 whose persistent ID is %@)\n"
        "set a to raw data of artwork 1 of t\n"
        "end tell\n"
        "set fh to open for access (POSIX file %@) with write permission\n"
        "set eof fh to 0\nwrite a to fh\nclose access fh\nreturn \"ok\"", AppleScriptQuoted(trackID), AppleScriptQuoted(path)];
    if (!musicOpen) { fromCatalogue(); return; }
    RunAppleScriptTimed(script, 20, ^(__unused NSString *output, __unused NSString *errorText, int status) {
        if (status == 0 && [[NSImage alloc] initWithContentsOfFile:path]) show();
        else { [NSFileManager.defaultManager removeItemAtPath:path error:nil]; fromCatalogue(); }
    });
}
// Requests are durable, fixed playlist snapshots. Play uses verified on-disk files in order;
// missing entries are skipped. Tiles are unavailable only when nothing is on this Mac.
- (NSString *)offlinePrimaryKey { return [@"playlist:" stringByAppendingString:[self appleMusicPlaylistName]]; }
- (NSString *)offlineCoverageCacheKey:(NSString *)key {
    return [NSString stringWithFormat:@"%@|%lu|%lu", key ?: @"", (unsigned long)_offlineRequestsGeneration,
            (unsigned long)(_offlineManifest ? _offlineManifest.hash : 0)];
}
- (void)invalidateOfflineCoverageCache {
    [_offlineCoverageCache removeAllObjects];
}
- (void)storeOfflineCoverage:(NSDictionary *)computed fingerprints:(NSArray *)fingerprints forKey:(NSString *)key
                    cacheKey:(NSString *)cacheKey request:(NSDictionary *)request manifest:(NSDictionary *)manifest {
    if (!computed) computed = @{@"total": @0, @"available": @0, @"ready": @NO, @"complete": @NO, @"paths": @[]};
    if (!_offlineCoverageCache) _offlineCoverageCache = [NSMutableDictionary dictionary];
    _offlineCoverageCache[cacheKey] = @{@"coverage": computed, @"fingerprints": fingerprints ?: @[]};
    (void)key; (void)request; (void)manifest;
}
- (void)scheduleOfflineCoverageRefresh:(NSString *)key {
    NSDictionary *request = _offlineRequests[key], *manifest = _offlineManifest;
    if (!request || !manifest) return;
    NSString *cacheKey = [self offlineCoverageCacheKey:key];
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSDictionary *requestCopy = request;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *computed = OfflinePlaylistCoverage(requestCopy, manifest, root, NO);
        NSArray *fingerprints = OfflinePlaylistDiskFingerprints(requestCopy, manifest, root);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![requestCopy isEqual:self->_offlineRequests[key]] || manifest != self->_offlineManifest) return;
            [self storeOfflineCoverage:computed fingerprints:fingerprints forKey:key cacheKey:cacheKey
                              request:requestCopy manifest:manifest];
            if (self->_popover.isShown) [self rebuildContent];
        });
    });
}
- (void)refreshOfflineCoverageCacheIfStale:(NSString *)key cached:(NSDictionary *)cached request:(NSDictionary *)request
                                  manifest:(NSDictionary *)manifest root:(NSString *)root cacheKey:(NSString *)cacheKey {
    NSDictionary *requestCopy = request, *manifestCopy = manifest;
    NSDictionary *cachedCopy = cached;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *disk = OfflinePlaylistDiskFingerprints(requestCopy, manifestCopy, root);
        if ([disk isEqual:cachedCopy[@"fingerprints"]]) return;
        NSDictionary *computed = OfflinePlaylistCoverage(requestCopy, manifestCopy, root, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![requestCopy isEqual:self->_offlineRequests[key]] || manifestCopy != self->_offlineManifest) return;
            [self storeOfflineCoverage:computed fingerprints:disk forKey:key cacheKey:cacheKey
                              request:requestCopy manifest:manifestCopy];
            if (self->_popover.isShown) [self rebuildContent];
        });
    });
}
- (NSDictionary *)offlineCoverageForDisplay:(NSString *)key {
    NSString *cacheKey = [self offlineCoverageCacheKey:key];
    NSDictionary *request = _offlineRequests[key], *manifest = _offlineManifest;
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSDictionary *cached = _offlineCoverageCache[cacheKey];
    if (cached) {
        [self refreshOfflineCoverageCacheIfStale:key cached:cached request:request manifest:manifest root:root cacheKey:cacheKey];
        return cached[@"coverage"];
    }
    __block NSDictionary *computed = nil;
    __block NSArray *fingerprints = nil;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        computed = OfflinePlaylistCoverage(request, manifest, root, NO);
        fingerprints = OfflinePlaylistDiskFingerprints(request, manifest, root);
    });
    [self storeOfflineCoverage:computed fingerprints:fingerprints forKey:key cacheKey:cacheKey request:request manifest:manifest];
    return computed ?: @{@"total": @0, @"available": @0, @"ready": @NO, @"complete": @NO, @"paths": @[]};
}
- (NSDictionary *)offlineCoverage:(NSString *)key verifyHash:(BOOL)verifyHash {
    if (verifyHash) {
        return OfflinePlaylistCoverage(_offlineRequests[key], _offlineManifest,
            [GBHomeDirectory() stringByAppendingPathComponent:@"Music"], verifyHash);
    }
    NSString *cacheKey = [self offlineCoverageCacheKey:key];
    NSDictionary *request = _offlineRequests[key], *manifest = _offlineManifest;
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSDictionary *cached = _offlineCoverageCache[cacheKey];
    if (cached) {
        NSDictionary *coverage = cached[@"coverage"];
        [self refreshOfflineCoverageCacheIfStale:key cached:cached request:request manifest:manifest root:root cacheKey:cacheKey];
        return coverage;
    }
    __block NSDictionary *computed = nil;
    __block NSArray *fingerprints = nil;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        computed = OfflinePlaylistCoverage(request, manifest, root, NO);
        fingerprints = OfflinePlaylistDiskFingerprints(request, manifest, root);
    });
    [self storeOfflineCoverage:computed fingerprints:fingerprints forKey:key cacheKey:cacheKey request:request manifest:manifest];
    return computed ?: @{@"total": @0, @"available": @0, @"ready": @NO, @"complete": @NO, @"paths": @[]};
}
- (NSString *)offlineStatus:(NSDictionary *)coverage {
    NSUInteger total = [coverage[@"total"] unsignedIntegerValue], available = [coverage[@"available"] unsignedIntegerValue];
    if (!total) return @"0 of 0 on this Mac";
    return [NSString stringWithFormat:@"%lu of %lu on this Mac", (unsigned long)available, (unsigned long)total];
}
- (void)retryUnpreparedMixSeeds {
    _onDiskLibraryIDs = nil;
    for (NSDictionary *seed in _mixSeeds)
        if (!_mixPrepared[seed[@"key"]] && ![_mixPreparing containsObject:seed[@"key"]]) [self prepareMix:seed then:nil];
    for (NSDictionary *seed in _mixSeedsNext)
        if (!_mixPrepared[seed[@"key"]] && ![_mixPreparing containsObject:seed[@"key"]]) [self prepareMix:seed then:nil];
}
- (NSSet<NSString *> *)onDiskLibraryTrackIDs {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_onDiskLibraryIDs && now - _onDiskLibraryAt < 300) return _onDiskLibraryIDs;
    NSMutableSet *ids = [NSMutableSet set];
    NSDictionary *manifest = _offlineManifest;
    if ([manifest[@"schemaVersion"] isEqual:@1] && [manifest[@"playlists"] isKindOfClass:NSArray.class]) {
        for (id playlist in manifest[@"playlists"]) {
            if (![playlist isKindOfClass:NSDictionary.class]) continue;
            for (id record in [playlist[@"tracks"] isKindOfClass:NSArray.class] ? playlist[@"tracks"] : @[]) {
                if (![record isKindOfClass:NSDictionary.class] || ![record[@"path"] length]) continue;
                NSString *trackID = record[@"id"];
                if ([trackID isKindOfClass:NSString.class] && trackID.length) [ids addObject:trackID];
            }
        }
    }
    _onDiskLibraryIDs = [ids copy];
    _onDiskLibraryAt = now;
    return _onDiskLibraryIDs;
}
- (NSString *)musicLibraryHotDirPath {
    if (_musicLibraryHotDir.length) return _musicLibraryHotDir;
    NSString *path = [GBHomeDirectory() stringByAppendingPathComponent:@".config/glancebar/music-library.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *hot = [doc isKindOfClass:NSDictionary.class] && [doc[@"hot_dir"] isKindOfClass:NSString.class] ? doc[@"hot_dir"] : @"";
    if (!hot.length) hot = @"~/Music/Glancebar Lossless";
    if ([hot hasPrefix:@"~"]) hot = [GBHomeDirectory() stringByAppendingPathComponent:[hot substringFromIndex:2]];
    _musicLibraryHotDir = hot.stringByStandardizingPath;
    return _musicLibraryHotDir;
}
- (BOOL)meteredLinkActive {
    return [NSFileManager.defaultManager fileExistsAtPath:
        [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/METERED_LINK"]];
}
- (BOOL)musicLibraryCannotFetch {
    return MusicLibraryCannotFetch(_networkKnown ? _networkOnline : YES, [self meteredLinkActive],
                                   _musicLibraryLastError, _musicLibraryUnmatched, _musicLibraryOverflow);
}
- (BOOL)musicLibraryCannotFetchForKey:(NSString *)key {
    return MusicLibraryCannotFetchForPlaylist(_musicLibraryStatus, key,
        _networkKnown ? _networkOnline : YES, [self meteredLinkActive]);
}
- (BOOL)noteMusicLibraryHelperLaunch {
    BOOL shouldLog = NO;
    if (!_musiclibHelperLaunchTimes) _musiclibHelperLaunchTimes = [NSMutableArray array];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL ok = MusicLibraryHelperLaunchPermitted(now, _musiclibHelperLaunchTimes, 6, 300, &shouldLog);
    if (ok) [_musiclibHelperLaunchTimes addObject:@(now)];
    else if (shouldLog && !_musiclibHelperLaunchLogged) {
        _musiclibHelperLaunchLogged = YES;
        NSLog(@"Glancebar: music-library helper launches rate-limited (6 per 5 min)");
    }
    return ok;
}
- (BOOL)isMixPlaylistKey:(NSString *)key {
    if (!key.length) return NO;
    if ([key isEqual:@"station:triplej"]) return YES;
    for (NSDictionary *seed in _mixSeeds)
        if ([seed[@"key"] isEqual:key]) return YES;
    for (NSDictionary *seed in _mixSeedsNext)
        if ([seed[@"key"] isEqual:key]) return YES;
    return NO;
}
- (NSDictionary *)mixTileStateForKey:(NSString *)key {
    NSDictionary *coverage = [self offlineCoverageForDisplay:key];
    if (![self isMixPlaylistKey:key]) return coverage;
    return OfflineMixTileState(coverage, _musiclibBusy, [self musicLibraryCannotFetchForKey:key]);
}
// Library refresh coalescer (one leg at a time; completion handlers never force a storm):
//   idle --maybeScheduleMusicLibrarySync--> syncing
//   syncing --done--> idle + queue cache + queue status
//   idle --libraryRefreshPump--> preparing --done--> idle + (status at most once, 30 s apart)
//   idle --libraryRefreshPump--> reading-status --done--> idle + maybeScheduleMusicLibrarySync (never cache)
// Tile clicks may bypass sync backoff once; busy and the helper rate limit still apply.
static const NSUInteger kLibraryRefreshIdle = 0;
static const NSUInteger kLibraryRefreshSyncing = 1;
static const NSUInteger kLibraryRefreshPreparingCache = 2;
static const NSUInteger kLibraryRefreshReadingStatus = 3;
- (void)libraryRefreshPump {
    for (;;) {
        if (_libraryRefreshPhase != kLibraryRefreshIdle) return;
        if (_libraryRefreshWantsCache && !_offlineCacheBusy) {
            _libraryRefreshWantsCache = NO;
            [self prepareOfflineCache];
            if (_offlineCacheBusy || _libraryRefreshPhase != kLibraryRefreshIdle) return;
            continue;
        }
        if (_libraryRefreshWantsStatus) {
            _libraryRefreshWantsStatus = NO;
            [self reloadMusicLibraryStatus];
            if (_libraryRefreshPhase != kLibraryRefreshIdle) return;
            continue;
        }
        if (_libraryRefreshWantsSync) {
            _libraryRefreshWantsSync = NO;
            [self maybeScheduleMusicLibrarySync];
        }
        return;
    }
}
- (void)libraryRefreshScheduleAfterRequestSave {
    _libraryRefreshWantsCache = YES;
    _libraryRefreshWantsSync = YES;
    [self libraryRefreshPump];
}
- (void)reloadMusicLibraryStatus {
    if (!_musicProbesEnabled || _mixFrozen || _musicOff) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_musicLibraryStatusAt > 0 && now - _musicLibraryStatusAt < 30) {
        _libraryRefreshPhase = kLibraryRefreshIdle;
        [self libraryRefreshPump];
        return;
    }
    if (!_libraryRefreshPhase) _libraryRefreshPhase = kLibraryRefreshReadingStatus;
    if (![self noteMusicLibraryHelperLaunch]) {
        _libraryRefreshPhase = kLibraryRefreshIdle;
        [self libraryRefreshPump];
        return;
    }
    _musicLibraryStatusAt = now;
    NSString *script = [NSBundle.mainBundle pathForResource:@"musiclib" ofType:@"py"];
    if (!script.length) {
        _libraryRefreshPhase = kLibraryRefreshIdle;
        [self libraryRefreshPump];
        return;
    }
    NSString *dir = MixDirectory(nil);
    NSString *requests = [dir stringByAppendingPathComponent:@"offline-requests.json"];
    NSString *stateErr = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/glancebar-music-library/last-status.json"];
    NSData *errData = [NSData dataWithContentsOfFile:stateErr];
    id errDoc = errData ? [NSJSONSerialization JSONObjectWithData:errData options:0 error:nil] : nil;
        if ([errDoc isKindOfClass:NSDictionary.class]) {
        id err = errDoc[@"lastError"];
        _musicLibraryLastError = [err isKindOfClass:NSString.class] ? err : (err == [NSNull null] ? @"" : @"");
        NSString *low = _musicLibraryLastError.lowercaseString;
        _musicLibraryUnmatched = [low containsString:@"unmatched"] || [low containsString:@"ambiguous"];
        _musicLibraryOverflow = [low containsString:@"cap exceeded"] || [low containsString:@"overflow"];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        task.arguments = @[script, @"status", @"--requests", requests];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        NSDictionary *status = nil;
        if ([task launchAndReturnError:nil]) {
            [task waitUntilExit];
            NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
            id parsed = out.length ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
            if ([parsed isKindOfClass:NSDictionary.class]) status = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status) self->_musicLibraryStatus = status;
            [self maybeSwapMixSeedsNext];
            self->_libraryRefreshPhase = kLibraryRefreshIdle;
            [self maybeScheduleMusicLibrarySync];
            [self libraryRefreshPump];
            if (self->_popover.isShown) [self rebuildContent];
        });
    });
}
- (void)maybeScheduleMusicLibrarySync {
    [self maybeScheduleMusicLibrarySyncBypassingBackoff:NO];
}
- (void)maybeScheduleMusicLibrarySyncBypassingBackoff:(BOOL)bypass {
    if (!_musicProbesEnabled || _mixFrozen || _musicOff) return;
    if (!MusicLibraryStatusIncomplete(_musicLibraryStatus)) return;
    BOOL metered = [self meteredLinkActive];
    BOOL may = MusicLibraryMayStartSync(CFAbsoluteTimeGetCurrent(), _musiclibLastSyncAttemptAt, _musiclibSyncFailures,
        _offlineRequestsGeneration, _musiclibLastAttemptGeneration, _musiclibSyncedRequestGeneration,
        _musiclibBusy || _libraryRefreshPhase == kLibraryRefreshSyncing, _networkKnown ? _networkOnline : YES, metered,
        _musiclibLastAttemptTerminal, bypass || _musiclibSyncBypassBackoff);
    _musiclibSyncBypassBackoff = NO;
    if (!may) return;
    if (_libraryRefreshPhase != kLibraryRefreshIdle) {
        _libraryRefreshWantsSync = YES;
        return;
    }
    [self prepareMusicLibrarySync];
}
- (void)prepareMusicLibrarySync {
    if (!_musicProbesEnabled || _mixFrozen || _musicOff) return;
    if (_musiclibBusy) { _musiclibAgain = YES; return; }
    if (![self noteMusicLibraryHelperLaunch]) return;
    NSString *script = [NSBundle.mainBundle pathForResource:@"musiclib" ofType:@"py"];
    if (!script.length) return;
    _libraryRefreshPhase = kLibraryRefreshSyncing;
    _musiclibLastSyncAttemptAt = CFAbsoluteTimeGetCurrent();
    _musiclibLastAttemptGeneration = _offlineRequestsGeneration;
    _musiclibBusy = YES;
    NSString *dir = MixDirectory(nil);
    NSString *requests = [dir stringByAppendingPathComponent:@"offline-requests.json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        task.arguments = @[script, @"sync", @"--requests", requests];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        BOOL launched = [task launchAndReturnError:nil];
        if (launched) [task waitUntilExit];
        int status = launched ? (int)task.terminationStatus : -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_musiclibBusy = NO;
            if (status == 0) {
                self->_musiclibSyncFailures = 0;
                self->_musiclibSyncedRequestGeneration = self->_offlineRequestsGeneration;
                self->_musiclibLastAttemptTerminal = NO;
                self->_musicLibraryLastError = @"";
                self->_musicLibraryUnmatched = NO;
                self->_musicLibraryOverflow = NO;
            } else if (launched) {
                self->_musiclibSyncFailures++;
                NSString *stateErr = [GBHomeDirectory() stringByAppendingPathComponent:
                    @".local/state/glancebar-music-library/last-status.json"];
                NSData *errData = [NSData dataWithContentsOfFile:stateErr];
                id errDoc = errData ? [NSJSONSerialization JSONObjectWithData:errData options:0 error:nil] : nil;
                if ([errDoc isKindOfClass:NSDictionary.class]) {
                    id err = errDoc[@"lastError"];
                    self->_musicLibraryLastError = [err isKindOfClass:NSString.class] ? err :
                        (err == [NSNull null] ? @"" : self->_musicLibraryLastError);
                }
                self->_musiclibLastAttemptTerminal = MusicLibrarySyncFailureTerminal(self->_musicLibraryLastError);
            }
            self->_libraryRefreshPhase = kLibraryRefreshIdle;
            self->_libraryRefreshWantsCache = YES;
            self->_libraryRefreshWantsStatus = YES;
            [self libraryRefreshPump];
            if (self->_popover.isShown) [self rebuildContent];
            if (self->_musiclibAgain) { self->_musiclibAgain = NO; [self maybeScheduleMusicLibrarySync]; }
        });
    });
}
- (void)touchMusicLibraryFile:(NSString *)path {
    if (!_musicProbesEnabled || !path.length) return;
    NSString *hot = [self musicLibraryHotDirPath];
    if (!hot.length || ![path hasPrefix:hot]) return;
    NSString *script = [NSBundle.mainBundle pathForResource:@"musiclib" ofType:@"py"];
    if (!script.length) return;
    if (![self noteMusicLibraryHelperLaunch]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        task.arguments = @[script, @"touch", path];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        [task launchAndReturnError:nil];
    });
}
- (void)applyPromotedMixSeeds:(NSArray *)promoted {
    if (!promoted.count) return;
    for (NSDictionary *old in _mixSeeds) [_offlineRequests removeObjectForKey:old[@"key"]];
    _mixSeeds = promoted;
    _mixSeedsNext = nil;
    [NSUserDefaults.standardUserDefaults setObject:_mixSeeds forKey:@"mixSeeds"];
    [self saveOfflineRequests];
    if (_popover.isShown) [self rebuildContent];
}
- (void)maybeSwapMixSeedsNext {
    if (!_mixSeedsNext.count) return;
    BOOL allReady = YES;
    NSMutableDictionary *tiles = [NSMutableDictionary dictionary];
    for (NSDictionary *seed in _mixSeedsNext) {
        NSDictionary *tile = [self mixTileStateForKey:seed[@"key"]];
        tiles[seed[@"key"]] = tile;
        if (![tile[@"state"] isEqual:@"ready"]) allReady = NO;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSArray *promoted = MixSeedsNextPromotion(_mixSeedsNext, tiles, allReady, now - _mixSeedsNextSince, _musiclibBusy, 600);
    if (!promoted) return;
    if (!promoted.count) { _mixSeedsNext = nil; if (_popover.isShown) [self rebuildContent]; return; }
    [self applyPromotedMixSeeds:promoted];
}
- (void)prepareOfflineCache {
    if (!_musicProbesEnabled || _mixFrozen || _musicOff) return;
    if (_offlineCacheBusy) { _offlineCacheAgain = YES; return; }
    NSString *script = [NSBundle.mainBundle pathForResource:@"offline_cache" ofType:@"py"];
    if (!script.length) return;  // Test executables have no helper and must never scan a real music pool.
    if (![self noteMusicLibraryHelperLaunch]) return;
    if (_libraryRefreshPhase == kLibraryRefreshIdle) _libraryRefreshPhase = kLibraryRefreshPreparingCache;
    _offlineCacheBusy = YES;
    _offlinePreparedAt = CFAbsoluteTimeGetCurrent();
    NSString *dir = MixDirectory(nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        NSMutableArray *args = [@[script, @"prepare", @"--requests", [dir stringByAppendingPathComponent:@"offline-requests.json"],
            @"--manifest", [dir stringByAppendingPathComponent:@"offline-manifest.json"]] mutableCopy];
        NSString *index = [dir stringByAppendingPathComponent:@"offline-source-index.json"];
        if ([NSFileManager.defaultManager fileExistsAtPath:index]) [args addObjectsFromArray:@[@"--index", index]];
        task.arguments = args;
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        BOOL launched = [task launchAndReturnError:nil];
        if (launched) [task waitUntilExit];
        NSDictionary *manifest = nil;
        if (launched && task.terminationReason == NSTaskTerminationReasonExit && (task.terminationStatus == 0 || task.terminationStatus == 2)) {
            NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"offline-manifest.json"]];
            id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([parsed isKindOfClass:NSDictionary.class]) manifest = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_offlineCacheBusy = NO;
            if (manifest) {
                self->_offlineManifest = manifest;
                [self invalidateOfflineCoverageCache];
                [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:@"offline-manifest.metadata.json"] error:nil];
                [self retryUnpreparedMixSeeds];
                [self maybeSwapMixSeedsNext];
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (self->_musicLibraryStatusAt <= 0 || now - self->_musicLibraryStatusAt >= 30)
                    self->_libraryRefreshWantsStatus = YES;
            }
            self->_libraryRefreshPhase = kLibraryRefreshIdle;
            [self libraryRefreshPump];
            if (self->_popover.isShown) [self rebuildContent];
            if (self->_offlineCacheAgain) { self->_offlineCacheAgain = NO; [self prepareOfflineCache]; }
        });
    });
}
- (void)saveOfflineRequests {
    NSMutableArray *requests = [NSMutableArray array];
    for (NSDictionary *seed in _mixSeeds) if (_offlineRequests[seed[@"key"]]) [requests addObject:_offlineRequests[seed[@"key"]]];
    for (NSDictionary *seed in _mixSeedsNext)
        if (_offlineRequests[seed[@"key"]]) [requests addObject:_offlineRequests[seed[@"key"]]];
    NSDictionary *primary = _offlineRequests[[self offlinePrimaryKey]];
    if (primary) [requests addObject:primary];
    if (_offlineRequests[@"station:triplej"]) [requests addObject:_offlineRequests[@"station:triplej"]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"playlists": requests} options:0 error:nil];
    if ([data writeToFile:[MixDirectory(nil) stringByAppendingPathComponent:@"offline-requests.json"] atomically:YES]) {
        _offlineRequestsGeneration++;
        [self invalidateOfflineCoverageCache];
        [self libraryRefreshScheduleAfterRequestSave];
    }
}
- (void)setOfflineRequest:(NSString *)key title:(NSString *)title tracks:(NSArray *)tracks {
    NSMutableArray *identities = [NSMutableArray array];
    for (NSDictionary *track in tracks) {
        if (![track isKindOfClass:NSDictionary.class] || ![track[@"id"] isKindOfClass:NSString.class] || ![track[@"id"] length]) { [identities removeAllObjects]; break; }
        NSMutableDictionary *identity = [NSMutableDictionary dictionary];
        for (NSString *field in @[@"id", @"title", @"artist", @"album"])
            identity[field] = [track[field] isKindOfClass:NSString.class] ? track[field] : @"";
        if ([track[@"local_path"] isKindOfClass:NSString.class] && [track[@"local_path"] length])
            identity[@"local_path"] = track[@"local_path"];
        if ([track[@"catalogue_relative_path"] isKindOfClass:NSString.class] && [track[@"catalogue_relative_path"] length])
            identity[@"catalogue_relative_path"] = track[@"catalogue_relative_path"];
        if ([track[@"sha256"] isKindOfClass:NSString.class] && [track[@"sha256"] length])
            identity[@"sha256"] = track[@"sha256"];
        if ([track[@"duration"] isKindOfClass:NSNumber.class]) identity[@"duration"] = track[@"duration"];
        [identities addObject:identity];
    }
    if (!_offlineRequests) _offlineRequests = [NSMutableDictionary dictionary];
    NSDictionary *request = @{@"key": key, @"title": title ?: key, @"tracks": identities};
    if ([_offlineRequests[key] isEqual:request]) return;
    _offlineRequests[key] = request;
    [self saveOfflineRequests];
}
- (void)ensureOfflinePlaylists {
    if (!_musicProbesEnabled || _mixFrozen || _musicOff) return;
    if (!_offlineLoaded) {
        _offlineLoaded = YES;
        _offlineRequests = [NSMutableDictionary dictionary];
        if (!_mixPrepared) _mixPrepared = [NSMutableDictionary dictionary];
        NSString *dir = MixDirectory(nil);
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"offline-requests.json"]];
        id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([saved isKindOfClass:NSDictionary.class] && [saved[@"schemaVersion"] isEqual:@1] && [saved[@"playlists"] isKindOfClass:NSArray.class]) {
            for (id request in saved[@"playlists"]) {
                if (![request isKindOfClass:NSDictionary.class] || ![request[@"key"] isKindOfClass:NSString.class] || ![request[@"tracks"] isKindOfClass:NSArray.class]) continue;
                NSMutableArray *ids = [NSMutableArray array];
                for (id track in request[@"tracks"]) if ([track isKindOfClass:NSDictionary.class] && [track[@"id"] isKindOfClass:NSString.class]) [ids addObject:track[@"id"]];
                if (ids.count != [request[@"tracks"] count]) continue;
                _offlineRequests[request[@"key"]] = request;
                if (ids.count) _mixPrepared[request[@"key"]] = ids;
            }
        }
        data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"offline-manifest.json"]];
        id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([manifest isKindOfClass:NSDictionary.class]) _offlineManifest = manifest;
        [self prepareOfflineCache];
    }
    // The existing exporter provides a named playlist snapshot without launching Music,
    // acquiring a playback lease, or consulting the stale download inventory.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!_offlineCacheBusy && now - _offlinePreparedAt >= 300) _libraryRefreshWantsCache = YES;
    // A background look every ten minutes. A sync finishing or a request changing asks for a
    // status read at once; polling every 30 s ran a helper process around the clock.
    if (now - _musicLibraryStatusAt >= 600) _libraryRefreshWantsStatus = YES;
    [self maybeScheduleMusicLibrarySync];
    [self libraryRefreshPump];
    if (_offlineExportChecked > 0 && now - _offlineExportChecked < 60) return;
    _offlineExportChecked = now;
    NSString *path = [GBHomeDirectory() stringByAppendingPathComponent:@"Music/Library-export/playlists.json"];
    NSDate *date = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    if (!date || ([_offlineExportDate isEqual:date] && _offlineRequests[[self offlinePrimaryKey]])) return;
    _offlineExportDate = date;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id playlists = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![playlists isKindOfClass:NSArray.class]) {
        [self setOfflineRequest:[self offlinePrimaryKey] title:[self appleMusicPlaylistName] tracks:@[]];
        return;
    }
    for (id playlist in playlists) {
        if ([playlist isKindOfClass:NSDictionary.class] && [playlist[@"name"] isEqual:[self appleMusicPlaylistName]] && [playlist[@"tracks"] isKindOfClass:NSArray.class]) {
            [self setOfflineRequest:[self offlinePrimaryKey] title:playlist[@"name"] tracks:playlist[@"tracks"]];
            return;
        }
    }
    [self setOfflineRequest:[self offlinePrimaryKey] title:[self appleMusicPlaylistName] tracks:@[]];
}
// Mixes are built ahead once, then persisted. New picks explicitly replaces the snapshot.
- (void)prepareMix:(NSDictionary *)seed then:(void (^)(NSArray *ids))done {
    NSString *key = seed[@"key"];
    if (_mixPrepared[key]) { if (done) done(_mixPrepared[key]); return; }
    if ([_mixPreparing containsObject:key] || !_mixLibrary.count) return;
    [_mixPreparing addObject:key];
    NSSet *onDisk = [self onDiskLibraryTrackIDs];
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *track in _mixLibrary) if ([onDisk containsObject:track[@"id"]]) [tracks addObject:track];
    BOOL claude = [NSUserDefaults.standardUserDefaults objectForKey:@"mixWithClaude"]
        ? [NSUserDefaults.standardUserDefaults boolForKey:@"mixWithClaude"] : YES;
    uint64_t salt = (uint64_t)[NSUserDefaults.standardUserDefaults integerForKey:@"mixPickCount"] * 31 + key.hash;
    NSUInteger pendingGen = _mixSeedsNextGen;
    dispatch_async(_mixQueue, ^{
        NSArray *ids = BuildSeedMix(tracks, seed, claude, salt);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_mixPreparing removeObject:key];
            if (!MixPrepareStillValid(key, self->_mixSeeds, self->_mixSeedsNext, pendingGen, self->_mixSeedsNextGen)) return;
            NSMutableArray *selected = [NSMutableArray array];
            for (NSString *trackID in ids) for (NSDictionary *track in tracks)
                if ([track[@"id"] isEqual:trackID]) { [selected addObject:track]; break; }
            if (ids.count && selected.count == ids.count) {
                self->_mixPrepared[key] = ids;
                [self setOfflineRequest:key title:seed[@"title"] tracks:selected];
            }
            if (done) done(ids);
        });
    });
}
- (BOOL)musicTimingLogEnabled {
    if (_musicTimingEnabled) return YES;
    const char *env = getenv("GLANCEBAR_MUSIC_TIMING");
    if (env && env[0] && strcmp(env, "0") != 0) return YES;
    return [NSUserDefaults.standardUserDefaults boolForKey:@"musicTimingLog"];
}
- (void)musicTimingMark:(NSString *)event {
    if (![self musicTimingLogEnabled]) return;
    if (!_musicTimingLog) _musicTimingLog = [NSMutableArray array];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double sinceClickMs = _musicTimingClick > 0 ? (now - _musicTimingClick) * 1000.0 : 0;
    [_musicTimingLog addObject:@{@"event": event ?: @"", @"ms": @(sinceClickMs), @"t": @(now)}];
    while (_musicTimingLog.count > 20) [_musicTimingLog removeObjectAtIndex:0];
    GBLog("music timing: %{public}@ +%.0f ms", event, sinceClickMs);
}
- (NSArray<NSDictionary *> *)musicTimingRecent {
    return [_musicTimingLog copy] ?: @[];
}
- (dispatch_queue_t)offlineHashQueue {
    if (!_offlineHashQueue) _offlineHashQueue = dispatch_queue_create("glancebar.offline-hash", DISPATCH_QUEUE_SERIAL);
    return _offlineHashQueue;
}
- (void)discardPreparedPlaylist {
    _preparedPlaylistKey = nil;
    _preparedFirstItem = nil;
}
- (void)preparePlaylistFirstItem:(NSString *)key {
    if (!key.length || _musicOff || !_musicProbesEnabled) return;
    if ([key isEqual:_preparedPlaylistKey] && _preparedFirstItem) return;
    [self discardPreparedPlaylist];
    NSDictionary *coverage = [self offlineCoverage:key verifyHash:NO];
    NSString *path = [coverage[@"paths"] isKindOfClass:NSArray.class] ? [coverage[@"paths"] firstObject] : nil;
    if (!path.length) return;
    NSDictionary *assetOpts = @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO};
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:assetOpts];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.preferredForwardBufferDuration = 2;
    _preparedPlaylistKey = [key copy];
    _preparedFirstItem = item;
}
- (void)schedulePreloadHover:(NSString *)key {
    [_preloadHoverTimer invalidate];
    _preloadHoverTimer = nil;
    _preloadHoverKey = [key copy];
    __weak Controller *weak = self;
    _preloadHoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *t) {
        (void)t;
        Controller *self = weak;
        if (!self || ![key isEqual:self->_preloadHoverKey]) return;
        [self preparePlaylistFirstItem:key];
    }];
}
- (void)cancelPreloadHover {
    [_preloadHoverTimer invalidate];
    _preloadHoverTimer = nil;
    _preloadHoverKey = nil;
}
- (BOOL)offlinePlaylistStillVisible:(NSString *)key {
    if (!key.length) return NO;
    if ([key isEqual:[self offlinePrimaryKey]] || [key isEqual:@"station:triplej"]) return YES;
    if (_offlineRequests[key]) return YES;
    for (NSDictionary *seed in _mixSeeds) if ([seed[@"key"] isEqual:key]) return YES;
    return NO;
}
// A track whose bytes no longer match its manifest hash leaves the queue. Addressed by path, never
// by index: the list may have changed since the hash was started. Transport intent is kept: a
// paused player stays paused, and a playing one moves to the next track.
- (void)dropLocalPath:(NSString *)path reason:(NSString *)reason {
    if (!_localMode || !path.length || !_localURLs.count) return;
    NSInteger current = _localIndex, removedBefore = 0;
    BOOL removedCurrent = NO;
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:_localURLs.count];
    for (NSInteger i = 0; i < (NSInteger)_localURLs.count; i++) {
        if ([_localURLs[i].path isEqual:path]) {
            if (i < current) removedBefore++;
            else if (i == current) removedCurrent = YES;
            continue;
        }
        [urls addObject:_localURLs[i]];
    }
    if (urls.count == _localURLs.count) return;
    GBLog("music: dropping track %{public}@ (%{public}@)", path.lastPathComponent, reason);
    [self notePlayback:@"drop" fields:@{@"item": path.lastPathComponent ?: @"", @"reason": reason ?: @""}];
    [self playbackCause:@"drop"];
    _libraryRefreshWantsSync = YES;
    [self libraryRefreshPump];
    BOOL wasPlaying = _playbackPlaying;
    _localURLs = urls;
    if (!urls.count) {
        [self tearDownLocalPlayer];
        _localMode = NO;
        _mixPlayingKey = nil;
        _playbackPlaying = NO;
        [self publishNowPlaying];
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    NSInteger index = current - removedBefore;
    AVPlayerItem *currentItem = _localPlayer.currentItem;
    if (removedCurrent || !currentItem) {
        if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
        _localStartPaused = !wasPlaying;
        [self playLocalIndex:index];
        _localStartPaused = NO;
        return;
    }
    // The current item is sound. Take only the rejected file out of the player's queue: the items
    // after the current one mirror consecutive list entries, so the window end moves back by the
    // number removed.
    _localIndex = index;
    NSMutableArray<AVPlayerItem *> *observed = [_localObservedItems mutableCopy] ?: [NSMutableArray array];
    NSInteger removedQueued = 0;
    for (AVPlayerItem *item in [_localPlayer.items copy]) {
        if (item == currentItem) continue;
        NSURL *url = [item.asset isKindOfClass:AVURLAsset.class] ? ((AVURLAsset *)item.asset).URL : nil;
        if (![url.path isEqual:path]) continue;
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
        [observed removeObjectIdenticalTo:item];
        [_localPlayer removeItem:item];
        removedQueued++;
    }
    _localObservedItems = observed;
    _localQueueEnd = MAX(_localIndex + 1, _localQueueEnd - removedQueued);
    [self maintainLocalPlayerQueue];
    if (_popover.isShown) [self rebuildContent];
}
- (NSDictionary *)offlineManifestRecordForPath:(NSString *)path key:(NSString *)key {
    NSDictionary *manifest = _offlineManifest;
    if (!path.length || !manifest) return nil;
    NSDictionary *entry = nil;
    if ([manifest[@"schemaVersion"] isEqual:@1] && [manifest[@"playlists"] isKindOfClass:NSArray.class]) {
        for (id candidate in manifest[@"playlists"])
            if ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"key"] isEqual:key]) { entry = candidate; break; }
    }
    for (id record in [entry[@"tracks"] isKindOfClass:NSArray.class] ? entry[@"tracks"] : @[]) {
        if ([record isKindOfClass:NSDictionary.class] && [record[@"path"] isEqual:path]) return record;
    }
    return nil;
}
// Background verification. All bookkeeping is on the main thread; the hash queue only ever sees
// immutable manifest records and reports back by path. A new playlist start changes the
// generation, which abandons queued work and ignores late results.
- (void)resetOfflineHashVerify:(NSUInteger)generation {
    _offlineHashGeneration = generation;
    atomic_store(&gOfflineHashLiveGeneration, generation);
    _offlineHashOK = [NSMutableSet set];
    _offlineHashPending = [NSMutableSet set];
}
- (void)maintainOfflineHashVerifyAhead {
    if (!_mixPlayingKey.length || !_localURLs.count || !_offlineHashOK) return;
    NSUInteger generation = _offlineHashGeneration;
    NSString *key = _mixPlayingKey, *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSInteger count = (NSInteger)_localURLs.count, from = MAX(0, MIN(_localIndex, count - 1));
    NSMutableArray<NSDictionary *> *batch = [NSMutableArray array];
    for (NSInteger step = 0; step < MIN(count, 10); step++) {
        NSString *path = _localURLs[(from + step) % count].path;
        if (!path.length || [_offlineHashOK containsObject:path] || [_offlineHashPending containsObject:path]) continue;
        NSDictionary *record = [self offlineManifestRecordForPath:path key:key];
        if (!record) continue;
        [_offlineHashPending addObject:path];
        [batch addObject:record];
    }
    if (!batch.count) return;
    dispatch_async([self offlineHashQueue], ^{
        for (NSDictionary *record in batch) {
            if (atomic_load(&gOfflineHashLiveGeneration) != generation) return;
            BOOL ok = OfflinePlaylistVerifyRecordHash(record, root);
            NSString *path = record[@"path"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_offlineHashGeneration) return;
                [self->_offlineHashPending removeObject:path];
                if (ok) [self->_offlineHashOK addObject:path];
                else if ([key isEqual:self->_mixPlayingKey]) [self dropLocalPath:path reason:@"sha256 mismatch"];
            });
        }
    });
}
- (void)playLocalPaths:(NSArray<NSString *> *)paths {
    [self playbackCauseIfNone:@"playlist"];
    if (!_musicProbesEnabled || !paths.count) return;
    OfflinePlaylistResetHashMetrics();
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
    NSString *first = paths.firstObject;
    BOOL uniform = first.length > 0;
    if (uniform) {
        for (NSString *path in paths) {
            if (!path.length || ![path isEqual:first]) { uniform = NO; break; }
        }
    }
    if (uniform) {
        NSURL *url = [NSURL fileURLWithPath:first];
        for (NSUInteger i = 0; i < paths.count; i++) [urls addObject:url];
    } else {
        for (NSString *path in paths) if (path.length) [urls addObject:[NSURL fileURLWithPath:path]];
    }
    if (!urls.count) return;
    _localURLs = urls;
    [self playLocalIndex:0];
    [self musicTimingMark:@"play"];
}
- (void)playOfflinePlaylist:(NSString *)key {
    if (!_musicProbesEnabled) return;
    NSUInteger generation = ++_offlinePlayGeneration;
    _mixStartingKey = nil;
    _musicTimingClick = CFAbsoluteTimeGetCurrent();
    [self musicTimingMark:@"click"];
    NSDictionary *tile = [self isMixPlaylistKey:key] ? [self mixTileStateForKey:key] : nil;
    if (tile && ([tile[@"state"] isEqual:@"fetching"] || ![tile[@"enabled"] boolValue])) {
        // Nothing playable on disk (or still arriving): a click asks for the tracks rather than doing nothing.
        _musicNote = tile[@"tooltip"];
        [self maybeScheduleMusicLibrarySyncBypassingBackoff:YES];
        _libraryRefreshWantsCache = YES;
        [self libraryRefreshPump];
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    // No hashing on the way to first audio. Each manifest record carries the size, mtime and inode
    // the file had when its SHA-256 was last confirmed; a file that still matches all three is
    // played now and re-hashed in the background (a mismatch drops that track from the queue).
    // This is a stat per track, computed fresh at the click: never the display cache, which may
    // describe the disk as it was a moment ago.
    NSDictionary *request = _offlineRequests[key], *manifest = _offlineManifest;
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSDictionary *coverage = OfflinePlaylistCoverage(request, manifest, root, NO);
    [self musicTimingMark:@"verify"];
    NSArray *paths = coverage[@"paths"];
    if (![coverage[@"ready"] boolValue] || !paths.count) {
        _musicNote = [self offlineStatus:coverage];
        [self invalidateOfflineCoverageCache];
        if (tile) {
            [self maybeScheduleMusicLibrarySyncBypassingBackoff:YES];
            _libraryRefreshWantsCache = YES;
            [self libraryRefreshPump];
        }
        [self prepareOfflineCache];
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    _mixStartingKey = key;
    if (![key isEqual:_preparedPlaylistKey]) [self discardPreparedPlaylist];
    // One hop through the main queue: repeated clicks collapse into the last one, and a pause, a
    // manifest change or the audio gate closing before the hop cancels the start.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_offlinePlayGeneration) {
            if (self->_popover.isShown) [self rebuildContent];
            return;
        }
        self->_mixStartingKey = nil;
        NSDictionary *currentManifest = self->_offlineManifest;
        if (!self->_musicProbesEnabled || self->_musicOff || ![self offlinePlaylistStillVisible:key] ||
            ![self->_offlineRequests[key] isEqual:request] ||
            !(manifest == currentManifest || [manifest isEqual:currentManifest])) {
            self->_musicNote = @"Offline playlist changed. Nothing was started.";
            if (self->_popover.isShown) [self rebuildContent];
            return;
        }
        self->_musicNote = nil;
        self->_mixPlayingKey = key;
        [self musicTimingMark:@"queue"];
        [self resetOfflineHashVerify:generation];
        [self playLocalPaths:paths];
        if (self->_popover.isShown) [self rebuildContent];
    });
}
- (void)playSeedLocally:(NSDictionary *)seed { [self playOfflinePlaylist:seed[@"key"]]; }
- (IBAction)playSeedMix:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_mixSeeds.count) return;
    [self playSeedLocally:_mixSeeds[sender.tag]];
}
- (IBAction)newMixPicks:(id)sender {
    (void)sender;
    if (!_mixLibrary) { [self ensureMixSeeds]; return; }
    [self chooseMixSeeds:YES];
}
- (void)ensureStation {
    if (_mixFrozen || !_musicProbesEnabled) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_stationLoaded && now - _stationChecked < 60) return;
    _stationChecked = now;
    NSString *scoutPath = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/glancebar-music-scout/new-music.json"];
    NSData *scoutData = [NSData dataWithContentsOfFile:scoutPath];
    id scoutRaw = scoutData ? [NSJSONSerialization JSONObjectWithData:scoutData options:0 error:nil] : nil;
    NSArray *scoutTracks = [scoutRaw isKindOfClass:NSDictionary.class] && [scoutRaw[@"tracks"] isKindOfClass:NSArray.class]
        ? scoutRaw[@"tracks"] : nil;
    if (scoutTracks.count) {
        _stationLoaded = YES;
        _stationDate = [NSFileManager.defaultManager attributesOfItemAtPath:scoutPath error:nil][NSFileModificationDate];
        NSMutableArray *tracks = [NSMutableArray array], *picks = [NSMutableArray array];
        for (id row in scoutTracks) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            NSString *trackKey = [row[@"track_key"] isKindOfClass:NSString.class] ? row[@"track_key"] : @"";
            NSString *title = [row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"";
            NSString *artist = [row[@"artist"] isKindOfClass:NSString.class] ? row[@"artist"] : @"";
            if (!trackKey.length || !title.length) continue;
            NSString *album = [row[@"album"] isKindOfClass:NSString.class] ? row[@"album"] : @"";
            NSMutableDictionary *track = [NSMutableDictionary dictionaryWithObjectsAndKeys:trackKey, @"id", title, @"title",
                                          artist, @"artist", album, @"album", nil];
            if ([row[@"duration"] isKindOfClass:NSNumber.class]) track[@"duration"] = row[@"duration"];
            else if ([row[@"duration"] isKindOfClass:NSString.class] && [(NSString *)row[@"duration"] length])
                track[@"duration"] = @([(NSString *)row[@"duration"] doubleValue]);
            if ([row[@"local_path"] isKindOfClass:NSString.class] && [(NSString *)row[@"local_path"] length])
                track[@"local_path"] = row[@"local_path"];
            if ([row[@"catalogue_relative_path"] isKindOfClass:NSString.class] && [(NSString *)row[@"catalogue_relative_path"] length])
                track[@"catalogue_relative_path"] = row[@"catalogue_relative_path"];
            if ([row[@"sha256"] isKindOfClass:NSString.class] && [(NSString *)row[@"sha256"] length])
                track[@"sha256"] = row[@"sha256"];
            [tracks addObject:track];
            NSString *why = [row[@"why"] isKindOfClass:NSString.class] ? row[@"why"] : @"";
            [picks addObject:@{@"title": title, @"artist": artist, @"reason": why}];
        }
        if (tracks.count) {
            _stationAvailable = YES;
            _stationFiles = @[];
            _stationPicks = picks;
            _stationTracks = tracks;
            [self setOfflineRequest:@"station:triplej" title:@"New music for you" tracks:tracks];
            return;
        }
    }
    NSString *path = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector/station.json"];
    NSDate *date = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    if (_stationLoaded && [_stationDate isEqual:date]) return;
    _stationLoaded = YES; _stationDate = date;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *station = StationFromJSON(data);
    _stationAvailable = station != nil;
    _stationFiles = station[@"files"] ?: @[];
    _stationPicks = station[@"picks"] ?: @[];
    _stationTracks = station[@"tracks"] ?: @[];
    id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *queue = [raw isKindOfClass:NSDictionary.class] && [raw[@"queue"] isKindOfClass:NSArray.class] ? raw[@"queue"] : @[];
    NSMutableArray *tracks = [NSMutableArray array], *sources = [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count; i++) {
        NSDictionary *row = [queue[i] isKindOfClass:NSDictionary.class] ? queue[i] : @{};
        NSString *file = [row[@"file"] isKindOfClass:NSString.class] ? row[@"file"] : ([row[@"path"] isKindOfClass:NSString.class] ? row[@"path"] : @"");
        NSMutableDictionary *track = [NSMutableDictionary dictionaryWithObject:[NSString stringWithFormat:@"station:%lu:%@", (unsigned long)i, file] forKey:@"id"];
        for (NSString *field in @[@"title", @"artist", @"album"]) track[field] = [row[field] isKindOfClass:NSString.class] ? row[field] : @"";
        [tracks addObject:track];
        if (file.length) { NSMutableDictionary *source = [track mutableCopy]; source[@"path"] = file; [sources addObject:source]; }
    }
    NSData *index = [NSJSONSerialization dataWithJSONObject:@{@"tracks": sources} options:0 error:nil];
    if ([index writeToFile:[MixDirectory(nil) stringByAppendingPathComponent:@"offline-source-index.json"] atomically:YES])
        [self setOfflineRequest:@"station:triplej" title:@"New music for you" tracks:tracks];
}
- (NSDictionary *)stationOfflineCoverage { return [self offlineCoverage:@"station:triplej" verifyHash:NO]; }
- (IBAction)playStation:(id)sender {
    (void)sender;
    if (!_stationAvailable) return;
    [self playOfflinePlaylist:@"station:triplej"];
}
- (IBAction)setOutputVolumeFromSlider:(NSSlider *)slider {
    NSDictionary *choice = [self playerOutputChoice];
    NSString *bound = [slider isKindOfClass:GBOutputVolumeSlider.class] ? ((GBOutputVolumeSlider *)slider).outputUID : nil;
    if (!bound.length || ![bound isEqual:choice[@"effectiveUID"]]) return;
    AudioObjectID device = [choice[@"device"][@"deviceID"] unsignedIntValue];
    if (device == kAudioObjectUnknown) return;
    _volumeSetAt = CFAbsoluteTimeGetCurrent();
    [self writeOutputVolume:slider.doubleValue device:device];
    _outputVolume = slider.doubleValue;
    _outputMuted = NO;
    NSTextField *level = nil;
    for (NSView *v in slider.superview.subviews)
        if ([v.accessibilityIdentifier isEqual:@"popover.sound.level"] && [v isKindOfClass:NSTextField.class]) level = (NSTextField *)v;
    if (level) {
        level.stringValue = OutputVolumeText(_outputVolume, NO);
        level.textColor = OutputVolumeColor(_outputVolume, NO);
    }
    slider.trackFillColor = OutputVolumeFill(_outputVolume, NO);
}
- (void)ensureAudioDisplay {
    if (_audioDevices) return;
    _audioDevices = ReadAudioDevices();
    _defaultOutputUID = DefaultOutputUID(_audioDevices);
}
- (NSInteger)likedCountEstimate {
    NSInteger count = [NSUserDefaults.standardUserDefaults integerForKey:@"youtubeLikedCount"];
    return count > 0 ? count : kYouTubeLikedDefaultCount;
}
- (void)rememberLikedCount:(NSInteger)count {
    if (count < 1) return;
    [NSUserDefaults.standardUserDefaults setInteger:count forKey:@"youtubeLikedCount"];
}
- (void)startNetworkMonitor {
    if (_pathMonitor || !_musicProbesEnabled) return;
    nw_path_monitor_t monitor = nw_path_monitor_create();
    _pathMonitor = monitor;
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        BOOL online = nw_path_get_status(path) == nw_path_status_satisfied;
        BOOL changed = !self->_networkKnown || online != self->_networkOnline;
        self->_networkKnown = YES;
        self->_networkOnline = online;
        // Coming back online while the offline player is paused (or finished) has to
        // leave local mode now, or the next Play press is stuck toggling silence.
        if (changed && !online) self->_offlineTracksEntering = YES;
        if (changed && online) {
            [self yieldLocalMusicIfIdle];
            [self maybeScheduleMusicLibrarySync];
        }
        if (changed && self->_popover.isShown) [self rebuildContent];
    });
    nw_path_monitor_start(monitor);
}
static NSArray<NSString *> *ScanLikedMusicDirectory(NSString *dir) {
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir isDirectory:YES]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *root = [GBHomeDirectory() stringByAppendingPathComponent:@"Music"];
    for (NSURL *url in urls) {
        if (!url.path.length) continue;
        NSString *path = url.path;
        if ([LikedMusicAudioFiles(@[path]) count] && [OfflinePathsCoverage(@[path], root)[@"paths"] count])
            [paths addObject:path];
    }
    return paths;
}
- (dispatch_queue_t)offlineTracksWorkQueue {
    if (!_offlineTracksQueue)
        _offlineTracksQueue = dispatch_queue_create("glancebar.offline-tracks", DISPATCH_QUEUE_SERIAL);
    return _offlineTracksQueue;
}
- (void)scheduleOfflineTrackScan {
    if (_offlineTracksScanBusy) return;
    _offlineTracksScanBusy = YES;
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@"Music/YouTube Liked"];
    dispatch_async([self offlineTracksWorkQueue], ^{
        NSArray<NSString *> *paths = ScanLikedMusicDirectory(dir);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_offlineTracks = paths;
            self->_offlineTracksAt = CFAbsoluteTimeGetCurrent();
            self->_offlineTracksReady = YES;
            self->_offlineTracksScanBusy = NO;
        });
    });
}
- (NSArray<NSString *> *)offlineTrackPathsBlockingRefresh {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL entering = _offlineTracksEntering;
    _offlineTracksEntering = NO;
    NSTimeInterval age = _offlineTracksReady ? now - _offlineTracksAt : 0;
    if (!OfflineTrackListStale(_offlineTracksReady, entering, age)) return _offlineTracks ?: @[];
    if (_offlineTracksScanBusy) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (_offlineTracksScanBusy && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        age = _offlineTracksReady ? CFAbsoluteTimeGetCurrent() - _offlineTracksAt : 0;
        if (!OfflineTrackListStale(_offlineTracksReady, NO, age)) return _offlineTracks ?: @[];
    }
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@"Music/YouTube Liked"];
    dispatch_queue_t queue = [self offlineTracksWorkQueue];
    __block NSArray<NSString *> *paths = nil;
    dispatch_sync(queue, ^{ paths = ScanLikedMusicDirectory(dir); });
    _offlineTracks = paths;
    _offlineTracksAt = CFAbsoluteTimeGetCurrent();
    _offlineTracksReady = YES;
    return paths ?: @[];
}
- (NSArray<NSString *> *)offlineTrackPaths {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL entering = _offlineTracksEntering;
    _offlineTracksEntering = NO;
    NSTimeInterval age = _offlineTracksReady ? now - _offlineTracksAt : 0;
    if (!OfflineTrackListStale(_offlineTracksReady, entering, age)) return _offlineTracks ?: @[];
    [self scheduleOfflineTrackScan];
    return _offlineTracks ?: @[];
}
- (void)publishNowPlaying {
    if (!_localMode) return;
    double elapsed = 0;
    if (_localPlayer.currentTime.timescale != 0) elapsed = CMTimeGetSeconds(_localPlayer.currentTime);
    if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
    GlanceNowPlayingSet(_localTitle, _localArtist, _localPlayer.rate > 0 ? 1 : 0, elapsed);
}
- (void)enableRemoteCommands {
    if (_remoteCommandsOn) return;
    _remoteCommandsOn = YES;
    GlanceRemoteCommandsEnable(self);
}
- (void)disableRemoteCommands {
    if (!_remoteCommandsOn) return;
    _remoteCommandsOn = NO;
    GlanceRemoteCommandsDisable(self);
}
- (void)applyLocalItemURL:(NSURL *)url {
    [self notePlayback:@"track" fields:@{@"file": url.lastPathComponent ?: @"", @"title": @"", @"artist": @"",
        @"cause": [PlaybackRateCause(_playbackCause, CFAbsoluteTimeGetCurrent() - _playbackCauseAt) isEqual:@"unattributed"]
            ? @"auto-advance" : _playbackCause}];
    [self touchMusicLibraryFile:url.path];
    NSDictionary *parsed = ParseLikedTrackFilename(url.lastPathComponent);
    _localTitle = parsed[@"title"] ?: @"";
    _localArtist = parsed[@"artist"] ?: @"";
    _localTagsReady = NO;
    _localHeartError = nil;
    _localHeartEpoch++;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"commonMetadata"] completionHandler:^{
        NSString *title = nil, *artist = nil;
        for (AVMetadataItem *item in asset.commonMetadata) {
            if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) title = item.stringValue;
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) artist = item.stringValue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_localMode || self->_localIndex < 0 || self->_localIndex >= (NSInteger)self->_localURLs.count) return;
            if (![self->_localURLs[self->_localIndex] isEqual:url]) return;
            if (title.length) self->_localTitle = title;
            if (artist.length) self->_localArtist = artist;
            self->_localTagsReady = title.length && artist.length;
            [self publishNowPlaying];
            if (self->_popover.isShown) [self rebuildContent];
        });
    }];
}
// --- Playback event log ---
- (void)playbackCause:(NSString *)cause {
    _playbackCause = cause;
    _playbackCauseAt = CFAbsoluteTimeGetCurrent();
}
// A click or a remote command names the cause first; the code it then runs must not rename it.
- (void)playbackCauseIfNone:(NSString *)cause {
    if (_playbackCause.length && CFAbsoluteTimeGetCurrent() - _playbackCauseAt <= 3.0) return;
    [self playbackCause:cause];
}
// A click always names the cause, except when a remote command has just arrived and is being
// carried out through the same method (remote next calls musicNext:).
- (void)playbackUserCause:(NSString *)cause {
    if ([_playbackCause hasPrefix:@"remote-"] && CFAbsoluteTimeGetCurrent() - _playbackCauseAt <= 0.5) return;
    [self playbackCause:cause];
}
- (void)notePlayback:(NSString *)event fields:(NSDictionary *)fields {
    NSMutableDictionary *doc = [NSMutableDictionary dictionary];
    if (_localMode && _localIndex >= 0 && _localIndex < (NSInteger)_localURLs.count) {
        doc[@"file"] = _localURLs[_localIndex].lastPathComponent ?: @"";
        doc[@"index"] = @(_localIndex);
        doc[@"of"] = @(_localURLs.count);
    }
    if (_localTitle.length) doc[@"title"] = _localTitle;
    if (_localArtist.length) doc[@"artist"] = _localArtist;
    if (_mixPlayingKey.length) doc[@"playlist"] = _mixPlayingKey;
    if (_localPlayer) {
        double elapsed = _localPlayer.currentTime.timescale != 0 ? CMTimeGetSeconds(_localPlayer.currentTime) : 0;
        if (isfinite(elapsed)) doc[@"elapsed"] = @(round(elapsed * 10) / 10);
    }
    for (NSDictionary *row in _audioDevices) {
        if (![row[@"uid"] isEqual:_defaultOutputUID]) continue;
        doc[@"output"] = row[@"name"] ?: @"";
        if ([row[@"transport"] integerValue] == GlanceAudioTransportBluetooth) doc[@"bluetooth"] = @YES;
        break;
    }
    if (_musicSilentQA) doc[@"silentQA"] = @YES;
    [doc addEntriesFromDictionary:fields ?: @{}];
    PlaybackLogAppend(event, doc);
}
- (void)watchLocalPlayerRate {
    [_localRateWatch invalidate];
    _localRateWatch = nil;
    AVQueuePlayer *player = _localPlayer;
    if (!player) return;
    __weak Controller *weakSelf = self;
    _localRateWatch = [[GBPlayerWatch alloc] initWithPlayer:player handler:^(AVPlayer *changed) {
        [weakSelf localPlayerRateChanged:changed];
    }];
    [self localPlayerRateChanged:player];
}
- (void)localPlayerRateChanged:(AVPlayer *)player {
    if (player != _localPlayer) return;
    NSString *state = @"paused";
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    if (player.timeControlStatus == AVPlayerTimeControlStatusPlaying) state = @"playing";
    else if (player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
        state = @"waiting";
        if (player.reasonForWaitingToPlay) fields[@"waitingFor"] = player.reasonForWaitingToPlay;
    }
    if ([state isEqual:_playbackRateState]) return;
    _playbackRateState = state;
    fields[@"state"] = state;
    fields[@"cause"] = PlaybackRateCause(_playbackCause, CFAbsoluteTimeGetCurrent() - _playbackCauseAt);
    [self notePlayback:@"rate" fields:fields];
}
- (void)playbackItemTrouble:(NSNotification *)note {
    AVPlayerItem *item = [note.object isKindOfClass:AVPlayerItem.class] ? note.object : nil;
    BOOL failed = [note.name isEqual:AVPlayerItemFailedToPlayToEndTimeNotification];
    NSError *error = failed ? note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] : nil;
    NSURL *url = [item.asset isKindOfClass:AVURLAsset.class] ? ((AVURLAsset *)item.asset).URL : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        if (url) fields[@"item"] = url.lastPathComponent ?: @"";
        if (error) {
            fields[@"error"] = error.localizedDescription ?: @"";
            fields[@"code"] = @(error.code);
            fields[@"domain"] = error.domain ?: @"";
            NSError *under = error.userInfo[NSUnderlyingErrorKey];
            if ([under isKindOfClass:NSError.class]) fields[@"underlying"] = @(under.code);
        }
        [self notePlayback:failed ? @"item-failed" : @"stalled" fields:fields];
        [self playbackCause:failed ? @"item-failed" : @"stalled"];
    });
}
- (void)detachLocalObservers {
    for (AVPlayerItem *item in _localObservedItems)
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    _localObservedItems = nil;
}
- (void)attachLocalObservers:(NSArray<AVPlayerItem *> *)items {
    [self detachLocalObservers];
    _localObservedItems = items;
    for (AVPlayerItem *item in items)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(localItemEnded:)
                                                   name:AVPlayerItemDidPlayToEndTimeNotification object:item];
}
static const NSInteger kLocalPlayerQueueAhead = 8;
- (NSArray<AVPlayerItem *> *)localItemsFromIndex:(NSInteger)index {
    NSMutableArray<AVPlayerItem *> *items = [NSMutableArray array];
    NSInteger end = MIN((NSInteger)_localURLs.count, index + kLocalPlayerQueueAhead);
    for (NSInteger i = index; i < end; i++)
        [items addObject:[AVPlayerItem playerItemWithURL:_localURLs[i]]];
    _localQueueEnd = end;
    return items;
}
- (void)extendLocalPlayerQueueIfNeeded {
    if (!_localPlayer || !_localURLs.count || _localQueueEnd >= (NSInteger)_localURLs.count) return;
    NSURL *url = _localURLs[_localQueueEnd];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [_localPlayer insertItem:item afterItem:nil];
    NSMutableArray *observed = [_localObservedItems mutableCopy] ?: [NSMutableArray array];
    [observed addObject:item];
    _localObservedItems = observed;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(localItemEnded:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    _localQueueEnd++;
}
- (void)maintainLocalPlayerQueue {
    if (!_localPlayer || !_localURLs.count) return;
    while (_localQueueEnd < (NSInteger)_localURLs.count && _localPlayer.items.count < kLocalPlayerQueueAhead)
        [self extendLocalPlayerQueueIfNeeded];
}
- (NSInteger)wrappedLocalIndex:(NSInteger)index {
    NSInteger n = (NSInteger)_localURLs.count;
    if (n <= 0) return 0;
    if (index < 0) return n - 1;
    if (index >= n) return 0;
    return index;
}
// The outgoing queue still holds every later track. Left alone it would start the
// one after this song once the item ends, under a fade that no longer observes it.
- (void)keepOnlyCurrentItemOn:(AVQueuePlayer *)player {
    if (!player) return;
    AVPlayerItem *current = player.currentItem;
    for (AVPlayerItem *item in [player.items copy])
        if (item != current) [player removeItem:item];
}
- (double)secondsRemainingInPlayer:(AVPlayer *)player {
    AVPlayerItem *item = player.currentItem;
    if (!item) return NAN;
    CMTime now = player.currentTime;
    CMTime length = item.duration;
    if (!CMTIME_IS_NUMERIC(now) || !CMTIME_IS_NUMERIC(length)) return NAN;
    double elapsed = CMTimeGetSeconds(now);
    double duration = CMTimeGetSeconds(length);
    if (!isfinite(elapsed) || !isfinite(duration)) return NAN;
    return duration - elapsed;
}
- (void)finishLocalBlend {
    [_localBlendTimer invalidate];
    _localBlendTimer = nil;
    // The incoming player is the one the UI already shows. Full volume, then the
    // outgoing player can go: a fade abandoned at the bottom would stay quiet.
    if (_localPlayer) _localPlayer.volume = MusicPlayerOutputVolume(_musicSilentQA);
    if (_localOutgoing) {
        [_localOutgoing pause];
        _localOutgoing = nil;
    }
}
- (void)cancelCoalescedSeek {
    [_seekCoalesceTimer invalidate];
    _seekCoalesceTimer = nil;
    _seekCoalesceItem = nil;
}
- (void)tearDownLocalPlayer {
    [self cancelCoalescedSeek];
    [_localBlendTimer invalidate];
    _localBlendTimer = nil;
    [self detachLocalObservers];
    if (_localOutgoing) {
        [_localOutgoing pause];
        _localOutgoing = nil;
    }
    [_localRateWatch invalidate];
    _localRateWatch = nil;
    _playbackRateState = nil;
    [_localPlayer pause];
    _localPlayer = nil;
}
// Quit doesn't spin the main run loop, so a dip's timer will not get to restore
// Music or the YouTube tab. Each restore runs on that target's volume queue and
// this method waits for it (at most a second once the queue is free). Both apps
// outlive us. The local player is in-process; assigning its volume is enough.
- (void)silenceMusicBlendsForQuit {
    [_musicNextArmTimer invalidate];
    _musicNextArmTimer = nil;
    _musicNextArmedAt = 0;
    [_localBlendTimer invalidate];
    _localBlendTimer = nil;
    if (_localOutgoing) {
        [_localOutgoing pause];
        _localOutgoing = nil;
    }
    if (_localPlayer) _localPlayer.volume = MusicPlayerOutputVolume(_musicSilentQA);
}
// The queue advances by itself and never updates the index, so Next would jump
// backwards and the label would stay on the finished song. At the end, wrap the
// same shuffle and keep going; otherwise the button sits on pause over silence.
- (void)localItemEnded:(NSNotification *)note {
    AVPlayerItem *item = [note.object isKindOfClass:AVPlayerItem.class] ? note.object : nil;
    if (!item) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self advanceAfterLocalItem:item]; });
        return;
    }
    [self advanceAfterLocalItem:item];
}
- (void)advanceAfterLocalItem:(AVPlayerItem *)item {
    if (!_localMode || !_localPlayer || ![_localObservedItems containsObject:item]) return;
    NSInteger next = _localIndex + 1;
    if (next < 0 || next >= (NSInteger)_localURLs.count) {
        [self playLocalIndex:0];
        return;
    }
    _localIndex = next;
    _playbackKnown = YES;
    _playbackPlaying = YES;
    [self maintainLocalPlayerQueue];
    [self maintainOfflineHashVerifyAhead];
    if (!_localPlayer.currentItem && _localQueueEnd < (NSInteger)_localURLs.count) {
        [self extendLocalPlayerQueueIfNeeded];
        [_localPlayer play];
    }
    [self applyLocalItemURL:_localURLs[_localIndex]];
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
// One source at a time. The deck and the local player are started from here while Apple
// Music may still be playing (10 Nov 2026: the station played over the Apple Music song).
// Pause it, never quit it; a closed Music is left closed.
- (void)pauseAppleMusicForLocalSource {
    if (!_musicProbesEnabled || !AppleMusicIsRunning()) return;
    RunAppleScript(@"tell application \"Music\"\nif player state is playing then pause\nend tell",
                   ^(NSString *output, NSString *errorText, int status) {
        (void)output;
        if (status != 0) GBLog("apple music: pause for local source status=%d err=%{public}@", status, errorText);
    });
}
- (void)playLocalIndex:(NSInteger)index {
    if (!_localURLs.count) return;
    if (!_localMode && !_musicSilentQA) [self pauseAppleMusicForLocalSource];
    _externalPlayback = nil;
    index = [self wrappedLocalIndex:index];
    _localIndex = index;
    NSMutableArray<AVPlayerItem *> *items = [[self localItemsFromIndex:index] mutableCopy];
    if (index == 0 && _preparedFirstItem && _localURLs.count) {
        NSURL *preparedURL = [_preparedFirstItem.asset isKindOfClass:AVURLAsset.class]
            ? ((AVURLAsset *)_preparedFirstItem.asset).URL : nil;
        if (preparedURL && [_localURLs[0] isEqual:preparedURL]) {
            [items replaceObjectAtIndex:0 withObject:_preparedFirstItem];
            [self discardPreparedPlaylist];
        }
    }
    [self tearDownLocalPlayer];
    _localPlayer = [AVQueuePlayer queuePlayerWithItems:items];
    _localPlayer.automaticallyWaitsToMinimizeStalling = NO;
    float level = MusicPlayerOutputVolume(_musicSilentQA);
    _localPlayer.volume = level;
    _localPlayer.muted = _musicSilentQA;
    [self attachLocalObservers:items];
    _localMode = YES;
    _localEmpty = NO;
    _playbackKnown = YES;
    _playbackPlaying = YES;
    [self maintainLocalPlayerQueue];
    [self applyLocalItemURL:_localURLs[index]];
    [self enableRemoteCommands];
    if (_localStartPaused) _playbackPlaying = NO;   // replacing a rejected track while paused
    else [_localPlayer play];
    [self playbackCauseIfNone:@"start"];
    [self watchLocalPlayerRate];
    OfflinePlaylistNotePlaybackStarted();
    [self musicTimingMark:@"rate"];
    [self maintainOfflineHashVerifyAhead];
    [self applyPlayerAudioOutput];
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
- (void)updateMusicTransportInPlace {
    if (!_popover.isShown) return;
    NSView *root = _popover.contentViewController.view;
    BOOL playing = _playbackPlaying;
    NSString *symbol = playing ? @"pause.fill" : @"play.fill";
    NSString *label = playing ? @"Pause" : @"Play";
    NSButton *play = (NSButton *)ViewWithAccessibilityIdentifier(root, @"popover.music.play");
    if (![play isKindOfClass:NSButton.class]) return;
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (image) play.image = image;
    play.accessibilityLabel = label;
}
- (void)updateMusicNextArmedInPlace {
    if (!_popover.isShown || _musicNextArmedAt <= 0) return;
    NSButton *next = (NSButton *)ViewWithAccessibilityIdentifier(_popover.contentViewController.view, @"popover.music.next");
    if ([next isKindOfClass:NSButton.class]) next.contentTintColor = NSColor.controlAccentColor;
}
- (void)localBlendTick:(NSTimer *)timer {
    (void)timer;
    if (!_localBlendTimer) return;
    if (!_localOutgoing || !_localPlayer) { [self finishLocalBlend]; return; }
    double duration = _localBlendDuration > 0 ? _localBlendDuration : kMusicBlendFullSec;
    double t = (CFAbsoluteTimeGetCurrent() - _localBlendStarted) / duration;
    if (!(t < 1)) { [self finishLocalBlend]; return; }
    MusicBlendGain gain = MusicBlendGainAt(t);
    float cap = MusicPlayerOutputVolume(_musicSilentQA);
    _localOutgoing.volume = (float)gain.outgoing * cap;
    _localPlayer.volume = (float)gain.incoming * cap;
}
// Keeps the current player. The new queue is built the same way as playLocalIndex:,
// at volume 0, and the row switches to it immediately.
- (void)beginLocalBlend {
    if (!_localURLs.count || !_localPlayer) {
        [self playLocalIndex:_localIndex + 1];
        return;
    }
    NSInteger index = [self wrappedLocalIndex:_localIndex + 1];
    double remaining = [self secondsRemainingInPlayer:_localPlayer];
    AVQueuePlayer *outgoing = _localPlayer;
    [self detachLocalObservers];
    [self keepOnlyCurrentItemOn:outgoing];
    float cap = MusicPlayerOutputVolume(_musicSilentQA);
    outgoing.volume = cap;
    outgoing.muted = _musicSilentQA;
    _localOutgoing = outgoing;
    NSArray<AVPlayerItem *> *items = [self localItemsFromIndex:index];
    AVQueuePlayer *incoming = [AVQueuePlayer queuePlayerWithItems:items];
    incoming.volume = 0;
    incoming.muted = _musicSilentQA;
    _localPlayer = incoming;
    _playbackRateState = nil;
    [self playbackCauseIfNone:@"crossfade"];
    [self watchLocalPlayerRate];
    [self attachLocalObservers:items];
    _localIndex = index;
    _localMode = YES;
    _localEmpty = NO;
    _playbackKnown = YES;
    _playbackPlaying = YES;
    [self applyLocalItemURL:_localURLs[index]];
    [self enableRemoteCommands];
    [_localPlayer play];
    [self applyPlayerAudioOutput];
    if (_localOutgoing) _localOutgoing.audioOutputDeviceUniqueID = _localPlayer.audioOutputDeviceUniqueID;
    [self publishNowPlaying];
    _localBlendDuration = MusicBlendSeconds(remaining, kMusicBlendFullSec, kMusicBlendMinSec);
    _localBlendStarted = CFAbsoluteTimeGetCurrent();
    [_localBlendTimer invalidate];
    _localBlendTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 target:self
                                             selector:@selector(localBlendTick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_localBlendTimer forMode:NSRunLoopCommonModes];
    if (_popover.isShown) [self rebuildContent];
}
- (void)startOfflinePlaybackLocal {
    if (!_musicProbesEnabled) return;
    _mixPlayingKey = nil;
    [self disableRemoteCommands];
    NSArray<NSString *> *paths = [self offlineTrackPathsBlockingRefresh];
    if (!paths.count) {
        [self tearDownLocalPlayer];
        _localMode = NO;
        _localEmpty = YES;
        _localTitle = nil;
        _localArtist = nil;
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    _localEmpty = NO;
    NSArray<NSString *> *order = ShuffledTrackOrder(paths, arc4random());
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *path in order) [urls addObject:[NSURL fileURLWithPath:path]];
    _localURLs = urls;
    [self playLocalIndex:0];
}
- (void)toggleLocalPlayback {
    ++_offlinePlayGeneration; _mixStartingKey = nil;
    if (!_musicProbesEnabled) return;
    if (!_localPlayer) {
        if (_mixPlayingKey.length) [self playOfflinePlaylist:_mixPlayingKey];
        else [self startOfflinePlaybackLocal];
        return;
    }
    // Pause finishes the fade first, so the incoming track is the one that pauses
    // and the outgoing player is not left audible underneath.
    if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
    if (_localPlayer.rate > 0) {
        _playbackPlaying = NO;
        _playbackKnown = YES;
        [self updateMusicTransportInPlace];
        [_localPlayer pause];
    } else {
        // Sound and the button first; quieting Apple Music is a slower call and comes after
        // (and never from a silent test run, as in playLocalIndex:).
        _playbackPlaying = YES;
        _playbackKnown = YES;
        [self updateMusicTransportInPlace];
        // Starting the audio hardware can hold the main thread for 100 ms or more. The button
        // has already flipped; the player starts on the next turn of the run loop so that flip
        // is drawn first. A pause in between leaves it stopped.
        AVQueuePlayer *player = _localPlayer;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_localPlayer != player || !self->_playbackPlaying) return;
            [player play];
            if (!self->_musicSilentQA) [self pauseAppleMusicForLocalSource];
        });
    }
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
- (void)yieldLocalMusicIfIdle {
    if (_mixPlayingKey.length && _offlineRequests[_mixPlayingKey]) return;
    BOOL playing = _localPlayer.rate > 0;
    if (!YieldLocalMusic(_localMode, _networkKnown && _networkOnline, playing)) return;
    [self notePlayback:@"stopped" fields:@{@"cause": @"yield-idle"}];
    [self tearDownLocalPlayer];
    _localMode = NO;
    _localTitle = nil;
    _localArtist = nil;
    _playbackKnown = NO;
    _playbackPlaying = NO;
    [self disableRemoteCommands];
    if (_popover.isShown) [self rebuildContent];
}
// A keyboard play/pause key arrives as "toggle"; Bluetooth headphones send a separate Pause or Play.
- (void)noteRemote:(NSString *)command {
    [self notePlayback:@"remote" fields:@{@"command": command}];
    [self playbackCause:[@"remote-" stringByAppendingString:command]];
}
- (NSInteger)remotePlay:(id)event {
    [self noteRemote:@"play"];
    (void)event; if (_localPlayer.rate == 0) [self toggleLocalPlayback];
    return 0;
}
- (NSInteger)remotePause:(id)event {
    [self noteRemote:@"pause"];
    ++_offlinePlayGeneration; _mixStartingKey = nil;
    (void)event; if (_localPlayer.rate > 0) [self toggleLocalPlayback];
    return 0;
}
- (NSInteger)remoteToggle:(id)event {
    [self noteRemote:@"toggle"];
    (void)event; [self toggleLocalPlayback]; return 0;
}
- (NSInteger)remoteNext:(id)event {
    [self noteRemote:@"next"];
    (void)event; [self musicNext:nil]; return 0;
}
- (NSInteger)remotePrevious:(id)event {
    [self noteRemote:@"previous"];
    (void)event; [self musicPrevious:nil]; return 0;
}
// --- Apple Music ---
- (NSString *)appleMusicPlaylistName {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:@"appleMusicPlaylist"];
    return name.length ? name : @"Favourite Songs";
}
- (NSDictionary *)currentLocalIdentity {
    if (!_localMode || _localIndex < 0 || _localIndex >= (NSInteger)_localURLs.count) return nil;
    NSString *path = _localURLs[_localIndex].path;
    if (!path.length) return nil;
    return LocalTrackIdentity(_stationTracks, path, _localTagsReady ? _localArtist : @"",
                              _localTagsReady ? _localTitle : @"", path.lastPathComponent);
}
- (NSMutableSet<NSString *> *)heartedKeys {
    if (!_heartedKeys) {
        _heartedKeys = [NSMutableSet set];
        if (_musicProbesEnabled) {
            NSString *path = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector/hearts.json"];
            NSString *json = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            [_heartedKeys addObjectsFromArray:HeartCacheKeys(json)];
        }
    }
    return _heartedKeys;
}
- (NSString *)heartHistoryJSONL {
    return [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector/heart-history.jsonl"];
}
- (void)appendHeartHistory:(NSString *)action
                  trackKey:(NSString *)key
                    artist:(NSString *)artist
                     title:(NSString *)title
                      path:(NSString *)path {
    if (!_musicProbesEnabled) return;
    NSString *line = HeartHistoryLine(action, key, artist, title, path, NSDate.date);
    if (!line.length) return;
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *histPath = [dir stringByAppendingPathComponent:@"heart-history.jsonl"];
    if (![NSFileManager.defaultManager fileExistsAtPath:histPath])
        [@"" writeToFile:histPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:histPath];
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
- (void)rememberHeart:(NSString *)key {
    if (!key.length) return;
    [[self heartedKeys] addObject:key];
    if (!_musicProbesEnabled) return;
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"hearts.json"];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *next = HeartCacheAdding(existing, key);
    if (![next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    [_heartedKeys setSet:[NSSet setWithArray:HeartCacheKeys(next)]];
}
- (void)forgetHeart:(NSString *)key {
    if (!key.length) return;
    [[self heartedKeys] removeObject:key];
    if (!_musicProbesEnabled) return;
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector"];
    NSString *path = [dir stringByAppendingPathComponent:@"hearts.json"];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *next = HeartCacheRemoving(existing, key);
    if (!next.length || ![next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    [_heartedKeys setSet:[NSSet setWithArray:HeartCacheKeys(next)]];
}
- (void)noteLocalHeartError:(NSString *)reason {
    NSString *text = [[reason ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length > 160) text = [text substringToIndex:160];
    _localHeartError = text.length ? text : @"Couldn't add to Apple Music";
    NSUInteger epoch = ++_localHeartEpoch;
    if (_popover.isShown) [self rebuildContent];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (epoch != self->_localHeartEpoch) return;
        self->_localHeartError = nil;
        if (self->_popover.isShown) [self rebuildContent];
    });
}
static NSString *LikesSyncScript(void) {
    return [GBHomeDirectory() stringByAppendingPathComponent:@"Projects/glancebar/tools/music-sync/likes_sync.py"];
}
static NSString *Python3Path(void) {
    for (NSString *path in @[@"/opt/homebrew/bin/python3", @"/usr/local/bin/python3", @"/usr/bin/python3"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    return @"/usr/bin/python3";
}
static NSDictionary *LoveResultJSON(NSString *stdoutText) {
    NSString *last = nil;
    for (NSString *line in [stdoutText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        if (line.length) last = line;
    NSData *data = [last dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}
- (void)loveCurrentLocalTrack {
    if (!_musicProbesEnabled || _localLoveInFlight) return;
    NSDictionary *ident = [self currentLocalIdentity];
    NSString *artist = ident[@"artist"] ?: @"";
    NSString *title = ident[@"title"] ?: @"";
    NSString *key = ident[@"trackKey"] ?: @"";
    if (!artist.length || !title.length || !key.length) {
        [self noteLocalHeartError:@"No artist and title"];
        return;
    }
    if ([[self heartedKeys] containsObject:key]) return;
    // The heart is a local fact first (10 Nov 2026: hearting a playing track did nothing
    // whenever Apple Music had no match, e.g. a YouTube DJ set, because the heart was only
    // saved after the Apple Music add succeeded). Save it and fill the button now; mirroring
    // it to Apple Music is best effort in the background and never undoes the heart.
    [self rememberHeart:key];
    [self appendHeartHistory:@"heart" trackKey:key artist:artist title:title path:ident[@"path"] ?: @""];
    _localHeartError = nil;
    _localHeartEpoch++;
    if (_popover.isShown) [self rebuildContent];
    NSString *script = LikesSyncScript();
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) {
        GBLog("heart: saved locally; likes sync is not installed");
        return;
    }
    _localLoveInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:Python3Path()];
        task.arguments = @[script, @"love", @"--artist", artist, @"--title", title, @"--apply"];
        NSPipe *out = [NSPipe pipe], *errPipe = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError = errPipe;
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        if (![task launchAndReturnError:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_localLoveInFlight = NO;
                GBLog("heart: saved locally; the Apple Music mirror could not start");
            });
            return;
        }
        GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:120];
        NSData *outData = [out.fileHandleForReading readDataToEndOfFile];
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        [watchdog disarm];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_localLoveInFlight = NO;
            NSString *stdoutText = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
            NSString *stderrText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
            NSDictionary *payload = LoveResultJSON(stdoutText);
            NSString *result = [payload[@"result"] isKindOfClass:NSString.class] ? payload[@"result"] : @"";
            int status = task.terminationReason == NSTaskTerminationReasonExit ? task.terminationStatus : 1;
            if (status == 0 && [result isEqual:@"ok"]) return;
            NSString *why = status == 3 || [result isEqual:@"no-match"] ? @"no Apple Music match" : stderrText;
            if (why.length > 160) why = [why substringToIndex:160];
            GBLog("heart: saved locally; not mirrored to Apple Music (%{public}@)", why ?: @"");
        });
    });
}
- (void)unloveCurrentLocalTrack {
    if (!_musicProbesEnabled || _localLoveInFlight) return;
    NSDictionary *ident = [self currentLocalIdentity];
    NSString *artist = ident[@"artist"] ?: @"";
    NSString *title = ident[@"title"] ?: @"";
    NSString *key = ident[@"trackKey"] ?: @"";
    if (!artist.length || !title.length || !key.length) return;
    if (![[self heartedKeys] containsObject:key]) return;
    [self forgetHeart:key];
    [self appendHeartHistory:@"unheart" trackKey:key artist:artist title:title path:ident[@"path"] ?: @""];
    _localHeartError = nil;
    _localHeartEpoch++;
    if (_popover.isShown) [self rebuildContent];
    NSString *script = LikesSyncScript();
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) {
        GBLog("unheart: saved locally; likes sync is not installed");
        return;
    }
    _localLoveInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:Python3Path()];
        task.arguments = @[script, @"unlove", @"--artist", artist, @"--title", title, @"--apply"];
        NSPipe *out = [NSPipe pipe], *errPipe = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError = errPipe;
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        if (![task launchAndReturnError:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_localLoveInFlight = NO;
                GBLog("unheart: saved locally; the Apple Music mirror could not start");
            });
            return;
        }
        GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:120];
        NSData *outData = [out.fileHandleForReading readDataToEndOfFile];
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        [watchdog disarm];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_localLoveInFlight = NO;
            NSString *stdoutText = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
            NSString *stderrText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
            NSDictionary *payload = LoveResultJSON(stdoutText);
            NSString *result = [payload[@"result"] isKindOfClass:NSString.class] ? payload[@"result"] : @"";
            int status = task.terminationReason == NSTaskTerminationReasonExit ? task.terminationStatus : 1;
            if (status == 0 && [result isEqual:@"ok"]) return;
            NSString *why = status == 3 || [result isEqual:@"no-match"] ? @"no Apple Music match" : stderrText;
            if (why.length > 160) why = [why substringToIndex:160];
            GBLog("unheart: saved locally; not mirrored to Apple Music (%{public}@)", why ?: @"");
        });
    });
}
- (void)appendSelectorFeedbackForArtist:(NSString *)artist title:(NSString *)title source:(NSString *)source {
    if (!_musicProbesEnabled) return;
    NSString *line = SelectorFeedbackLine(artist, title, source, NSDate.date);
    if (!line.length) return;
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@".local/state/selector"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"feedback.jsonl"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
- (IBAction)musicFavorite:(id)sender {
    (void)sender;
    if (!_localMode) return;
    NSDictionary *ident = [self currentLocalIdentity];
    NSString *key = ident[@"trackKey"] ?: @"";
    if (key.length && [[self heartedKeys] containsObject:key]) [self unloveCurrentLocalTrack];
    else [self loveCurrentLocalTrack];
}
- (NSMutableSet<NSString *> *)mixLiked {
    if (!_mixLiked) {
        NSString *path = [MixDirectory(nil) stringByAppendingPathComponent:@"feedback.jsonl"];
        _mixLiked = [MixLikedIDs([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]) mutableCopy];
    }
    return _mixLiked;
}
- (IBAction)musicThumbsUp:(id)sender {
    (void)sender;
    if (!_localMode) return;
    NSDictionary *ident = [self currentLocalIdentity];
    NSString *thumbID = [ident[@"trackID"] length] ? ident[@"trackID"] : ident[@"trackKey"];
    if (!thumbID.length) return;
    BOOL liked = ![[self mixLiked] containsObject:thumbID];
    if (liked) [_mixLiked addObject:thumbID]; else [_mixLiked removeObject:thumbID];
    NSString *title = ident[@"title"] ?: _localTitle;
    NSString *artist = ident[@"artist"] ?: _localArtist;
    NSString *line = MixFeedbackLine(thumbID, title, artist, liked, NSDate.date);
    NSString *path = [MixDirectory(nil) stringByAppendingPathComponent:@"feedback.jsonl"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    for (NSUInteger i = 0; i < _mixLibrary.count; i++)
        if ([_mixLibrary[i][@"id"] isEqual:thumbID]) {
            NSMutableArray *lib = [_mixLibrary mutableCopy]; NSMutableDictionary *t = [lib[i] mutableCopy];
            t[@"thumb"] = @(liked); lib[i] = t; _mixLibrary = lib; break;
        }
    if (liked) {
        [self appendSelectorFeedbackForArtist:artist title:title source:@"local"];
        NSString *heartKey = ident[@"trackKey"];
        if (heartKey.length && ![[self heartedKeys] containsObject:heartKey]) [self loveCurrentLocalTrack];
    }
    if (_popover.isShown) [self rebuildContent];
}
- (NSUInteger)coalescedSeekApplyCount { return _coalescedSeekCount; }
- (void)performCoalescedSeek {
    _seekCoalesceTimer = nil;
    AVPlayerItem *item = _seekCoalesceItem;
    _seekCoalesceItem = nil;
    // A deferred seek belongs to the track it was made on: never applied to its successor.
    if (!_localMode || !_localPlayer || !item || _localPlayer.currentItem != item) return;
    _coalescedSeekCount++;
    double seconds = _seekCoalesceSeconds;
    CMTime target = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    [_localPlayer seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
           completionHandler:^(BOOL __unused finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self noteLocalPlaybackTime]; });
    }];
}
- (IBAction)musicSeek:(id)sender {
    if (!_localMode || !_localPlayer || ![sender isKindOfClass:NSSlider.class]) return;
    if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
    double seconds = ((NSSlider *)sender).doubleValue;
    if (!isfinite(seconds) || seconds < 0) return;
    _trackElapsed = seconds;
    _trackSampledAt = CFAbsoluteTimeGetCurrent();
    _seekCoalesceSeconds = seconds;
    _seekCoalesceItem = _localPlayer.currentItem;
    [_seekCoalesceTimer invalidate];
    _seekCoalesceTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(performCoalescedSeek)
                                                        userInfo:nil repeats:NO];
}
- (IBAction)musicPlay:(id)sender {
    (void)sender;
    if (!_musicProbesEnabled) return;
    [self playbackUserCause:@"click"];
    ++_offlinePlayGeneration;
    _mixStartingKey = nil;
    if (_localMode) { [self toggleLocalPlayback]; return; }
    [self ensureOfflinePlaylists];
    [self startOfflinePlaybackLocal];
}
- (IBAction)musicPrevious:(id)sender {
    [self playbackUserCause:@"click-previous"];
    ++_offlinePlayGeneration; _mixStartingKey = nil;
    (void)sender;
    if (!_musicProbesEnabled || !_localMode || !_localPlayer) return;
    if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
    double seconds = CMTimeGetSeconds(_localPlayer.currentTime);
    if (seconds > 3) {
        [self cancelCoalescedSeek];
        [_localPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL __unused finished) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self noteLocalPlaybackTime]; });
        }];
        _trackElapsed = 0;
        _trackSampledAt = CFAbsoluteTimeGetCurrent();
        return;
    }
    [self playLocalIndex:_localIndex - 1];
}
- (void)invalidateMusicNextArmTimer {
    [_musicNextArmTimer invalidate];
    _musicNextArmTimer = nil;
}
- (BOOL)musicBlendRunning {
    return _localBlendTimer != nil || _localOutgoing != nil;
}
- (void)performMusicNextCutNow {
    if (!_localMode) return;
    if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
    [self playLocalIndex:_localIndex + 1];
}
- (void)finishRunningBlendAsCut {
    if (_localBlendTimer || _localOutgoing) [self finishLocalBlend];
    else [self performMusicNextCutNow];
}
- (void)performMusicNextBlend {
    if (!_localMode) return;
    if (_localBlendTimer || _localOutgoing) { [self finishLocalBlend]; return; }
    [self beginLocalBlend];
}
- (IBAction)musicNext:(id)sender {
    [self playbackUserCause:@"click-next"];
    ++_offlinePlayGeneration; _mixStartingKey = nil;
    (void)sender;
    if (!_musicProbesEnabled) return;
    BOOL blending = [self musicBlendRunning];
    MusicNextTap tap = ClassifyMusicNext(&_musicNextArmedAt, CFAbsoluteTimeGetCurrent(),
                                        kMusicNextTapWindowSec, NO, blending);
    if (tap == MusicNextTapCut) {
        [self invalidateMusicNextArmTimer];
        if (blending) [self finishRunningBlendAsCut];
        else [self performMusicNextCutNow];
        return;
    }
    if (tap != MusicNextTapWait) return;
    [self updateMusicNextArmedInPlace];
    [self invalidateMusicNextArmTimer];
    _musicNextArmTimer = [NSTimer scheduledTimerWithTimeInterval:kMusicNextTapWindowSec target:self
                                                       selector:@selector(musicNextArmFired:)
                                                       userInfo:nil repeats:NO];
}
- (void)musicNextArmFired:(NSTimer *)timer {
    (void)timer;
    _musicNextArmTimer = nil;
    if (!_musicProbesEnabled) { _musicNextArmedAt = 0; return; }
    double now = CFAbsoluteTimeGetCurrent();
    MusicNextTap tap = ClassifyMusicNext(&_musicNextArmedAt, now, kMusicNextTapWindowSec,
                                        YES, [self musicBlendRunning]);
    if (tap == MusicNextTapBlend) { [self performMusicNextBlend]; return; }
    // Fired before the window (the pure check keeps the arm). One more wait.
    if (tap == MusicNextTapNone && _musicNextArmedAt > 0) {
        double remain = (_musicNextArmedAt + kMusicNextTapWindowSec) - CFAbsoluteTimeGetCurrent();
        if (remain < 0.01) remain = 0.01;
        _musicNextArmTimer = [NSTimer scheduledTimerWithTimeInterval:remain target:self
                                                           selector:@selector(musicNextArmFired:)
                                                           userInfo:nil repeats:NO];
    }
}
- (NSButton *)transportButton:(NSString *)symbol pointSize:(CGFloat)pointSize side:(CGFloat)side
                         action:(SEL)action identifier:(NSString *)identifier label:(NSString *)label {
    // Same configuration family as the output mark and the lead symbols: regular weight, point size only.
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.title = @"";   // buttonWithImage: leaves the stock "Button" title
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.labelColor;
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = label;
    button.frame = NSMakeRect(0, (kSoundH - side) / 2.0, side, side);
    return button;
}
- (void)stopTrackTick {
    [_trackTick invalidate];
    _trackTick = nil;
}
- (void)syncTrackTick {
    BOOL run = _popover.isShown && _playbackPlaying && isfinite(_trackDuration) && _trackDuration > 0;
    if (!run) { [self stopTrackTick]; return; }
    if (_trackTick) return;
    _trackTick = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(trackTick:)
                                                userInfo:nil repeats:YES];
}
// The popover reconciles its view tree in place, so a label captured at build time
// would point at a view that is no longer on screen. Look the subtitle up each tick.
- (void)trackTick:(NSTimer *)timer {
    (void)timer;
    if (!_popover.isShown || !_playbackPlaying) { [self stopTrackTick]; return; }
    NSTextField *subtitle = (NSTextField *)ViewWithAccessibilityIdentifier(
        _popover.contentViewController.view, @"popover.music.subtitle");
    if (![subtitle isKindOfClass:NSTextField.class]) return;
    double elapsed = _trackElapsed;
    if (_trackSampledAt > 0) elapsed += CFAbsoluteTimeGetCurrent() - _trackSampledAt;
    if (_localMode) {
        NSView *view = _popover.contentViewController.view;
        NSTextField *now = (NSTextField *)ViewWithAccessibilityIdentifier(view, @"popover.music.elapsed");
        NSTextField *length = (NSTextField *)ViewWithAccessibilityIdentifier(view, @"popover.music.duration");
        NSSlider *slider = (NSSlider *)ViewWithAccessibilityIdentifier(view, @"popover.music.position");
        NSString *clock = FormatTrackClock(elapsed, _trackDuration);
        if ([now isKindOfClass:NSTextField.class] && clock) now.stringValue = clock;
        if ([length isKindOfClass:NSTextField.class] && _trackDuration > 0)
            length.stringValue = FormatTrackClock(_trackDuration, _trackDuration);
        if ([slider isKindOfClass:NSSlider.class] && _trackDuration > 0)
            slider.doubleValue = MIN(MAX(elapsed, 0), _trackDuration);
    }
    if (!_localMode) return;
    NSString *artist = _localArtist;
    if (_trackDuration > 0) {
        subtitle.stringValue = artist.length ? artist : @"";
        subtitle.accessibilityLabel = subtitle.stringValue;
        return;
    }
    NSString *time = FormatTrackTime(elapsed, _trackDuration);
    if (!time.length) return;
    subtitle.stringValue = artist.length ? [NSString stringWithFormat:@"%@ · %@", artist, time] : time;
    subtitle.accessibilityLabel = subtitle.stringValue;   // VoiceOver reads the label, not the text
}
- (void)noteLocalPlaybackTime {
    if (!_localPlayer) { _trackDuration = 0; _trackSampledAt = 0; return; }
    CMTime now = _localPlayer.currentTime;
    CMTime length = _localPlayer.currentItem ? _localPlayer.currentItem.duration : kCMTimeInvalid;
    double elapsed = CMTIME_IS_NUMERIC(now) ? CMTimeGetSeconds(now) : 0;
    double duration = CMTIME_IS_NUMERIC(length) ? CMTimeGetSeconds(length) : 0;
    if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
    _trackElapsed = elapsed;
    _trackSampledAt = CFAbsoluteTimeGetCurrent();
    _trackDuration = (isfinite(duration) && duration > 0) ? duration : 0;
}
- (CGFloat)addMusicControlsTo:(NSView *)root at:(CGFloat)y {
    [self ensureOfflinePlaylists];
    BOOL loaded = _localMode;
    if (_musicProbesEnabled && !_localMode) {
        NSArray *tracks = [self offlineTrackPaths];
        _localEmpty = tracks.count == 0;
    }
    if (_localMode && _localPlayer) {
        [self noteLocalPlaybackTime];
        _playbackKnown = YES;
        _playbackPlaying = _localPlayer.rate > 0;
    }
    BOOL external = !_localMode && [_externalPlayback[@"valid"] boolValue];
    NSString *trackTitle = _localMode ? _localTitle : (external ? _externalPlayback[@"title"] : nil);
    NSString *trackArtist = _localMode ? _localArtist : (external ? _externalPlayback[@"artist"] : nil);
    NSString *symbol = @"play.fill", *playLabel = @"Play";
    if (loaded) {
        if (!_playbackKnown) { symbol = @"playpause"; playLabel = @"Play or pause"; }
        else if (_playbackPlaying) { symbol = @"pause.fill"; playLabel = @"Pause"; }
    }
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kSoundH)];
    row.accessibilityIdentifier = @"popover.sound.row";
    CGFloat x = kPad;
    NSButton *prev = [self transportButton:@"backward.end.fill" pointSize:18 side:22
                                    action:@selector(musicPrevious:) identifier:@"popover.music.previous"
                                     label:@"Previous track"];
    prev.frame = NSOffsetRect(prev.frame, x, 0);
    prev.enabled = loaded;
    if (!loaded) prev.contentTintColor = NSColor.tertiaryLabelColor;
    [row addSubview:prev];
    x = NSMaxX(prev.frame) + 2;
    NSButton *play = [self transportButton:symbol pointSize:24 side:28
                                    action:@selector(musicPlay:) identifier:@"popover.music.play" label:playLabel];
    play.frame = NSOffsetRect(play.frame, x, 0);
    if (!loaded) {
        NSArray *liked = [self offlineTrackPaths];
        play.enabled = liked.count > 0;
        if (!liked.count) {
            NSDictionary *coverage = [self offlineCoverage:[self offlinePrimaryKey] verifyHash:NO];
            play.accessibilityHelp = [self offlineStatus:coverage];
        }
    }
    [row addSubview:play];
    x = NSMaxX(play.frame) + 2;
    NSButton *next = [self transportButton:@"forward.end.fill" pointSize:18 side:22
                                    action:@selector(musicNext:) identifier:@"popover.music.next" label:kMusicNextTip];
    next.accessibilityHelp = kMusicNextTip;
    next.toolTip = kMusicNextTip;
    next.frame = NSOffsetRect(next.frame, x, 0);
    next.enabled = loaded;
    if (!loaded) next.contentTintColor = NSColor.tertiaryLabelColor;
    [row addSubview:next];
    CGFloat textX = NSMaxX(next.frame) + 8;
    CGFloat textRight = kW - kPad;
    if (external) {
        NSString *bundle = [_externalPlayback[@"source"] isEqual:@"spotify"] ? kSpotifyBundleID : kAppleMusicBundleID;
        NSString *playingIn = [_externalPlayback[@"source"] isEqual:@"spotify"] ? @"Playing in Spotify" : @"Playing in Music";
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundle];
        NSImage *icon = appURL ? [NSWorkspace.sharedWorkspace iconForFile:appURL.path] : nil;
        NSImageView *source = [NSImageView imageViewWithImage:icon ?: [NSImage imageNamed:NSImageNameApplicationIcon]];
        source.imageScaling = NSImageScaleProportionallyDown;
        source.frame = NSMakeRect(textRight - 22, (kSoundH - 22) / 2.0, 22, 22);
        source.accessibilityIdentifier = @"popover.music.external";
        source.accessibilityLabel = playingIn;
        source.accessibilityHelp = playingIn;
        [row addSubview:source];
        textRight = NSMinX(source.frame) - 6;
    } else if (loaded) {
        NSDictionary *ident = [self currentLocalIdentity];
        NSString *key = ident[@"trackKey"];
        BOOL hearted = key.length && [[self heartedKeys] containsObject:key];
        NSString *thumbID = [ident[@"trackID"] length] ? ident[@"trackID"] : key;
        NSButton *heart = [self transportButton:hearted ? @"heart.fill" : @"heart" pointSize:15 side:22
                                         action:@selector(musicFavorite:) identifier:@"popover.music.favorite"
                                          label:hearted ? @"Remove from Favourites" : @"Add to Favourites"];
        heart.frame = NSOffsetRect(heart.frame, textRight - 22, 0);
        if (_localHeartError.length) {
            heart.contentTintColor = NSColor.systemRedColor;
            heart.toolTip = _localHeartError;
            heart.accessibilityHelp = _localHeartError;
        } else {
            heart.contentTintColor = hearted ? NSColor.systemPinkColor : NSColor.secondaryLabelColor;
            NSString *hist = [NSString stringWithContentsOfFile:[self heartHistoryJSONL]
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            NSString *heartTip = HeartHistoryTooltip(hist, key, hearted);
            if (heartTip.length) {
                heart.toolTip = heartTip;
                heart.accessibilityHelp = heartTip;
            }
        }
        [row addSubview:heart];
        BOOL liked = thumbID.length && [[self mixLiked] containsObject:thumbID];
        NSButton *thumb = [self transportButton:liked ? @"hand.thumbsup.fill" : @"hand.thumbsup" pointSize:14 side:22
                                         action:@selector(musicThumbsUp:) identifier:@"popover.music.thumbsup"
                                          label:liked ? @"Remove thumbs-up" : @"Thumbs-up: mixes should play more like this"];
        thumb.frame = NSOffsetRect(heart.frame, -22, 0);
        thumb.contentTintColor = liked ? NSColor.systemBlueColor : NSColor.secondaryLabelColor;
        [row addSubview:thumb];
        textRight = NSMinX(thumb.frame) - 6;
    }
    CGFloat textW = textRight - textX;
    NSString *titleText = trackTitle.length ? trackTitle : @"Liked Music";
    const CGFloat titleH = 15, subtitleH = 14, textGap = 1;
    CGFloat textBottom = (kSoundH - (titleH + textGap + subtitleH)) / 2.0;
    NSTextField *title = [self text:titleText font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                              color:nil at:NSMakeRect(textX, textBottom + subtitleH + textGap, textW, titleH)
                             align:NSTextAlignmentLeft];
    title.accessibilityIdentifier = @"popover.music.title";
    title.accessibilityLabel = titleText;
    [row addSubview:title];
    double shownElapsed = _trackElapsed;
    if (loaded && _playbackPlaying && _trackSampledAt > 0)
        shownElapsed += CFAbsoluteTimeGetCurrent() - _trackSampledAt;
    NSString *time = loaded ? FormatTrackTime(shownElapsed, _trackDuration) : nil;
    NSString *subtitleText;
    if (external) {
        subtitleText = trackArtist.length ? trackArtist : @"";
    } else if (!loaded) {
        NSDictionary *coverage = [self offlineCoverage:[self offlinePrimaryKey] verifyHash:NO];
        subtitleText = [self offlineStatus:coverage];
    } else if (_trackDuration > 0) {
        subtitleText = trackArtist.length ? trackArtist : @"";
    } else if (trackArtist.length && time.length) {
        subtitleText = [NSString stringWithFormat:@"%@ · %@", trackArtist, time];
    } else subtitleText = trackArtist.length ? trackArtist : (time ?: @"");
    NSTextField *subtitle = [self text:subtitleText
                                  font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                                 color:NSColor.secondaryLabelColor
                                    at:NSMakeRect(textX, textBottom, textW, subtitleH) align:NSTextAlignmentLeft];
    subtitle.accessibilityIdentifier = @"popover.music.subtitle";
    subtitle.accessibilityLabel = subtitleText;
    [row addSubview:subtitle];
    [root addSubview:row];
    y += kSoundH;
    if (loaded && _trackDuration > 0) y = [self addAppleMusicScrubberTo:root at:y elapsed:shownElapsed];
    y = [self addOutputLineTo:root at:y];
    if (!_musicOff) y = [self addSeedTilesTo:root at:y];
    return [self addMusicNoteTo:root at:y + 2];
}
#pragma mark Other Macs

// The worker Macs to show, from `defaults write com.iantodd.glancebar remoteMachines`:
// an array of {name, host}, host being an ssh alias. Empty by default.
- (NSArray<NSDictionary *> *)remoteMachines {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:@"remoteMachines"];
    NSMutableArray *out = [NSMutableArray array];
    for (id m in list) if ([m isKindOfClass:NSDictionary.class] && [m[@"host"] length]) [out addObject:m];
    return out;
}
// This Mac's installed Glancebar commit, else the checkout HEAD. Empty when neither is known.
static NSString *FleetLocalSHA(void) {
    NSString *home = NSHomeDirectory();
    NSString *path = [home stringByAppendingPathComponent:@".local/state/glancebar-update/installed"];
    NSString *sha = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (sha.length) return sha;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[@"-C", [home stringByAppendingPathComponent:@"Projects/glancebar"], @"rev-parse", @"HEAD"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return @"";
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return @"";
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}
// Orange fleet word, after the chip temperature when the datum has one, otherwise in front of the limit.
static void AppendFleetWord(NSTextField *datum, NSString *word) {
    if (!word.length || !datum) return;
    NSMutableAttributedString *base = [datum.attributedStringValue mutableCopy] ?: [NSMutableAttributedString new];
    NSString *plain = base.string ?: @"";
    NSDictionary *gap = @{NSFontAttributeName: datum.font};
    NSDictionary *orange = @{NSFontAttributeName: datum.font, NSForegroundColorAttributeName: NSColor.systemOrangeColor};
    if ([plain isEqual:@"ready"]) {
        datum.attributedStringValue = [[NSAttributedString alloc] initWithString:word attributes:orange];
        datum.allowsDefaultTighteningForTruncation = YES;
        return;
    }
    NSRange deg = [plain rangeOfString:@"°"];
    NSUInteger insertAt = deg.location == NSNotFound ? 0 : NSMaxRange(deg);
    NSMutableAttributedString *piece = [NSMutableAttributedString new];
    if (insertAt > 0)
        [piece appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:gap]];
    [piece appendAttributedString:[[NSAttributedString alloc] initWithString:word attributes:orange]];
    if (insertAt == 0 && plain.length)
        [piece appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:gap]];
    [base insertAttributedString:piece atIndex:insertAt];
    datum.allowsDefaultTighteningForTruncation = YES;
    datum.attributedStringValue = base;
}
// Background poll of the other Macs: every two minutes on mains, every ten on battery (owner,
// 11 Nov 2026: "less often on battery"). A reading counts as current for a little longer than
// the poll interval; an open popover renews it every 25 s whatever the power source.
static const double kRemotePollMainsSeconds = 120, kRemotePollBatterySeconds = 600;
// One ssh round trip per Mac: its Glancebar --sample, heavy-slot governor mode and slots,
// and the fleet-sync status file. At most every 25 s while the popover is open.
- (void)pollRemoteMachinesIfDue {
    if (!_popover.isShown || !_musicProbesEnabled || CFAbsoluteTimeGetCurrent() - _remotePolledAt < 25) return;
    [self pollRemoteMachinesNow];
}
// With the popover closed the readings are kept warm from the 15 s refresh timer, every two
// minutes on mains and every ten on battery, so opening the popover shows the other Macs at
// once instead of after an ssh round trip (about 3 s, or a 5 s timeout for a Mac that is away).
// Owner, 11 Nov 2026: "usually when I open it there's a long lag to get any telemetry back".
- (double)remotePollSeconds { return (_bat.valid && !_bat.acConnected) ? kRemotePollBatterySeconds : kRemotePollMainsSeconds; }
- (double)remoteReadingFreshSeconds { return [self remotePollSeconds] + 180; }
- (void)pollRemoteMachinesInBackgroundIfDue {
    if (_popover.isShown || !_musicProbesEnabled || !_remoteInFlight || ![self remoteMachines].count) return;
    double every = [self remotePollSeconds];
    if (CFAbsoluteTimeGetCurrent() - _remotePolledAt < every) return;
    [self pollRemoteMachinesNow];
}
- (void)pollRemoteMachinesNow {
    _remotePolledAt = CFAbsoluteTimeGetCurrent();
    NSString *localSHA = FleetLocalSHA();
    for (NSDictionary *m in [self remoteMachines]) {
        NSString *host = m[@"host"];
        if ([_remoteInFlight containsObject:host]) continue;
        [_remoteInFlight addObject:host];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
            // One kept-open connection per Mac: over a relayed tailnet link the handshake is most
            // of a poll (3-12 s with it, about 1.5 s without), and polls slower than the watchdog
            // were being dropped, which left the row empty (11 Nov 2026).
            NSString *control = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh/glancebar-%C"];
            task.arguments = @[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=8",
                @"-o", @"ControlMaster=auto", @"-o", [@"ControlPath=" stringByAppendingString:control],
                @"-o", @"ControlPersist=900", @"-o", @"ServerAliveInterval=30", @"-o", @"ServerAliveCountMax=3", host,
                (@"G=/Applications/Glancebar.app/Contents/MacOS/Glancebar; [ -x \"$G\" ] || G=\"$HOME/Applications/Glancebar.app/Contents/MacOS/Glancebar\"; "
                  "\"$G\" --sample; echo @@; cat ~/.local/state/heavy-slot/mode 2>/dev/null; echo @@; ~/.local/bin/heavy-slot status 2>/dev/null; "
                  "echo @@; cat ~/.local/state/glancebar-update/status.json 2>/dev/null")];
            NSPipe *out = [NSPipe pipe];
            task.standardOutput = out;
            task.standardError = [NSFileHandle fileHandleWithNullDevice];
            task.standardInput = [NSFileHandle fileHandleWithNullDevice];
            NSDictionary *reading = nil;
            if ([task launchAndReturnError:NULL]) {
                GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:30];
                NSString *text = [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
                [task waitUntilExit];
                [watchdog disarm];
                NSArray *parts = [text componentsSeparatedByString:@"@@"];
                NSData *json = [[parts.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding];
                id sample = json.length ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
                if ([sample isKindOfClass:NSDictionary.class]) {
                    NSString *mode = parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
                    NSInteger free = 0, slots = parts.count > 2 ? HeavySlotCounts(parts[2], &free) : 0;
                    NSString *glance = parts.count > 3 ? [parts[3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
                    reading = @{@"sample": sample, @"mode": mode ?: @"", @"free": @(free), @"slots": @(slots),
                                @"at": @(CFAbsoluteTimeGetCurrent()), @"glancebar": glance ?: @"", @"localSHA": localSHA ?: @""};
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_remoteInFlight removeObject:host];
                if (reading) self->_remote[host] = reading;
                if (self->_popover.isShown) [self rebuildContent];
            });
        });
    }
}
- (void)toggleRemoteMachine:(ClickRow *)row {
    NSString *host = [row.accessibilityIdentifier stringByReplacingOccurrencesOfString:@"popover.row.remote." withString:@""];
    NSString *key = [@"remoteOpen." stringByAppendingString:host];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (_fleetExpandedHosts) {
        if ([_fleetExpandedHosts containsObject:host]) [_fleetExpandedHosts removeObject:host];
        else [_fleetExpandedHosts addObject:host];
    } else [ud setBool:![ud boolForKey:key] forKey:key];
    [self rebuildContent];
}
static NSColor *ReadinessColor(double score) {
    return score >= 0.7 ? NSColor.systemGreenColor : score >= 0.4 ? NSColor.systemOrangeColor : NSColor.systemRedColor;
}
// One row per Mac: name and chevron, a readiness bar, the score and what limits it.
static NSAttributedString *HeatTempsReadout(double chipC, NSColor *chipColor, double cellsC, NSColor *cellColor);

// Clicking opens that Mac's Storage, Battery, System and Speed rows beneath.
- (CGFloat)addRemoteMachinesTo:(NSView *)root at:(CGFloat)y {
    NSArray *machines = [self remoteMachines];
    if (!machines.count) return y;
    [self pollRemoteMachinesIfDue];
    y += 4;   // a thin rule separates this Mac from the others
    NSBox *rule = [self dividerAt:y];
    rule.accessibilityIdentifier = @"popover.divider.remote";
    [root addSubview:rule];
    y += 4;
    for (NSDictionary *m in machines) {
        NSString *host = m[@"host"], *name = [m[@"name"] length] ? m[@"name"] : host;
        NSString *stem = [@"popover.remote." stringByAppendingString:host];
        NSDictionary *reading = _remote[host];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double age = reading ? now - [reading[@"at"] doubleValue] : 0;
        BOOL fresh = reading && age < [self remoteReadingFreshSeconds];
        NSDictionary *sample = reading[@"sample"];
        NSDictionary *ready = fresh ? WorkerReadiness(sample, reading[@"mode"], [reading[@"free"] integerValue], [reading[@"slots"] integerValue]) : nil;
        NSString *awayText = RemoteAwayText(reading ? age : 0);
        double score = [ready[@"score"] doubleValue];
        NSColor *color = ready ? ReadinessColor(score) : NSColor.tertiaryLabelColor;
        BOOL open = _fleetExpandedHosts ? [_fleetExpandedHosts containsObject:host] : [NSUserDefaults.standardUserDefaults boolForKey:[@"remoteOpen." stringByAppendingString:host]];
        NSString *glance = fresh && [reading[@"glancebar"] isKindOfClass:NSString.class] ? reading[@"glancebar"] : nil;
        NSDictionary *drift = glance.length ? FleetSyncDrift(glance, [reading[@"localSHA"] isKindOfClass:NSString.class] ? reading[@"localSHA"] : @"") : nil;
        NSString *driftWord = [drift[@"word"] isKindOfClass:NSString.class] ? drift[@"word"] : nil;
        NSString *driftDetail = [drift[@"detail"] isKindOfClass:NSString.class] ? drift[@"detail"] : nil;
        NSString *tip = ready ? [NSString stringWithFormat:@"%@ · %@ ready · limited by %@ · click for details", name,
                                 [NSString stringWithFormat:@"%d%%", (int)lround(score * 100)], ready[@"limit"]]
                              : [NSString stringWithFormat:@"%@ · %@ · not reachable over ssh (%@)", name, awayText, host];
        if (driftDetail.length) tip = [tip stringByAppendingFormat:@" · %@", driftDetail];
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(toggleRemoteMachine:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = [@"popover.row.remote." stringByAppendingString:host];
        row.accessibilityLabel = tip;
        row.accessibilityHelp = tip;
        if (driftDetail.length) row.toolTip = tip;
        [self instrumentSymbol:@"laptopcomputer" tint:color identifier:[stem stringByAppendingString:@".symbol"] in:row];
        NSTextField *nameField = [self instrumentName:name identifier:[stem stringByAppendingString:@".name"] in:row];
        CGFloat nameW = ceil([name sizeWithAttributes:@{NSFontAttributeName: nameField.font}].width);
        NSImageView *chevron = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:(open ? @"chevron.down" : @"chevron.right") accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold]]];
        chevron.contentTintColor = NSColor.tertiaryLabelColor;
        chevron.frame = NSMakeRect(NSMinX(nameField.frame) + nameW + 6, (kRowH - 12) / 2.0, 12, 12);
        chevron.accessibilityIdentifier = [stem stringByAppendingString:@".chevron"];
        [row addSubview:chevron];
        Gauge *g = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        g.fraction = ready ? score : 0; g.color = color; g.markerFraction = -1; g.metricLabel = @"Readiness";
        g.accessibilityIdentifier = [stem stringByAppendingString:@".gauge"];
        [row addSubview:g];
        [self instrumentValue:(ready ? [NSString stringWithFormat:@"%d%%", (int)lround(score * 100)] : @"—") color:color
                   identifier:[stem stringByAppendingString:@".value"] in:row];
        NSTextField *datum = [self instrumentDatum:(ready ? ready[@"limit"] : awayText)
                        color:(ready && [ready[@"limit"] isEqual:@"ready"] ? NSColor.secondaryLabelColor : color)
                   identifier:[stem stringByAppendingString:@".datum"] in:row];
        // Chip temperature leads the datum: it is what Ian watches on the workers. The limit
        // follows only when something is limiting; "ready" adds nothing next to a green gauge.
        NSNumber *chipN = fresh ? SampleNumber(sample[@"chipC"]) : nil;
        if (ready && chipN.doubleValue > 0) {
            NSString *thermal = SampleString(sample[@"thermal"]);
            double chipC = chipN.doubleValue;
            NSColor *chipColor = (thermal && ![thermal isEqual:@"nominal"]) ? NSColor.systemOrangeColor
                : chipC >= 95 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
            NSMutableAttributedString *text = [HeatTempsReadout(chipC, chipColor, 0, nil) mutableCopy];
            if (text && ![ready[@"limit"] isEqual:@"ready"])
                [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:ready[@"limit"]]
                    attributes:@{NSFontAttributeName: datum.font, NSForegroundColorAttributeName: color}]];
            if (text) datum.attributedStringValue = text;
        }
        if (driftWord.length) AppendFleetWord(datum, driftWord);
        [root addSubview:row];
        y += kRowH;
        if (!open || !fresh) continue;
        y = [self addRemoteDetailRows:sample stem:stem to:root at:y];
    }
    return y;
}
// The opened drawer: the same four instruments as this Mac's, from the worker's sample.
- (CGFloat)addRemoteDetailRows:(NSDictionary *)s stem:(NSString *)stem to:(NSView *)root at:(CGFloat)y {
    NSMutableArray *rows = [NSMutableArray array];
    NSNumber *totalN = SampleNumber(s[@"diskTotalGB"]), *freeN = SampleNumber(s[@"diskFreeGB"]);
    if (totalN && freeN && totalN.doubleValue > 0) {
        double total = totalN.doubleValue, free = freeN.doubleValue;
        double used = MAX(0, MIN(1, 1 - free / total));
        [rows addObject:@[@"internaldrive", @"Storage", @(used), DiskColor(used), [NSString stringWithFormat:@"%d%%", (int)lround(used * 100)],
                          [NSString stringWithFormat:@"%.0f GB free", free], NSColor.secondaryLabelColor, @"storage"]];
    }
    NSArray *reported = [s[@"volumes"] isKindOfClass:NSArray.class] ? s[@"volumes"] : nil;
    NSUInteger volumeIndex = 0;
    NSFont *nameFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    for (NSDictionary *volume in GlanceExternalVolumes(reported)) {
        id freeValue = volume[@"freeBytes"], totalValue = volume[@"totalBytes"];
        if (![freeValue isKindOfClass:NSNumber.class] || ![totalValue isKindOfClass:NSNumber.class]) continue;
        long long cap = [totalValue longLongValue], freeBytes = [freeValue longLongValue];
        if (cap <= 0) continue;
        if (freeBytes < 0) freeBytes = 0;
        if (freeBytes > cap) freeBytes = cap;
        double used = GlanceExternalUsedFraction(volume);
        NSString *full = [volume[@"name"] isKindOfClass:NSString.class] ? volume[@"name"] : @"Disk";
        NSArray *names = [volume[@"names"] isKindOfClass:NSArray.class] ? volume[@"names"] : nil;
        NSString *shown = VolumeLabelThatFits(full, names, nameFont, RowNameW());
        NSString *tip = GlanceExternalTooltip(volume) ?: @"";
        [rows addObject:@[@"externaldrive", shown, @(used), DiskColor(used),
                          [NSString stringWithFormat:@"%d%%", (int)lround(used * 100)],
                          [NSString stringWithFormat:@"%@ free", CompactByteCount(freeBytes)],
                          NSColor.secondaryLabelColor,
                          [NSString stringWithFormat:@"volume.%lu", (unsigned long)volumeIndex],
                          tip, full]];
        volumeIndex++;
    }
    NSNumber *battN = SampleNumber(s[@"batt"]);
    if (battN) {
        int pct = battN.intValue;
        NSNumber *wattsN = SampleNumber(s[@"battW"]);
        double watts = wattsN ? wattsN.doubleValue : 0;
        NSNumber *acN = SampleNumber(s[@"ac"]);
        NSString *w = fabs(watts) < 0.3 ? @"0 W" : (FormatSignedWatts(watts) ?: @"");
        [rows addObject:@[(acN && acN.boolValue) ? @"battery.100.bolt" : @"battery.75", @"Battery", @(pct / 100.0), BattBarColor(pct),
                          [NSString stringWithFormat:@"%d%%", pct], w,
                          fabs(watts) < 0.3 ? NSColor.secondaryLabelColor : watts > 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor, @"battery"]];
    }
    NSNumber *cpuN = SampleNumber(s[@"cpu"]);
    if (cpuN) {
        double cpu = cpuN.doubleValue / 100;
        [rows addObject:@[@"cpu", @"System", @(cpu), CPUColor(cpu), [NSString stringWithFormat:@"%d%%", (int)lround(cpu * 100)], @"", NSColor.secondaryLabelColor, @"system"]];
    }
    NSString *thermal = SampleString(s[@"thermal"]);
    NSNumber *topN = SampleNumber(s[@"pTopMHz"]), *mhzN = SampleNumber(s[@"pMHz"]), *busyN = SampleNumber(s[@"pBusy"]);
    double top = topN.doubleValue, mhz = mhzN.doubleValue;
    double speed = thermal && [thermal isEqual:@"nominal"] ? 1
        : (top > 0 && mhz > 0 && busyN && busyN.doubleValue >= 0.5 ? MIN(1, mhz / top) : -1);
    if (speed >= 0) {
        NSColor *sc = [thermal isEqual:@"nominal"] ? NSColor.systemGreenColor : [thermal isEqual:@"moderate"] ? NSColor.systemOrangeColor : NSColor.systemRedColor;
        // Same readout as this Mac's Speed row: a chip glyph for the hottest core, a
        // battery glyph for the cells, each in its own colour.
        NSNumber *chipN = SampleNumber(s[@"chipC"]), *cellsN = SampleNumber(s[@"cellsC"]);
        double chipC = chipN ? chipN.doubleValue : 0, cellsC = cellsN ? cellsN.doubleValue : 0;
        BatteryHeat cells = BatteryHeatFor(cellsC);
        NSColor *chipColor = [thermal isEqual:@"nominal"] ? NSColor.secondaryLabelColor : sc;
        NSColor *cellColor = cells == BatteryHeatHot ? NSColor.systemRedColor
            : cells == BatteryHeatWarm ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
        NSString *needle = speed >= 0.9 ? @"gauge.with.dots.needle.100percent"
            : speed >= 0.6 ? @"gauge.with.dots.needle.67percent" : @"gauge.with.dots.needle.33percent";
        [rows addObject:@[needle, @"Speed", @(speed), sc, [NSString stringWithFormat:@"%d%%", (int)lround(speed * 100)],
                          HeatTempsReadout(chipC, chipColor, cellsC, cellColor) ?: @"", NSColor.secondaryLabelColor, @"speed"]];
    }
    for (NSArray *r in rows) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        NSString *rs = [NSString stringWithFormat:@"%@.%@", stem, r[7]];
        row.accessibilityIdentifier = rs;
        NSString *volumeTip = r.count > 8 && [r[8] isKindOfClass:NSString.class] ? r[8] : nil;
        NSString *fullName = r.count > 9 && [r[9] isKindOfClass:NSString.class] && [r[9] length] ? r[9] : r[1];
        if (volumeTip.length) {
            row.accessibilityHelp = volumeTip;
            row.accessibilityLabel = volumeTip;
            if (![fullName isEqual:r[1]] || [volumeTip containsString:@"Disk image:"]) row.toolTip = volumeTip;
        }
        [self instrumentSymbol:r[0] tint:r[3] identifier:[rs stringByAppendingString:@".symbol"] in:row];
        // Grey names: these rows belong to the Mac above, not this one.
        NSTextField *nameField = [self instrumentName:r[1] identifier:[rs stringByAppendingString:@".name"] in:row];
        nameField.textColor = NSColor.secondaryLabelColor;
        if (![fullName isEqual:r[1]]) nameField.accessibilityLabel = fullName;
        Gauge *g = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        g.fraction = [r[2] doubleValue]; g.color = r[3]; g.markerFraction = -1; g.metricLabel = fullName;
        g.accessibilityIdentifier = [rs stringByAppendingString:@".gauge"];
        [row addSubview:g];
        [self instrumentValue:r[4] color:r[3] identifier:[rs stringByAppendingString:@".value"] in:row];
        if ([r[5] length]) {
            NSTextField *datum = [self instrumentDatum:([r[5] isKindOfClass:NSAttributedString.class] ? [r[5] string] : r[5])
                                                 color:r[6] identifier:[rs stringByAppendingString:@".datum"] in:row];
            if ([r[5] isKindOfClass:NSAttributedString.class]) datum.attributedStringValue = r[5];
        }
        [root addSubview:row];
        y += kRowH;
    }
    return y;
}

// Four seed songs, the triple j station, and a round New picks button. A click plays
// that seed's mix; the playing tile is outlined. Missing station.json dims the station.
- (CGFloat)addSeedTilesTo:(NSView *)root at:(CGFloat)y {
    if (_musicOff) return y;
    [self ensureMixSeeds];
    [self ensureStation];
    const CGFloat side = 54, buttonSide = 22, capH = 30, top = 6, rowH = 14;
    NSUInteger n = MIN(_mixSeeds.count, 4);
    NSUInteger gaps = n + 1;   // between the seeds, the station and the button
    CGFloat gap = (kW - 2 * kPad - (n + 1) * side - buttonSide) / (CGFloat)gaps;
    if (gap < 2) gap = 2;
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(0, y + top, kW, side + capH)];
    line.accessibilityIdentifier = @"popover.mix";
    NSFont *capFont = [NSFont systemFontOfSize:10];
    CGFloat x = kPad;
    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *seed = _mixSeeds[i];
        BOOL playing = _localMode && [seed[@"key"] isEqual:_mixPlayingKey];
        BOOL starting = [seed[@"key"] isEqual:_mixStartingKey];
        NSImage *cover = _mixArt[seed[@"trackID"]];
        GBSeedTile *seedTile = [GBSeedTile buttonWithImage:cover ?: [[NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil]
                                                   imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular]]
                                  target:self action:@selector(playSeedMix:)];
        seedTile.cover = cover;
        seedTile.songTitle = SeedCaption(seed[@"title"]);
        seedTile.songArtist = seed[@"artist"];
        seedTile.seedKey = seed[@"key"];
        NSDictionary *tile = [self mixTileStateForKey:seed[@"key"]];
        seedTile.offlineStatus = tile[@"tooltip"];
        seedTile.enabled = [tile[@"enabled"] boolValue];
        seedTile.alphaValue = [tile[@"alpha"] doubleValue];
        seedTile.imageScaling = cover ? NSImageScaleProportionallyUpOrDown : NSImageScaleNone;
        if (!cover) seedTile.contentTintColor = NSColor.tertiaryLabelColor;
        seedTile.tag = (NSInteger)i;
        seedTile.wantsLayer = YES;
        seedTile.title = @"";
        seedTile.bordered = NO;
        seedTile.imagePosition = NSImageOnly;
        seedTile.layer.cornerRadius = 4;
        seedTile.layer.masksToBounds = YES;
        seedTile.accessibilityIdentifier = [NSString stringWithFormat:@"popover.mix.seed.%lu", (unsigned long)i];
        BOOL album = [seed[@"kind"] isEqual:@"album"];
        seedTile.accessibilityLabel = [NSString stringWithFormat:@"Play a mix from %@ %@ by %@", album ? @"the album" : @"the song",
                                   seed[@"title"], seed[@"subtitle"]];
        seedTile.accessibilityHelp = [NSString stringWithFormat:@"%@ — %@ · a mix around this %@", seed[@"title"], seed[@"subtitle"],
                                  album ? @"album" : @"song"];
        seedTile.accessibilityHelp = [seedTile.accessibilityHelp stringByAppendingFormat:@" · %@", seedTile.offlineStatus];
        if (!cover) seedTile.layer.backgroundColor = [NSColor colorWithWhite:0.5 alpha:0.15].CGColor;
        if (playing) { seedTile.layer.borderWidth = 2; seedTile.layer.borderColor = NSColor.controlAccentColor.CGColor; }
        if (starting) seedTile.alphaValue = 0.45;
        seedTile.frame = NSMakeRect(x, capH, side, side);
        [line addSubview:seedTile];
        CGFloat capW = side + gap - 2, capX = x - (gap - 2) / 2;
        NSArray *captions = @[SeedCaption(seed[@"title"]), seed[@"artist"] ?: @""];
        for (NSUInteger l = 0; l < captions.count; l++) {
            NSTextField *cap = [GBRecoverableTextField labelWithString:captions[l]];
            cap.font = capFont;
            cap.textColor = playing ? NSColor.controlAccentColor : (l ? NSColor.secondaryLabelColor : NSColor.labelColor);
            cap.alignment = NSTextAlignmentCenter;
            cap.lineBreakMode = NSLineBreakByTruncatingTail;
            cap.allowsDefaultTighteningForTruncation = YES;
            cap.frame = NSMakeRect(capX, capH - 2 - rowH * (l + 1), capW, rowH);
            [(GBRecoverableTextField *)cap updateClippedTextHelp];
            cap.accessibilityIdentifier = [NSString stringWithFormat:l ? @"popover.mix.artist.%lu" : @"popover.mix.caption.%lu", (unsigned long)i];
            [line addSubview:cap];
        }
        GBSeedHover *hover = [[GBSeedHover alloc] initWithFrame:NSMakeRect(capX, 0, capW, capH + side)];
        hover.tile = seedTile;
        hover.controller = self;
        hover.preloadKey = seed[@"key"];
        hover.accessibilityIdentifier = [NSString stringWithFormat:@"popover.mix.hover.%lu", (unsigned long)i];
        [line addSubview:hover];
        x += side + gap;
    }
    NSDictionary *stationTile = [self mixTileStateForKey:@"station:triplej"];
    BOOL stationOn = _stationAvailable && [stationTile[@"enabled"] boolValue];
    if (!_stationAvailable) stationTile = @{@"alpha": @0.4, @"tooltip": stationTile[@"tooltip"] ?: @"", @"enabled": @NO, @"state": @"empty"};
    BOOL stationPlaying = [_mixPlayingKey isEqual:@"station:triplej"];
    GBStationTile *station = [GBStationTile buttonWithImage:StationTileImage(!stationOn) target:self action:@selector(playStation:)];
    station.seedKey = @"station:triplej";
    station.picks = _stationPicks ?: @[];
    station.title = @"";
    station.bordered = NO;
    station.imagePosition = NSImageOnly;
    station.imageScaling = NSImageScaleNone;
    station.wantsLayer = YES;
    station.layer.cornerRadius = 4;
    station.layer.masksToBounds = YES;
    station.alphaValue = [stationTile[@"alpha"] doubleValue];
    station.enabled = stationOn;
    station.offlineStatus = stationTile[@"tooltip"];
    station.accessibilityIdentifier = @"popover.mix.station";
    NSUInteger pickCount = station.picks.count;
    station.accessibilityLabel = @"New music for you";
    station.accessibilityHelp = [@"New music for you · " stringByAppendingString:station.offlineStatus];
    if (stationPlaying) { station.layer.borderWidth = 2; station.layer.borderColor = NSColor.controlAccentColor.CGColor; }
    station.frame = NSMakeRect(x, capH, side, side);
    [line addSubview:station];
    if (stationOn && pickCount > 0) {
        GBCountBadge *badge = [[GBCountBadge alloc] initWithFrame:NSMakeRect(NSMaxX(station.frame) - 18, NSMaxY(station.frame) - 18, 16, 16)];
        badge.count = (NSInteger)pickCount;
        badge.accessibilityIdentifier = @"popover.mix.station.badge";
        badge.accessibilityLabel = [NSString stringWithFormat:@"%lu new picks", (unsigned long)pickCount];
        [line addSubview:badge];
    }
    {
        CGFloat capW = side + gap - 2, capX = x - (gap - 2) / 2;
        NSArray *captions = @[@"New music", @"for you"];
        for (NSUInteger l = 0; l < captions.count; l++) {
            NSTextField *cap = [GBRecoverableTextField labelWithString:captions[l]];
            cap.font = capFont;
            cap.textColor = stationPlaying ? NSColor.controlAccentColor
                : (l ? NSColor.secondaryLabelColor : (stationOn ? NSColor.labelColor : NSColor.tertiaryLabelColor));
            cap.alignment = NSTextAlignmentCenter;
            cap.lineBreakMode = NSLineBreakByTruncatingTail;
            cap.frame = NSMakeRect(capX, capH - 2 - rowH * (l + 1), capW, rowH);
            [(GBRecoverableTextField *)cap updateClippedTextHelp];
            cap.accessibilityIdentifier = l ? @"popover.mix.artist.4" : @"popover.mix.caption.4";
            [line addSubview:cap];
        }
        GBSeedHover *hover = [[GBSeedHover alloc] initWithFrame:NSMakeRect(capX, 0, capW, capH + side)];
        hover.tile = station;
        hover.controller = self;
        hover.preloadKey = @"station:triplej";
        hover.accessibilityIdentifier = @"popover.mix.hover.station";
        [line addSubview:hover];
    }
    x += side + gap;
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    NSButton *picks = [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:nil]
                                                imageWithSymbolConfiguration:cfg] target:self action:@selector(newMixPicks:)];
    picks.title = @"";
    picks.bordered = NO;
    picks.imagePosition = NSImageOnly;
    picks.imageScaling = NSImageScaleNone;
    picks.contentTintColor = NSColor.secondaryLabelColor;
    picks.wantsLayer = YES;
    picks.layer.backgroundColor = [NSColor colorWithWhite:0.5 alpha:0.15].CGColor;
    picks.layer.cornerRadius = buttonSide / 2.0;
    picks.layer.masksToBounds = YES;
    picks.accessibilityIdentifier = @"popover.mix.newpicks";
    picks.accessibilityLabel = @"New picks";
    picks.accessibilityHelp = @"Four new songs and albums to start a mix from";
    picks.frame = NSMakeRect(x, capH + (side - buttonSide) / 2.0, buttonSide, buttonSide);
    [line addSubview:picks];
    [root addSubview:line];
    return y + top + side + capH;
}
// Where it will play and how loud, before anything starts: the output device (its symbol and
// name; click to cycle, right-click for the list), a volume slider, and the level.
- (CGFloat)addOutputLineTo:(NSView *)root at:(CGFloat)y {
    [self ensureAudioDisplay];
    [self watchOutputVolume];
    [self refreshOutputVolume];
    NSDictionary *choice = [self playerOutputChoice];
    const CGFloat levelW = 40, rowH = 24, sliderMin = 88;
    NSButton *output = [self outputButton];
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, rowH)];
    line.accessibilityIdentifier = @"popover.sound.line";
    CGFloat nameW = kW - 2 * kPad - levelW - 4 - sliderMin - 26;
    output.frame = NSMakeRect(kPad, 1, nameW, rowH - 2);
    [line addSubview:output];
    CGFloat sliderX = NSMaxX(output.frame) + 4;
    CGFloat sliderW = kW - kPad - levelW - 4 - sliderX;
    BOOL known = [choice[@"volumeControllable"] boolValue] && _outputVolume >= 0 && [choice[@"effectiveUID"] length];
    BOOL showMute = _musicSilentQA || (known && _outputMuted);
    NSImageView *speaker = [NSImageView imageViewWithImage:[[NSImage imageWithSystemSymbolName:showMute ? @"speaker.slash" : @"speaker.wave.2" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular]]];
    speaker.contentTintColor = showMute ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    speaker.frame = NSMakeRect(sliderX, 3, 18, 16);
    speaker.accessibilityIdentifier = @"popover.sound.volume.symbol";
    [line addSubview:speaker];
    sliderX += 22;
    sliderW -= 22;
    GBOutputVolumeSlider *slider = [GBOutputVolumeSlider sliderWithValue:known ? _outputVolume : 0 minValue:0 maxValue:1
        target:self action:@selector(setOutputVolumeFromSlider:)];
    slider.outputUID = choice[@"effectiveUID"];
    slider.controlSize = NSControlSizeSmall;
    slider.continuous = YES;
    slider.enabled = known;
    slider.trackFillColor = OutputVolumeFill(known ? _outputVolume : -1, showMute);
    slider.frame = NSMakeRect(sliderX, 2, sliderW, 18);
    slider.accessibilityIdentifier = @"popover.sound.volume";
    slider.accessibilityLabel = @"Player speaker volume";
    slider.accessibilityHelp = [NSString stringWithFormat:@"Hardware volume on %@", choice[@"name"]];
    [line addSubview:slider];
    NSTextField *level = [self text:OutputVolumeText(known ? _outputVolume : -1, showMute)
        font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]
        color:OutputVolumeColor(known ? _outputVolume : -1, showMute)
        at:NSMakeRect(kW - kPad - levelW, 3, levelW, 16) align:NSTextAlignmentRight];
    level.accessibilityIdentifier = @"popover.sound.level";
    level.accessibilityLabel = showMute ? @"Muted" : [NSString stringWithFormat:@"Volume %@", level.stringValue];
    if (_musicSilentQA) level.accessibilityHelp = @"Silent QA mode: player output forced to mute";
    [line addSubview:level];
    [root addSubview:line];
    return y + rowH;
}
// Elapsed, a seek slider, and the length under the transport row.
- (CGFloat)addAppleMusicScrubberTo:(NSView *)root at:(CGFloat)y elapsed:(double)elapsed {
    const CGFloat h = 18, clockW = 40;
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, h)];
    line.accessibilityIdentifier = @"popover.music.scrubber";
    NSFont *clockFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    CGFloat rightX = kW - kPad;
    BOOL timed = _trackDuration > 0;
    NSTextField *now = [self text:timed ? FormatTrackClock(elapsed, _trackDuration) : @"" font:clockFont
                            color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, 2, clockW, 14)
                            align:NSTextAlignmentLeft];
    now.accessibilityIdentifier = @"popover.music.elapsed";
    [line addSubview:now];
    NSTextField *length = [self text:timed ? FormatTrackClock(_trackDuration, _trackDuration) : @"" font:clockFont
                               color:NSColor.secondaryLabelColor
                                  at:NSMakeRect(rightX - clockW, 2, clockW, 14) align:NSTextAlignmentRight];
    length.accessibilityIdentifier = @"popover.music.duration";
    [line addSubview:length];
    if (timed) {
        NSSlider *slider = [NSSlider sliderWithValue:MIN(MAX(elapsed, 0), _trackDuration) minValue:0
                                            maxValue:_trackDuration target:self action:@selector(musicSeek:)];
        slider.controlSize = NSControlSizeSmall;
        slider.continuous = NO;
        CGFloat sx = NSMaxX(now.frame) + 4;
        slider.frame = NSMakeRect(sx, 0, NSMinX(length.frame) - 4 - sx, h);
        slider.accessibilityIdentifier = @"popover.music.position";
        slider.accessibilityLabel = @"Position";
        [line addSubview:slider];
    }
    [root addSubview:line];
    return y + h;
}
- (NSButton *)outputButton {
    [self ensureAudioDisplay];
    NSDictionary *choice = [self playerOutputChoice];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:@"hifispeaker"
        accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    OutputCycleButton *button = [OutputCycleButton buttonWithImage:image target:self action:@selector(cycleOutput:)];
    button.bordered = NO;
    button.imagePosition = NSImageLeading;
    button.imageHugsTitle = YES;
    button.alignment = NSTextAlignmentLeft;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.secondaryLabelColor;
    NSString *title = [NSString stringWithFormat:@" %@", choice[@"name"]];
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    ((NSButtonCell *)button.cell).wraps = NO;
    ((NSButtonCell *)button.cell).usesSingleLineMode = YES;
    ((NSButtonCell *)button.cell).lineBreakMode = NSLineBreakByTruncatingTail;
    button.accessibilityIdentifier = @"popover.sound";
    NSString *label = _playerOutputUID.length
        ? [NSString stringWithFormat:@"Player output, %@", choice[@"name"]]
        : [NSString stringWithFormat:@"Player output, System, %@", choice[@"name"]];
    button.accessibilityLabel = label;
    NSString *help = [choice[@"note"] length] ? choice[@"note"] : @"";
    if ([choice[@"diverged"] boolValue] && [choice[@"systemDefaultName"] length]) {
        NSString *tip = [NSString stringWithFormat:@"Mac output is %@ (no volume control)",
                         choice[@"systemDefaultName"]];
        help = help.length ? [NSString stringWithFormat:@"%@\n%@", help, tip] : tip;
    } else if (!help.length) {
        help = @"Choose where Glancebar's player plays. Other apps stay on the Mac's output.";
    }
    button.toolTip = [choice[@"diverged"] boolValue] && [choice[@"systemDefaultName"] length]
        ? [NSString stringWithFormat:@"Mac output is %@ (no volume control)", choice[@"systemDefaultName"]] : nil;
    button.accessibilityHelp = help;
    return button;
}
- (IBAction)cycleOutput:(id)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL menuGesture = (event.modifierFlags & NSEventModifierFlagOption) ||
        event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp;
    NSView *anchor = [sender isKindOfClass:NSView.class] ? sender : nil;
    if (menuGesture) { [self showOutputMenu:anchor]; return; }
    if (_musicProbesEnabled) {
        _audioDevices = ReadAudioDevices();
        NSString *live = DefaultOutputUID(_audioDevices);
        if (live.length) _defaultOutputUID = live;
    }
    NSArray *choices = PlayerOutputMenuChoices(_audioDevices, _defaultOutputUID);
    NSString *next = PlayerOutputCycleNext(choices, _playerOutputUID);
    if (!next.length) { [self showOutputMenu:anchor]; return; }
    NSString *name = @"";
    for (NSDictionary *row in choices) {
        if (![row[@"uid"] isEqual:next]) continue;
        name = row[@"name"];
        break;
    }
    [self setPlayerOutputChoiceUID:next name:name];
}
#pragma mark Player output
- (CGFloat)addMusicNoteTo:(NSView *)root at:(CGFloat)y {
    if (!_musicNote.length) return y;
    NSTextField *hint = [self text:_musicNote font:[NSFont systemFontOfSize:11]
                             color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kPad, y, kW - 2 * kPad, 14) align:NSTextAlignmentLeft];
    hint.maximumNumberOfLines = 1;
    hint.accessibilityHelp = _musicNote;
    hint.accessibilityIdentifier = @"popover.music.hint";
    [root addSubview:hint];
    return y + 16;
}
- (NSMenu *)playerOutputMenu {
    NSMenu *menu = [NSMenu new]; menu.autoenablesItems = NO;
    NSDictionary *choice = [self playerOutputChoice];
    if ([choice[@"note"] length]) {
        NSMenuItem *status = [menu addItemWithTitle:choice[@"note"] action:nil keyEquivalent:@""];
        status.enabled = NO;
        [menu addItem:NSMenuItem.separatorItem];
    }
    NSMenuItem *header = [menu addItemWithTitle:@"Player output" action:nil keyEquivalent:@""];
    header.enabled = NO;
    for (NSDictionary *row in PlayerOutputMenuChoices(_audioDevices, _defaultOutputUID)) {
        NSString *uid = row[@"uid"] ?: @"";
        NSMenuItem *item = [menu addItemWithTitle:row[@"name"] ?: @"Output" action:@selector(choosePlayerOutput:)
                                    keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{@"uid": uid, @"name": row[@"name"] ?: @""};
        BOOL selected = [uid isEqual:_playerOutputUID] || (!uid.length && !_playerOutputUID.length);
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        if (![row[@"system"] boolValue]) {
            for (NSDictionary *dev in _audioDevices) {
                if ([dev[@"uid"] isEqual:uid]) {
                    item.image = [NSImage imageWithSystemSymbolName:AudioSymbolName(dev) accessibilityDescription:nil];
                    break;
                }
            }
        }
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *macHeader = [menu addItemWithTitle:@"Mac output (system default)" action:nil keyEquivalent:@""];
    macHeader.enabled = NO;
    for (NSDictionary *device in AudioOutputMenuDevices(_audioDevices, _defaultOutputUID)) {
        NSMenuItem *item = [menu addItemWithTitle:device[@"name"] ?: @"Output" action:@selector(chooseSystemOutput:)
                                    keyEquivalent:@""];
        item.target = self; item.representedObject = device[@"uid"];
        item.state = [device[@"uid"] isEqual:_defaultOutputUID] ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = [NSImage imageWithSystemSymbolName:AudioSymbolName(device) accessibilityDescription:nil];
    }
    if (!AudioOutputMenuDevices(_audioDevices, _defaultOutputUID).count) {
        NSMenuItem *empty = [menu addItemWithTitle:@"No output devices" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }
    return menu;
}
- (void)choosePlayerOutput:(NSMenuItem *)item {
    NSDictionary *row = item.representedObject;
    if (![row isKindOfClass:NSDictionary.class]) return;
    [self setPlayerOutputChoiceUID:row[@"uid"] name:row[@"name"]];
}
- (void)chooseSystemOutput:(NSMenuItem *)item {
    NSString *uid = item.representedObject;
    if (![uid isKindOfClass:NSString.class]) return;
    for (NSDictionary *row in ReadAudioDevices()) {
        if (![row[@"uid"] isEqual:uid]) continue;
        SetOutputDevice((AudioObjectID)[row[@"deviceID"] unsignedIntValue]);
        _defaultOutputUID = uid;
        break;
    }
    if (_popover.isShown) [self rebuildContent];
}
- (void)showOutputMenu:(NSView *)sender {
    [self ensureAudioDisplay];
    if (_musicProbesEnabled) { _audioDevices = ReadAudioDevices(); _defaultOutputUID = DefaultOutputUID(_audioDevices); }
    [[self playerOutputMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds)) inView:sender];
}
- (void)toggleSwitchToNewOutputs:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:!SwitchToNewOutputs() forKey:@"switchToNewOutputs"];
}

- (void)refreshVolumesAsync {
    // Each abandoned scan leaves a thread blocked in the kernel; retry a mount that keeps
    // hanging every few minutes, not every tick.
    if (_volumeAbandonedAt > 0 && CFAbsoluteTimeGetCurrent() - _volumeAbandonedAt < 300) return;
    if (_volumesLoading) {
        // The in-flight scan owns the serial queue. Another tick must not enqueue a
        // second one behind it; past the budget the UI says the reading is unavailable.
        if (!_volumesUnavailable &&
            VolumeScanUnavailable(YES, CFAbsoluteTimeGetCurrent() - _volumeScanStarted)) {
            _volumesUnavailable = YES;
            // The stuck call cannot be cancelled. Abandon its queue to it and let the next
            // tick scan on a fresh one, so a mount that recovers is read again.
            _volumeQueue = dispatch_queue_create("com.iantodd.glancebar.volumes", DISPATCH_QUEUE_SERIAL);
            _volumesLoading = NO;
            _volumeAbandonedAt = CFAbsoluteTimeGetCurrent();
            [self updateBar];
            [self refreshVisibleSurfaces];
        }
        return;
    }
    _volumesLoading = YES;
    _volumeScanStarted = CFAbsoluteTimeGetCurrent();
    NSUInteger generation = ++_volumeScanGen;
    dispatch_async(_volumeQueue, ^{
        NSArray<Volume *> *volumes = ScanVolumes();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_volumeScanGen) return;   // an abandoned scan finishing late
            self->_volumesLoading = NO;
            // Keep last-good data if an offline mount makes a scan fail wholesale.
            if (volumes.count) {
                self->_vols = volumes;
                self->_volumesUnavailable = NO;
                self->_lastVolumeSuccess = NSDate.date;
            } else self->_volumesUnavailable = YES;
            [self updateBar];
            [self refreshVisibleSurfaces];
        });
    });
}

- (void)meteredWillSleep:(NSNotification *)note { (void)note; [self notePlayback:@"sleep" fields:nil]; [self playbackCause:@"sleep"]; _storageSleeping=YES; _storageIndex.paused=YES; _activityGeneration++; _activitySurvey = nil; [_meteredMonitor sleep]; }
- (void)meteredDidWake:(NSNotification *)note { (void)note; [self notePlayback:@"wake" fields:nil]; _storageSleeping=NO; [_meteredMonitor wake]; [self requestStorageScanIfNeeded]; }

- (void)refresh {
    [_meteredMonitor tick];
    [self pollRemoteMachinesInBackgroundIfDue];
    [self refreshVolumesAsync];
    BOOL wasOnAC = _bat.valid && _bat.acConnected;
    _bat = ReadBattery();
    [self runHeatGuard];
    [self batteryForecast];
    [self noteEnergyBaseline:wasOnAC];
    [self captureBatteryDiagnosticIfRequested];
    // refresh fires from three uncoordinated sources (15s timer, IOPS notification
    // bursts, popover open); only advance the CPU tick baseline when the window is
    // wide enough to be meaningful, and reuse the last good reading otherwise.
    double nowT = CFAbsoluteTimeGetCurrent();
    BOOL advance = nowT - _cpuBaselineTime >= 2.0;
    SystemState s = ReadSystemState(advance ? &_cpuPrev : NULL);
    if (advance) _cpuBaselineTime = nowT;
    if (s.cpuValid) { _lastCPU = s.cpu; _lastCPUValid = YES; }
    else if (_lastCPUValid) { s.cpu = _lastCPU; s.cpuValid = YES; }
    _sys = s;
    ThermalLevel thermal = SystemThermalLevel(s);
    _heatSpeed = HeatSpeedFraction(thermal, s.clocks.valid ? s.clocks.pMHz : 0, s.clocks.pMaxMHz,
                                   s.clocks.valid ? s.clocks.pBusy : 0, _heatSpeed);
    if (thermal != ThermalNear && thermal != ThermalThrottling) _pressureSince = 0;
    else if (!_pressureSince) _pressureSince = CFAbsoluteTimeGetCurrent();
    _lastMachineRefresh = NSDate.date;
    [self refreshAIUsageAsync];
    [self refreshLidAwakeAsync];
    if (_bat.valid) {
        [_ampHistory addObject:@(_bat.amperage_mA)];
        while (_ampHistory.count > 6) [_ampHistory removeObjectAtIndex:0];
    }
    [self updateBar];
    [self refreshVisibleSurfaces];
    // The details window stays open indefinitely; refresh its one-shot process samples
    // on a slow cadence so they don't masquerade as live data next to live numbers.
    if (_storageCacheLoaded) [self requestStorageScanIfNeeded];
    if (_detailsWindow.isVisible && ![self activityTabSelected] && ![self storageTabSelected] && !_hogsLoading && !_procStatsLoading &&
        CFAbsoluteTimeGetCurrent() - _lastSampleTime >= 30)
        [self beginSampling];
}

// AI state lives in local files plus sqlite child processes — never read it on the
// main thread (refresh fires every 15s and on IOPS bursts). Single-flight: a tick
// that arrives mid-read is skipped; the next one catches up.
// A catch-up continuation: skips the hidden-pass throttle, which exists to space out
// fresh passes, not to strand one halfway through the backlog.
- (void)refreshAIUsageAsyncDraining {
    _aiDraining = YES;
    [self refreshAIUsageAsync];
    _aiDraining = NO;
}

- (void)refreshAIUsageAsync {
    BOOL showAI = !_activityPresenting && (_popover.isShown || (_detailsWindow.isVisible && ![self activityTabSelected]));
    // While every AI surface is hidden, one bounded pass every few minutes keeps the figures
    // warm. Skipping hidden passes entirely meant every open began from whatever the last
    // open left behind, a "Cached limit" from hours ago that read as stuck (2026-10-06).
    if (!showAI && !_aiDraining && _lastAIRefresh && -_lastAIRefresh.timeIntervalSinceNow < kHiddenAIRefreshInterval) return;
    if (_aiLoading) { _aiRefreshPending = YES; return; }
    _aiLoading = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL useAccount = [ud boolForKey:@"useClaudeAccount"];
    BOOL useCursorAccount = [ud boolForKey:@"useCursorAccount"];
    // Keep already opted-in accounts current between opens. The reader enforces the
    // shared 15-minute fetch interval and provider retry delays; hiding the panel must
    // not prevent an otherwise due refresh. Low Data and account consent still gate it.
    BOOL allowAccountFetch = useAccount && !GBLowDataEnabled();
    BOOL allowCursorAccountFetch = useCursorAccount && !GBLowDataEnabled();
    BOOL allowTranscripts = [ud boolForKey:@"useClaudeTranscripts"];
    if (!_aiGatesLogged || showAI != _lastShowAI || useAccount != _lastUseAccount ||
        useCursorAccount != _lastUseCursorAccount || allowTranscripts != _lastAllowTranscripts) {
        GBLog("gates: showAI=%d useClaudeAccount=%d useCursorAccount=%d transcripts=%d",
              showAI, useAccount, useCursorAccount, allowTranscripts);
        _aiGatesLogged = YES; _lastShowAI = showAI;
        _lastUseAccount = useAccount; _lastUseCursorAccount = useCursorAccount;
        _lastAllowTranscripts = allowTranscripts;
    }
    dispatch_async(_aiQueue, ^{
        self->_aiReader.allowCodexAccountFetch = !GBLowDataEnabled();
        self->_aiReader.useClaudeAccount = useAccount;
        self->_aiReader.allowClaudeAccountFetch = allowAccountFetch;
        self->_aiReader.useCursorAccount = useCursorAccount;
        self->_aiReader.allowCursorAccountFetch = allowCursorAccountFetch;
        self->_aiReader.allowClaudeTranscripts = allowTranscripts;
        NSArray<AIUsage *> *usage = [self->_aiReader read];
        BOOL needsImmediateRescan = self->_aiReader.needsImmediateRescan;
        BOOL totalsIncomplete = self->_aiReader.totalsIncomplete;
        NSString *catchUpStatus = self->_aiReader.catchUpStatus;
        NSMutableString *sig = [NSMutableString string];
        for (AIUsage *u in usage)
            [sig appendFormat:@"%@|%d|%d|%d|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%.4f|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@;",
             u.name, u.available, u.limitStatusAvailable, u.limitStale,
             u.todayTokens, u.todayTokensAll, u.weekTokens, u.weekTokensAll,
             u.todaySessions, u.weekSessions, u.todayMessages, u.todayToolCalls,
             u.remainingFraction, u.resetText, u.statusText, u.statusReason,
             u.statusSource, u.extraUsage, u.limitWindows, u.models, u.lastActivity,
             u.limitUpdatedAt, u.limitRefreshError, u.billingNote];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_aiLoading = NO;
            BOOL rerun = self->_aiRefreshPending;
            self->_aiRefreshPending = NO;
            self->_aiUsage = usage;
            self->_lastAIRefresh = NSDate.date;
            self->_aiTotalsIncomplete = totalsIncomplete;
            self->_aiCatchUpStatus = catchUpStatus;
            if (![sig isEqualToString:self->_aiSignature]) {
                self->_aiSignature = sig;
                [self updateBar];
                [self refreshVisibleSurfaces];
            }
            if (rerun) [self refreshAIUsageAsync];
            else if (needsImmediateRescan) {
                // Drain the bounded reader to the end: promptly while an AI surface is
                // visible, gently while hidden. A hidden pass that stopped after one chunk
                // left hundreds of MB for every open to chew through (2026-10-06).
                BOOL visible = self->_popover.isShown || self->_detailsWindow.isVisible;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((visible ? 0.15 : 1.0) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self refreshAIUsageAsyncDraining]; });
            }
        });
    });
}

- (double)avgAmp {
    if (!_ampHistory.count) return 0;
    double s = 0; for (NSNumber *a in _ampHistory) s += a.doubleValue;
    return s / _ampHistory.count;
}

- (int)rootDiskPct {
    Volume *boot = [self primaryVolume];
    return boot ? (int)lround(boot.fraction * 100) : -1;
}

// A cached figure whose window has since reset says nothing about now.
static BOOL AIWindowElapsed(AIUsage *u) {
    return u.limitStale && u.resetAt && u.resetAt.timeIntervalSinceNow <= 0;
}

- (AIUsage *)lowestAIStatus {
    AIUsage *lowest = nil;
    for (AIUsage *u in _aiUsage) {
        if (!u.limitStatusAvailable || u.remainingFraction < 0 || CodexQuotaUnavailable(u)) continue;
        // A still-current figure from any tool outranks an elapsed cached one, however
        // low the elapsed one reads; among peers the least room wins.
        BOOL elapsed = AIWindowElapsed(u), lowestElapsed = lowest ? AIWindowElapsed(lowest) : YES;
        if (!lowest || (lowestElapsed && !elapsed) ||
            (elapsed == lowestElapsed && u.remainingFraction < lowest.remainingFraction))
            lowest = u;
    }
    return lowest;
}

- (NSString *)aiPercentText:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0 || CodexQuotaUnavailable(u)) return @"—";
    return [NSString stringWithFormat:@"%d%%", (int)lround(u.remainingFraction * 100)];
}

- (NSColor *)windowColor:(double)frac {
    return AIQuotaColor(frac);
}

// A cached figure older than two poll intervals is not one a refresh would reproduce:
// the number turns amber so the reader does not act on it as current.
- (BOOL)aiSnapshotStaleWarns:(AIUsage *)u {
    if (CodexQuotaUnavailable(u)) return YES;
    if (!u.limitStale || !u.limitUpdatedAt) return NO;
    return StaleSnapshotWarns(-u.limitUpdatedAt.timeIntervalSinceNow, kAccountPollInterval);
}

- (NSColor *)aiStatusColor:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return NSColor.tertiaryLabelColor;
    if ([self aiSnapshotStaleWarns:u]) return NSColor.systemOrangeColor;
    return [self windowColor:u.remainingFraction];
}

- (NSArray<NSDictionary *> *)barSegments {
    NSMutableArray *segments = [NSMutableArray array];
    NSColor *fg = NSColor.controlTextColor;
    if (_barShowDisk) {
        int pct = [self rootDiskPct];
        double frac = pct >= 0 ? pct / 100.0 : 0;
        NSColor *driveTextColor = pct >= 0 && frac >= 0.85 ? DiskColor(frac) : fg;
        Volume *boot = [self primaryVolume];
        NSString *driveSymbol = (boot && !boot.isInternal) ? @"externaldrive" : @"internaldrive";
        // The symbol stays the menu-bar foreground. Only the percent takes the warning tint.
        [segments addObject:@{@"image": BarFittedSymbol(driveSymbol, fg, 17),
                              @"text": pct >= 0 ? [NSString stringWithFormat:@"%d%%", pct] : @"—",
                              @"color": driveTextColor}];
    }
    BOOL lidAwakeShown = NO;
    // Modes are shown by SHAPE, the same glyphs as the footer buttons: the cup for Keep
    // Awake, the tortoise for Low Power (a yellow tint alone was too faint to read).
    NSImage *awakeIcon = GlyphPair(_lidAwake ? TintedSymbol(@"cup.and.saucer.fill", -1, 13, fg) : nil,
                                   LowPowerModeEnabled() ? TintedSymbol(@"tortoise.fill", -1, 13, fg) : nil);
    if (_barShowBattery) {
        NSString *text = _bat.valid ? [NSString stringWithFormat:@"%d%%", _bat.percent] : @"—";
        BOOL lowBattery = _bat.valid && _bat.percent <= 20 && !_bat.acConnected;
        NSColor *color = lowBattery ? BattBarColor(_bat.percent) : fg;
        NSMutableDictionary *seg = [@{@"text": text, @"color": color} mutableCopy];
        if (_bat.valid) {   // no battery (desktop Mac): text-only, no misleading empty glyph
            // The compact tier keeps exactly one high-value reading. Battery percentage
            // wins because macOS may have hidden its own percentage to make room for us.
            seg[@"compactPriority"] = @YES;
            // In the ordinary case the number alone is the densest useful form. Keep the
            // mode glyphs when either mode is on: that reminder outranks width.
            if (!awakeIcon) seg[@"compactTextOnly"] = @YES;
            if (awakeIcon) {
                // A mode is on: swap the battery glyph for its glyph(s) — the footer buttons'
                // icons — an always-visible reminder of settings that persist across reboots.
                // The % stays: battery drain is exactly what you watch while it's forced awake.
                seg[@"image"] = awakeIcon;
                seg[@"keepIcon"] = @YES;   // a reminder, not decoration: survives every tier
                lidAwakeShown = YES;
            } else {
                NSColor *battColor = PowerFlowColor(_bat, fg);
                NSImage *fitted = BarFittedSymbol(BatterySymbolName(_bat.percent, NO), battColor, 24);
                seg[@"image"] = BatteryGlyphWithBadge(fitted, PowerFlowFor(_bat), battColor);
            }
        }
        [segments addObject:seg];
    }
    if (_barShowSystem) {
        NSString *level = SystemPressureLevel(_sys);
        NSString *text = _sys.cpuValid ? [NSString stringWithFormat:@"%d%%", (int)lround(_sys.cpu * 100)] : @"SYS";
        [segments addObject:@{@"symbol": @"cpu", @"text": text, @"color": SystemPressureColor(level)}];
    }
    // The cup normally rides in the battery segment; if that segment is hidden or there's no
    // battery, still surface a standalone cup so an always-awake Mac never lacks its reminder.
    if (awakeIcon && !lidAwakeShown)
        [segments insertObject:@{@"image": awakeIcon,
                                 @"compactPriority": @YES, @"keepIcon": @YES} atIndex:0];
    return segments;
}

- (NSString *)barAccessibilityText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_barShowDisk) {
        int pct = [self rootDiskPct];
        [parts addObject:pct >= 0 ? [NSString stringWithFormat:@"Storage %d percent used", pct]
                                  : @"Storage scanning"];
    }
    if (_barShowBattery) {
        [parts addObject:_bat.valid ? [NSString stringWithFormat:@"Battery %d percent%@", _bat.percent,
                                        _bat.acConnected ? @", on AC" : @""]
                                    : @"No battery detected"];
    }
    if (_barShowSystem) {
        NSString *cpu = _sys.cpuValid ? [NSString stringWithFormat:@", CPU %d percent", (int)lround(_sys.cpu * 100)] : @"";
        [parts addObject:[NSString stringWithFormat:@"System pressure %@%@", SystemPressureLevel(_sys), cpu]];
    }
    if (_lidAwake) [parts insertObject:@"Keep Awake on" atIndex:0];
    if (LowPowerModeEnabled()) [parts insertObject:@"Low Power Mode" atIndex:0];
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"Status";
}

// A notched status strip grows left as far as the notch; on a notchless display it
// grows toward the fixed app menus instead. Status hosts to our left can move into
// that free space when we widen; they consume their width, not the whole gap.
// Window bounds/PIDs from CGWindowList carry no TCC gate (names would; we read none)
// and no network — consistent with the README's privacy stance.
//
// macOS 26 hosts the visible status-item window inside Control Centre, with a window
// number unrelated to the app-side NSWindow. Excluding only that number counted our
// own current width as occupied space: Full measured 114pt against its own 115pt
// image, collapsed to Compact, then expanded and repeated forever. Match the hosted
// copy by horizontal geometry and measure the live slot's leftward growth capacity.
static double BarCapacityForWindows(NSArray *list, CGRect displayBounds, double leftBoundary,
                                     BarWindowSpan own, NSInteger ownWindowNumber) {
    double rightEdge = CGRectGetMaxX(displayBounds);
    double menuBarY = CGRectGetMinY(displayBounds);
    double fixedBoundary = leftBoundary;
    CGWindowLevel statusLevel = CGWindowLevelForKey(kCGStatusWindowLevelKey);
    if (![list isKindOfClass:NSArray.class] || list.count == 0) return -1;
    NSMutableData *spanData = [NSMutableData dataWithLength:list.count * sizeof(BarWindowSpan)];
    BarWindowSpan *spans = spanData.mutableBytes;
    size_t spanCount = 0;
    for (NSDictionary *w in list) {
        NSNumber *num = w[(__bridge NSString *)kCGWindowNumber];
        if (num.integerValue == ownWindowNumber) continue;   // our own occupancy is ours to spend
        CGRect b = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)w[(__bridge NSString *)kCGWindowBounds], &b)) continue;
        // The item's own display's menu-bar band. Quartz coordinates put each
        // display's top at CGDisplayBounds.minY, including vertically arranged screens.
        if (fabs(b.origin.y - menuBarY) > 1 || b.size.height > 40) continue;
        // Degenerate 1-px windows (several apps park them at the screen origin) are
        // not status items and do not occupy bar space.
        if (b.size.width < 8 || b.size.height <= 0) continue;
        if (CGRectGetMaxX(b) <= leftBoundary || b.origin.x >= rightEdge) continue;
        NSNumber *layer = w[(__bridge NSString *)kCGWindowLayer];
        if (![layer isKindOfClass:NSNumber.class]) return -1;
        if (layer.integerValue != statusLevel) {
            // A full-display backdrop is not occupied app-menu space. Other windows
            // on our left are fixed, including menus newly intruding into our frame.
            BOOL backdrop = CGRectGetMinX(b) <= CGRectGetMinX(displayBounds) + 1 &&
                            CGRectGetMaxX(b) >= rightEdge - 1;
            if (!backdrop && CGRectGetMinX(b) < own.x)
                fixedBoundary = MAX(fixedBoundary, CGRectGetMaxX(b));
            continue;
        }
        spans[spanCount++] = (BarWindowSpan){b.origin.x, b.size.width};
    }
    // A fixed menu crossing own.x is known crowding, not stale display geometry.
    // Measure the pooled region up to our left edge, then impose the fixed squeeze.
    double boundary = MAX(leftBoundary, MIN(fixedBoundary, own.x));
    double capacity = BarCapacityFromWindowSpans(boundary, rightEdge, own, spans, spanCount);
    return capacity < 0 ? capacity : MIN(capacity, MAX(0.0, own.x + own.width - fixedBoundary));
}

static NSArray<NSString *> *BarRenderedSegmentStrings(NSArray<NSDictionary *> *segments) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        id text = seg[@"text"];
        [texts addObject:[text isKindOfClass:NSString.class] ? text : @""];
    }
    return texts;
}

// Displays, the notch, and our own frame — the geometry MeasuredBarCapacity reads
// besides the window list. The list itself is what the 60s bound rechecks.
static NSString *BarScreenConfigurationKey(NSStatusItem *item) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSRect frame = screen.frame;
        NSRect aux = screen.auxiliaryTopRightArea;
        id number = screen.deviceDescription[@"NSScreenNumber"] ?: @"?";
        [parts addObject:[NSString stringWithFormat:@"%@ %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f",
                          number,
                          frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                          aux.origin.x, aux.origin.y, aux.size.width, aux.size.height]];
    }
    NSWindow *win = item.button.window;
    NSRect itemFrame = win.frame;
    id own = win.screen.deviceDescription[@"NSScreenNumber"] ?: @"-";
    [parts addObject:[NSString stringWithFormat:@"own %@ item %.1f %.1f %.1f %.1f",
                      own, itemFrame.origin.x, itemFrame.origin.y,
                      itemFrame.size.width, itemFrame.size.height]];
    return parts.count ? [parts componentsJoinedByString:@"|"] : nil;
}

static double MeasuredBarCapacity(NSStatusItem *item) {
    NSWindow *win = item.button.window;
    NSScreen *screen = win.screen ?: NSScreen.screens.firstObject;
    if (!screen || !win) return -1;
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (![screenNumber isKindOfClass:NSNumber.class]) return -1;
    CGRect displayBounds = CGDisplayBounds((CGDirectDisplayID)screenNumber.unsignedIntValue);
    if (CGRectIsEmpty(displayBounds)) return -1;
    NSRect aux = screen.auxiliaryTopRightArea;
    double leftBoundary = NSWidth(aux) > 0 ? NSMinX(aux) : CGRectGetMinX(displayBounds);
    NSArray *list = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    BarWindowSpan own = {NSMinX(win.frame), NSWidth(win.frame)};
    return BarCapacityForWindows(list, displayBounds, leftBoundary, own, win.windowNumber);
}

// Is the item sitting in the menu bar right now? Stated positively, because the
// interesting question at launch is "has it ever been in the bar", not "is it
// missing" — a window that exists but has not yet been ordered in looks identical
// to an evicted one, and treating that as eviction forced the glyph tier on every
// launch (observed live 2026-08-12: `evicted=1 tier 0→2` against a roomy 160pt gap).
// Worse, on a Mac with no notch the gap is never measurable, so that false eviction
// latched the glyph permanently. The caller therefore only trusts a NO from this
// once it has seen a YES. Judged by position: display sleep occludes every window
// without moving it, so occlusion must not read as eviction. Measured against the
// window's OWN screen — with several displays the item follows the active menu bar,
// and comparing it to the primary's top edge would false-positive forever.
// Whether the bar can be observed at all right now. With the lid closed and the panel
// dark, CGWindowList reports none of this process's own windows — identical to having
// been evicted — and no tier decision can be right or even matter, because nobody is
// looking. Judge the display the item actually lives on, so a clamshell Mac driving an
// external screen still measures normally.
static BOOL BarDisplayObservable(NSStatusItem *item) {
    NSScreen *screen = item.button.window.screen ?: NSScreen.mainScreen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (![number isKindOfClass:NSNumber.class]) return NO;
    CGDirectDisplayID display = (CGDirectDisplayID)number.unsignedIntValue;
    return CGDisplayIsActive(display) && !CGDisplayIsAsleep(display);
}

static BOOL BarItemOnBar(NSStatusItem *item) {
    NSWindow *win = item.button.window;
    NSScreen *screen = win.screen ?: NSScreen.screens.firstObject;
    if (!win || !screen) return NO;
    return win.isVisible && NSMaxY(win.frame) >= NSMaxY(screen.frame) - 40;
}

- (NSArray<NSDictionary *> *)barSegmentsForTier:(int)tier full:(NSArray<NSDictionary *> *)full {
    if (tier == BarTierFull) return full;
    if (tier == BarTierText) {
        // Give up the meter icons before giving up any reading: the numbers are what the
        // item is for, and dropping the icons buys roughly a third of the width. A
        // segment with no text of its own (the standalone Keep Awake cup) keeps its icon,
        // and so does any segment that asked to (`keepIcon`) — the cup is a reminder
        // about a setting that persists across reboots, not decoration.
        NSMutableArray *text = [NSMutableArray array];
        for (NSDictionary *seg in full) {
            NSString *label = [seg[@"text"] isKindOfClass:NSString.class] ? seg[@"text"] : nil;
            BOOL keepIcon = [seg[@"keepIcon"] boolValue] || !label.length;
            if (!label.length && !keepIcon) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            if (!keepIcon) {
                [d removeObjectForKey:@"image"];
                [d removeObjectForKey:@"symbol"];
                [d removeObjectForKey:@"var"];
            }
            [d removeObjectForKey:@"compactPriority"];
            [d removeObjectForKey:@"compactTextOnly"];
            [d removeObjectForKey:@"keepIcon"];
            [text addObject:d];
        }
        if (text.count) return text;
    }
    if (tier == BarTierCompact) {
        // Preserve one deliberately prioritised reading before falling all the way to
        // pictograms. On a MacBook that is battery percentage: it is more actionable
        // than two unlabeled meters and remains useful even in a crowded menu bar.
        NSMutableArray *priority = [NSMutableArray array];
        for (NSDictionary *seg in full) {
            if (![seg[@"compactPriority"] boolValue]) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            if ([d[@"compactTextOnly"] boolValue]) {
                [d removeObjectForKey:@"image"];
                [d removeObjectForKey:@"symbol"];
                [d removeObjectForKey:@"var"];
            }
            [d removeObjectForKey:@"compactPriority"];
            [d removeObjectForKey:@"compactTextOnly"];
            [priority addObject:d];
            break;   // compact mode has one job: preserve the highest-priority reading
        }
        if (priority.count) return priority;

        // No reading opted into compact mode (for example, battery is disabled): keep
        // the old icons-only fallback so another configured metric still survives.
        // A text-only segment (a batteryless Mac renders battery as a bare "—") has
        // nothing left once the text goes: it would contribute an invisible segment
        // that still eats an inter-segment gap, and in the worst case — battery the
        // only segment — leave a 4pt blank item, which is precisely the disappearance
        // this feature exists to prevent. Drop those, and fall back to the glyph if
        // dropping them empties the tier, so tier widths stay non-increasing.
        NSMutableArray *icons = [NSMutableArray arrayWithCapacity:full.count];
        for (NSDictionary *seg in full) {
            if (!seg[@"image"] && !seg[@"symbol"]) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            [d removeObjectForKey:@"text"];
            [icons addObject:d];
        }
        if (icons.count) return icons;
    }
    // Glyph tier: identity mark — except the Keep Awake cup takes over, so that
    // always-visible reminder survives every tier at zero extra width.
    if (_lidAwake || LowPowerModeEnabled())
        return @[@{@"image": TintedSymbol(_lidAwake ? @"cup.and.saucer.fill" : @"tortoise.fill", -1, 13,
                                          NSColor.controlTextColor)}];
    return @[@{@"symbol": @"gauge.with.dots.needle.50percent"}];
}

- (void)updateBar {
    // The bar is drawn into a detached, non-template NSImage, so dynamic colors like
    // controlTextColor resolve against whatever drawing appearance is current. Left to
    // default that's the *app's* appearance, which can be Light while the menu bar is
    // dark (e.g. a dark wallpaper in Light mode) — baking black text onto a dark bar.
    // Draw under the button's own menu-bar appearance instead so the neutral fg and the
    // alert colors all resolve to the shade the menu bar actually uses. barSegments
    // builds the meter icons eagerly (each lockFocuses), so it must run inside the block.
    [_item.button.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *fg = NSColor.controlTextColor;
        NSArray<NSDictionary *> *full = [self barSegments];
        NSArray<NSDictionary *> *tierSegs[kBarTierCount] = {
            full,
            [self barSegmentsForTier:BarTierText full:full],
            [self barSegmentsForTier:BarTierCompact full:full],
            [self barSegmentsForTier:BarTierGlyph full:full],
        };
        double widths[kBarTierCount]; NSArray<NSDictionary *> *draws[kBarTierCount];
        for (int t = 0; t < kBarTierCount; t++) {
            CGFloat w = 0;
            draws[t] = BarLayout(tierSegs[t], fg, &w);
            widths[t] = w;
        }
        // Only a fall FROM the bar is eviction. Before the item has ever been in the
        // bar there is nothing to have been evicted from, so the safety net stays
        // disarmed — otherwise every launch can start at the glyph tier before Control
        // Centre has placed the host window we need for a real capacity measurement.
        // A sleeping display makes every input to this decision untrustworthy, so make
        // no decision: hold the tier and re-measure when the display returns.
        BOOL observable = BarDisplayObservable(self->_item);
        BOOL onBar = observable && BarItemOnBar(self->_item);
        // Before the hosted item is actually on-bar, its app-side frame is not a valid
        // self-exclusion key. Hold the current tier until Control Centre places it.
        // The window list is the expensive read. Skip it while the strings we draw and
        // the screen geometry are the ones we last measured, and never for longer than
        // a minute — neighbours move without changing either.
        double capacity = -1;
        if (onBar) {
            NSString *key = BarCapacityCacheKey(BarRenderedSegmentStrings(full),
                                                BarScreenConfigurationKey(self->_item));
            double now = CFAbsoluteTimeGetCurrent();
            double age = self->_barCapacityMeasuredAt > 0 ? now - self->_barCapacityMeasuredAt
                                                          : kBarCapacityMaxAgeSec;
            if (BarCapacityMeasurementFresh(self->_barCapacityKey, key, age, kBarCapacityMaxAgeSec)) {
                capacity = self->_barCapacityCached;
            } else {
                capacity = MeasuredBarCapacity(self->_item);
                if (key && capacity >= 0) {
                    self->_barCapacityKey = key;
                    self->_barCapacityCached = capacity;
                    self->_barCapacityMeasuredAt = now;
                }
            }
        }
        // The status-item host is wider than its image (16pt on the live Tahoe shell).
        // Price that chrome into every candidate tier or a 115pt image can be judged to
        // fit in 130pt even though its real 131pt host will be evicted. Derive it from
        // the currently installed image, not _barTier: Control Centre resizes the host
        // asynchronously after a tier change, so those two can briefly disagree.
        NSImage *installedImage = self->_item.button.image;
        double hostFrameWidth = NSWidth(self->_item.button.window.frame);
        // After a tier swap the host keeps its OLD width until Control Centre resizes it;
        // measuring chrome against that frame credits the whole width difference to
        // chrome (24pt for battery-only Full→Compact). Wait for the frame to move.
        if (self->_barSwapPending && fabs(hostFrameWidth - self->_barFrameBeforeSwap) > 0.5)
            self->_barSwapPending = NO;
        if (onBar && installedImage && !self->_barSwapPending) {
            double chrome = hostFrameWidth - installedImage.size.width;
            if (isfinite(chrome) && chrome >= 0 && chrome <= 24) {
                self->_barChromeWidth = chrome;
                self->_barChromeKnown = YES;
            }
        }
        double occupiedWidths[kBarTierCount];
        double chrome = self->_barChromeKnown ? self->_barChromeWidth : 0;
        for (int t = 0; t < kBarTierCount; t++) occupiedWidths[t] = widths[t] + chrome;
        if (onBar) self->_barWasOnBar = YES;
        BOOL evicted = BarEvictionSuspected(observable, self->_barWasOnBar, onBar,
                                            CFAbsoluteTimeGetCurrent() - self->_barCreatedAt);
        // The grace counts time the bar was actually observable: a Mac that spent the
        // first minute of its session with the lid shut has not yet had a chance to be
        // placed, and must not be judged as though it had.
        if (!observable) self->_barCreatedAt = CFAbsoluteTimeGetCurrent();
        BarTierState chosen = ChooseBarTier(self->_barTier, capacity, occupiedWidths, evicted,
                                            CFAbsoluteTimeGetCurrent());
        if (getenv("GLANCEBAR_BAR_DEBUG"))
            NSLog(@"bar: capacity=%.0f image=[%.0f %.0f %.0f %.0f] occupied=[%.0f %.0f %.0f %.0f] chrome=%.0f onBar=%d evicted=%d tier %d→%d streak=%d host=[%.0f %.0f]",
                  capacity, widths[0], widths[1], widths[2], widths[3],
                  occupiedWidths[0], occupiedWidths[1], occupiedWidths[2], occupiedWidths[3], chrome,
                  observable ? onBar : -1, evicted,
                  self->_barTier.tier, chosen.tier, chosen.expandStreak,
                  NSMinX(self->_item.button.window.frame), hostFrameWidth);
        self->_barTier = chosen;
        NSImage *next = BarImageFromLayout(draws[chosen.tier], widths[chosen.tier]);
        if (installedImage && fabs(next.size.width - installedImage.size.width) > 0.5) {
            self->_barSwapPending = YES;
            self->_barFrameBeforeSwap = hostFrameWidth;
        }
        self->_item.button.image = next;
    }];
    NSString *summary = [self barAccessibilityText];
    _item.button.accessibilityHelp = [@"Glancebar — " stringByAppendingString:summary];
    [_item.button setAccessibilityLabel:@"Glancebar"];
    [_item.button setAccessibilityValue:summary];
    [_item.button setAccessibilityHelp:@"Open Glancebar status and details"];
}

// SleepDisabled is read through a `pmset -g` subprocess, so — like the AI usage read — it
// must stay off the main thread (refresh fires every 15s and on IOPS bursts). Single-flight:
// a tick arriving mid-read is skipped. Only redraws the bar when the cached value changes.
- (void)refreshLidAwakeAsync { [self refreshLidAwakeForced:NO]; }
// Polled once a minute (other tools can flip the setting); forced right after our own
// toggle, through pmset itself, so the cup follows the change without waiting.
- (void)refreshLidAwakeForced:(BOOL)force {
    if (_lidAwakeReading) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (!force && _lidAwakeLastRead > 0 && now - _lidAwakeLastRead < 60) return;
    _lidAwakeReading = YES;
    _lidAwakeLastRead = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *state = force ? SleepDisabledStateViaTool() : SleepDisabledState();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lidAwakeReading = NO;
            if (!state) return;   // unknown: keep the last known reading
            BOOL awake = state.boolValue;
            if (awake != self->_lidAwake) { self->_lidAwake = awake; [self syncPowerButtons]; [self updateBar]; }
        });
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == kBarAppearanceContext) {
        [self updateBar];   // redraw in the new menu-bar appearance
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// Redraw whatever on-screen surfaces are currently visible.
- (void)refreshVisibleSurfaces {
    if (_popover.isShown) [self rebuildContent];
    else if (_popover && !_popoverPreparePending) {
        _popoverPreparePending=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            self->_popoverPreparePending=NO;
            if(!self->_terminating && !self->_popover.isShown)[self rebuildContent];
        });
    }
    if (_detailsWindow.isVisible) [self rebuildDetails];
}

- (NSDictionary *)focusSnapshotForWindow:(NSWindow *)window rootView:(NSView *)root {
    if (!window || !root) return @{};
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    id focused = window.accessibilityFocusedUIElement;
    NSView *focusedView = ViewOwningAccessibilityElement(root, focused);
    if (!focusedView && [focused respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *identifier = [focused accessibilityIdentifier];
        if (identifier.length) snapshot[@"accessibility"] = identifier;
    }
    if (focusedView) {
        if (focusedView.accessibilityIdentifier.length)
            snapshot[@"accessibility"] = focusedView.accessibilityIdentifier;
        NSArray<NSNumber *> *path = SubviewPathToView(root, focusedView);
        if (path) snapshot[@"accessibilityPath"] = path;
    }
    NSResponder *responder = window.firstResponder;
    NSView *keyboardView = nil;
    BOOL hasFieldEditor = [responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isFieldEditor;
    if (hasFieldEditor) {
        id delegate = ((NSTextView *)responder).delegate;
        if ([delegate isKindOfClass:NSView.class]) keyboardView = delegate;
        else keyboardView = ViewOwningAccessibilityElement(root, delegate);
        snapshot[@"selection"] = [NSValue valueWithRange:((NSTextView *)responder).selectedRange];
    }
    for (NSUInteger depth = 0; responder && depth < 8; depth++, responder = responder.nextResponder) {
        if (!keyboardView && [responder isKindOfClass:NSView.class] &&
            !(hasFieldEditor && depth == 0)) keyboardView = (NSView *)responder;
        if (keyboardView) break;
    }
    if (keyboardView) {
        if (keyboardView.accessibilityIdentifier.length)
            snapshot[@"keyboard"] = keyboardView.accessibilityIdentifier;
        NSArray<NSNumber *> *path = SubviewPathToView(root, keyboardView);
        if (path) snapshot[@"keyboardPath"] = path;
    }
    return snapshot;
}

- (void)restoreFocus:(NSDictionary *)snapshot
             inView:(NSView *)root window:(NSWindow *)window {
    if (!snapshot.count || !root || !window) return;
    NSView *accessibilityView = ViewWithAccessibilityIdentifier(root, snapshot[@"accessibility"]);
    if (!accessibilityView && [snapshot[@"accessibilityPath"] isKindOfClass:NSArray.class])
        accessibilityView = ViewAtSubviewPath(root, snapshot[@"accessibilityPath"]);
    if (accessibilityView) accessibilityView.accessibilityFocused = YES;
    NSView *keyboardView = ViewWithAccessibilityIdentifier(root, snapshot[@"keyboard"]);
    if (!keyboardView && [snapshot[@"keyboardPath"] isKindOfClass:NSArray.class])
        keyboardView = ViewAtSubviewPath(root, snapshot[@"keyboardPath"]);
    if (keyboardView) {
        [window makeFirstResponder:keyboardView];
        NSValue *selection = [snapshot[@"selection"] isKindOfClass:NSValue.class] ? snapshot[@"selection"] : nil;
        NSText *editor = selection ? [window fieldEditor:NO forObject:keyboardView] : nil;
        if ([editor isKindOfClass:NSTextView.class]) {
            NSRange range = selection.rangeValue;
            range.location = MIN(range.location, ((NSTextView *)editor).string.length);
            range.length = MIN(range.length, ((NSTextView *)editor).string.length - range.location);
            ((NSTextView *)editor).selectedRange = range;
        }
    }
}

#pragma mark popover

// F3 opens Glancebar. On Apple keyboards F3 is the Mission Control key: it sends a HID usage
// (consumer 0x29F, or Apple vendor 0xFF01/0x10 on older keyboards) that macOS acts on before
// any app sees a key, so Glancebar remaps it to F13 with hidutil (re-applied each launch,
// since the mapping lasts until restart; never over someone's own mapping) and registers
// F13, plus plain F3 for fn-F3, as global hot keys. No Accessibility permission. Opt-in:
// popoverHotKey.
static NSString *const kMissionControlToF13 =
    @"{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":0xC0000029F,\"HIDKeyboardModifierMappingDst\":0x700000068},"
     "{\"HIDKeyboardModifierMappingSrc\":0xFF0100000010,\"HIDKeyboardModifierMappingDst\":0x700000068}]}";
static void RemapMissionControlKey(void) {
    NSString *current = RunTaskOutput(@"/usr/bin/hidutil", @[@"property", @"--get", @"UserKeyMapping"]) ?: @"";
    BOOL ours = [current containsString:@"0x700000068"] || [current containsString:@"30064771176"];
    BOOL others = !ours && ([current containsString:@"HIDKeyboardModifierMappingSrc"]);
    if (ours || others) return;
    RunTaskOutput(@"/usr/bin/hidutil", @[@"property", @"--set", kMissionControlToF13]);
}
static OSStatus GBPopoverHotKeyPressed(EventHandlerCallRef next, EventRef event, void *client) {
    (void)next; (void)event;
    Controller *controller = (__bridge Controller *)client;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller togglePopover:nil]; });
    return noErr;
}
- (void)registerPopoverHotKeys {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"popoverHotKey"]) return;
    static BOOL installed;
    if (installed) return;
    installed = YES;
    EventTypeSpec pressed = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&GBPopoverHotKeyPressed, 1, &pressed, (__bridge void *)self, NULL);
    RemapMissionControlKey();
    UInt32 codes[] = {kVK_F13, kVK_F3, 160};
    for (UInt32 i = 0; i < 3; i++) {
        EventHotKeyRef ref = NULL;
        EventHotKeyID hid = {'GBar', i + 1};
        OSStatus status = RegisterEventHotKey(codes[i], 0, hid, GetApplicationEventTarget(), 0, &ref);
        os_log(OS_LOG_DEFAULT, "Glancebar hot key %u: %d", (unsigned)codes[i], (int)status);
    }
}
- (void)focusFleetRows {
    NSView *root = _popover.contentViewController.view;
    NSView *divider = ViewWithAccessibilityIdentifier(root, @"popover.divider.remote");
    if (divider && _popoverScroll) {
        _fleetFocusPending = NO;
        CGFloat y = [divider convertRect:divider.bounds toView:_popoverScroll.documentView].origin.y;
        CGFloat maximum = MAX(0, NSHeight(_popoverScroll.documentView.bounds) - NSHeight(_popoverScroll.contentView.bounds));
        [_popoverScroll.contentView scrollToPoint:NSMakePoint(0, MIN(y, maximum))];
        [_popoverScroll reflectScrolledClipView:_popoverScroll.contentView];
    }
}
- (void)showPopoverRequested:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPopoverRequested:notification]; });
        return;
    }
    if (_terminating || !_popover) return;
    NSString *destination = notification.userInfo[@"destination"] ?: @"popover";
    if ([destination isEqual:@"battery"]) { [self showBatteryDetails:nil]; return; }
    if ([destination isEqual:@"ai"]) { [self showDetailsTab:@"ai" sender:nil]; return; }
    if ([destination isEqual:@"fleet"]) {
        _fleetFocusPending = YES;
        _fleetExpandedHosts = [NSMutableSet set];
        for (NSDictionary *machine in [self remoteMachines]) [_fleetExpandedHosts addObject:machine[@"host"]];
        [self rebuildContent];
        if (!_popover.isShown) [self togglePopover:nil];
        [self pollRemoteMachinesIfDue]; // existing in-flight and 25-second throttle
        [self focusFleetRows];
        _fleetFocusPending = _remoteInFlight.count > 0; // one final focus after this bounded poll settles
        return;
    }
    if (![destination isEqual:@"popover"]) return;
    // A Touch Bar tap means show, never toggle shut on a repeated request.
    if (!_popover.isShown) [self togglePopover:nil];
}
- (void)togglePopover:(id)sender {
    if (_popover.isShown) {
        [self cancelPreloadHover];
        [self discardPreparedPlaylist];
        [_popover close];
        return;
    }
    // A transient popover dismisses on the mouse-DOWN of an outside click — and a click on
    // our own status-item button counts as "outside". The button's action then fires on
    // mouse-UP; without this guard it sees isShown==NO and reopens, so a second icon click
    // never closes the panel the way a menu would. Suppress the reopen for a frame or two
    // after any close so the icon toggles cleanly. (sender is nil for programmatic opens.)
    if (sender && CFAbsoluteTimeGetCurrent() - _popoverClosedAt < 0.20) return;
    // The prepared tree is refreshed while hidden. Nothing reads telemetry or
    // walks the filesystem between this click and the presentation request.
    if (!_popoverPrepared) [self rebuildContent];
    if (_popoverScroll) {
        [_popoverScroll.contentView scrollToPoint:NSZeroPoint];
        [_popoverScroll reflectScrolledClipView:_popoverScroll.contentView];
    }
    [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSMaxYEdge];
    if (_mixPlayingKey.length) [self preparePlaylistFirstItem:_mixPlayingKey];
    else if (_mixSeeds.firstObject[@"key"]) [self preparePlaylistFirstItem:_mixSeeds.firstObject[@"key"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(!self->_popover.isShown || self->_terminating)return;
        [self refresh];
        if(self->_musicProbesEnabled && !self->_musicOff){[self yieldLocalMusicIfIdle];}
        [self beginSampling];[self startPowerTick];
    });
    // When the panel is taller than the screen allows it scrolls, and an overlay scroller
    // stays invisible until something scrolls it — so the sections below the fold (AI
    // Status is the last one) look like they do not exist. Flash it on open only: the
    // periodic rebuild would otherwise flash it every 15 seconds.
    [_popoverScroll flashScrollers];
    // Accessory (LSUIElement) apps don't activate on their own, so the popover's window
    // never becomes key — and a transient popover with no key window to resign is never
    // dismissed when the user clicks another app. Activate on open so a click elsewhere
    // (and the key-window resign it triggers) closes the panel like a normal menu.
    [NSApp activateIgnoringOtherApps:YES];
}

// Power changes (charger plugged, load spikes, AlDente letting go) post no IOPS event, so
// the 15s refresh showed stale watts. While the popover or Details is open, re-read the
// battery every second — an IORegistry read, no subprocess — and update the readings in
// place; a change of state (plugged, charging, percent) rebuilds the panel.
- (void)startPowerTick {
    if (_powerTickTimer) return;
    _powerTickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(powerTick:)
                                                     userInfo:nil repeats:YES];
    _powerTickTimer.tolerance = 0.2;
}
- (void)stopPowerTick {
    [_powerTickTimer invalidate];
    _powerTickTimer = nil;
}
- (void)powerTick:(NSTimer *)timer {
    (void)timer;
    BOOL popover = _popover.isShown, details = _detailsWindow.isVisible;
    if (!popover && !details) { [self stopPowerTick]; return; }
    BatteryState fresh = ReadBattery();
    if (!fresh.valid) { _bat = fresh; [self batteryForecast]; [self refreshVisibleSurfaces]; return; }
    BOOL stateChanged = fresh.acConnected != _bat.acConnected || fresh.isCharging != _bat.isCharging ||
                        fresh.percent != _bat.percent || ChargerFallsShort(fresh) != _chargerRowShown;
    BOOL powerChanged = fresh.amperage_mA != _bat.amperage_mA || fresh.systemLoad_mW != _bat.systemLoad_mW ||
                        fresh.systemPowerIn_mW != _bat.systemPowerIn_mW;
    BOOL wasOnAC = _bat.acConnected;
    _bat = fresh;
    [self batteryForecast];
    _powerTicks++;
    [self noteEnergyBaseline:wasOnAC];
    if ([self burnActive] && _powerTicks % 2 == 0 && ![self activityTabSelected]) [self sampleBurnAsync];
    if (stateChanged) {
        if (popover) [self rebuildContent];
        if (details) [self rebuildDetails];
        [self updateBar];
        return;
    }
    if (popover) {
        NSView *root = _popover.contentViewController.view;
        BatteryForecastView *forecast = (BatteryForecastView *)ViewWithAccessibilityIdentifier(root, @"popover.battery.forecast");
        if ([forecast isKindOfClass:BatteryForecastView.class]) [self configureBatteryForecast:forecast];
        NSString *tip = [self batteryPopoverTip];
        for (NSString *key in @[@"popover.row.battery", @"popover.battery.gauge", @"popover.battery.value", @"popover.battery.trend", @"popover.battery.datum"]) {
            NSView *view = ViewWithAccessibilityIdentifier(root, key); view.accessibilityHelp = tip;
        }
    }
    if (!powerChanged) { if (details && _powerTicks % 2 == 0) [self rebuildDetails]; return; }
    [self updateBar];   // the bar glyph's shade follows the watts
    if (popover) {
        NSView *root = _popover.contentViewController.view;
        NSTextField *datum = (NSTextField *)ViewWithAccessibilityIdentifier(root, @"popover.battery.datum");
        TrendArrow *arrow = (TrendArrow *)ViewWithAccessibilityIdentifier(root, @"popover.battery.trend");
        NSView *chargeBar = ViewWithAccessibilityIdentifier(root, @"popover.battery.gauge");
        NSView *chargerRow = ViewWithAccessibilityIdentifier(root, @"popover.row.charger");
        if (chargerRow) [self configureChargerRow:chargerRow];
        if ([datum isKindOfClass:NSTextField.class]) {
            datum.stringValue = [self batteryRateText];
            datum.textColor = [self batteryRateColor];
            if ([arrow isKindOfClass:TrendArrow.class] && chargeBar) [self configureTrend:arrow over:chargeBar];
            NSButton *glyph = (NSButton *)ViewWithAccessibilityIdentifier(root, @"popover.battery.symbol");
            if ([glyph isKindOfClass:NSButton.class]) {
                NSImage *batteryImage = [self liveBatteryGlyph];
                if (batteryImage) glyph.image = batteryImage;
                glyph.contentTintColor = batteryImage.template ? PowerFlowColor(_bat, NSColor.labelColor) : nil;
            }
            NSString *tip = [self batteryPopoverTip];
            datum.accessibilityHelp = tip;
            NSView *row = ViewWithAccessibilityIdentifier(root, @"popover.row.battery");
            row.accessibilityHelp = tip; row.accessibilityLabel = tip;
        }
    }
    // Details rows are rebuilt wholesale; every other second is live enough there.
    if (details && _powerTicks % 2 == 0) [self rebuildDetails];
}

// Records when the popover last closed so togglePopover: can tell a real "open me" click
// apart from the mouse-UP that trails a transient dismiss. Fires on every close path —
// outside click, second icon click, or Escape — which is exactly the set we want to guard.
- (void)popoverWillClose:(NSNotification *)note {
    _fleetExpandedHosts = nil;
    _fleetFocusPending = NO;
    _popoverPrepared = NO;
    _burnLatch = 0;
    [GBSeedTile closeLarge];
    (void)note;
    _popoverClosedAt = CFAbsoluteTimeGetCurrent();
    [self stopTrackTick];
    if (!_detailsWindow.isVisible) [self stopPowerTick];
}

// Unplugging takes one energy snapshot so "since unplug" has a starting point; plugging
// in drops it. Launching on battery starts the count from launch instead.
// Burn attribution runs whenever the battery is carrying load: on battery, or behind a
// charger that falls short of the Mac's draw.
- (BOOL)burnActive {
    return _bat.valid && (!_bat.acConnected || ChargerFallsShort(_bat));
}

- (void)noteEnergyBaseline:(BOOL)wasOnAC {
    if (!_bat.valid) return;
    if (![self burnActive]) {
        _energyBaseline = nil; _energyPrev = nil; _energyBaselineAt = nil; _burnRows = nil;
        [_burnGroupCache removeAllObjects];
        return;
    }
    if (_energyBaseline || _energySampling) return;
    _energySampling = YES;
    _energyBaselineAtUnplug = wasOnAC;
    _energyBaselineWh = BatteryWattHours(_bat.rawCurrent_mAh, _bat.voltage_mV);
    NSDate *at = NSDate.date;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *snap = SnapshotProcessEnergy();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_energySampling = NO;
            if (![self burnActive]) return;   // charging properly again meanwhile
            self->_energyBaseline = snap;
            self->_energyBaselineAt = at;
        });
    });
}

// The Mac's whole draw while the battery carries load: Apple's system-load telemetry,
// else the discharge.
- (double)burnDrawWatts {
    if (![self burnActive]) return -1;
    if (_bat.systemLoad_mW > 0 && _bat.systemLoad_mW != LONG_MIN) return _bat.systemLoad_mW / 1000.0;
    double bw = BatteryWatts(_bat);
    return !isnan(bw) && bw < 0 ? -bw : -1;
}

// Battery Wh used since the baseline, from the battery's own charge.
- (double)burnSinceBaselineWh {
    if (!_energyBaselineAt || isnan(_energyBaselineWh)) return -1;
    double now = BatteryWattHours(_bat.rawCurrent_mAh, _bat.voltage_mV);
    return isnan(now) ? -1 : MAX(0, _energyBaselineWh - now);
}

// One live energy sample (panel open, on battery). The first only seeds the delta.
- (void)sampleBurnAsync {
    if (![self burnActive] || _energySampling) return;
    _energySampling = YES;
    NSDictionary *prev = _energyPrev, *baseline = _energyBaseline;
    CFAbsoluteTime prevAt = _energyPrevAt;
    if (!_burnGroupCache) _burnGroupCache = [NSMutableDictionary dictionary];
    NSMutableDictionary *cache = _burnGroupCache;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *cur = SnapshotProcessEnergy();
        CFAbsoluteTime at = CFAbsoluteTimeGetCurrent();
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        @synchronized (cache) { [names addEntriesFromDictionary:cache]; }
        NSString *(^group)(pid_t) = ^NSString *(pid_t pid) {
            NSString *name = names[@(pid)];
            if (!name) { name = AppGroupForPid(pid) ?: @""; names[@(pid)] = name; }
            return name;
        };
        NSArray *rows = BurnRows(prev, cur, baseline, prev ? at - prevAt : 0, group);
        // Root daemons (a backup running with its app closed) hide their energy: estimate them.
        if (prev) rows = BurnRowsWithUnreadable(rows, ProcessCPUByPid(), [NSSet setWithArray:cur.allKeys], group);
        @synchronized (cache) { [cache addEntriesFromDictionary:names]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_energySampling = NO;
            if (![self burnActive]) return;
            self->_energyPrev = cur;
            self->_energyPrevAt = at;
            if (prev) { self->_burnRows = rows; [self refreshVisibleSurfaces]; }
        });
    });
}

// Starts both process samplers, invalidating any still-in-flight results: top takes
// >1s, so a close/reopen can otherwise interleave an old sample over a newer one.
- (void)beginSampling {
    // A stale previous sample would average over the time the panel was closed.
    if (CFAbsoluteTimeGetCurrent() - _energyPrevAt > 5) { _energyPrev = nil; _burnRows = nil; }
    [self sampleBurnAsync];
    _sampleGen++;
    _lastSampleTime = CFAbsoluteTimeGetCurrent();
    [self sampleHogsAsync];
    [self sampleProcessStatsAsync];
}

- (void)sampleHogsAsync {
    NSUInteger gen = _sampleGen;
    _hogs = @[];
    _hogsLoading = YES;
    _hogsUnavailable = NO;
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *hogs = SampleHogs(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_sampleGen) return;   // superseded by a newer sampling pass
            self->_hogs = hogs ? hogs : @[];
            self->_hogsLoading = NO;
            self->_hogsUnavailable = self->_hogs.count == 0;
            [self refreshVisibleSurfaces];
        });
    });
}

- (void)sampleProcessStatsAsync {
    NSUInteger gen = _sampleGen;
    _topCPU = @[];
    _topMem = @[];
    _procStatsLoading = YES;
    _procStatsUnavailable = NO;
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *stats = SampleProcessStats(5);
        NSArray *cpu = stats[@"cpu"] ? stats[@"cpu"] : @[];
        NSArray *memory = stats[@"memory"] ? stats[@"memory"] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_sampleGen) return;   // superseded by a newer sampling pass
            self->_topCPU = cpu;
            self->_topMem = memory;
            self->_procStatsLoading = NO;
            self->_procStatsUnavailable = cpu.count == 0 && memory.count == 0;
            [self refreshVisibleSurfaces];
        });
    });
}

// --- layout helpers ---
- (NSTextField *)text:(NSString *)s font:(NSFont *)f color:(NSColor *)c at:(NSRect)fr align:(NSTextAlignment)a {
    NSTextField *t = [GBRecoverableTextField labelWithString:s ?: @""];
    t.font = f; if (c) t.textColor = c; t.alignment = a; t.frame = fr;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}
- (NSView *)sectionHeader:(NSString *)title at:(CGFloat)y {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 16)];
    NSTextField *heading = [self text:title.uppercaseString
                                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                                 color:NSColor.tertiaryLabelColor
                                    at:NSMakeRect(kPad, 0, kW-2*kPad, 14)
                                 align:NSTextAlignmentLeft];
    ApplyHeadingAccessibility(heading, title);
    heading.accessibilityIdentifier = [@"popover.heading." stringByAppendingString:title.lowercaseString];
    [v addSubview:heading];
    return v;
}
// Icon and a short label, side by side. The pill fill is the on/off state. Push-on/push-off
// so VoiceOver reports a toggle. The glyph matches the menu bar.
- (NSButton *)powerToggle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    PillButton *b = [PillButton buttonWithTitle:title target:self action:action];
    [b setButtonType:NSButtonTypePushOnPushOff];
    b.bordered = NO;   // PillButton draws the background itself
    b.imagePosition = NSImageLeft;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kFooterSymbol
                                                                                     weight:NSFontWeightMedium];
    b.image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title]
               imageWithSymbolConfiguration:cfg];
    b.accessibilityLabel = title;
    return b;
}
// `ink` is the icon colour on the tint: dark on yellow, white on brown.
- (void)styleToggle:(NSButton *)b on:(BOOL)on tint:(NSColor *)tint ink:(NSColor *)ink {
    if (!b) return;   // popover not built yet (a Low Power change can arrive before first open)
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ([b isKindOfClass:PillButton.class]) ((PillButton *)b).onColor = tint;
    // Off is a normal, available control, not a disabled one: full label colour.
    NSColor *inkNow = on ? ink : NSColor.labelColor;
    b.contentTintColor = inkNow;
    b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title ?: @"" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: inkNow}];
    b.needsDisplay = YES;
}
// The footer shows exactly what the menu bar shows, from the same live state: the cup
// while Keep Awake is on, the yellow battery while Low Power is.
- (void)syncPowerButtons {
    if (!_keepAwakeButton || !_lowPowerButton) return;   // popover not built yet
    [self styleToggle:_keepAwakeButton on:_lidAwake tint:NSColor.systemBrownColor ink:NSColor.whiteColor];
    BOOL lowPower = LowPowerModeEnabled();
    [self styleToggle:_lowPowerButton on:lowPower tint:NSColor.systemYellowColor
                  ink:[NSColor colorWithWhite:0.1 alpha:1]];
    NSString *awakeState = _lidAwake ? @"on" : @"off";
    NSString *lowState = lowPower ? @"on" : @"off";
    _keepAwakeButton.accessibilityLabel = [NSString stringWithFormat:@"Keep Awake — %@", awakeState];
    _lowPowerButton.accessibilityLabel = [NSString stringWithFormat:@"Low Power — %@", lowState];
    // The pill already shows its name and state; the tooltip says only what it does.
    _keepAwakeButton.accessibilityHelp = PmsetRuleInstalled() ? @"No sleep, even with the lid closed"
                                                    : @"No sleep, even with the lid closed · asks for your password";
    _lowPowerButton.accessibilityHelp = @"macOS Low Power Mode";
    _keepAwakeButton.frame = NSMakeRect(kPad, 0, kKeepW, kToggleH);
    _lowPowerButton.frame = NSMakeRect(kPad + kKeepW + kToggleGap, 0, kLowW, kToggleH);
    if (_chargeButton) {
        // A visible toggle, not a hidden click on the battery glyph: on = Apple's 80% limit,
        // off = charging to full until tomorrow.
        BOOL limited = ![[self effectiveChargeMode] isEqualToString:@"full"];
        [self styleToggle:_chargeButton on:limited tint:NSColor.systemGreenColor ink:NSColor.whiteColor];
        _chargeButton.accessibilityLabel = [NSString stringWithFormat:@"Limit charge to 80%% — %@", limited ? @"on" : @"off"];
        _chargeButton.accessibilityHelp = [self chargeLimitTooltip];
        _chargeButton.frame = NSMakeRect(kPad + kKeepW + kToggleGap + kLowW + kToggleGap, 0, kChargeW, kToggleH);
    }
}
- (NSBox *)dividerAt:(CGFloat)y {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kW-2*kPad, 1)];
    b.boxType = NSBoxSeparator; return b;
}
- (NSView *)processMetricRow:(NSDictionary *)h right:(NSString *)right fraction:(double)fraction color:(NSColor *)color
                       width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSDictionary *info = ProcessDisplayInfo(h);
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, width, 38)];
    CGFloat inner = width - 2*pad;
    CGFloat rightW = 92;
    [row addSubview:[self text:info[@"title"] font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 21, inner-rightW-6, 15) align:NSTextAlignmentLeft]];
    [row addSubview:[self text:right font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                         color:NSColor.secondaryLabelColor at:NSMakeRect(width-pad-rightW, 21, rightW, 15) align:NSTextAlignmentRight]];
    [row addSubview:[self text:info[@"detail"] font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                          at:NSMakeRect(pad, 6, inner, 13) align:NSTextAlignmentLeft]];
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(pad, 2, inner, 3.5)];
    g.fraction = fraction; g.color = color;
    g.metricLabel = [NSString stringWithFormat:@"%@ — %@", info[@"title"], right ?: @""];
    [row addSubview:g];
    return row;
}
- (NSView *)processMetricRow:(NSDictionary *)h right:(NSString *)right fraction:(double)fraction color:(NSColor *)color at:(CGFloat)y {
    return [self processMetricRow:h right:right fraction:fraction color:color width:kW pad:kPad at:y];
}

- (NSView *)compactSignalRow:(NSString *)title right:(NSString *)right fraction:(double)fraction color:(NSColor *)color
                       width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, width, 28)];
    CGFloat inner = width - 2*pad;
    CGFloat rightW = 82;
    [row addSubview:[self text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 11, inner-rightW-8, 15) align:NSTextAlignmentLeft]];
    [row addSubview:[self text:right font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                         color:NSColor.secondaryLabelColor at:NSMakeRect(width-pad-rightW, 11, rightW, 15)
                         align:NSTextAlignmentRight]];
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(pad, 3, inner, 4)];
    g.fraction = MIN(1.0, MAX(0.0, fraction));
    g.color = color ?: NSColor.controlAccentColor;
    g.metricLabel = right.length ? [NSString stringWithFormat:@"%@ — %@", title, right] : title;
    [row addSubview:g];
    return row;
}

// The reset instant as a line of English, or nil when this provider has none to give.
// Falls back to whatever preformatted string the source supplied when there is no date
// behind it (a status-file override may hand over free text).
- (NSString *)compactResetText:(AIUsage *)u {
    NSString *clock = u.resetAt ? ResetClockText(u.resetAt, NSDate.date) : nil;
    if (clock.length) return [@"Resets " stringByAppendingString:clock];
    NSString *reset = u.resetText ?: @"";
    if (!reset.length || [reset isEqualToString:@"Not exposed locally"] ||
        [reset isEqualToString:@"Not provided"] || [reset isEqualToString:@"Not started"])
        return nil;
    return [NSString stringWithFormat:@"Resets %@", reset];
}

// How old the shown figure is, when it isn't live: "cached 3h ago" inline after the reset,
// "Cached 3h ago" on the dual meter's own line. WHY the refresh is failing is a plumbing
// question and lives in the details sheet, not in the one line the reader came to read.
//
// A figure restored from disk is flagged stale even when it is a minute old, because the
// reader means "I did not fetch this myself". Saying so below the poll interval would be
// a warning about nothing: a successful fetch at that age would have returned the same
// numbers. Past it, the age is the whole point.
- (NSString *)aiStalenessNote:(AIUsage *)u capitalized:(BOOL)capitalized {
    if (!u.limitStale) return nil;
    if (!u.limitUpdatedAt) return capitalized ? @"Cached figure" : @"cached";
    if (-u.limitUpdatedAt.timeIntervalSinceNow < kAccountPollInterval) return nil;
    return [NSString stringWithFormat:@"%@ %@", capitalized ? @"Cached" : @"cached",
            [self shortAgeForDate:u.limitUpdatedAt]];
}

// One line, one job: when does this quota come back. Diagnostics only get the line when
// there is no reset to report — otherwise they push the answer off the end of the row.
- (NSString *)aiStatusSubtext:(AIUsage *)u {
    NSString *note = nil;   // staleness is the datum's job ("stale 1h"); no "cached" machinery here
    // Overage has no reset to report — the paid budget is not a window that rolls over.
    NSString *lead = u.overageActive ? nil : [self compactResetText:u];
    // A signed-out account will not refresh on its own; the fix outranks the reset clock,
    // which would otherwise sit beside a figure frozen at the last good fetch.
    if ([u.limitRefreshError hasPrefix:@"Signed out"]) lead = u.limitRefreshError;
    if (!lead.length) lead = u.statusReason;
    // Keep billing visible even when a carried-forward plan window has a reset.
    if ([u.billingNote containsString:@"credits"]) {
        NSString *billing = [u.billingNote containsString:@"none available"] ? @"No credits" : @"Using credits";
        lead = lead.length ? [NSString stringWithFormat:@"%@ · %@", billing, lead] : billing;
    }
    if (lead.length)
        return note.length ? [NSString stringWithFormat:@"%@ · %@", lead, note] : lead;
    if (!u.available) return @"No local state";
    if (u.stale && u.statusText.length)   // e.g. Claude's cache computes through yesterday
        return [NSString stringWithFormat:@"No limit status · %@", u.statusText];
    return @"No limit status";
}

- (NSString *)aiResetDetailText:(AIUsage *)u {
    if (!u.limitStatusAvailable) return @"Not available";
    NSString *reset = u.resetText ?: @"";
    if (!reset.length || [reset isEqualToString:@"Not exposed locally"]) return @"Not provided";
    return reset;
}

// A problem replaces the reset clock in the datum column. The full sentence stays
// on the tooltip (aiStatusSubtext / limitRefreshError). Nil means "show the reset".
- (NSString *)aiProblemText:(AIUsage *)u {
    if (CodexQuotaUnavailable(u) && (!u.limitUpdatedAt || u.limitUpdatedAt.timeIntervalSinceNow>5)) return @"unavailable";
    NSString *err = u.limitRefreshError ?: @"";
    if ([err hasPrefix:@"Signed out"]) return @"signed out";
    if ([err hasPrefix:@"Claude Code token expired"]) return @"login expired";
    NSString *blob = [[NSString stringWithFormat:@"%@ %@", err, u.statusReason ?: @""] lowercaseString];
    if ([blob containsString:@"rate-limited"] || [blob containsString:@"rate limited"] ||
        [blob containsString:@"429"])
        return @"rate limited";
    if ([self aiSnapshotStaleWarns:u]) {
        NSString *age = u.limitUpdatedAt ? [self shortAgeForDate:u.limitUpdatedAt] : @"";
        age = [age stringByReplacingOccurrencesOfString:@" ago" withString:@""];
        if (!age.length || [age isEqualToString:@"pending"]) return @"stale";
        return [@"stale " stringByAppendingString:age];
    }
    // Token-total indexing never reaches the popover: it feeds Details' token counts,
    // not the quota gauge, and "indexing 96%" in place of the reset read as a fault.
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return @"unavailable";
    return nil;
}

// Extra figures remain in accessibility help. Hover is reserved for recovering clipped text.
- (NSString *)batteryPopoverTip {
    if (!_bat.valid) return @"No battery";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *eta = BatteryForecastDetail([self batteryForecast], NSDate.date.timeIntervalSince1970, nil);
    if (eta.length) [parts addObject:eta];
    if (_bat.acConnected && _bat.systemPowerIn_mW != LONG_MIN && _bat.systemPowerIn_mW >= 0) {
        NSString *in = _bat.adapterWatts > 0
            ? [NSString stringWithFormat:@"in %.0f of %ld W", _bat.systemPowerIn_mW / 1000.0, _bat.adapterWatts]
            : [NSString stringWithFormat:@"in %.0f W", _bat.systemPowerIn_mW / 1000.0];
        [parts addObject:in];
    }
    if (_bat.systemLoad_mW > 0 && _bat.systemLoad_mW != LONG_MIN)
        [parts addObject:[NSString stringWithFormat:@"Mac %.0f W", _bat.systemLoad_mW / 1000.0]];
    if (_bat.designCap_mAh > 0)
        [parts addObject:[NSString stringWithFormat:@"health %d%%", (int)lround(100.0 * _bat.rawMax_mAh / _bat.designCap_mAh)]];
    if (_bat.tempC > 0) {
        [parts addObject:[NSString stringWithFormat:@"cells %ld °C", lround(_bat.tempC)]];
    }
    if (_heatGuard == HeatGuardEngaged) [parts addObject:@"Low Power on for heat"];
    if (!parts.count) return @"Battery";
    if (eta.length && parts.count > 1) return [NSString stringWithFormat:@"%@\n%@", parts.firstObject,
        [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" · "]];
    return [parts componentsJoinedByString:@" · "];
}

- (void)ensureChargeModeLoaded {
    if (_chargeModeLoaded) return;
    _chargeModeLoaded = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (!_chargeMode) {
        id mode = [ud objectForKey:@"glancebarChargeMode"];
        if ([mode isKindOfClass:NSString.class]) _chargeMode = mode;
    }
    if (!_chargeModeAt) {
        id at = [ud objectForKey:@"glancebarChargeModeAt"];
        if ([at isKindOfClass:NSDate.class]) _chargeModeAt = at;
    }
}
- (NSString *)effectiveChargeMode {
    [self ensureChargeModeLoaded];
    return ChargeModeEffective(_chargeMode, _chargeModeAt, NSDate.date);
}
- (NSString *)chargeFullUntilText {
    if (!_chargeModeAt) return @"tomorrow";
    NSDate *until = [_chargeModeAt dateByAddingTimeInterval:24 * 60 * 60];
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.calendar = cal;
    fmt.timeZone = cal.timeZone;
    fmt.dateFormat = [cal isDate:until inSameDayAsDate:NSDate.date] ? @"HH:mm" : @"EEE HH:mm";
    return [fmt stringFromDate:until] ?: @"tomorrow";
}
- (NSString *)chargeLimitTooltip {
    if (_chargeShortcutsKnown && !_chargeShortcutsPresent)
        return @"Needs the Glancebar Charge 80 / Full shortcuts";
    if ([[self effectiveChargeMode] isEqualToString:@"full"])
        return [NSString stringWithFormat:@"Full until %@ · click for 80%%", [self chargeFullUntilText]];
    return @"Click to charge to full until tomorrow";
}
- (void)refreshChargeShortcutsIfStale {
    if (!_musicProbesEnabled || _chargeShortcutsChecking) return;
    if (_chargeShortcutsKnown && CFAbsoluteTimeGetCurrent() - _chargeShortcutsCheckedAt < 60) return;
    _chargeShortcutsChecking = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = RunTaskOutput(@"/usr/bin/shortcuts", @[@"list"]);
        BOOL has80 = NO, hasFull = NO;
        for (NSString *line in [out componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([name isEqualToString:@"Glancebar Charge 80"]) has80 = YES;
            if ([name isEqualToString:@"Glancebar Charge Full"]) hasFull = YES;
        }
        BOOL present = out != nil && has80 && hasFull;
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL changed = !self->_chargeShortcutsKnown || present != self->_chargeShortcutsPresent;
            self->_chargeShortcutsChecking = NO;
            self->_chargeShortcutsKnown = YES;
            self->_chargeShortcutsPresent = present;
            self->_chargeShortcutsCheckedAt = CFAbsoluteTimeGetCurrent();
            if (changed && self->_popover.isShown) [self rebuildContent];
        });
    });
}
- (void)runChargeShortcut:(NSString *)name mode:(NSString *)mode previous:(NSString *)previous previousAt:(NSDate *)previousAt {
    if (!name.length || !mode.length) return;
    if (_chargeShortcutInFlight) {
        // Clicked again mid-run: the last click wins once the running shortcut returns.
        _chargePendingName = name; _chargePendingMode = mode;
        return;
    }
    _chargeShortcutInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shortcuts"];
        task.arguments = @[@"run", name];
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        if (![task launchAndReturnError:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_chargeShortcutInFlight = NO; });
            return;
        }
        GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:10];
        [task waitUntilExit];
        [watchdog disarm];
        BOOL ok = task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_chargeShortcutInFlight = NO;
            // Already shown as set; only a failed shortcut walks the toggle back.
            if (!ok) [self applyChargeModeLocally:previous at:previousAt];
            NSString *nextName = self->_chargePendingName, *nextMode = self->_chargePendingMode;
            self->_chargePendingName = nil; self->_chargePendingMode = nil;
            if (nextName && ![nextMode isEqualToString:(ok ? mode : previous)])
                [self runChargeShortcut:nextName mode:nextMode previous:(ok ? mode : previous) previousAt:NSDate.date];
        });
    });
}
- (void)applyChargeModeLocally:(NSString *)mode at:(NSDate *)at {
    _chargeMode = mode;
    _chargeModeAt = at;
    _chargeModeLoaded = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:mode forKey:@"glancebarChargeMode"];
    [ud setObject:at forKey:@"glancebarChargeModeAt"];
    [self syncPowerButtons];
    [self refreshVisibleSurfaces];
}
- (void)toggleChargeLimit:(id)sender {
    (void)sender;
    if (!_musicProbesEnabled) { [self syncPowerButtons]; return; }
    // The toggle answers the click at once; the shortcut sets the limit in the background
    // and only a failure puts the toggle back (Ian: the second it takes needn't show).
    NSString *previous = [self effectiveChargeMode];
    NSDate *previousAt = _chargeModeAt;
    BOOL toFull = ![previous isEqualToString:@"full"];
    NSString *target = toFull ? @"full" : @"limit80";
    [self applyChargeModeLocally:target at:NSDate.date];
    BOOL fresh = _chargeShortcutsKnown && CFAbsoluteTimeGetCurrent() - _chargeShortcutsCheckedAt < 60;
    void (^act)(BOOL) = ^(BOOL present) {
        if (!present) {
            [self applyChargeModeLocally:previous at:previousAt];
            NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Battery-Settings.extension"];
            if (url) [NSWorkspace.sharedWorkspace openURL:url];
            return;
        }
        [self runChargeShortcut:(toFull ? @"Glancebar Charge Full" : @"Glancebar Charge 80")
                           mode:target previous:previous previousAt:previousAt];
    };
    if (fresh) { act(_chargeShortcutsPresent); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = RunTaskOutput(@"/usr/bin/shortcuts", @[@"list"]);
        BOOL has80 = NO, hasFull = NO;
        for (NSString *line in [out componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([name isEqualToString:@"Glancebar Charge 80"]) has80 = YES;
            if ([name isEqualToString:@"Glancebar Charge Full"]) hasFull = YES;
        }
        BOOL present = out != nil && has80 && hasFull;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_chargeShortcutsKnown = YES;
            self->_chargeShortcutsPresent = present;
            self->_chargeShortcutsCheckedAt = CFAbsoluteTimeGetCurrent();
            self->_chargeShortcutsChecking = NO;
            act(present);
        });
    });
}
- (int)chargeTargetPercent {
    return [[self effectiveChargeMode] isEqualToString:@"limit80"] ? 80 : 100;
}
- (BatteryForecast)batteryForecast {
    if (!_batteryForecastTracker) _batteryForecastTracker = [BatteryForecastTracker new];
    return [_batteryForecastTracker update:_bat limit80:[self chargeTargetPercent] == 80 at:NSDate.date.timeIntervalSince1970];
}
- (int)chargeForecastMinutes {
    if (!_bat.acConnected) return -1;
    BatteryForecast forecast = [self batteryForecast];
    double arrival = [self chargeTargetPercent] == 80 ? forecast.thresholdTime : forecast.endpointTime;
    return arrival > 0 ? MAX(1, (int)lround((arrival - NSDate.date.timeIntervalSince1970) / 300.0) * 5) : -1;
}
- (NSString *)chargeETAText {
    int minutes = [self chargeForecastMinutes];
    return minutes < 0 ? nil : [NSString stringWithFormat:@"~%@ to %@", FmtDuration(minutes),
        [self chargeTargetPercent] == 80 ? @"80%" : @"full"];
}
- (void)configureBatteryForecast:(BatteryForecastView *)view {
    BatteryForecast f = [self batteryForecast];
    view.forecast = f;
    double now = NSDate.date.timeIntervalSince1970;
    view.thresholdText = f.thresholdReached || f.hideLabels ? @"" : BatteryForecastDuration(f.thresholdTime, now);
    view.endpointText = f.endpointReached || f.hideLabels ? @"" : BatteryForecastDuration(f.endpointTime, now);
    view.accessibilityHelp = [NSString stringWithFormat:@"%@\n%@", BatteryForecastDetail(f, NSDate.date.timeIntervalSince1970, nil),
        BatteryForecastStatus(f)];
    view.accessibilityLabel = [NSString stringWithFormat:@"%d%% %@ · %d%% %@. %@", f.thresholdPercent,
        view.thresholdText, f.endpointPercent, view.endpointText, view.accessibilityHelp];
    [view setAccessibilityElement:YES]; view.accessibilityRole = NSAccessibilityImageRole;
    view.needsDisplay = YES;
}
- (NSImage *)liveBatteryGlyph {
    NSString *name = BatterySymbolName(_bat.percent, NO);
    CGFloat pt = FittedSymbolPointSize(name, kLeadSymbol, kLeadW);
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:pt
                                                                                      weight:NSFontWeightRegular];
    NSImage *base = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:@"Charge limit"]
                     imageWithSymbolConfiguration:cfg];
    if (!base) return nil;
    return BatteryGlyphWithBadge(base, PowerFlowFor(_bat), PowerFlowColor(_bat, NSColor.labelColor));
}
- (void)badgeBatterySymbolView:(NSImageView *)mark {
    if (![mark isKindOfClass:NSImageView.class]) return;
    NSImage *glyph = [self liveBatteryGlyph];
    if (!glyph) return;
    mark.image = glyph;
    mark.contentTintColor = glyph.template ? mark.contentTintColor : nil;
}
// Battery = quantity plus flow. The bar is the charge; a trend arrow above it runs from
// the level to where it will be in an hour at the current rate (stopping at the charge
// limit), and the datum is the signed rate in watts.
- (void)configureTrend:(TrendArrow *)arrow over:(NSView *)gauge {
    double bw = BatteryWatts(_bat);
    double fullWh = BatteryWattHours(_bat.rawMax_mAh, _bat.voltage_mV);
    double level = _bat.percent / 100.0;
    BOOL moving = !isnan(bw) && fabs(bw) >= 0.3 && !isnan(fullWh) && fullWh > 0;
    double cap = [[self effectiveChargeMode] isEqualToString:@"limit80"] ? MAX(0.8, level) : 1.0;
    // Plugged in with telemetry: the charger's input and the Mac's draw are separate
    // vectors. Otherwise one vector carries the battery's own rate.
    BOOL split = _bat.acConnected && _bat.systemPowerIn_mW != LONG_MIN && _bat.systemPowerIn_mW >= 0 &&
        _bat.systemLoad_mW != LONG_MIN && _bat.systemLoad_mW > 0 && !isnan(fullWh) && fullWh > 0 && moving;
    double to = level, drawTo = NAN;
    if (split) {
        to = MIN(cap, level + _bat.systemPowerIn_mW / 1000.0 / fullWh);
        drawTo = MAX(0, level - _bat.systemLoad_mW / 1000.0 / fullWh);
    } else if (moving) {
        double target = MIN(cap, MAX(0, level + bw / fullWh));
        if (bw > 0) to = target; else drawTo = target;
    }
    BOOL inShows = fabs(to - level) >= 0.01, drawShows = isfinite(drawTo) && fabs(drawTo - level) >= 0.01;
    arrow.from = level; arrow.to = inShows ? to : level; arrow.drawTo = drawShows ? drawTo : NAN;
    arrow.hidden = !inShows && !drawShows;
    // In line with the bar, unless a head would run off its end (draining from very low):
    // then it lifts just above.
    BOOL roomInLine = NSWidth(gauge.frame) * (drawShows ? drawTo : to) >= 6;
    CGFloat y = roomInLine ? NSMidY(gauge.frame) - 7 : NSMinY(gauge.frame) - 9;
    arrow.frame = NSMakeRect(NSMinX(gauge.frame) - 5, y, NSWidth(gauge.frame) + 10, roomInLine ? 14 : 10);
}
- (NSString *)batteryRateText {
    double bw = BatteryWatts(_bat);
    if (isnan(bw)) return @"";
    return fabs(bw) < 0.3 ? @"0 W" : FormatSignedWatts(bw);
}
- (NSColor *)batteryRateColor {
    double bw = BatteryWatts(_bat);
    return isnan(bw) || fabs(bw) < 0.3 ? NSColor.secondaryLabelColor
         : bw > 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
}
- (void)addBatteryTrendTo:(NSView *)row gauge:(NSView *)gauge datum:(NSRect)datum
                     stem:(NSString *)stem tip:(NSString *)tip {
    NSRect frame = gauge.frame; frame.origin.y = 9; gauge.frame = frame;
    // The forecast layer owns both target markers so the same treatment reaches every surface.
    if ([gauge isKindOfClass:Gauge.class]) ((Gauge *)gauge).markerFraction = -1;
    TrendArrow *arrow = [[TrendArrow alloc] initWithFrame:NSZeroRect];
    [self configureTrend:arrow over:gauge];
    arrow.accessibilityIdentifier = [stem stringByAppendingString:@".trend"];
    arrow.accessibilityHelp = tip;
    [row addSubview:arrow];
    BatteryForecastView *forecast = [[BatteryForecastView alloc] initWithFrame:
        NSMakeRect(NSMinX(frame) - kBatteryForecastSideRoom, 0, NSWidth(frame) + 2 * kBatteryForecastSideRoom, 30)];
    forecast.accessibilityIdentifier = [stem stringByAppendingString:@".forecast"];
    [self configureBatteryForecast:forecast];
    [row addSubview:forecast];
    NSTextField *rate = [self text:[self batteryRateText]
                              font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                             color:[self batteryRateColor] at:datum align:NSTextAlignmentLeft];
    rate.accessibilityIdentifier = [stem stringByAppendingString:@".datum"];
    rate.accessibilityHelp = tip;
    [row addSubview:rate];
}

// "Input 18.8 W (20 W charger) · system 14.9 W · battery +3.9 W", from Apple's telemetry.
- (NSString *)batteryPowerFlowText {
    NSMutableArray *parts = [NSMutableArray array];
    if (_bat.acConnected && _bat.systemPowerIn_mW > 0 && _bat.systemPowerIn_mW != LONG_MIN) {
        NSString *input = [NSString stringWithFormat:@"Input %.1f W", _bat.systemPowerIn_mW / 1000.0];
        if (_bat.adapterWatts > 0) input = [input stringByAppendingFormat:@" (%ld W charger)", _bat.adapterWatts];
        [parts addObject:input];
    }
    if (_bat.systemLoad_mW > 0 && _bat.systemLoad_mW != LONG_MIN)
        [parts addObject:[NSString stringWithFormat:@"system %.1f W", _bat.systemLoad_mW / 1000.0]];
    NSString *battery = FormatSignedWatts(BatteryWatts(_bat));
    if (battery) [parts addObject:[@"battery " stringByAppendingString:battery]];
    return [parts componentsJoinedByString:@" · "];
}
// "30.2 Wh of 52.0 Wh (design 55.3 Wh)".
- (NSString *)batteryEnergyText {
    NSString *now = FormatWattHours(BatteryWattHours(_bat.rawCurrent_mAh, _bat.voltage_mV));
    NSString *full = FormatWattHours(BatteryWattHours(_bat.rawMax_mAh, _bat.voltage_mV));
    NSString *design = FormatWattHours(BatteryWattHours(_bat.designCap_mAh, _bat.voltage_mV));
    if (!now) return nil;
    NSString *text = full ? [NSString stringWithFormat:@"%@ of %@", now, full] : now;
    return design ? [text stringByAppendingFormat:@" (design %@)", design] : text;
}

// The System instrument at any scale: a CPU gauge and percent, then memory pressure as
// the memory-chip symbol plus rising pips. A swap glyph appears only while swapping.
- (void)addSystemInstrumentTo:(NSView *)row gauge:(NSRect)gaugeFrame value:(NSRect)valueFrame
                        datum:(NSRect)datumFrame stem:(NSString *)stem tip:(NSString *)tip {
    double cpu = _sys.cpuValid ? _sys.cpu : 0;
    NSColor *cpuColor = _sys.cpuValid ? CPUColor(cpu) : NSColor.tertiaryLabelColor;
    NSString *cpuTip = CPUStatusText(_sys);
    Gauge *g = [[Gauge alloc] initWithFrame:gaugeFrame];
    g.fraction = MIN(cpu, 1.0);
    g.color = cpuColor;
    g.metricLabel = @"CPU";
    g.accessibilityIdentifier = [stem stringByAppendingString:@".gauge"];
    g.accessibilityHelp = tip;
    [row addSubview:g];
    NSTextField *value = [self text:(_sys.cpuValid ? [NSString stringWithFormat:@"%d%%", (int)lround(cpu * 100)] : @"—")
                               font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                              color:cpuColor at:valueFrame align:NSTextAlignmentRight];
    value.accessibilityIdentifier = [stem stringByAppendingString:@".value"];
    value.accessibilityLabel = cpuTip;
    value.accessibilityHelp = tip;
    [row addSubview:value];

    NSString *memTip = [NSString stringWithFormat:@"%@\n%@", MemoryStatusText(_sys), SwapStatusText(_sys)];
    // CPU is the bar. Memory pressure tints the row's symbol; memory figures live in the System tab.
    (void)memTip;
}

// The Speed instrument: the fast cores' speed against their top clock as the bar and
// percent, the speed held back shaded red behind the bar, then chip and cell temperatures.
// It appears once macOS reports thermal pressure or the cells reach 38 °C.
- (BOOL)heatShowing {
    return HeatShowing([NSUserDefaults.standardUserDefaults boolForKey:@"speedAlways"],
                       SystemThermalLevel(_sys), _bat.valid ? _bat.tempC : 0);
}
- (NSColor *)heatSpeedColor {
    if (_heatSpeed < 0) return NSColor.tertiaryLabelColor;
    ThermalLevel level = SystemThermalLevel(_sys);
    return level == ThermalThrottling ? NSColor.systemRedColor
         : level == ThermalNear ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
}
// The worse of the chip's pressure and the cells' heat.
- (NSColor *)heatTempsColor {
    ThermalLevel level = SystemThermalLevel(_sys);
    BatteryHeat cells = BatteryHeatFor(_bat.valid ? _bat.tempC : 0);
    if (level == ThermalThrottling || cells == BatteryHeatHot) return NSColor.systemRedColor;
    if (level == ThermalNear || cells == BatteryHeatWarm) return NSColor.systemOrangeColor;
    return NSColor.secondaryLabelColor;
}
- (NSString *)heatPressureAge {
    return _pressureSince > 0 ? BatteryForecastDuration(CFAbsoluteTimeGetCurrent(), _pressureSince) : nil;
}
// "Fast cores 2.3 of 4.5 GHz (52%)\nHottest core 78 °C · cells 34 °C · pressure heavy for 40m"
- (NSString *)heatTip {
    NSMutableArray *lines = [NSMutableArray array];
    CoreClocks k = _sys.clocks;
    ThermalLevel level = SystemThermalLevel(_sys);
    if (level == ThermalNominal) [lines addObject:@"Fast cores at full speed"];
    else if (_heatSpeed >= 0)
        [lines addObject:[NSString stringWithFormat:@"Fast cores at %d%% of top speed", (int)lround(_heatSpeed * 100)]];
    if (k.valid && k.pMHz > 0)
        [lines addObject:[NSString stringWithFormat:@"now %.1f of %.1f GHz", k.pMHz / 1000, k.pMaxMHz / 1000]];
    NSMutableArray *parts = [NSMutableArray array];
    if (_sys.tempValid) [parts addObject:[NSString stringWithFormat:@"Hottest core %ld °C", lround(_sys.cpuTempC)]];
    if (_bat.valid && _bat.tempC > 0) [parts addObject:[NSString stringWithFormat:@"cells %ld °C", lround(_bat.tempC)]];
    if (_sys.thermalValid) {
        NSString *p = [@"pressure " stringByAppendingString:ThermalPressureName(_sys.thermalPressure)];
        NSString *age = [self heatPressureAge];
        [parts addObject:age && ![age isEqual:@"—"] ? [p stringByAppendingFormat:@" for %@", age] : p];
    }
    if (parts.count) [lines addObject:[parts componentsJoinedByString:@" · "]];
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"Heat unknown";
}
// The temperature readout: each reading carries its own symbol and colour, a chip
// for the hottest core and a battery for the cells. Nil when neither is known.
static NSAttributedString *HeatTempsReadout(double chipC, NSColor *chipColor, double cellsC, NSColor *cellColor) {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
    NSMutableAttributedString *temps = [NSMutableAttributedString new];
    void (^reading)(NSString *, double, NSColor *) = ^(NSString *symbol, double c, NSColor *color) {
        if (c <= 0) return;
        if (temps.length) [temps appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{NSFontAttributeName: font}]];
        NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:kDatumFont - 2.5 weight:NSFontWeightRegular]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
        NSImage *glyph = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
        if (glyph) {
            NSTextAttachment *mark = [NSTextAttachment new];
            mark.image = glyph;
            mark.bounds = NSMakeRect(0, (font.capHeight - glyph.size.height) / 2, glyph.size.width, glyph.size.height);
            [temps appendAttributedString:[NSAttributedString attributedStringWithAttachment:mark]];
        }
        [temps appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld°", lround(c)]
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
    };
    reading(@"cpu", chipC, chipColor);
    reading(@"battery.75", cellsC, cellColor);
    return temps.length ? temps : nil;
}
- (void)addHeatInstrumentTo:(NSView *)row gauge:(NSRect)gaugeFrame value:(NSRect)valueFrame
                      datum:(NSRect)datumFrame stem:(NSString *)stem tip:(NSString *)tip {
    NSColor *speedColor = [self heatSpeedColor];
    Gauge *g = [[Gauge alloc] initWithFrame:gaugeFrame];
    g.fraction = MAX(0, _heatSpeed);
    g.color = speedColor;
    g.metricLabel = @"Speed";
    if (_heatSpeed >= 0 && _heatSpeed < 0.98) g.lossColor = NSColor.systemRedColor;   // the speed macOS is holding back
    g.accessibilityIdentifier = [stem stringByAppendingString:@".gauge"];
    g.accessibilityHelp = tip;
    [row addSubview:g];
    NSTextField *value = [self text:(_heatSpeed >= 0 ? [NSString stringWithFormat:@"%d%%", (int)lround(_heatSpeed * 100)] : @"—")
                               font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                              color:speedColor at:valueFrame align:NSTextAlignmentRight];
    value.accessibilityIdentifier = [stem stringByAppendingString:@".value"];
    value.accessibilityLabel = @"Fast-core speed";
    value.accessibilityHelp = tip;
    [row addSubview:value];
    // Each temperature carries its own symbol and colour: chip for the hottest core, battery for the cells.
    ThermalLevel level = SystemThermalLevel(_sys);
    BatteryHeat cellHeat = BatteryHeatFor(_bat.valid ? _bat.tempC : 0);
    NSColor *chipColor = level == ThermalThrottling ? NSColor.systemRedColor
        : level == ThermalNear ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    NSColor *cellColor = cellHeat == BatteryHeatHot ? NSColor.systemRedColor
        : cellHeat == BatteryHeatWarm ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    NSAttributedString *temps = HeatTempsReadout(_sys.tempValid ? _sys.cpuTempC : 0, chipColor, _bat.valid ? _bat.tempC : 0, cellColor);
    if (temps) {
        NSFont *font = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
        NSTextField *datum = [self text:@"" font:font color:NSColor.secondaryLabelColor at:datumFrame align:NSTextAlignmentLeft];
        datum.attributedStringValue = temps;
        datum.accessibilityIdentifier = [stem stringByAppendingString:@".datum"];
        NSMutableArray *said = [NSMutableArray array];
        if (_sys.tempValid) [said addObject:[NSString stringWithFormat:@"Hottest core %ld °C", lround(_sys.cpuTempC)]];
        if (_bat.valid && _bat.tempC > 0) [said addObject:[NSString stringWithFormat:@"battery cells %ld °C", lround(_bat.tempC)]];
        datum.accessibilityLabel = [said componentsJoinedByString:@", "];
        datum.accessibilityHelp = tip;
        [row addSubview:datum];
    }
}
// A speedometer whose needle sits where the fast cores are.
- (NSString *)heatSymbol {
    if (_heatSpeed < 0 || _heatSpeed >= 0.9) return @"gauge.with.dots.needle.100percent";
    return _heatSpeed >= 0.6 ? @"gauge.with.dots.needle.67percent" : @"gauge.with.dots.needle.33percent";
}
- (NSColor *)heatSymbolColor {
    NSColor *c = [self heatTempsColor];
    return c == NSColor.secondaryLabelColor ? [self heatSpeedColor] : c;
}

- (NSImageView *)instrumentSymbol:(NSString *)name tint:(NSColor *)tint identifier:(NSString *)identifier in:(NSView *)row {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kLeadSymbol weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
    NSImageView *iv = [NSImageView imageViewWithImage:image];
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    iv.frame = NSMakeRect(kPad, (NSHeight(row.bounds) - kLeadSymbol) / 2.0, kLeadW, kLeadSymbol);
    iv.accessibilityIdentifier = identifier;
    [row addSubview:iv];
    return iv;
}

- (NSImageView *)instrumentLogo:(NSImage *)image identifier:(NSString *)identifier in:(NSView *)row {
    NSImageView *iv = [NSImageView imageViewWithImage:image];
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    iv.imageAlignment = NSImageAlignCenter;
    iv.frame = NSMakeRect(kPad, (NSHeight(row.bounds) - kLeadSymbol) / 2.0, kLeadW, kLeadSymbol);
    iv.accessibilityIdentifier = identifier;
    [row addSubview:iv];
    return iv;
}

- (NSTextField *)instrumentName:(NSString *)text identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                              color:NSColor.labelColor
                                 at:NSMakeRect(kAINameX, (NSHeight(row.bounds) - 16) / 2.0, RowNameW(), 16)
                              align:NSTextAlignmentLeft];
    field.accessibilityIdentifier = identifier;
    field.maximumNumberOfLines = 1;
    field.allowsDefaultTighteningForTruncation = YES;
    [row addSubview:field];
    return field;
}

- (NSTextField *)instrumentValue:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                              color:color at:NSMakeRect(kValueX, (NSHeight(row.bounds) - kValueH) / 2.0, kValueW, kValueH) align:NSTextAlignmentRight];
    field.accessibilityIdentifier = identifier;
    [row addSubview:field];
    return field;
}

- (NSTextField *)instrumentDatum:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text ?: @"" font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                              color:color ?: NSColor.secondaryLabelColor
                                 at:NSMakeRect(kDatumX, (NSHeight(row.bounds) - kDatumH) / 2.0, kDatumW, kDatumH) align:NSTextAlignmentLeft];
    field.accessibilityIdentifier = identifier;
    [row addSubview:field];
    return field;
}

// The installed app's own icon, cached once per launch. Nil when the app is absent;
// callers then keep the SF Symbol. No logo files are stored in the repo.
static NSImage *CachedBundleIcon(NSString *bundleID, NSString *fallbackPath) {
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@", bundleID ?: @"", fallbackPath ?: @""];
    id hit = cache[key];
    if (hit) return hit == NSNull.null ? nil : hit;
    NSWorkspace *ws = NSWorkspace.sharedWorkspace;
    NSURL *url = bundleID.length ? [ws URLForApplicationWithBundleIdentifier:bundleID] : nil;
    if (!url && fallbackPath.length && [NSFileManager.defaultManager fileExistsAtPath:fallbackPath])
        url = [NSURL fileURLWithPath:fallbackPath];
    NSImage *icon = url ? [ws iconForFile:url.path] : nil;
    cache[key] = icon ?: NSNull.null;
    return icon;
}
static NSImage *AIProviderIcon(NSString *provider) {
    if ([provider isEqualToString:@"Claude"])
        return CachedBundleIcon(@"com.anthropic.claudefordesktop", @"/Applications/Claude.app");
    if ([provider isEqualToString:@"Cursor"])
        return CachedBundleIcon(@"com.todesktop.230313mzl4w4u92", @"/Applications/Cursor.app");
    if ([provider isEqualToString:@"Codex"]) {
        NSImage *codex = CachedBundleIcon(@"com.openai.codex", nil);
        if (codex) return codex;
        return CachedBundleIcon(@"com.openai.chat", @"/Applications/ChatGPT.app");
    }
    return nil;
}
static NSImage *AIProviderLogo(NSString *provider, CGFloat pt) {
    NSImage *icon = AIProviderIcon(provider);
    if (!icon) return nil;
    NSImage *sized = [icon copy];
    sized.size = NSMakeSize(pt, pt);
    sized.template = NO;
    return sized;
}

// The lead glyph for a provider. Missing symbols (older than the OS that shipped them)
// fall back to a dashed circle so the column still lines up.
- (NSString *)aiSymbolName:(NSString *)provider {
    NSString *symbol = @"circle.dashed";
    if ([provider isEqualToString:@"Claude"]) symbol = @"sparkle";
    else if ([provider isEqualToString:@"Codex"]) symbol = @"chevron.left.forwardslash.chevron.right";
    else if ([provider isEqualToString:@"Cursor"]) symbol = @"cursorarrow.rays";
    if (![NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]) symbol = @"circle.dashed";
    return symbol;
}

// Claude's row: the gauge and the number are the WEEKLY allowance across all models.
// The 5-hour window stays in the tooltip and Details. A problem (signed out, stale,
// indexing) takes the datum column; the reset clock is the datum otherwise.
// The provider's name sits beside its logo. The tooltip still leads with the name.
static NSString *BurnShortName(NSString *name) {
    for (NSString *vendor in @[@"Google ", @"Microsoft ", @"Adobe "])
        if ([name hasPrefix:vendor] && name.length > vendor.length) return [name substringFromIndex:vendor.length];
    return name;
}

// Resolve live group members, caching images by outer bundle path, never by reusable pid.
static NSImage *BurnAppIcon(NSDictionary *group) {
    static NSCache<NSString *, NSImage *> *icons;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icons = [NSCache new]; icons.countLimit = 64; });
    for (NSNumber *pid in group[@"pids"]) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
        NSString *path = app.bundleURL.path;
        if (!path) {
            char executable[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid.intValue, executable, sizeof(executable)) > 0)
                path = [NSString stringWithUTF8String:executable];
        }
        NSRange boundary = [path rangeOfString:@".app/"];
        if (path && boundary.location != NSNotFound) path = [path substringToIndex:boundary.location + 4];
        if (![path hasSuffix:@".app"]) continue;
        NSImage *icon = [icons objectForKey:path];
        if (!icon) {
            icon = [NSWorkspace.sharedWorkspace iconForFile:path];
            if (icon) [icons setObject:icon forKey:path];
        }
        if (icon) return icon;
    }
    return nil;
}

- (NSString *)burnSinceLabel {
    if (!_energyBaselineAt) return nil;
    return _energyBaselineAtUnplug ? @"Since unplug" : [@"Since " stringByAppendingString:ClockText(_energyBaselineAt)];
}

- (NSString *)burnTip:(double)draw {
    NSMutableArray *lines = [NSMutableArray array];
    BOOL hasWh = _energyBaselineAt != nil;
    double apps = 0;
    for (NSDictionary *row in _burnRows) {
        double w = [row[@"watts"] doubleValue], wh = [row[@"wh"] doubleValue];
        apps += w;
        // A root daemon's watts are estimated from its CPU share; it has no Wh.
        if ([row[@"estimated"] boolValue])
            [lines addObject:[NSString stringWithFormat:@"%@ ~%.1f W (from CPU)", BurnShortName(row[@"name"]), w]];
        else [lines addObject:hasWh ? [NSString stringWithFormat:@"%@ %.1f W · %.1f Wh", BurnShortName(row[@"name"]), w, wh]
                                    : [NSString stringWithFormat:@"%@ %.1f W", BurnShortName(row[@"name"]), w]];
    }
    double since = [self burnSinceBaselineWh];
    if (draw > 0) {
        NSString *screen = [NSString stringWithFormat:@"Screen + system %.1f W", MAX(0, draw - apps)];
        [lines addObject:screen];
    }
    if (hasWh && since >= 0) {
        int minutes = (int)lround(-_energyBaselineAt.timeIntervalSinceNow / 60.0);
        [lines addObject:[NSString stringWithFormat:@"%@: %.1f Wh over %@", [self burnSinceLabel], since, FmtDuration(minutes)]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// One actionable app: at least half an hour gained before the 20% reserve.
- (CGFloat)addBurnRowTo:(NSView *)root at:(CGFloat)y {
    double draw = [self burnDrawWatts];
    NSDictionary *top = _burnRows.firstObject;
    double watts = [top[@"watts"] doubleValue];
    int gain = BurnGainMinutes(MinutesTo20(_bat, [self avgAmp]), draw, watts);
    // Behind a short charger only the net drain empties the pack; quitting an app that
    // costs more than that turns the drain into a charge.
    BOOL turnsToCharge = NO;
    if (ChargerFallsShort(_bat)) {
        double net = -BatteryWatts(_bat), fullWh = BatteryWattHours(_bat.rawMax_mAh, _bat.voltage_mV);
        int minutes = _bat.percent > 20 && fullWh > 0 && net > 0
            ? (int)lround((_bat.percent - 20) / 100.0 * fullWh / net * 60.0) : -1;
        turnsToCharge = watts >= net && watts >= 1;
        gain = turnsToCharge ? 0 : BurnGainMinutes(minutes, net, watts);
    }
    BOOL want = draw > 0 && top && (gain >= 0 || turnsToCharge);
    // The gain hovers around its half-hour bar, and the row popping in and out moved everything under
    // the pointer (Ian, 1 Nov 2026): decide once when the popover opens, hold until it closes.
    if (_popover.isShown) {
        if (_burnLatch) want = _burnLatch == 1 && draw > 0 && top;
        else _burnLatch = want ? 1 : 2;
    }
    if (!want) return y;
    ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
    row.target = self;
    row.action = @selector(showBatteryDetails:);
    row.accessibilityRole = NSAccessibilityButtonRole;
    row.accessibilityIdentifier = @"popover.row.burn";
    NSString *tip = [self burnTip:draw];
    row.accessibilityHelp = tip;
    row.accessibilityLabel = tip;
    NSImage *icon = BurnAppIcon(top);
    NSImageView *symbol = icon ? [self instrumentLogo:icon identifier:@"popover.burn.symbol" in:row]
        : [self instrumentSymbol:@"terminal" tint:NSColor.secondaryLabelColor identifier:@"popover.burn.symbol" in:row];
    symbol.accessibilityHelp = tip;
    NSString *name = BurnShortName(top[@"name"]);
    NSTextField *nameField = [self instrumentName:name identifier:@"popover.burn.name" in:row];
    nameField.lineBreakMode = NSLineBreakByTruncatingTail;
    nameField.accessibilityHelp = tip;
    Gauge *bar = [[Gauge alloc] initWithFrame:RowGaugeRect()];
    bar.fraction = MIN(1, watts / draw);
    bar.color = NSColor.systemOrangeColor;
    bar.metricLabel = @"App share of battery draw";
    bar.accessibilityIdentifier = @"popover.burn.gauge";
    bar.accessibilityHelp = tip;
    [row addSubview:bar];
    // Root daemons' watts are estimated from CPU share: say so with "≈".
    NSString *value = [NSString stringWithFormat:watts >= 10 ? @"%.0f W" : @"%.1f W", watts];
    [self instrumentValue:value color:watts >= draw * 0.5 ? NSColor.systemRedColor : NSColor.labelColor
               identifier:@"popover.burn.value" in:row].accessibilityHelp = tip;
    [self instrumentDatum:turnsToCharge ? @"quit \u2192 charges" : gain >= 0 ? [@"quit +" stringByAppendingString:FmtDuration(gain)] : @""
                    color:turnsToCharge ? NSColor.systemGreenColor : NSColor.secondaryLabelColor
               identifier:@"popover.burn.datum" in:row].accessibilityHelp = tip;
    [root addSubview:row];
    return y + kRowH;
}

- (CGFloat)addAICard:(AIUsage *)u toView:(NSView *)root width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    (void)width; (void)pad;
    NSString *name = u.name.length ? u.name : @"AI";
    NSString *slug = name.lowercaseString;
    NSDictionary *cursorPools = CursorPoolQuotas(u);
    CGFloat rowH = kRowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, rowH)];
    row.accessibilityIdentifier = [@"popover.row.ai." stringByAppendingString:slug];
    NSDictionary *quotas = [name isEqualToString:@"Claude"] && !u.overageActive && u.limitStatusAvailable
        ? ClaudeModelQuotas(u.limitWindows) : nil;
    double week = quotas ? [quotas[@"opus"] doubleValue] : -1;
    BOOL claudeMeter = quotas != nil;
    BOOL hasGauge = claudeMeter || cursorPools || (u.limitStatusAvailable && u.remainingFraction >= 0 && !CodexQuotaUnavailable(u));
    NSString *pct = @"—";
    NSColor *valueColor = NSColor.tertiaryLabelColor;
    NSString *tip = [self aiStatusSubtext:u] ?: @"";
    // The logo (or the SF Symbol, if the app is not installed) plus the provider name.
    // popover.ai.<slug>.name stays on the text so focus restoration still finds it.
    NSString *symbolID = [NSString stringWithFormat:@"popover.ai.%@.symbol", slug];
    NSImage *logo = AIProviderLogo(name, kLeadSymbol);
    NSImageView *mark = logo ? [self instrumentLogo:logo identifier:symbolID in:row]
        : [self instrumentSymbol:[self aiSymbolName:name] tint:valueColor identifier:symbolID in:row];
    NSTextField *nameField = [self instrumentName:name
                                     identifier:[NSString stringWithFormat:@"popover.ai.%@.name", slug] in:row];
    QuotaPairGauge *meter = nil;
    Gauge *plainGauge = nil;
    if (claudeMeter) {
        pct = week < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", week * 100];
        BOOL staleWarns = [self aiSnapshotStaleWarns:u];
        valueColor = staleWarns ? NSColor.systemOrangeColor
            : (week < 0 ? NSColor.tertiaryLabelColor : AIQuotaColor(week));
        NSString *weekClock = [quotas[@"resetsAt"] isKindOfClass:NSNumber.class]
            ? ResetClockText([NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]], NSDate.date) : nil;
        // Week figure is on the row; the tooltip adds only the week's reset and the 5-hour window.
        NSMutableArray *parts = [NSMutableArray array];
        if (weekClock.length) [parts addObject:[@"week resets " stringByAppendingString:weekClock]];
        for (NSDictionary *w in u.limitWindows)
            if ([w[@"window"] isEqual:@"5-hour"] && [w[@"remainingFraction"] isKindOfClass:NSNumber.class]) {
                NSString *clock = [w[@"resetsAt"] isKindOfClass:NSNumber.class]
                    ? CompactResetClock([NSDate dateWithTimeIntervalSince1970:[w[@"resetsAt"] doubleValue]], NSDate.date) : nil;
                [parts addObject:[NSString stringWithFormat:@"5 h %.0f%%%@", [w[@"remainingFraction"] doubleValue] * 100,
                    clock.length ? [@", resets " stringByAppendingString:clock] : @""]];
            }
        if (!weekClock.length && tip.length) [parts addObject:tip];
        if (u.limitRefreshError.length) [parts addObject:u.limitRefreshError];
        tip = [parts componentsJoinedByString:@" · "];
        meter = [[QuotaPairGauge alloc] initWithFrame:RowGaugeRect()];
        meter.secondFraction = week;
        meter.accessibilityIdentifier = @"popover.ai.claude.gauge";
        meter.accessibilityLabel = @"Claude weekly allowance remaining, all models";
        [row addSubview:meter];
    } else if (cursorPools) {
        double primary = CursorPrimaryFraction(cursorPools);
        pct = primary < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", primary * 100];
        valueColor = [self aiSnapshotStaleWarns:u] ? NSColor.systemOrangeColor : AIQuotaColor(MAX(primary, 0));

        plainGauge = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        plainGauge.fraction = MAX(primary, 0);
        plainGauge.color = valueColor;
        plainGauge.metricLabel = @"Cursor Grok + Composer remaining";
        plainGauge.accessibilityIdentifier = @"popover.ai.cursor.gauge";
        [row addSubview:plainGauge];
    } else if (hasGauge) {
        pct = [self aiPercentText:u];
        valueColor = [self aiStatusColor:u];
        plainGauge = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        plainGauge.fraction = u.remainingFraction;
        plainGauge.color = valueColor;
        plainGauge.metricLabel = [NSString stringWithFormat:@"%@ quota remaining", name];
        plainGauge.accessibilityIdentifier = [NSString stringWithFormat:@"popover.ai.%@.gauge", slug];
        [row addSubview:plainGauge];
    }
    NSDate *resetDate = cursorPools ? CursorPoolReset(cursorPools) : u.resetAt;
    if (claudeMeter && [quotas[@"resetsAt"] isKindOfClass:NSNumber.class])
        resetDate = [NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]];
    NSString *named = tip.length ? [NSString stringWithFormat:@"%@ — %@", name, tip] : name;   // spoken
    NSString *shortTip = tip.length ? tip : name;   // shown: the row already names itself
    if (!logo) mark.contentTintColor = valueColor;
    mark.accessibilityHelp = shortTip;
    mark.accessibilityLabel = named;
    nameField.accessibilityHelp = shortTip;
    nameField.accessibilityLabel = name;
    if (meter) meter.accessibilityHelp = shortTip;
    if (plainGauge) plainGauge.accessibilityHelp = shortTip;
    NSString *valueID = [name isEqualToString:@"Claude"] ? @"popover.claude.value"
        : [NSString stringWithFormat:@"popover.ai.%@.value", slug];
    NSTextField *value = [self instrumentValue:pct color:valueColor identifier:valueID in:row];
    value.accessibilityHelp = shortTip;
    if (claudeMeter) value.accessibilityLabel = @"Percent of the week remaining, all models";
    NSString *problem = [self aiProblemText:u];
    NSColor *datumColor = NSColor.secondaryLabelColor;
    NSString *datum = @"";
    if (problem.length) {
        datum = problem;
        BOOL severe = [problem isEqualToString:@"signed out"] || [problem isEqualToString:@"rate limited"];
        datumColor = severe ? NSColor.systemRedColor : NSColor.systemOrangeColor;
    } else if (!u.overageActive) {
        NSDate *reset = resetDate;
        // A bare "21:00" beside a bar could mean anything; one word says what it is.
        NSString *clock = CompactResetClock(reset, NSDate.date);
        datum = clock.length ? [@"resets " stringByAppendingString:clock] : @"";
    }
    NSTextField *datumField = [self instrumentDatum:datum color:datumColor
                                        identifier:[NSString stringWithFormat:@"popover.ai.%@.datum", slug] in:row];
    datumField.accessibilityHelp = shortTip;
    datumField.accessibilityLabel = named.length ? named : datum;
    row.accessibilityHelp = shortTip;
    row.accessibilityLabel = named;
    [root addSubview:row];
    y += rowH;
    // Cursor's API pool is its own plain row under the Grok row: same bar, same column,
    // nothing to decode. Only when Grok is the row above (both pools reported).
    double api = cursorPools ? CursorPoolFraction(cursorPools, @"api") : -1;
    if (api >= 0 && CursorPoolFraction(cursorPools, @"cursor") >= 0) {
        NSView *apiRow = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        apiRow.accessibilityIdentifier = @"popover.row.ai.cursor.api";
        NSColor *ink = [self aiSnapshotStaleWarns:u] ? NSColor.systemOrangeColor : AIQuotaColor(api);
        NSString *apiTip = [NSString stringWithFormat:@"Cursor API · %.0f%% left", api * 100];
        NSTextField *apiName = [self text:@"API" font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                                    color:NSColor.secondaryLabelColor
                                       at:NSMakeRect(kAINameX, (kRowH - 16) / 2.0, kAINameW, 16) align:NSTextAlignmentLeft];
        apiName.accessibilityIdentifier = @"popover.ai.cursor.api.name";
        [apiRow addSubview:apiName];
        Gauge *apiBar = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        apiBar.fraction = api; apiBar.color = ink;
        apiBar.metricLabel = @"Cursor API remaining";
        apiBar.accessibilityIdentifier = @"popover.ai.cursor.api.gauge";
        [apiRow addSubview:apiBar];
        [self instrumentValue:[NSString stringWithFormat:@"%.0f%%", api * 100] color:ink
                   identifier:@"popover.ai.cursor.api.value" in:apiRow];
        apiRow.accessibilityHelp = apiTip;
        for (NSView *sub in apiRow.subviews) sub.accessibilityHelp = apiTip;
        [root addSubview:apiRow];
        y += kRowH;
    }
    return y;
}

- (NSString *)aiOverviewText {
    AIUsage *lowest = [self lowestAIStatus];
    if (lowest) return [NSString stringWithFormat:@"%@ %@ remaining · %@",
                        lowest.name, [self aiPercentText:lowest], [self aiStatusSubtext:lowest]];
    return @"Limit status unavailable";
}

- (NSString *)shortAgeForDate:(NSDate *)date {
    if (!date) return @"pending";
    NSTimeInterval age = MAX(0, -date.timeIntervalSinceNow);
    if (age < 10) return @"now";
    if (age < 60) return [NSString stringWithFormat:@"%.0fs ago", age];
    if (age < 3600) return [NSString stringWithFormat:@"%.0fm ago", age / 60.0];
    return [NSString stringWithFormat:@"%.0fh ago", age / 3600.0];
}

- (NSDictionary *)meteredFigures {
    NSDate *now = NSDate.date;
    NSString *link = _metered[@"link"];
    int day = MeteredResetDay(link);
    NSTimeZone *zone = MeteredZone(link);
    NSDate *start = MeteredCycleStartInZone(now, day, zone), *end = MeteredCycleEndInZone(now, day, zone);
    BOOL current = fabs([_metered[@"cycleStart"] doubleValue] - start.timeIntervalSince1970) < 1;
    double down = current ? [_metered[@"downloadBytes"] doubleValue] / 1e9 : 0;
    double up = current ? [_metered[@"uploadBytes"] doubleValue] / 1e9 : 0;
    double cap = MeteredCapGB(link), used = down + up;
    double recent = current ? [_metered[@"recentBytesPerSecond"] doubleValue] : 0;
    NSString *rate = [NSString stringWithFormat:@"now %.1f MB/s · %@ GB/h last hour",
        current ? [_metered[@"bytesPerSecond"] doubleValue] / 1e6 : 0,
        recent > 0 ? [NSString stringWithFormat:@"%.1f", recent * 3600 / 1e9] : @"—"];
    // The account counts every device; the Mac's bytes since the last read keep it live.
    NSDictionary *account = [_metered[@"account"] isKindOfClass:NSDictionary.class] ? _metered[@"account"] : nil;
    double accountEnd = [account[@"cycleEnd"] doubleValue];
    BOOL accountCurrent = [account[@"usedGB"] isKindOfClass:NSNumber.class] &&
        [account[@"cycleStart"] doubleValue] <= now.timeIntervalSince1970 && now.timeIntervalSince1970 < accountEnd;
    NSString *headline;
    if (accountCurrent) {
        double since = [account[@"macCycleStart"] doubleValue] == [_metered[@"cycleStart"] doubleValue] && current
            ? MAX(0, used * 1e9 - [account[@"macBytes"] doubleValue]) / 1e9 : 0;
        int age = (int)MAX(0, lround((now.timeIntervalSince1970 - [account[@"fetchedAt"] doubleValue]) / 60));
        end = [NSDate dateWithTimeIntervalSince1970:accountEnd];
        headline = [NSString stringWithFormat:@"%@ %.1f GB of %g GB · read %@ ago%@\nMac ↓ %.1f GB  ↑ %.1f GB",
            MeteredName(link), [account[@"usedGB"] doubleValue] + since, cap,
            age < 60 ? [NSString stringWithFormat:@"%d min", age] : [NSString stringWithFormat:@"%d h", age / 60],
            since >= 0.05 ? [NSString stringWithFormat:@" + Mac %.1f", since] : @"", down, up];
        used = [account[@"usedGB"] doubleValue] + since;
    } else {
        headline = [NSString stringWithFormat:@"Mac %.1f GB of %g GB\n↓ %.1f GB  ↑ %.1f GB", used, cap, down, up];
    }
    double fraction = MAX(0, MIN(1, 1 - used / cap));
    NSDictionary *choice = MeteredAllowanceDatum(MAX(0, cap - used) * 1e9, recent, now, end);
    NSMutableString *tip = [NSMutableString stringWithFormat:@"%@\n%@", headline, rate];
    if ([account[@"problem"] isKindOfClass:NSString.class]) [tip appendFormat:@"\naccount: %@", account[@"problem"]];
    if ([choice[@"urgency"] intValue] > 0) [tip appendFormat:@"\n%@", choice[@"reset"]];
    return @{@"fraction": @(fraction), @"urgency": choice[@"urgency"], @"account": @(accountCurrent),
             @"value": [NSString stringWithFormat:@"%.0f%%", fraction * 100],
             @"datum": choice[@"datum"], @"tip": tip};
}
- (NSColor *)meteredDatumColor:(NSDictionary *)figures {
    int urgency = [figures[@"urgency"] intValue];
    return urgency == 2 ? NSColor.systemRedColor : urgency == 1 ? NSColor.systemYellowColor : NSColor.secondaryLabelColor;
}

- (CGFloat)addMeteredTo:(NSView *)root at:(CGFloat)y {
    if (![_metered[@"onLink"] boolValue]) return y;
    NSString *link = _metered[@"link"];
    NSDictionary *figures = [self meteredFigures];
    double fraction = [figures[@"fraction"] doubleValue];
    NSColor *color = AIQuotaColor(fraction);
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
    row.accessibilityIdentifier = [NSString stringWithFormat:@"popover.row.%@", link];
    row.accessibilityHelp = figures[@"tip"];
    row.accessibilityLabel = [[MeteredName(link) stringByAppendingString:@" — "] stringByAppendingString:figures[@"tip"]];
    [self instrumentSymbol:MeteredSymbol(link) tint:color identifier:[NSString stringWithFormat:@"popover.%@.symbol", link] in:row];
    [self instrumentName:MeteredName(link) identifier:[NSString stringWithFormat:@"popover.%@.name", link] in:row];
    Gauge *gauge = [[Gauge alloc] initWithFrame:RowGaugeRect()];
    gauge.fraction = fraction;
    gauge.markerFraction = -1;
    gauge.color = color;
    gauge.metricLabel = [MeteredName(link) stringByAppendingString:[figures[@"account"] boolValue] ? @" data remaining" : @" Mac data remaining"];
    gauge.accessibilityIdentifier = [NSString stringWithFormat:@"popover.%@.gauge", link];
    [row addSubview:gauge];
    [self instrumentValue:figures[@"value"] color:color identifier:[NSString stringWithFormat:@"popover.%@.value", link] in:row];
    [self instrumentDatum:figures[@"datum"] color:[self meteredDatumColor:figures] identifier:[NSString stringWithFormat:@"popover.%@.datum", link] in:row];
    for (NSView *child in row.subviews) child.accessibilityHelp = figures[@"tip"];
    [root addSubview:row];
    return y + kRowH;
}

// Explicit diagnostic launch only: at most two minutes of the running controller's
// real battery state and the production row, rendered offscreen without opening UI.
- (void)captureBatteryDiagnosticIfRequested {
    const char *directory = getenv("GLANCEBAR_BATTERY_DEBUG_DIR");
    if (!directory || !*directory) return;
    NSString *path = [NSString stringWithUTF8String:directory];
    BOOL isDirectory = NO;
    if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return;
    double now = NSDate.date.timeIntervalSince1970;
    if (!_batteryDebugStarted) _batteryDebugStarted = now;
    if (now - _batteryDebugStarted > 120 || (_batteryDebugLast && now - _batteryDebugLast < 14)) return;
    _batteryDebugLast = now;
    ClickRow *row = [self batteryInstrumentRow];
    BatteryForecastView *view = nil;
    for (NSView *child in row.subviews) if ([child isKindOfClass:BatteryForecastView.class]) view = (BatteryForecastView *)child;
    if (!view) return;
    BatteryForecast f = view.forecast;
    NSDictionary *record = @{@"at":@(now), @"elapsed":@(now - _batteryDebugStarted), @"pid":@(getpid()),
        @"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"test",
        @"percent":@(_bat.percent), @"charging":@(_bat.isCharging), @"ac":@(_bat.acConnected),
        @"current_mAh":@(_bat.rawCurrent_mAh), @"full_mAh":@(_bat.rawMax_mAh), @"current_mA":@(_bat.amperage_mA),
        @"systemFullMinutes":@(_bat.minutesToFull), @"telemetryAge":@(now - _bat.telemetryTimestamp),
        @"chargeMode":[self effectiveChargeMode], @"hypotheticalFull":@(f.hypotheticalFull), @"hideLabels":@(f.hideLabels),
        @"thresholdFromSystem":@(f.thresholdFromSystem),
        @"thresholdArrival":@(f.thresholdTime), @"endpointArrival":@(f.endpointTime),
        @"thresholdLabel":view.thresholdText ?: @"", @"endpointLabel":view.endpointText ?: @"", @"accessibilityHelp":view.accessibilityHelp ?: @"",
        @"thresholdCenterX":@(NSMinX(view.frame)+NSMidX([view labelRect:YES])),
        @"endpointCenterX":@(NSMinX(view.frame)+NSMidX([view labelRect:NO])),
        @"gaugeStartX":@(RowGaugeX()), @"gaugeWidth":@(RowGaugeW())};
    NSString *stem = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"live-%03d", (int)lround(now - _batteryDebugStarted)]];
    [[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
        writeToFile:[stem stringByAppendingString:@".json"] atomically:YES];
    for (NSString *name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        PopoverRootView *host = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0,0,kW,kRowH)];
        host.appearance = [NSAppearance appearanceNamed:name];
        [host addSubview:row];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)kW pixelsHigh:(NSInteger)kRowH bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
        NSString *suffix = [name isEqual:NSAppearanceNameAqua] ? @"-light.png" : @"-dark.png";
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[stem stringByAppendingString:suffix] atomically:YES];
    }
}

// While plugged in but still draining, the charger is its own plain row under Battery:
// the bar is the share of the Mac's draw it covers, the value what it delivers.
- (NSView *)chargerInstrumentRow {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    row.accessibilityIdentifier = @"popover.row.charger";
    NSTextField *name = [self text:@"Charger" font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                             color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kAINameX, (kRowH - 16) / 2.0, kAINameW, 16) align:NSTextAlignmentLeft];
    name.accessibilityIdentifier = @"popover.charger.name";
    [row addSubview:name];
    Gauge *bar = [[Gauge alloc] initWithFrame:RowGaugeRect()];
    bar.metricLabel = @"Share of the Mac's draw the charger covers";
    bar.accessibilityIdentifier = @"popover.charger.gauge";
    [row addSubview:bar];
    [self instrumentValue:@"" color:nil identifier:@"popover.charger.value" in:row];
    [self instrumentDatum:@"" color:NSColor.secondaryLabelColor identifier:@"popover.charger.datum" in:row];
    [self configureChargerRow:row];
    return row;
}
- (void)configureChargerRow:(NSView *)row {
    double in = _bat.systemPowerIn_mW / 1000.0, load = _bat.systemLoad_mW / 1000.0;
    BOOL loadKnown = _bat.systemLoad_mW != LONG_MIN && load > 0;
    Gauge *bar = (Gauge *)ViewWithAccessibilityIdentifier(row, @"popover.charger.gauge");
    if ([bar isKindOfClass:Gauge.class]) {
        bar.fraction = loadKnown ? MIN(1, MAX(0, in / load)) : 0;
        bar.color = in < 1 ? NSColor.systemRedColor : NSColor.systemGreenColor;
        bar.needsDisplay = YES;
    }
    NSTextField *value = (NSTextField *)ViewWithAccessibilityIdentifier(row, @"popover.charger.value");
    value.stringValue = [NSString stringWithFormat:@"%.0f W", in];
    value.textColor = in < 1 ? NSColor.systemYellowColor : NSColor.labelColor;
    NSTextField *datum = (NSTextField *)ViewWithAccessibilityIdentifier(row, @"popover.charger.datum");
    datum.stringValue = loadKnown ? [NSString stringWithFormat:@"Mac %.0f W", load] : @"";
    NSString *tip = _bat.adapterWatts > 0
        ? [NSString stringWithFormat:@"%ld W charger", _bat.adapterWatts] : @"Charger";
    row.accessibilityLabel = [NSString stringWithFormat:@"Charger %.0f W of the Mac's %.0f W", in, load];
    row.accessibilityHelp = tip;
}

- (ClickRow *)batteryInstrumentRow {
    ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    row.target = self;
    row.action = @selector(showBatteryDetails:);
    row.accessibilityRole = NSAccessibilityButtonRole;
    row.accessibilityIdentifier = @"popover.row.battery";
    NSString *tip = [self batteryPopoverTip];
    row.accessibilityHelp = tip;
    row.accessibilityLabel = tip;
    if (_bat.valid) {
        NSImage *batteryImage = [self liveBatteryGlyph];
        NSButton *symbol = [NSButton buttonWithImage:batteryImage target:self action:@selector(toggleChargeLimit:)];
        symbol.title = @"";
        symbol.bordered = NO;
        symbol.imagePosition = NSImageOnly;
        symbol.imageScaling = NSImageScaleProportionallyDown;
        symbol.contentTintColor = batteryImage.template ? PowerFlowColor(_bat, NSColor.labelColor) : nil;
        symbol.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2.0, kLeadW, kLeadSymbol);
        symbol.accessibilityIdentifier = @"popover.battery.symbol";
        symbol.accessibilityHelp = [self chargeLimitTooltip];
        symbol.accessibilityLabel = symbol.accessibilityHelp;
        [row addSubview:symbol];
        [self instrumentName:@"Battery" identifier:@"popover.battery.name" in:row];
        Gauge *g = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        g.fraction = _bat.percent / 100.0;
        g.markerFraction = [[self effectiveChargeMode] isEqualToString:@"limit80"] ? 0.80 : -1;
        g.color = BattBarColor(_bat.percent);
        g.metricLabel = @"Battery charge";
        g.accessibilityIdentifier = @"popover.battery.gauge";
        g.accessibilityHelp = tip;
        [row addSubview:g];
        NSTextField *value = [self instrumentValue:[NSString stringWithFormat:@"%d%%", _bat.percent]
                                            color:BattBarColor(_bat.percent)
                                       identifier:@"popover.battery.value" in:row];
        value.accessibilityHelp = tip;
        [self addBatteryTrendTo:row gauge:g datum:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2.0, kDatumW, kDatumH)
                           stem:@"popover.battery" tip:tip];
    } else {
        [self instrumentSymbol:@"battery.0" tint:NSColor.tertiaryLabelColor
                   identifier:@"popover.battery.symbol" in:row];
    [self instrumentName:@"Battery" identifier:@"popover.battery.name" in:row];
        NSTextField *value = [self instrumentValue:@"—" color:NSColor.tertiaryLabelColor
                                       identifier:@"popover.battery.value" in:row];
        value.accessibilityHelp = tip;
        [self instrumentDatum:@"" color:nil identifier:@"popover.battery.datum" in:row];
    }
    return row;
}

- (void)rebuildContent {
    CFAbsoluteTime rebuildStarted = CFAbsoluteTimeGetCurrent();
    _popoverPrepared=YES;
      // Playback scale harness: frozen mix, popover never shown, music off — skip full tree rebuild.
    if (!_popover.isShown && _mixFrozen && _musicOff) {
        SetRowNameW([self popoverNameColumnWidth]);
        return;
    }
    SetRowNameW([self popoverNameColumnWidth]);
    [self refreshChargeShortcutsIfStale];
    // macOS 13 throws if a bare NSViewController is asked for a view it never loaded
    // (it looks for a nib); 14 quietly makes an empty one. The first build has none.
    NSViewController *previous = _popover.contentViewController;
    NSView *previousView = previous.isViewLoaded ? previous.view : nil;
    NSWindow *popoverWindow = previousView.window;
    NSDictionary *focusSnapshot = [self focusSnapshotForWindow:popoverWindow rootView:previousView];
    FlippedView *root = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0,0,kW,2000)];
    CGFloat y = 8;   // no header row any more; the first instrument starts at the top

    // Machine group. No section labels: the symbol's colour is the state, and the
    // name, the sentence and the breakdown live on the row's tooltip and in Details.
    if (!_vols.count) {
        NSString *status = VolumeScanStatus(_volumesLoading, _volumesUnavailable);
        NSTextField *statusField = [self text:status font:[NSFont systemFontOfSize:12]
                                          color:NSColor.secondaryLabelColor
                                             at:NSMakeRect(kPad, y, kW-2*kPad, 16)
                                          align:NSTextAlignmentLeft];
        statusField.accessibilityIdentifier = @"popover.storage.status";
        [root addSubview:statusField];
        y += kRowH;
    }
    Volume *leadVolume = [self primaryVolume];
    NSDictionary *secondaryNotice = [self storageSecondaryNotice];
    if (leadVolume) {
        Volume *v = leadVolume;
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showStorageDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.storage";
        NSMutableString *tip = [NSMutableString stringWithFormat:@"%@ · %@", v.name ?: @"Disk", CompactByteCount(v.total)];
        if (v.purgeable > 0) [tip appendFormat:@" · %@ purgeable", CompactByteCount(v.purgeable)];
        if ([secondaryNotice[@"text"] isKindOfClass:NSString.class])
            [tip appendFormat:@"\n%@", secondaryNotice[@"text"]];
        row.accessibilityHelp = tip;
        row.accessibilityLabel = tip;
        // A second mount over 85% full is the alarm: it tints the symbol and is named above.
        NSColor *symbolTint = secondaryNotice ? DiskColor([secondaryNotice[@"fraction"] doubleValue])
                                              : DiskColor(v.fraction);
        [self instrumentSymbol:(v.isInternal ? @"internaldrive" : @"externaldrive")
                         tint:symbolTint identifier:@"popover.storage.symbol" in:row];
        [self instrumentName:@"Storage" identifier:@"popover.storage.name" in:row];
        Gauge *g = [[Gauge alloc] initWithFrame:RowGaugeRect()];
        g.fraction = v.fraction;
        g.color = DiskColor(v.fraction);
        g.metricLabel = [NSString stringWithFormat:@"%@ storage used", v.name];
        g.accessibilityIdentifier = @"popover.storage.gauge";
        g.accessibilityHelp = tip;
        [row addSubview:g];
        NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(v.fraction * 100)];
        NSTextField *value = [self instrumentValue:pct color:DiskColor(v.fraction)
                                        identifier:@"popover.storage.value" in:row];
        value.accessibilityHelp = tip;
        value.accessibilityLabel = [NSString stringWithFormat:@"%@ percent used", pct];
        NSTextField *datum = [self instrumentDatum:[NSString stringWithFormat:@"%@ free", CompactByteCount(v.available)]
                                            color:NSColor.secondaryLabelColor
                                       identifier:@"popover.storage.datum" in:row];
        datum.accessibilityHelp = tip;
        [root addSubview:row];
        y += kRowH;
    }
    y = [self addPopoverExternalStorageTo:root at:y];

    ClickRow *batteryRow = [self batteryInstrumentRow];
    batteryRow.frame = NSMakeRect(0, y, kW, kRowH);
    [root addSubview:batteryRow];
    y += kRowH;
    _chargerRowShown = ChargerFallsShort(_bat);
    if (_chargerRowShown) {
        NSView *charger = [self chargerInstrumentRow];
        charger.frame = NSMakeRect(0, y, kW, kRowH);
        [root addSubview:charger];
        y += kRowH;
    }

    y = [self addBurnRowTo:root at:y];

    {
        NSString *sysLevel = SystemPressureLevel(_sys);
        NSString *summary = SystemSummaryText(_sys);
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showSystemDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.system";
        row.accessibilityHelp = summary;
        row.accessibilityLabel = summary;
        [self instrumentSymbol:@"cpu" tint:SystemPressureColor(sysLevel)
                   identifier:@"popover.system.symbol" in:row];
        [self instrumentName:@"System" identifier:@"popover.system.name" in:row];
        [self addSystemInstrumentTo:row
                              gauge:RowGaugeRect()
                              value:NSMakeRect(kValueX, (kRowH - kValueH) / 2.0, kValueW, kValueH)
                              datum:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2.0, kDatumW, kDatumH)
                               stem:@"popover.system" tip:summary];
        [root addSubview:row];
        y += kRowH;
    }
    if ([self heatShowing]) {
        NSString *tip = [self heatTip];
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showThermalDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.heat";
        row.accessibilityHelp = tip;
        row.accessibilityLabel = tip;
        [self instrumentSymbol:[self heatSymbol] tint:[self heatSymbolColor] identifier:@"popover.heat.symbol" in:row];
        [self instrumentName:@"Speed" identifier:@"popover.heat.name" in:row];
        [self addHeatInstrumentTo:row
                            gauge:RowGaugeRect()
                            value:NSMakeRect(kValueX, (kRowH - kValueH) / 2.0, kValueW, kValueH)
                            datum:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2.0, kDatumW, kDatumH)
                             stem:@"popover.heat" tip:tip];
        [root addSubview:row];
        y += kRowH;
    }
    y = [self addRemoteMachinesTo:root at:y];

    y = [self addMeteredTo:root at:y];

    y += 8;
    NSBox *soundRule = [self dividerAt:y];
    soundRule.accessibilityIdentifier = @"popover.divider.sound";
    [root addSubview:soundRule];
    y += 8;
    y = [self addMusicControlsTo:root at:y];

    y += 6;
    NSBox *aiRule = [self dividerAt:y];
    aiRule.accessibilityIdentifier = @"popover.divider.ai";
    [root addSubview:aiRule];
    y += 8;
    if (!_aiUsage.count) {
        NSTextField *empty = [self text:@"Limit status unavailable" font:[NSFont systemFontOfSize:12]
                                  color:NSColor.secondaryLabelColor
                                     at:NSMakeRect(kPad, y, kW - 2 * kPad, 16) align:NSTextAlignmentLeft];
        empty.accessibilityIdentifier = @"popover.ai.empty";
        [root addSubview:empty];
        y += kRowH;
    } else {
        for (AIUsage *u in _aiUsage)
            y = [self addAICard:u toView:root width:kW pad:kPad at:y];
    }

    // ---------- fixed footer ----------
    // Keep navigation and freshness visible even when the metric document is
    // taller than the current display and needs to scroll.
    y += 2;
    NSString *freshness = _aiTotalsIncomplete && _aiCatchUpStatus.length
        ? _aiCatchUpStatus
        : [NSString stringWithFormat:@"Checked: machine %@ · AI %@",
           [self shortAgeForDate:_lastMachineRefresh], [self shortAgeForDate:_lastAIRefresh]];
    const CGFloat footerH = kToggleH + 12;   // 6pt above and below the icon toggles
    // Fills windowBackgroundColor in drawRect: instead of freezing it into a CALayer CGColor,
    // so the footer follows a live Light/Dark switch like the panel above it.
    PopoverRootView *footer = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, footerH)];
    NSBox *footerRule = [self dividerAt:0];
    footerRule.accessibilityIdentifier = @"popover.divider.footer";
    [footer addSubview:footerRule];
    NSView *foot = [[NSView alloc] initWithFrame:NSMakeRect(0, 6, kW, kToggleH)];
    _keepAwakeButton = [self powerToggle:@"Keep Awake" symbol:@"cup.and.saucer.fill"
                                   action:@selector(toggleKeepAwake:)];
    _keepAwakeButton.accessibilityIdentifier = @"popover.keepAwake";
    _lowPowerButton = [self powerToggle:@"Low Power" symbol:@"tortoise.fill" action:@selector(toggleLowPowerMode:)];
    _lowPowerButton.accessibilityIdentifier = @"popover.lowPower";
    _chargeButton = nil;
    if (_bat.valid) {   // desktop Macs have no charge limit to set
        _chargeButton = [self powerToggle:@"Limit 80%" symbol:@"battery.75" action:@selector(toggleChargeLimit:)];
        _chargeButton.accessibilityIdentifier = @"popover.chargeLimit";
    }
    [self syncPowerButtons];
    [foot addSubview:_keepAwakeButton];
    [foot addSubview:_lowPowerButton];
    if (_chargeButton) [foot addSubview:_chargeButton];
    NSImageSymbolConfiguration *moreCfg = [NSImageSymbolConfiguration configurationWithPointSize:kLeadSymbol
                                                                                         weight:NSFontWeightRegular];
    NSImage *moreImage = [[NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:@"More"]
                          imageWithSymbolConfiguration:moreCfg];
    NSButton *more = [NSButton buttonWithImage:moreImage target:self action:@selector(showMenu:)];
    more.title = @"";   // buttonWithImage: leaves the stock "Button" title
    more.bordered = NO;
    more.imagePosition = NSImageOnly;
    more.imageScaling = NSImageScaleProportionallyDown;
    more.contentTintColor = NSColor.secondaryLabelColor;
    more.frame = NSMakeRect(kW - kPad - kToggleH, 0, kToggleH, kToggleH);
    more.accessibilityHelp = [@"Details, settings and Quit. " stringByAppendingString:freshness];
    more.accessibilityIdentifier = @"popover.more";
    [foot addSubview:more];
    [footer addSubview:foot];

    root.frame = NSMakeRect(0, 0, kW, MAX(y, 1));
    NSScreen *screen = _item.button.window.screen ?: NSScreen.mainScreen;
    CGFloat maxPopoverH = 720;
    if (screen) maxPopoverH = MIN(maxPopoverH, MAX(360.0, screen.visibleFrame.size.height - 72.0));
    NSView *freshView = nil;
    NSScrollView *freshScroll = nil;
    if (y + footerH > maxPopoverH) {
        // Preserve position across periodic rebuilds; togglePopover: clears the
        // stored scroll view so every newly opened popover starts at the top.
        CGFloat offset = _popoverScroll ? _popoverScroll.contentView.bounds.origin.y : 0;
        CGFloat scrollH = maxPopoverH - footerH;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kW, scrollH)];
        scroll.borderType = NSNoBorder;
        scroll.drawsBackground = YES;
        scroll.backgroundColor = NSColor.windowBackgroundColor;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.documentView = root;
        [scroll.contentView scrollToPoint:NSMakePoint(0, MIN(offset, MAX(0, y - scrollH)))];
        [scroll reflectScrolledClipView:scroll.contentView];
        FlippedView *container = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kW, maxPopoverH)];
        footer.frame = NSMakeRect(0, scrollH, kW, footerH);
        [container addSubview:scroll];
        [container addSubview:footer];
        freshView = container;
        freshScroll = scroll;
        _popover.contentSize = NSMakeSize(kW, maxPopoverH);
    } else {
        footer.frame = NSMakeRect(0, y, kW, footerH);
        [root addSubview:footer];
        root.frame = NSMakeRect(0, 0, kW, y + footerH);
        freshView = root;
        _popover.contentSize = NSMakeSize(kW, y + footerH);
    }
    [self syncTrackTick];
    if (ReconcileViewTree(previousView, freshView)) {
        _popoverScroll = FirstScrollView(previousView);
        // The outlets were assigned on the discarded fresh tree; point them at the buttons
        // that are actually on screen, or syncPowerButtons styles detached copies.
        NSButton *keepAwake = (NSButton *)ViewWithAccessibilityIdentifier(previousView, @"popover.keepAwake");
        NSButton *lowPower = (NSButton *)ViewWithAccessibilityIdentifier(previousView, @"popover.lowPower");
        NSButton *charge = (NSButton *)ViewWithAccessibilityIdentifier(previousView, @"popover.chargeLimit");
        if ([charge isKindOfClass:NSButton.class]) _chargeButton = charge;
        if ([keepAwake isKindOfClass:NSButton.class]) _keepAwakeButton = keepAwake;
        if ([lowPower isKindOfClass:NSButton.class]) _lowPowerButton = lowPower;
    } else {
        _popover.contentViewController.view = freshView;
        _popoverScroll = freshScroll;
        [self restoreFocus:focusSnapshot inView:freshView window:popoverWindow];
    }
    if (_fleetFocusPending && _popover.isShown && !_remoteInFlight.count) {
        [self focusFleetRows];
        _fleetFocusPending = NO; // no later refresh may override manual scrolling
    }
    _popoverLastRebuildMs = (CFAbsoluteTimeGetCurrent() - rebuildStarted) * 1000.0;
}

// 16pt template glyph. Every actionable menu item, Details tab, and instrument heading
// goes through here so the small-symbol size cannot drift.
- (NSImage *)menuSymbol:(NSString *)name {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                                     weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                      imageWithSymbolConfiguration:cfg];
    if (!image)
        image = [[NSImage imageWithSystemSymbolName:@"circle.dashed" accessibilityDescription:nil]
                 imageWithSymbolConfiguration:cfg];
    image.template = YES;
    return image;
}

// One short menu off the footer's ⋯: the things you reach for, then everything that is
// set once and left alone tucked into Settings.
- (NSMenu *)moreMenu {
    NSMenu *m = [NSMenu new];
    NSMenuItem *details = [m addItemWithTitle:@"Details…" action:@selector(showDetails:) keyEquivalent:@""];
    details.target = self;
    details.image = [self menuSymbol:@"rectangle.grid.1x2"];
    NSMenuItem *activity = [m addItemWithTitle:@"Activity…" action:@selector(showActivityDetails:) keyEquivalent:@""];
    activity.target = self;
    activity.image = [self menuSymbol:@"waveform.path.ecg"];
    NSMenuItem *settings = [m addItemWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settings.image = [self menuSymbol:@"gearshape"];
    settings.submenu = [self settingsMenu];
    NSString *switchSymbol = [NSImage imageWithSystemSymbolName:@"hifispeaker.and.appletv" accessibilityDescription:nil]
        ? @"hifispeaker.and.appletv" : @"speaker.badge.plus";
    NSMenuItem *switchOutputs = [m addItemWithTitle:@"Switch to new outputs" action:@selector(toggleSwitchToNewOutputs:) keyEquivalent:@""];
    switchOutputs.target = self;
    switchOutputs.image = [self menuSymbol:switchSymbol];
    switchOutputs.state = SwitchToNewOutputs() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *about = [m addItemWithTitle:@"About Glancebar" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    about.image = [self menuSymbol:@"info.circle"];
    NSMenuItem *quit = [m addItemWithTitle:@"Quit Glancebar" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    quit.image = [self menuSymbol:@"power"];
    return m;
}
- (void)showMenu:(NSButton *)sender {
    [[self moreMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}
- (void)addSection:(NSMenu *)m title:(NSString *)title {
    if (m.numberOfItems) [m addItem:NSMenuItem.separatorItem];
    if (@available(macOS 14.0, *)) { [m addItem:[NSMenuItem sectionHeaderWithTitle:title]]; return; }
    [m addItemWithTitle:title action:nil keyEquivalent:@""].enabled = NO;
}
- (NSMenuItem *)settingsItem:(NSMenu *)m title:(NSString *)title symbol:(NSString *)symbol action:(SEL)action on:(BOOL)on {
    NSMenuItem *item = [m addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.image = [self menuSymbol:symbol];
    item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}
- (NSMenu *)settingsMenu {
    NSMenu *m = [NSMenu new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self addSection:m title:@"Menu bar"];
    [self settingsItem:m title:@"Storage" symbol:@"internaldrive" action:@selector(toggleBarDisk:) on:_barShowDisk];
    [self settingsItem:m title:@"Battery" symbol:@"battery.100" action:@selector(toggleBarBattery:) on:_barShowBattery];
    [self settingsItem:m title:@"System" symbol:@"cpu" action:@selector(toggleBarSystem:) on:_barShowSystem];

    [self addSection:m title:@"Panel"];
    [self settingsItem:m title:@"Speed row always" symbol:@"gauge.with.dots.needle.67percent"
                    action:@selector(toggleSpeedAlways:)
                    on:[ud boolForKey:@"speedAlways"]].accessibilityHelp = @"Keep the Speed row (fast-core clock, chip and cell temperatures) up while the Mac is cool, instead of only under thermal pressure.";

    [self addSection:m title:@"Battery"];
    [self settingsItem:m title:@"Current draw" symbol:@"bolt" action:@selector(toggleWatts:) on:_showWatts].enabled = _bat.valid;
    [self settingsItem:m title:@"Health" symbol:@"heart" action:@selector(toggleHealth:) on:_showHealth].enabled = _bat.valid;
    NSMenuItem *guard = [self settingsItem:m title:@"Low Power when battery is hot" symbol:@"thermometer.medium"
                                    action:@selector(toggleHeatGuard:) on:[ud boolForKey:@"heatGuard"]];
    guard.enabled = _bat.valid && PmsetRuleInstalled();
    guard.accessibilityHelp = PmsetRuleInstalled() ? @"On at 38 °C, off again at 35 °C"
                                                   : @"Needs Keep Awake & Low Power without a password";
    [self settingsItem:m title:@"Keep Awake & Low Power without a password" symbol:@"lock.open"
                    action:@selector(togglePmsetRule:)
                    on:PmsetRuleInstalled()].accessibilityHelp = @"Installs or removes a sudoers rule limited to four pmset commands (needs your password once).";

    [self addSection:m title:@"AI status"];
    [self settingsItem:m title:@"Low Data · Glancebar" symbol:@"arrow.down.circle"
                    action:@selector(toggleLowData:) on:GBLowDataEnabled()].accessibilityHelp = GBLowDataTip;
    [self settingsItem:m title:@"Claude transcript token totals" symbol:@"doc.text"
                    action:@selector(toggleClaudeTranscripts:)
                    on:[ud boolForKey:@"useClaudeTranscripts"]];
    NSMenuItem *claudeAccount = [self settingsItem:m title:@"Claude account via Keychain/API…" symbol:@"sparkle"
                    action:@selector(toggleClaudeAccount:)
                    on:[ud boolForKey:@"useClaudeAccount"]];
    NSImage *claudeLogo = AIProviderLogo(@"Claude", 16);
    if (claudeLogo) claudeAccount.image = claudeLogo;
    if (CursorServicePresent(GBHomeDirectory())) {
        NSMenuItem *cursorAccount = [self settingsItem:m title:@"Cursor account via local session/API…" symbol:@"cursorarrow.rays"
                        action:@selector(toggleCursorAccount:)
                        on:[ud boolForKey:@"useCursorAccount"]];
        NSImage *cursorLogo = AIProviderLogo(@"Cursor", 16);
        if (cursorLogo) cursorAccount.image = cursorLogo;
    }

    [m addItem:NSMenuItem.separatorItem];
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    NSMenuItem *login = [self settingsItem:m title:loginStatus == SMAppServiceStatusRequiresApproval
                                                    ? @"Launch at Login (approve in System Settings)" : @"Launch at Login"
                                    symbol:@"power.circle"
                                    action:@selector(toggleLaunchAtLogin:) on:loginStatus == SMAppServiceStatusEnabled];
    if (loginStatus == SMAppServiceStatusRequiresApproval) login.state = NSControlStateValueMixed;
    return m;
}

// Explicit opt-in: `/usr/bin/security` performs an Apple-tool-authorized, normally silent
// read of Claude Code's credential, so the app itself—not a system prompt—must explain and
// obtain consent before the token is read or sent to Anthropic's usage endpoint.
- (void)toggleClaudeAccount:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useClaudeAccount"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Enable Claude account status?";
        alert.informativeText = @"Glancebar will ask Apple’s /usr/bin/security tool to read the Claude Code OAuth credential from your Keychain. That read is normally silent—macOS may not show its own permission dialog. Glancebar keeps the token only in memory and sends it only to api.anthropic.com to request your usage limits, at most every 15 minutes. This relies on Claude Code’s private Keychain layout and an undocumented account endpoint, so it may stop working after an update.";
        [alert addButtonWithTitle:@"Enable"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useClaudeAccount"];
    if (!enabling) dispatch_async(_aiQueue, ^{ [self->_aiReader forgetClaudeAccountCredentials]; });
    [self refresh];
}
- (void)toggleCursorAccount:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useCursorAccount"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Enable Cursor account status?";
        alert.informativeText = @"Glancebar will read the signed-in Cursor session token from Cursor’s local state database (state.vscdb) and, for the Cursor CLI, from your Keychain through Apple’s /usr/bin/security tool, using whichever is current. It keeps the token only in memory and sends it only to api2.cursor.sh to request your included usage limits, at most every 15 minutes. This relies on Cursor’s private local layout and undocumented account endpoints, so it may stop working after an update.";
        [alert addButtonWithTitle:@"Enable"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useCursorAccount"];
    if (!enabling) dispatch_async(_aiQueue, ^{ [self->_aiReader forgetCursorAccountCredentials]; });
    [self refresh];
}
- (void)toggleClaudeTranscripts:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useClaudeTranscripts"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Read Claude transcript usage counters?";
        alert.informativeText = @"Claude transcript files contain conversation records. Glancebar scans them locally and never sends transcript contents over the network. Its mode-0600 local index stores only file offsets/identity, daily token and activity totals (per model), timestamps, and opaque per-message hashes—not prompts or responses. The same file also keeps the last account usage response when that toggle is on, never a token.";
        [alert addButtonWithTitle:@"Enable Local Scan"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useClaudeTranscripts"];
    if (!enabling) dispatch_async(_aiQueue, ^{
        self->_aiReader.allowClaudeTranscripts = NO;
        [self->_aiReader purgeClaudeTranscriptIndex];
    });
    [self refresh];
}
// Keep Awake flips the SleepDisabled system power setting: the only switch that also holds
// a closed lid (a caffeinate-style IOPMAssertion defeats idle sleep only). Nothing is
// stored — the live setting is the single source of truth, so the bar and the button
// always agree however it was last changed. It survives a reboot on its own. Quit clears
// it only when the passwordless sudoers rule is installed (applicationWillTerminate:).
- (void)toggleKeepAwake:(id)s {
    [self syncPowerButtons];   // undo the click's own flip until the system confirms
    NSNumber *current = SleepDisabledState();
    if (!current) {
        // Flipping blind could turn the setting ON when the user meant OFF.
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn’t read the current sleep setting";
        alert.informativeText = @"Glancebar couldn’t read a valid power-settings report from pmset -g, so it can’t tell whether Keep Awake is already on. Try again, or check with `pmset -g`.";
        [alert runModal];
        return;
    }
    BOOL enabling = !current.boolValue;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (enabling && ![ud boolForKey:@"keepAwakeExplained"]) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Keep this Mac awake?";
        alert.informativeText = PmsetRuleInstalled()
            ? @"Keep Awake stops the Mac sleeping at all—when idle, and with the lid closed (the display still sleeps). Glancebar switches it off when it quits; if it’s left on some other way, a closed Mac can keep running and overheat in a bag, so the cup in the menu bar stays as a reminder."
            : @"Keep Awake stops the Mac sleeping at all—when idle, and with the lid closed (the display still sleeps). Without the one-click setup it needs your password, and Glancebar leaves it on when it quits; a closed Mac can keep running and overheat in a bag, so the cup in the menu bar stays as a reminder.";
        [alert addButtonWithTitle:@"Keep Awake"];
        [alert addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        [ud setBool:YES forKey:@"keepAwakeExplained"];
    }
    [self applyPmset:@"disablesleep" on:enabling
            reason:enabling ? @"keep this Mac awake" : @"let this Mac sleep again"
              then:^{
        // pmset rewrites the power plist before it exits, so this read is already current.
        NSNumber *state = SleepDisabledState();
        if (state && state.boolValue != self->_lidAwake) {
            self->_lidAwake = state.boolValue;
            [self syncPowerButtons];
            [self updateBar];
        }
        [self refreshLidAwakeForced:YES];
    }];
}
// The battery heat guard: Low Power on while the cells are warm, off once cool, undoing only
// its own switch. It acts only through the sudoers rule, never with a password prompt.
- (void)runHeatGuard {
    if (!ShouldStartPmset(_pmsetInFlight)) return;   // judge Low Power once the last switch has landed
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"heatGuard"] && PmsetRuleInstalled();
    HeatGuardAction action = HeatGuardStep(enabled, _bat.tempC, LowPowerModeEnabled(), &_heatGuard);
    [NSUserDefaults.standardUserDefaults setInteger:_heatGuard forKey:@"heatGuardState"];
    if (action == HeatGuardNothing) return;
    BOOL on = action == HeatGuardEnable;
    [self applyPmset:@"lowpowermode" on:on reason:on ? @"turn on Low Power Mode" : @"turn off Low Power Mode" then:^{
        [self syncPowerButtons];
        [self updateBar];
    }];
}
- (void)toggleHeatGuard:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:![ud boolForKey:@"heatGuard"] forKey:@"heatGuard"];
    [self runHeatGuard];
}

// Flips system Low Power Mode from the footer toggle. Like the lid toggle, the live system
// state is the only truth: nothing is stored, and a cancelled admin prompt just re-reads
// it so the toggle snaps back.
- (void)toggleLowPowerMode:(id)s {
    BOOL enabling = !LowPowerModeEnabled();
    BOOL wasVisible = _popover.isShown || _detailsWindow.isVisible;
    [self syncPowerButtons];   // undo the click's own flip until the system confirms
    [self applyPmset:@"lowpowermode" on:enabling
            reason:enabling ? @"turn on Low Power Mode" : @"turn off Low Power Mode"
              then:^{
        [self syncPowerButtons];
        [self lowPowerFinishedEnabling:enabling active:LowPowerModeEnabled() reveal:wasVisible];
    }];
}
// Applies one pmset flag, then runs `then` on the main queue whatever happened (callers
// re-read live state, so a cancel needs no rollback). With the rule installed: `sudo -n`,
// no prompt. Without it: offer the one-time setup once, else the password prompt.
- (void)applyPmset:(NSString *)setting on:(BOOL)on reason:(NSString *)reason then:(dispatch_block_t)then {
    // sudo/osascript run off the main thread. A second click, or quit, must not start
    // another one until this attempt finishes.
    if (!ShouldStartPmset(_pmsetInFlight)) return;
    _pmsetInFlight = YES;
    dispatch_queue_t work = [self pmsetWorkQueue];
    dispatch_block_t finish = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_pmsetInFlight = NO;
            if (then) then();
        });
    };
    NSString *adminPrompt = [NSString stringWithFormat:@"Glancebar needs administrator access to %@.", reason];
    NSString *command = [NSString stringWithFormat:@"/usr/bin/pmset -a %@ %d", setting, on ? 1 : 0];
    if (PmsetRuleInstalled()) {
        dispatch_async(work, ^{
            if (self->_terminating) { finish(); return; }   // never enable as the app quits
            // A rule that no longer matches (edited, or sudo changed) falls back to the prompt.
            if (!RunPmsetViaSudo(setting, on)) SetPmsetShellViaAdmin(command, adminPrompt);
            finish();
        });
        return;
    }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (![ud boolForKey:@"pmsetTouchIDOffered"]) {
        [ud setBool:YES forKey:@"pmsetTouchIDOffered"];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Switch Low Power and Keep Awake without a password?";
        alert.informativeText = @"macOS asks for your administrator password every time these change. Glancebar can instead add a small rule to /etc/sudoers.d that lets your account run just these four commands—pmset lowpowermode 0/1 and disablesleep 0/1—so the switches work with one click. You’ll type your password once to install it. Remove it any time from ⋯ › Settings.";
        [alert addButtonWithTitle:@"Set Up One-Click"];
        [alert addButtonWithTitle:@"Use Password"];
        [NSApp activateIgnoringOtherApps:YES];
        BOOL setUp = [alert runModal] == NSAlertFirstButtonReturn;
        dispatch_async(work, ^{
            // Just authenticated to install, so apply this first change without asking again.
            if (!(setUp && InstallPmsetRule() && RunPmsetViaSudo(setting, on)))
                SetPmsetShellViaAdmin(command, adminPrompt);
            finish();
        });
        return;
    }
    dispatch_async(work, ^{
        SetPmsetShellViaAdmin(command, adminPrompt);
        finish();
    });
}
- (void)togglePmsetRule:(id)s {
    BOOL installed = PmsetRuleInstalled();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (installed) RemovePmsetRule(); else InstallPmsetRule();
    });
}
- (void)toggleWatts:(id)s {
    _showWatts = !_showWatts;
    [NSUserDefaults.standardUserDefaults setBool:_showWatts forKey:@"showWatts"];
    [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}
- (void)toggleHealth:(id)s {
    _showHealth = !_showHealth;
    [NSUserDefaults.standardUserDefaults setBool:_showHealth forKey:@"showHealth"];
    [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}

- (void)showError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = error ? [NSAlert alertWithError:error] : [NSAlert new];
    if (title.length) alert.messageText = title;
    [alert runModal];
}

- (BOOL)setLaunchAtLoginEnabled:(BOOL)enabled showErrors:(BOOL)showErrors {
    NSError *error = nil;
    BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                      : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!ok && showErrors) [self showError:error title:@"Couldn’t update Launch at Login"];
    if (ok && enabled && SMAppService.mainAppService.status == SMAppServiceStatusRequiresApproval && showErrors) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Approval required";
        alert.informativeText = @"macOS requires approval in System Settings → General → Login Items. Glancebar has submitted the request.";
        [alert runModal];
    }
    return ok;
}

- (void)toggleLaunchAtLogin:(id)sender {
    BOOL enabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    [self setLaunchAtLoginEnabled:!enabled showErrors:YES];
}

- (void)showWelcomeIfNeeded {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud boolForKey:@"hasShownWelcome"]) return;
    [ud setBool:YES forKey:@"hasShownWelcome"];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Glancebar is ready";
    alert.informativeText = @"Glancebar now lives in your menu bar. Click its meters for storage, battery, system, and AI status. Keep Awake and Low Power sit at the bottom of the panel; ⋯ › Settings controls what appears and keeps Claude access off until you explicitly enable it. If the item is hidden by a MacBook notch, free one menu-bar slot in Control Center.";
    [alert addButtonWithTitle:@"Got It"];
    [alert addButtonWithTitle:@"Launch at Login"];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self setLaunchAtLoginEnabled:YES showErrors:YES];
}

- (void)showAbout:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Glancebar %@", GBVersion];
    alert.informativeText = @"One native menu-bar item for machine and AI status. No third-party dependencies; no network access unless Claude account status is explicitly enabled.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)saveBarOption:(NSString *)key value:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [self updateBar];
    [self refreshAIUsageAsync];
    if (_popover.isShown) [self rebuildContent];
}

- (void)toggleBarDisk:(id)s {
    _barShowDisk = !_barShowDisk; [self saveBarOption:@"barShowDisk" value:_barShowDisk];
}
- (void)toggleBarBattery:(id)s {
    _barShowBattery = !_barShowBattery; [self saveBarOption:@"barShowBattery" value:_barShowBattery];
}
- (void)toggleBarSystem:(id)s {
    _barShowSystem = !_barShowSystem; [self saveBarOption:@"barShowSystem" value:_barShowSystem];
}
- (void)toggleSpeedAlways:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self saveBarOption:@"speedAlways" value:![ud boolForKey:@"speedAlways"]];
}
- (Volume *)primaryVolume {
    NSMutableArray<NSNumber *> *boots = [NSMutableArray arrayWithCapacity:_vols.count];
    for (Volume *v in _vols) [boots addObject:@([v.path isEqualToString:@"/"])];
    NSInteger index = StorageHeadlineIndex(boots);
    if (index < 0 || (NSUInteger)index >= _vols.count) return nil;
    return _vols[(NSUInteger)index];
}

// Local external disks, in scan order. Volumes in one APFS container are one row.
// The boot row stays separate.
- (NSArray<NSDictionary *> *)externalGlanceRecords {
    if (!_vols.count) return @[];
    NSMutableArray *records = [NSMutableArray arrayWithCapacity:_vols.count];
    for (Volume *volume in _vols) [records addObject:GlanceRecordForVolume(volume)];
    return GlanceExternalVolumes(records);
}

- (Volume *)volumeForGlancePath:(NSString *)path {
    for (Volume *volume in _vols)
        if ([volume.path isEqualToString:path]) return volume;
    return nil;
}

- (NSArray<Volume *> *)externalGlanceVolumes {
    NSMutableArray<Volume *> *out = [NSMutableArray array];
    for (NSDictionary *row in [self externalGlanceRecords]) {
        BOOL hosted = [row[@"hosted"] isKindOfClass:NSArray.class] && [row[@"hosted"] count];
        if (![row[@"grouped"] boolValue] && !hosted) {
            Volume *volume = [self volumeForGlancePath:row[@"path"]];
            if (volume) [out addObject:volume];
            continue;
        }
        Volume *volume = [Volume new];
        volume.name = [row[@"name"] isKindOfClass:NSString.class] && [row[@"name"] length] ? row[@"name"] : @"Disk";
        volume.path = [row[@"path"] isKindOfClass:NSString.class] ? row[@"path"] : @"";
        volume.memberNames = [row[@"names"] isKindOfClass:NSArray.class] ? row[@"names"] : @[volume.name];
        volume.memberPaths = [row[@"paths"] isKindOfClass:NSArray.class] ? row[@"paths"]
            : (volume.path.length ? @[volume.path] : @[]);
        volume.total = [row[@"totalBytes"] longLongValue];
        volume.available = [row[@"freeBytes"] longLongValue];
        volume.physicalAvailable = volume.available;
        volume.grouped = [row[@"grouped"] boolValue];
        volume.groupUsed = [row[@"usedBytes"] longLongValue];
        volume.hostedNames = hosted ? row[@"hosted"] : nil;
        volume.glanceTooltip = GlanceExternalTooltip(row);
        volume.isLocal = YES;
        [out addObject:volume];
    }
    return out;
}

- (CGFloat)popoverNameColumnWidth {
    NSFont *font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    CGFloat maxField = MaxInstrumentNameW();
    __block CGFloat width = kAINameW;
    void (^consider)(NSString *, NSArray *) = ^(NSString *full, NSArray *names) {
        if (![full isKindOfClass:NSString.class] || !full.length) return;
        NSString *shown = VolumeLabelThatFits(full, names, font, maxField);
        CGFloat need = ceil([shown sizeWithAttributes:@{NSFontAttributeName: font}].width) + 4;
        if (need > width) width = need;
    };
    for (Volume *volume in [self externalGlanceVolumes])
        consider(volume.name, volume.memberNames);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSDictionary *machine in [self remoteMachines]) {
        NSString *host = machine[@"host"];
        if (![host isKindOfClass:NSString.class] || !host.length) continue;
        BOOL open = _fleetExpandedHosts ? [_fleetExpandedHosts containsObject:host]
            : [ud boolForKey:[@"remoteOpen." stringByAppendingString:host]];
        if (!open) continue;
        NSDictionary *reading = _remote[host];
        if (![reading isKindOfClass:NSDictionary.class]) continue;
        double age = CFAbsoluteTimeGetCurrent() - [reading[@"at"] doubleValue];
        if (age >= [self remoteReadingFreshSeconds]) continue;
        NSArray *reported = [reading[@"sample"][@"volumes"] isKindOfClass:NSArray.class] ? reading[@"sample"][@"volumes"] : nil;
        for (NSDictionary *row in GlanceExternalVolumes(reported))
            consider(row[@"name"], [row[@"names"] isKindOfClass:NSArray.class] ? row[@"names"] : nil);
    }
    return width;
}

// A volume with its own row is not also a "97% full" note on the boot row.
- (NSDictionary *)storageSecondaryNotice {
    NSMutableSet<NSString *> *shown = [NSMutableSet set];
    for (Volume *volume in [self externalGlanceVolumes]) {
        if (volume.memberPaths.count) [shown addObjectsFromArray:volume.memberPaths];
        else if (volume.path.length) [shown addObject:volume.path];
    }
    NSMutableArray *fillRows = [NSMutableArray array];
    for (Volume *volume in _vols) {
        if ([shown containsObject:volume.path ?: @""]) continue;
        [fillRows addObject:@{@"name": volume.name ?: @"", @"fraction": @(volume.fraction),
                              @"boot": @([volume.path isEqualToString:@"/"])}];
    }
    return StorageSecondaryNotice(fillRows);
}

- (CGFloat)addPopoverStorageVolume:(Volume *)volume displayName:(NSString *)displayName
                              stem:(NSString *)stem rowID:(NSString *)rowID
                                to:(NSView *)root at:(CGFloat)y {
    ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
    row.target = self;
    row.action = @selector(showStorageDetails:);
    row.accessibilityRole = NSAccessibilityButtonRole;
    row.accessibilityIdentifier = rowID;
    NSString *tip = volume.glanceTooltip.length ? volume.glanceTooltip
        : StorageVolumeTooltip(volume.name, volume.total, volume.available, volume.purgeable);
    row.accessibilityHelp = tip;
    row.accessibilityLabel = tip;
    BOOL namesDiffer = volume.name.length && ![displayName isEqual:volume.name];
    if (namesDiffer || volume.hostedNames.count) row.toolTip = tip;
    [self instrumentSymbol:(volume.isInternal ? @"internaldrive" : @"externaldrive")
                     tint:DiskColor(volume.fraction)
               identifier:[stem stringByAppendingString:@".symbol"] in:row];
    NSTextField *nameField = [self instrumentName:displayName identifier:[stem stringByAppendingString:@".name"] in:row];
    if (namesDiffer) nameField.accessibilityLabel = volume.name;
    Gauge *gauge = [[Gauge alloc] initWithFrame:RowGaugeRect()];
    gauge.fraction = volume.fraction;
    gauge.color = DiskColor(volume.fraction);
    gauge.metricLabel = [NSString stringWithFormat:@"%@ storage used", volume.name ?: @"Volume"];
    gauge.accessibilityIdentifier = [stem stringByAppendingString:@".gauge"];
    gauge.accessibilityHelp = tip;
    [row addSubview:gauge];
    NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(volume.fraction * 100)];
    NSTextField *value = [self instrumentValue:pct color:DiskColor(volume.fraction)
                                    identifier:[stem stringByAppendingString:@".value"] in:row];
    value.accessibilityHelp = tip;
    value.accessibilityLabel = [NSString stringWithFormat:@"%@ percent used", pct];
    NSTextField *datum = [self instrumentDatum:[NSString stringWithFormat:@"%@ free", CompactByteCount(volume.available)]
                                        color:NSColor.secondaryLabelColor
                                   identifier:[stem stringByAppendingString:@".datum"] in:row];
    datum.accessibilityHelp = tip;
    [root addSubview:row];
    return y + kRowH;
}

- (CGFloat)addPopoverExternalStorageTo:(NSView *)root at:(CGFloat)y {
    NSUInteger index = 1;
    NSFont *nameFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    for (Volume *volume in [self externalGlanceVolumes]) {
        NSString *stem = [NSString stringWithFormat:@"popover.storage.%lu", (unsigned long)index];
        NSString *rowID = [NSString stringWithFormat:@"popover.row.storage.%lu", (unsigned long)index];
        NSString *full = volume.name.length ? volume.name : @"Disk";
        y = [self addPopoverStorageVolume:volume
                               displayName:VolumeLabelThatFits(full, volume.memberNames, nameFont, RowNameW())
                                      stem:stem rowID:rowID to:root at:y];
        index++;
    }
    return y;
}

- (NSString *)batteryStatusText {
    if (!_bat.valid) return @"No battery detected";
    if (_bat.acConnected) {
        if (_bat.fullyCharged || _bat.percent >= 100) return @"Fully charged · on AC";
        if (_bat.isCharging) return [NSString stringWithFormat:@"%d%% · charging", _bat.percent];
        return [NSString stringWithFormat:@"%d%% · on AC, not charging", _bat.percent];
    }
    if (_bat.percent <= 20)
        return [NSString stringWithFormat:@"%d%% · at or below the 20%% reserve", _bat.percent];
    int minutes = MinutesTo20(_bat, [self avgAmp]);
    return minutes >= 0 ? [NSString stringWithFormat:@"%d%% · %@ until 20%%",
                           _bat.percent, FmtDuration(minutes)]
                        : [NSString stringWithFormat:@"%d%% · estimating time until 20%%", _bat.percent];
}

- (NSString *)batteryPowerText {
    if (!_bat.valid) return @"Unavailable";
    if (_bat.voltage_mV <= 0 || _bat.amperage_mA == 0) return _bat.acConnected ? @"On AC" : @"Estimating";
    double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
    return [NSString stringWithFormat:@"%@ %.1f W",
            _bat.amperage_mA < 0 ? @"Drawing" : @"Charging at", watts];
}

// The glyph that already means this instrument in the popover, or nil for a heading that
// is not one of those instruments (a breakdown, a privacy note, a model list).
- (NSString *)detailHeadingSymbolForTitle:(NSString *)title key:(NSString *)sectionKey {
    NSString *key = sectionKey.lowercaseString ?: @"";
    if ([key isEqualToString:@"overview"]) return @"square.grid.2x2";
    if ([key isEqualToString:@"storage"]) return @"internaldrive";
    if ([key hasPrefix:@"volume."]) {
        for (Volume *volume in _vols) {
            NSString *volumeKey = [@"volume." stringByAppendingString:volume.path ?: volume.name ?: @""].lowercaseString;
            if ([volumeKey isEqualToString:key])
                return volume.isInternal ? @"internaldrive" : @"externaldrive";
        }
        return @"externaldrive";
    }
    if ([key isEqualToString:@"battery"]) return @"battery.100";
    if ([key isEqualToString:@"system"] || [key isEqualToString:@"top-cpu"]) return @"cpu";
    if ([key isEqualToString:@"top-memory"]) return @"memorychip";
    if ([key isEqualToString:@"thermal"]) return @"thermometer.medium";
    if ([key isEqualToString:@"energy"]) return @"bolt";
    if ([key isEqualToString:@"top-signals"]) return @"chart.bar";
    if ([key isEqualToString:@"sources"] || [key isEqualToString:@"privacy"]) return @"checkmark.circle";
    if ([key isEqualToString:@"ai-status"]) return @"sparkle";
    if ([key hasSuffix:@".claude"] || [title isEqualToString:@"Claude"]) return [self aiSymbolName:@"Claude"];
    if ([key hasSuffix:@".codex"] || [title isEqualToString:@"Codex"]) return [self aiSymbolName:@"Codex"];
    if ([key hasSuffix:@".cursor"] || [title isEqualToString:@"Cursor"]) return [self aiSymbolName:@"Cursor"];
    if ([title isEqualToString:@"AI"]) return [self aiSymbolName:@"AI"];
    return nil;
}

// `sectionKey` is a stable semantic path for the section this heading OPENS — never the
// section it follows, and never a build-order index. Rows added after it inherit it.
// `tint` and `tip` carry a problem on the heading (an amber symbol, the sentence in the
// tooltip) so the document does not grow a status line under it.
- (void)addDetailHeading:(NSString *)title key:(NSString *)sectionKey
                      to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width
                    tint:(NSColor *)tint tip:(NSString *)tip {
    if (*y > kDetailPad) *y += 8;
    FlippedView *detailRoot = [root isKindOfClass:FlippedView.class] ? (FlippedView *)root : nil;
    CGFloat textX = kDetailPad;
    CGFloat textY = *y;
    NSString *symbol = [self detailHeadingSymbolForTitle:title key:sectionKey];
    NSString *provider = nil;
    NSString *headingKey = sectionKey.lowercaseString ?: @"";
    if ([headingKey hasSuffix:@".claude"] || [title isEqualToString:@"Claude"]) provider = @"Claude";
    else if ([headingKey hasSuffix:@".codex"] || [title isEqualToString:@"Codex"]) provider = @"Codex";
    else if ([headingKey hasSuffix:@".cursor"] || [title isEqualToString:@"Cursor"]) provider = @"Cursor";
    NSImage *providerLogo = provider ? AIProviderLogo(provider, 16) : nil;
    if (symbol.length || providerLogo) {
        NSImageView *mark = [NSImageView imageViewWithImage:(providerLogo ?: [self menuSymbol:symbol])];
        mark.imageScaling = NSImageScaleProportionallyDown;
        mark.contentTintColor = providerLogo ? nil : (tint ?: NSColor.secondaryLabelColor);
        mark.frame = NSMakeRect(kDetailPad, *y, 16, 16);
        mark.accessibilityElement = NO;   // the heading text is the accessible name
        if (tip.length) mark.accessibilityHelp = tip;
        [root addSubview:mark];
        textX = kDetailPad + 20;
        textY = *y + 1;
    }
    NSTextField *heading = [self text:title.uppercaseString
                                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                                 color:NSColor.tertiaryLabelColor
                                    at:NSMakeRect(textX, textY, width - kDetailPad - textX, 14)
                                 align:NSTextAlignmentLeft];
    ApplyHeadingAccessibility(heading, title);
    if (tip.length) heading.accessibilityHelp = tip;
    NSString *key = sectionKey.length ? sectionKey.lowercaseString : title.lowercaseString;
    NSString *scope = root.accessibilityIdentifier ?: @"details";
    heading.accessibilityIdentifier = DisambiguatedDetailKey(detailRoot, @"id",
        [NSString stringWithFormat:@"%@.heading.%@", scope, key]);
    if (detailRoot) detailRoot.accessibilitySection = key;
    [root addSubview:heading];
    *y += 24;
}

- (void)addDetailHeading:(NSString *)title key:(NSString *)sectionKey
                      to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    [self addDetailHeading:title key:sectionKey to:root y:y width:width tint:nil tip:nil];
}

- (void)addDetailKey:(NSString *)key value:(NSString *)value to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    [self addDetailKey:key value:value identifierKey:key to:root y:y width:width];
}

// `identifierKey` names the row for focus restoration and defaults to the displayed key.
// Pass a distinct one wherever the display text is lossy — ShortModelName maps both
// "claude-opus-4-8" and "opus-4-8" onto "opus-4-8", and the rows are ordered by usage, so
// a key built from the display name would swap identifiers as token counts cross.
- (void)addDetailKey:(NSString *)key value:(NSString *)value identifierKey:(NSString *)identifierKey
                  to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    CGFloat keyW = 126;
    CGFloat valueW = width - 2*kDetailPad - keyW;
    NSFont *valueFont = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSString *safeValue = value ?: @"";
    NSRect measured = [safeValue boundingRectWithSize:NSMakeSize(valueW, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                            attributes:@{NSFontAttributeName: valueFont}];
    CGFloat rowH = MAX(16, ceil(measured.size.height));
    [root addSubview:[self text:key font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                            at:NSMakeRect(kDetailPad, *y, keyW, 16) align:NSTextAlignmentLeft]];
    NSTextField *field = [self text:safeValue font:valueFont color:nil
                                at:NSMakeRect(kDetailPad+keyW, *y, valueW, rowH)
                             align:NSTextAlignmentLeft];
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    field.selectable = YES;
    field.accessibilityIdentifier = DetailIdentifier(root, @"value", identifierKey.length ? identifierKey : key);
    [root addSubview:field];
    *y += MAX(24, rowH + 8);
}

- (void)addDetailStatus:(NSString *)status to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    CGFloat fieldW = width - 2*kDetailPad;
    NSFont *font = [NSFont systemFontOfSize:12];
    NSString *safeStatus = status ?: @"";
    NSRect measured = [safeStatus boundingRectWithSize:NSMakeSize(fieldW, CGFLOAT_MAX)
                                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                             attributes:@{NSFontAttributeName: font}];
    CGFloat rowH = MAX(16, ceil(measured.size.height));
    NSTextField *field = [self text:safeStatus font:font color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kDetailPad, *y, fieldW, rowH) align:NSTextAlignmentLeft];
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    field.selectable = YES;
    field.accessibilityIdentifier = DetailIdentifier(root, @"status", @"status");
    [root addSubview:field];
    *y += MAX(24, rowH + 8);
}

- (NSScrollView *)detailScrollForRoot:(NSView *)root height:(CGFloat)height {
    root.frame = NSMakeRect(0, 0, kDetailW, MAX(height + kDetailPad, 360));
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 420)];
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = root;
    return scroll;
}

// A survey is a bounded snapshot, not a background monitor. Completion only updates
// an already visible window; closing Details never causes it to reopen.
- (BOOL)activityTabSelected {
    NSTabViewController *tabs = [_detailsWindow.contentViewController isKindOfClass:NSTabViewController.class]
        ? (NSTabViewController *)_detailsWindow.contentViewController : nil;
    return [tabs.tabView.selectedTabViewItem.identifier isEqual:@"activity"];
}
- (NSDictionary *)performActivitySurvey { return GBActivitySurvey(); }
- (void)requestActivitySurvey {
    if (_activityLoading || _terminating) return;
    _activityLoading = YES;
    NSUInteger generation = _activityGeneration;
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = [self performActivitySurvey];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_activityLoading = NO;
            if (self->_terminating) return;
            if (generation == self->_activityGeneration) self->_activitySurvey = result;
            [self refreshVisibleSurfaces];
        });
    });
}
- (void)requestActivitySurveyIfNeeded {
    double age = NSDate.date.timeIntervalSince1970 - [_activitySurvey[@"capturedAt"] doubleValue];
    if (!_activitySurvey || age < 0 || age > 60) [self requestActivitySurvey];
}
- (void)surveyActivity:(id)sender { (void)sender; [self requestActivitySurvey]; }
- (void)sortActivity:(NSSegmentedControl *)sender {
    _activitySort = MAX(0, MIN(2, sender.selectedSegment));
    [self rebuildDetails];
}
- (void)toggleLowData:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:!GBLowDataEnabled() forKey:@"lowData"];
    [self refreshVisibleSurfaces];
    // Local reads stay available. Existing authorized requests resume only when off.
    [self refreshAIUsageAsync];
    [_meteredMonitor tick];
}
- (void)showActivityDetails:(id)sender {
    _activityPresenting = YES;
    [self showDetailsTab:@"activity" sender:sender];
    _activityPresenting = NO;
    [self stopPowerTick];
    [self requestActivitySurveyIfNeeded];
}
- (void)lowPowerFinishedEnabling:(BOOL)enabling active:(BOOL)active reveal:(BOOL)reveal {
    (void)reveal;
    if (!enabling || !active || _terminating) return;
    // A toggle only toggles: never open a window. Collect the survey quietly so the
    // Activity tab is ready if the owner goes looking; the Burn row names the drain.
    [self requestActivitySurvey];
}
- (NSScrollView *)activityDetailsView {
    CGFloat width = kDetailW, pad = 16;
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, width, 360)];
    root.accessibilityIdentifier = @"details.activity";
    NSSegmentedControl *sort = [NSSegmentedControl segmentedControlWithLabels:@[@"CPU", @"Download", @"Upload"]
                    trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(sortActivity:)];
    sort.frame = NSMakeRect(pad, 12, 230, 28);
    sort.selectedSegment = _activitySort;
    sort.accessibilityIdentifier = @"details.activity.sort";
    sort.accessibilityLabel = @"Sort activity by";
    sort.accessibilityHelp = @"Sort this snapshot; selecting a metric does not take another sample.";
    [root addSubview:sort];
    NSButton *lowData = [self powerToggle:@"Low Data · Glancebar" symbol:@"arrow.down.circle" action:@selector(toggleLowData:)];
    lowData.frame = NSMakeRect(width - 274, 12, 184, 28);
    [self styleToggle:lowData on:GBLowDataEnabled() tint:NSColor.systemYellowColor ink:[NSColor colorWithWhite:0.1 alpha:1]];
    lowData.accessibilityIdentifier = @"details.activity.low-data";
    lowData.accessibilityLabel = @"Low Data for Glancebar only";
    lowData.accessibilityHelp = GBLowDataTip;
    [root addSubview:lowData];
    NSButton *survey = [NSButton buttonWithTitle:_activityLoading ? @"Sampling…" : @"Survey" target:self action:@selector(surveyActivity:)];
    survey.frame = NSMakeRect(width - 84, 12, 76, 28);
    survey.enabled = !_activityLoading;
    survey.accessibilityIdentifier = @"details.activity.survey";
    survey.accessibilityHelp = @"Take a short read-only sample. Apps and transfers keep running.";
    [root addSubview:survey];
    CGFloat nameW = width - 404, cpuX = width - 376, downX = width - 290, upX = width - 142;
    NSArray *titles = @[@"App / process", @"CPU", @"Down", @"Up"];
    CGFloat xs[] = {pad, cpuX, downX, upX}, ws[] = {nameW, 64, 126, 126};
    for (NSUInteger col = 0; col < 4; col++)
        [self detailText:titles[col] font:[NSFont systemFontOfSize:12.5] color:NSColor.secondaryLabelColor
                   frame:NSMakeRect(xs[col], 82, ws[col], 18) align:col ? NSTextAlignmentRight : NSTextAlignmentLeft
              identifier:[@"details.activity.heading." stringByAppendingString:titles[col]] in:root];
    NSString *metric = @[@"cpu", @"download", @"upload"][_activitySort];
    NSArray *rows = GBActivitySortedRows(_activitySurvey[@"rows"] ?: @[], metric);
    CGFloat y = 108;
    NSUInteger index = 0;
    for (NSDictionary *entry in rows) {
        NSString *name = entry[@"name"] ?: @"Process";
        NSString *identity = entry[@"group"] ?: [NSString stringWithFormat:@"%lu", (unsigned long)index];
        NSString *prefix = [@"details.activity.row." stringByAppendingString:identity];
        NSString *tip = [NSString stringWithFormat:@"%@\nCPU: 100%% = one core. ≥ = accessible subset. Network includes local and tunnel traffic.\nPIDs: %@", name, [entry[@"pids"] componentsJoinedByString:@", "] ?: @""];
        NSArray *values = @[name, GBActivityCPU(entry[@"cpu"], [entry[@"cpuPartial"] boolValue]),
            GBActivityRate(entry[@"download"], [entry[@"networkPartial"] boolValue]),
            GBActivityRate(entry[@"upload"], [entry[@"networkPartial"] boolValue])];
        for (NSUInteger col = 0; col < 4; col++) {
            NSFont *font = col ? [NSFont monospacedDigitSystemFontOfSize:13 weight:col == 1 ? NSFontWeightSemibold : NSFontWeightRegular]
                              : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
            NSTextField *field = [self detailText:values[col] font:font color:col < 2 ? NSColor.labelColor : NSColor.secondaryLabelColor
                          frame:NSMakeRect(xs[col], y, ws[col], 18) align:col ? NSTextAlignmentRight : NSTextAlignmentLeft
                     identifier:[prefix stringByAppendingFormat:@".%lu", (unsigned long)col] in:root];
            field.accessibilityHelp = tip;
            field.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", name, titles[col]];
        }
        y += 32; index++;
    }
    if (!rows.count) {
        NSString *empty = _activityLoading ? @"Sampling…" : _activitySurvey ? @"Activity unavailable" : @"Take a survey";
        [self detailText:empty font:[NSFont systemFontOfSize:13] color:NSColor.secondaryLabelColor
                  frame:NSMakeRect(pad, y, width - 2 * pad, 18) align:NSTextAlignmentLeft
             identifier:@"details.activity.empty" in:root];
        y += 32;
    }
    NSString *stamp = @"";
    if (_activitySurvey) {
        NSDateFormatter *clock = [NSDateFormatter new]; clock.dateFormat = @"d MMM HH:mm:ss";
        stamp = [NSString stringWithFormat:@"Sample %@ · %.1fs · accessible processes%@",
            [clock stringFromDate:[NSDate dateWithTimeIntervalSince1970:[_activitySurvey[@"capturedAt"] doubleValue]]],
            [_activitySurvey[@"intervalSeconds"] doubleValue], [_activitySurvey[@"networkAvailable"] boolValue] ? @"" : @" · network unavailable"];
    }
    NSTextField *status = [self detailText:stamp font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                 frame:NSMakeRect(pad, 52, width - 2 * pad, 18) align:NSTextAlignmentLeft
            identifier:@"details.activity.stamp" in:root];
    status.accessibilityHelp = _activitySurvey[@"problem"] ?: @"Snapshot only; not a live monitor. Missing or reset counters show —. VPN and local traffic are not Internet billing totals.";
    return [self detailScrollForRoot:root height:y + 8];
}

- (NSString *)detailTabSymbol:(NSString *)identifier {
    if ([identifier isEqualToString:@"overview"]) return @"square.grid.2x2";
    if ([identifier isEqualToString:@"storage"]) return @"internaldrive";
    if ([identifier isEqualToString:@"battery"]) return @"battery.100";
    if ([identifier isEqualToString:@"system"]) return @"cpu";
    if ([identifier isEqualToString:@"thermal"]) return @"thermometer.medium";
    if ([identifier isEqualToString:@"activity"]) return @"waveform.path.ecg";
    if ([identifier isEqualToString:@"ai"]) return @"sparkle";   // the section, not one provider
    return @"circle.dashed";
}

// Toolbar-tab items. Assigning viewController overwrites identifier, label, and image
// from the controller, so the stable tab id and the symbol go on after that.
- (NSTabViewItem *)detailTabWithIdentifier:(NSString *)identifier title:(NSString *)title view:(NSView *)view {
    NSViewController *child = [[NSViewController alloc] init];
    child.title = title;
    child.view = view;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:child];
    item.identifier = identifier;
    item.label = title;
    item.image = [self menuSymbol:[self detailTabSymbol:identifier]];
    // The AI tab is the section. Its image is not one provider's logo; each provider
    // row inside the tab carries that app's icon.
    return item;
}

- (NSTabViewController *)newDetailsTabController {
    GBDetailsTabs *controller = [[GBDetailsTabs alloc] init];
    controller.tabStyle = NSTabViewControllerTabStyleToolbar;
    controller.transitionOptions = NSViewControllerTransitionNone;
    controller.tabView.accessibilityIdentifier = @"details.tabs";
    NSArray<NSArray<NSString *> *> *specs = @[
        @[@"overview", @"Overview"],
        @[@"storage", @"Storage"],
        @[@"battery", @"Battery"],
        @[@"system", @"System"],
        @[@"thermal", @"Thermal"],
        @[@"activity", @"Activity"],
        @[@"ai", @"AI"],
    ];
    for (NSArray<NSString *> *spec in specs) {
        // Unselected tabs acquire their document when selected; creating the
        // toolbar never constructs six independent dashboards on the click path.
        NSScrollView *view=[spec[0] isEqual:@"overview"] ? [self overviewDetailsView]
            : [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,kDetailW,420)];
        [controller addTabViewItem:[self detailTabWithIdentifier:spec[0] title:spec[1] view:view]];
    }
    __weak Controller *owner = self;
    controller.activitySelected = ^{ [owner rebuildDetails]; [owner stopPowerTick]; [owner requestActivitySurveyIfNeeded]; };
    controller.storageSelected = ^{ [owner rebuildDetails]; [owner stopPowerTick]; [owner requestStorageScanIfNeeded]; };
    controller.otherSelected = ^{ [owner rebuildDetails]; [owner startPowerTick]; };
    return controller;
}

// Details columns, shared by every tab. Lead is the symbol plus a name column
// ("Macintosh HD", "Battery", "Claude"); the gauge starts after that name so every
// instrument lines up. Window labels sit in the same name column. Capacity and the
// reveal button sit in the trailing part of the datum column, so values still share an x.
static const CGFloat kDetailRowH = 32;
static const CGFloat kDetailGaugeH = 10;
static const CGFloat kDetailBarH = 4;

typedef struct {
    CGFloat width, rowH, symbol, gaugeH, barH, gap;
    CGFloat gaugeX, gaugeW, gaugeRight;
    CGFloat valueX, valueW, valueH, datumX, datumW, datumH;
    CGFloat labelX, labelW, nameX, nameW, storageGaugeX, storageGaugeW;
    CGFloat freeW, trailW, capX, capW, revealX, revealW;
    CGFloat barNameX, barNameW, barX, barW;
} DetailColumns;

static DetailColumns DetailLayout(CGFloat width) {
    DetailColumns c;
    c.width = width;
    c.rowH = kDetailRowH;
    c.symbol = kLeadSymbol;
    c.gaugeH = kDetailGaugeH;
    c.barH = kDetailBarH;
    c.gap = 8;
    c.valueW = 72;
    c.valueH = kValueH;
    c.datumH = kDatumH;
    c.freeW = 116;
    c.capW = 56;
    c.revealW = 24;
    c.nameX = kDetailPad + kLeadW + 6;
    c.nameW = 120;   // "Macintosh HD" at 13pt, and "bengalfox" on a window row
    c.labelX = c.nameX;
    c.labelW = c.nameW;
    CGFloat right = width - kDetailPad;
    c.revealX = right - c.revealW;
    c.capX = c.revealX - 6 - c.capW;
    c.datumX = c.capX - 6 - c.freeW;
    c.datumW = c.freeW;
    c.trailW = right - c.datumX;   // storage keeps freeW; every other datum runs to the margin
    c.valueX = c.datumX - c.gap - c.valueW;
    c.gaugeRight = c.valueX - c.gap;
    c.storageGaugeX = c.nameX + c.nameW + c.gap;
    c.gaugeX = c.storageGaugeX;
    c.gaugeW = MAX(32.0, c.gaugeRight - c.gaugeX);
    c.storageGaugeW = c.gaugeW;
    c.barNameX = kDetailPad;
    c.barNameW = 172;
    c.barX = c.barNameX + c.barNameW + c.gap;
    c.barW = MAX(24.0, c.gaugeRight - c.barX);
    return c;
}

static NSRect DetailLeadRect(DetailColumns c) {
    return NSMakeRect(kDetailPad, (c.rowH - c.symbol) / 2.0, kLeadW, c.symbol);
}
static NSRect DetailValueRect(DetailColumns c) {
    return NSMakeRect(c.valueX, (c.rowH - c.valueH) / 2.0, c.valueW, c.valueH);
}
static NSRect DetailDatumRect(DetailColumns c) {
    return NSMakeRect(c.datumX, (c.rowH - c.datumH) / 2.0, c.trailW, c.datumH);
}

static NSString *DetailBucketLabel(NSDictionary *w) {
    if ([w[@"bucketLabel"] isKindOfClass:NSString.class] && [w[@"bucketLabel"] length]) return w[@"bucketLabel"];
    if ([w[@"bucket"] isKindOfClass:NSString.class]) return CodexBucketLabel(w[@"bucket"]);
    return nil;
}
static NSRect DetailGaugeRect(DetailColumns c) {
    return NSMakeRect(c.gaugeX, (c.rowH - c.gaugeH) / 2.0, c.gaugeW, c.gaugeH);
}

static NSString *DetailWindowBaseLabel(NSDictionary *w) {
    // Cursor's pools by their stable key: Grok (Cursor's own models) and API.
    if ([w[@"pool"] isEqual:@"cursor"]) return @"Grok";
    if ([w[@"pool"] isEqual:@"api"]) return @"API";
    NSString *window = w[@"window"];
    if (![window isKindOfClass:NSString.class] || !window.length) return @"—";
    if ([window isEqualToString:@"5-hour"]) return @"5h";
    if ([window isEqualToString:@"weekly"]) return @"week";
    if ([window hasPrefix:@"weekly "]) {
        NSString *rest = [window substringFromIndex:7];
        return rest.length ? rest : @"week";
    }
    return window;   // the label column fits it; a blind cut produced "Cursor m"
}

static NSArray<NSString *> *DetailWindowLabels(NSArray *windows) {
    if (![windows isKindOfClass:NSArray.class] || !windows.count) return @[];
    NSMutableArray<NSString *> *bases = [NSMutableArray arrayWithCapacity:windows.count];
    NSCountedSet *counts = [NSCountedSet set];
    NSMutableSet *buckets = [NSMutableSet set];
    for (id item in windows) {
        NSDictionary *w = [item isKindOfClass:NSDictionary.class] ? item : @{};
        NSString *base = DetailWindowBaseLabel(w);
        [bases addObject:base];
        [counts addObject:base];
        if (w[@"bucket"]) [buckets addObject:w[@"bucket"]];
    }
    BOOL multi = buckets.count > 1;
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:windows.count];
    [windows enumerateObjectsUsingBlock:^(id item, NSUInteger i, BOOL *stop) {
        (void)stop;
        NSDictionary *w = [item isKindOfClass:NSDictionary.class] ? item : @{};
        NSString *bucket = DetailBucketLabel(w);
        if (multi && [counts countForObject:bases[i]] > 1 && bucket.length) [labels addObject:bucket];
        else [labels addObject:bases[i]];
    }];
    return labels;
}

static double HogShare(NSDictionary *h, NSArray *hogs) {
    double total = [hogs.firstObject[@"totalImpact"] doubleValue];
    if (total <= 0) for (NSDictionary *row in hogs) total += [row[@"impact"] doubleValue];
    return total > 0 ? [h[@"impact"] doubleValue] / total : 0;
}

static NSColor *HealthColor(double fraction) {
    if (fraction < 0.60) return NSColor.systemRedColor;
    if (fraction < 0.80) return NSColor.systemOrangeColor;
    return NSColor.systemGreenColor;
}

- (NSTextField *)detailText:(NSString *)text font:(NSFont *)font color:(NSColor *)color
                       frame:(NSRect)frame align:(NSTextAlignment)align
                  identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text ?: @"" font:font color:color at:frame align:align];
    field.maximumNumberOfLines = 1;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.cell.wraps = NO;
    if (identifier.length) field.accessibilityIdentifier = identifier;
    [row addSubview:field];
    return field;
}

- (NSImageView *)detailSymbol:(NSString *)name size:(CGFloat)size tint:(NSColor *)tint
                         frame:(NSRect)frame identifier:(NSString *)identifier in:(NSView *)row {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular];
    NSImage *base = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!base) base = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
    NSImageView *iv = [NSImageView imageViewWithImage:[base imageWithSymbolConfiguration:cfg]];
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    iv.frame = frame;
    iv.accessibilityIdentifier = identifier;
    [row addSubview:iv];
    return iv;
}

- (Gauge *)detailGauge:(NSRect)frame fraction:(double)fraction color:(NSColor *)color
                  label:(NSString *)label identifier:(NSString *)identifier tip:(NSString *)tip in:(NSView *)row {
    Gauge *gauge = [[Gauge alloc] initWithFrame:frame];
    gauge.fraction = MIN(1.0, MAX(0.0, fraction));
    gauge.color = color ?: NSColor.controlAccentColor;
    gauge.metricLabel = label.length ? label : @"Progress";
    gauge.accessibilityIdentifier = identifier;   // metricLabel overwrites this; set it after
    gauge.accessibilityHelp = tip;
    [row addSubview:gauge];
    return gauge;
}

- (NSView *)detailRowAt:(CGFloat)y cols:(DetailColumns)c identifier:(NSString *)identifier
                    tip:(NSString *)tip in:(NSView *)root {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, c.width, c.rowH)];
    row.accessibilityIdentifier = identifier;
    if (tip.length) {
        row.accessibilityHelp = tip;
        row.accessibilityLabel = tip;
    }
    [root addSubview:row];
    return row;
}

- (NSTextField *)detailValue:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier
                          tip:(NSString *)tip in:(NSView *)row cols:(DetailColumns)c {
    NSTextField *field = [self detailText:text font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                                     color:color frame:DetailValueRect(c) align:NSTextAlignmentRight
                                identifier:identifier in:row];
    if (tip.length) field.accessibilityHelp = tip;
    return field;
}

- (NSTextField *)detailDatum:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier
                          tip:(NSString *)tip in:(NSView *)row cols:(DetailColumns)c {
    NSTextField *field = [self detailText:text ?: @"" font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                     color:color ?: NSColor.secondaryLabelColor
                                     frame:DetailDatumRect(c) align:NSTextAlignmentLeft
                                identifier:identifier in:row];
    if (tip.length) field.accessibilityHelp = tip;
    return field;
}

// A list that is empty carries nothing, so the caller skips it. Loading is a dim dash;
// a failed sampler is an amber mark plus the word, with the sentence in the tooltip.
- (CGFloat)addDetailNoticeTo:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c
                   identifier:(NSString *)identifier tip:(NSString *)tip problem:(BOOL)problem {
    NSView *row = [self detailRowAt:y cols:c identifier:identifier tip:tip in:root];
    if (problem) {
        NSImageView *mark = [self detailSymbol:@"exclamationmark.triangle" size:c.symbol
                                          tint:NSColor.systemOrangeColor frame:DetailLeadRect(c)
                                    identifier:[identifier stringByAppendingString:@".symbol"] in:row];
        mark.accessibilityHelp = tip;
        mark.accessibilityLabel = tip;
        [self detailDatum:@"unavailable" color:NSColor.systemOrangeColor
               identifier:[identifier stringByAppendingString:@".datum"] tip:tip in:row cols:c];
    } else {
        [self detailValue:@"—" color:NSColor.tertiaryLabelColor
               identifier:[identifier stringByAppendingString:@".value"] tip:tip in:row cols:c];
    }
    return y + c.rowH;
}

- (CGFloat)addDetailBar:(NSDictionary *)h value:(NSString *)value context:(NSString *)context
               fraction:(double)fraction color:(NSColor *)color identifier:(NSString *)identifier
                     to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSDictionary *info = ProcessDisplayInfo(h);
    NSString *title = info[@"title"] ?: @"Process";
    NSString *detail = info[@"detail"] ?: @"";
    // The process description lives on the tooltip; a mixed list (Overview) names its
    // metric with the same symbol the System and Battery tabs use, not a word.
    NSString *metric = context.length ? [NSString stringWithFormat:@" %@", context] : @"";
    NSString *tip = detail.length
        ? [NSString stringWithFormat:@"%@ · %@%@\n%@", title, value ?: @"", metric, detail]
        : [NSString stringWithFormat:@"%@ · %@%@", title, value ?: @"", metric];
    NSView *row = [self detailRowAt:y cols:c identifier:identifier tip:tip in:root];
    NSTextField *name = [self detailText:title font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                    color:NSColor.labelColor
                                    frame:NSMakeRect(c.barNameX, (c.rowH - 16) / 2.0, c.barNameW, 16)
                                    align:NSTextAlignmentLeft
                               identifier:[identifier stringByAppendingString:@".name"] in:row];
    name.accessibilityHelp = tip;
    NSRect bar = NSMakeRect(c.barX, (c.rowH - c.barH) / 2.0, c.barW, c.barH);
    [self detailGauge:bar fraction:fraction color:color label:tip
           identifier:[identifier stringByAppendingString:@".bar"] tip:tip in:row];
    [self detailValue:value color:color identifier:[identifier stringByAppendingString:@".value"] tip:tip in:row cols:c];
    NSString *symbol = @{@"energy": @"bolt", @"CPU": @"cpu", @"memory": @"memorychip"}[context ?: @""];
    if (symbol) {
        NSRect datum = DetailDatumRect(c);
        NSImageView *mark = [self detailSymbol:symbol size:15 tint:NSColor.tertiaryLabelColor
                                         frame:NSMakeRect(NSMinX(datum), (c.rowH - 18) / 2.0, 20, 18)
                                    identifier:[identifier stringByAppendingString:@".context"] in:row];
        mark.accessibilityHelp = tip;
        mark.accessibilityLabel = context;
    }
    return y + c.rowH;
}

- (BOOL)batteryWattsKnown:(double *)outWatts {
    if (!_bat.valid || _bat.voltage_mV <= 0 || _bat.amperage_mA == 0) return NO;
    if (outWatts) *outWatts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
    return YES;
}

// The provider row the popover draws, at the Details column positions. Window rows and
// token history are added by the AI tab; Overview stops at this one line per provider.
- (CGFloat)addDetailProviderRow:(AIUsage *)u scope:(NSString *)scope
                             to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSString *name = u.name.length ? u.name : @"AI";
    NSString *slug = name.lowercaseString;
    BOOL overview = [scope isEqualToString:@"details.overview"];
    NSString *rowID = overview ? [NSString stringWithFormat:@"details.overview.row.ai.%@", slug]
                               : [NSString stringWithFormat:@"details.ai.row.%@", slug];
    NSString *stem = overview ? [NSString stringWithFormat:@"details.overview.ai.%@", slug]
                              : [NSString stringWithFormat:@"details.ai.%@", slug];
    NSDictionary *quotas = [name isEqualToString:@"Claude"] && !u.overageActive && u.limitStatusAvailable
        ? ClaudeModelQuotas(u.limitWindows) : nil;
    double week = quotas ? [quotas[@"opus"] doubleValue] : -1;
    BOOL claudeMeter = quotas != nil;
    NSDictionary *cursorPools = CursorPoolQuotas(u);
    BOOL hasGauge = claudeMeter || cursorPools || (u.limitStatusAvailable && u.remainingFraction >= 0 && !CodexQuotaUnavailable(u));
    NSString *pct = @"—";
    NSColor *valueColor = NSColor.tertiaryLabelColor;
    NSString *tip = [self aiStatusSubtext:u] ?: @"";
    if (claudeMeter) {
        pct = week < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", week * 100];
        BOOL staleWarns = [self aiSnapshotStaleWarns:u];
        valueColor = staleWarns ? NSColor.systemOrangeColor
            : (week < 0 ? NSColor.tertiaryLabelColor : AIQuotaColor(week));
        NSString *weekClock = [quotas[@"resetsAt"] isKindOfClass:NSNumber.class]
            ? ResetClockText([NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]], NSDate.date) : nil;
        // Week figure is on the row; the tooltip adds only the week's reset and the 5-hour window.
        NSMutableArray *parts = [NSMutableArray array];
        if (weekClock.length) [parts addObject:[@"week resets " stringByAppendingString:weekClock]];
        for (NSDictionary *w in u.limitWindows)
            if ([w[@"window"] isEqual:@"5-hour"] && [w[@"remainingFraction"] isKindOfClass:NSNumber.class]) {
                NSString *clock = [w[@"resetsAt"] isKindOfClass:NSNumber.class]
                    ? CompactResetClock([NSDate dateWithTimeIntervalSince1970:[w[@"resetsAt"] doubleValue]], NSDate.date) : nil;
                [parts addObject:[NSString stringWithFormat:@"5 h %.0f%%%@", [w[@"remainingFraction"] doubleValue] * 100,
                    clock.length ? [@", resets " stringByAppendingString:clock] : @""]];
            }
        if (!weekClock.length && tip.length) [parts addObject:tip];
        if (u.limitRefreshError.length) [parts addObject:u.limitRefreshError];
        tip = [parts componentsJoinedByString:@" · "];
    } else if (cursorPools) {
        double primary = CursorPrimaryFraction(cursorPools);
        pct = primary < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", primary * 100];
        valueColor = [self aiSnapshotStaleWarns:u] ? NSColor.systemOrangeColor : AIQuotaColor(MAX(primary, 0));

    } else if (hasGauge) {
        pct = [self aiPercentText:u];
        valueColor = [self aiStatusColor:u];
    }
    NSDate *resetDate = cursorPools ? CursorPoolReset(cursorPools) : u.resetAt;
    if (claudeMeter && [quotas[@"resetsAt"] isKindOfClass:NSNumber.class])
        resetDate = [NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]];
    NSString *named = tip.length ? [NSString stringWithFormat:@"%@ — %@", name, tip] : name;
    if (u.limitRefreshError.length && ![named containsString:u.limitRefreshError])
        named = [named stringByAppendingFormat:@"\n%@", u.limitRefreshError];
    if (u.billingNote.length && ![named containsString:u.billingNote])
        named = [named stringByAppendingFormat:@"\n%@", u.billingNote];
    if (u.extraUsage.length) named = [named stringByAppendingFormat:@"\n%@", u.extraUsage];
    if (u.limitUpdatedAt) named = [named stringByAppendingFormat:@"\nChecked %@", ClockText(u.limitUpdatedAt)];
    if (u.statusSource.length && ![[u.statusSource lowercaseString] isEqualToString:@"unknown"])
        named = [named stringByAppendingFormat:@"\n%@", u.statusSource];

    NSView *row = [self detailRowAt:y cols:c identifier:rowID tip:named in:root];
    NSImage *logo = AIProviderLogo(name, c.symbol);
    NSImageView *mark = logo
        ? [self detailSymbol:[self aiSymbolName:name] size:c.symbol tint:nil frame:DetailLeadRect(c)
                  identifier:[stem stringByAppendingString:@".symbol"] in:row]
        : [self detailSymbol:[self aiSymbolName:name] size:c.symbol tint:valueColor frame:DetailLeadRect(c)
                  identifier:[stem stringByAppendingString:@".symbol"] in:row];
    if (logo) { mark.image = logo; mark.contentTintColor = nil; }
    mark.accessibilityHelp = named;
    mark.accessibilityLabel = named;
    NSTextField *providerName = [self detailText:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                           color:NSColor.labelColor
                                           frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                           align:NSTextAlignmentLeft
                                      identifier:[stem stringByAppendingString:@".name"] in:row];
    providerName.accessibilityHelp = named;
    providerName.accessibilityLabel = name;
    if (claudeMeter) {
        QuotaPairGauge *meter = [[QuotaPairGauge alloc] initWithFrame:DetailGaugeRect(c)];
        meter.secondFraction = week;   // weekly all-models figure; Fable stays off this gauge
        meter.accessibilityIdentifier = [stem stringByAppendingString:@".gauge"];
        meter.accessibilityLabel = @"Claude weekly allowance remaining, all models";
        meter.accessibilityHelp = named;
        [row addSubview:meter];
    } else if (cursorPools) {
        [self detailGauge:DetailGaugeRect(c) fraction:MAX(CursorPrimaryFraction(cursorPools), 0) color:valueColor
                                 label:@"Cursor Grok + Composer remaining"
                            identifier:[stem stringByAppendingString:@".gauge"] tip:named in:row];
    } else if (hasGauge) {
        [self detailGauge:DetailGaugeRect(c) fraction:u.remainingFraction color:valueColor
                    label:[NSString stringWithFormat:@"%@ quota remaining", name]
               identifier:[stem stringByAppendingString:@".gauge"] tip:named in:row];
    }
    NSTextField *value = [self detailValue:pct color:valueColor
                                identifier:[stem stringByAppendingString:@".value"] tip:named in:row cols:c];
    if (claudeMeter) value.accessibilityLabel = @"Percent of the week remaining, all models";
    NSString *problem = [self aiProblemText:u];
    NSColor *datumColor = NSColor.secondaryLabelColor;
    NSString *datum = @"";
    if (problem.length) {
        datum = problem;
        BOOL severe = [problem isEqualToString:@"signed out"] || [problem isEqualToString:@"rate limited"];
        datumColor = severe ? NSColor.systemRedColor : NSColor.systemOrangeColor;
    } else if (!u.overageActive) {
        NSDate *reset = resetDate;
        NSString *clock = CompactResetClock(reset, NSDate.date);
        datum = clock.length ? [@"resets " stringByAppendingString:clock] : @"";
    }
    [self detailDatum:datum color:datumColor identifier:[stem stringByAppendingString:@".datum"] tip:named in:row cols:c];
    y += c.rowH;
    double api = cursorPools ? CursorPoolFraction(cursorPools, @"api") : -1;
    if (overview && api >= 0 && CursorPoolFraction(cursorPools, @"cursor") >= 0) {
        NSString *apiTip = [NSString stringWithFormat:@"Cursor API · %.0f%% left", api * 100];
        NSView *apiRow = [self detailRowAt:y cols:c identifier:[rowID stringByAppendingString:@".api"] tip:apiTip in:root];
        NSColor *ink = [self aiSnapshotStaleWarns:u] ? NSColor.systemOrangeColor : AIQuotaColor(api);
        [self detailText:@"API" font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium] color:NSColor.secondaryLabelColor
                   frame:NSMakeRect(c.labelX, (c.rowH - 16) / 2.0, c.labelW, 16) align:NSTextAlignmentLeft
              identifier:[stem stringByAppendingString:@".api.name"] in:apiRow].accessibilityHelp = apiTip;
        [self detailGauge:DetailGaugeRect(c) fraction:api color:ink label:@"Cursor API remaining"
               identifier:[stem stringByAppendingString:@".api.gauge"] tip:apiTip in:apiRow];
        [self detailValue:[NSString stringWithFormat:@"%.0f%%", api * 100] color:ink
               identifier:[stem stringByAppendingString:@".api.value"] tip:apiTip in:apiRow cols:c];
        y += c.rowH;
    }
    return y;
}

- (CGFloat)addDetailWindows:(AIUsage *)u to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSString *slug = (u.name.length ? u.name : @"AI").lowercaseString;
    NSArray *windows = u.limitWindows ?: @[];
    if (CursorPoolQuotas(u))   // Grok first: it is the reading that matters
        windows = [windows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"pool"] isEqual:@"cursor"] ? NSOrderedAscending : [b[@"pool"] isEqual:@"cursor"] ? NSOrderedDescending : NSOrderedSame;
        }];
    NSArray<NSString *> *labels = DetailWindowLabels(windows);
    for (NSUInteger i = 0; i < windows.count; i++) {
        NSDictionary *w = [windows[i] isKindOfClass:NSDictionary.class] ? windows[i] : @{};
        NSString *label = i < labels.count ? labels[i] : @"—";
        NSString *windowName = [w[@"window"] isKindOfClass:NSString.class] ? w[@"window"] : label;
        NSString *bucket = DetailBucketLabel(w);
        NSString *full = bucket.length ? [NSString stringWithFormat:@"%@ · %@", windowName, bucket] : windowName;
        BOOL hasFrac = [w[@"remainingFraction"] isKindOfClass:NSNumber.class];
        NSDate *observed=DateFromStatusString([w[@"observedAt"] isKindOfClass:NSString.class] ? w[@"observedAt"] : nil);
        BOOL staleCodex=[u.name isEqualToString:@"Codex"] &&
            (w[@"observedAt"] || u.limitStale) &&
            !CodexObservationFresh(observed ?: u.limitUpdatedAt,NSDate.date.timeIntervalSince1970);
        if (staleCodex) hasFrac=NO;
        double frac = hasFrac ? [w[@"remainingFraction"] doubleValue] : -1;
        NSString *pct = hasFrac ? [NSString stringWithFormat:@"%d%%", (int)lround(frac * 100.0)] : @"—";
        NSDate *resetDate = [w[@"resetsAt"] isKindOfClass:NSNumber.class]
            ? [NSDate dateWithTimeIntervalSince1970:[w[@"resetsAt"] doubleValue]] : nil;
        NSString *clock = CompactResetClock(resetDate, NSDate.date);
        NSString *reset = clock.length ? [@"resets " stringByAppendingString:clock] : @"";
        if (staleCodex) {
            NSDate *stamp=observed ?: u.limitUpdatedAt;
            NSString *age=stamp && stamp.timeIntervalSinceNow<=5 ? [self shortAgeForDate:stamp] : nil;
            age=[age stringByReplacingOccurrencesOfString:@" ago" withString:@""];
            reset=age.length && ![age isEqual:@"pending"] ? [@"stale " stringByAppendingString:age] : @"unavailable";
        }
        // Each window is coloured by its own remaining fraction. A full window stays
        // green even when the provider row is amber or red.
        NSColor *color = hasFrac ? AIQuotaColor(MIN(1.0, MAX(0.0, frac))) : NSColor.tertiaryLabelColor;
        NSMutableString *tip = [NSMutableString stringWithFormat:@"%@ · %@ left", full, pct];
        if (clock.length) [tip appendFormat:@" · resets %@", clock];
        else if ([w[@"fresh"] boolValue]) [tip appendString:@" · not started"];
        NSString *rowID = [NSString stringWithFormat:@"details.ai.window.%@.%lu", slug, (unsigned long)i];
        NSView *row = [self detailRowAt:y cols:c identifier:rowID tip:tip in:root];
        NSTextField *lab = [self detailText:label font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                                       color:NSColor.secondaryLabelColor
                                       frame:NSMakeRect(c.labelX, (c.rowH - 16) / 2.0, c.labelW, 16)
                                       align:NSTextAlignmentLeft
                                  identifier:[rowID stringByAppendingString:@".label"] in:row];
        lab.accessibilityHelp = tip;
        if (hasFrac && frac >= 0)
            [self detailGauge:DetailGaugeRect(c) fraction:frac color:color label:tip
                   identifier:[rowID stringByAppendingString:@".gauge"] tip:tip in:row];
        [self detailValue:pct color:color identifier:[rowID stringByAppendingString:@".value"] tip:tip in:row cols:c];
        [self detailDatum:reset color:NSColor.secondaryLabelColor
               identifier:[rowID stringByAppendingString:@".datum"] tip:tip in:row cols:c];
        y += c.rowH;
    }
    return y;
}

- (NSString *)detailHistoryTip:(AIUsage *)u {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (u.todayTokens > 0)
        [parts addObject:[NSString stringWithFormat:@"Today %@", FmtTokenCount(u.todayTokens)]];
    if (u.todayTokensAll > u.todayTokens && u.todayTokensAll > 0)
        [parts addObject:[NSString stringWithFormat:@"%@ today including cached context", FmtCompact(u.todayTokensAll)]];
    if (u.weekTokens > 0)
        [parts addObject:[NSString stringWithFormat:@"7 days %@", FmtTokenCount(u.weekTokens)]];
    if (u.weekTokensAll > u.weekTokens && u.weekTokensAll > 0)
        [parts addObject:[NSString stringWithFormat:@"%@ in 7 days including cached context", FmtCompact(u.weekTokensAll)]];
    if (u.todaySessions > 0 || u.weekSessions > 0)
        [parts addObject:[NSString stringWithFormat:@"%lld sessions today · %lld in 7 days",
                          u.todaySessions, u.weekSessions]];
    if (u.todayMessages > 0)
        [parts addObject:[NSString stringWithFormat:@"%lld messages · %lld tool calls",
                          u.todayMessages, u.todayToolCalls]];
    for (NSDictionary *model in u.models) {
        NSString *raw = [model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : nil;
        if (!raw.length) continue;
        if ([model[@"tokens"] isKindOfClass:NSNumber.class])
            [parts addObject:[NSString stringWithFormat:@"%@ · %@", ShortModelName(raw), FmtTokenCount([model[@"tokens"] longLongValue])]];
        else if ([model[@"sessions"] isKindOfClass:NSNumber.class])
            [parts addObject:[NSString stringWithFormat:@"%@ · %lld sessions", ShortModelName(raw), [model[@"sessions"] longLongValue]]];
    }
    if (u.lastActivity) [parts addObject:[NSString stringWithFormat:@"Updated %@", ClockText(u.lastActivity)]];
    NSString *source = u.source ?: @"";
    if (source.length && ![[source lowercaseString] isEqualToString:@"unknown"]) [parts addObject:source];
    return parts.count ? [parts componentsJoinedByString:@"\n"] : (u.name ?: @"Usage");
}

- (CGFloat)addDetailHistory:(AIUsage *)u to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    BOOL hasTokens = u.todayTokens > 0 || u.weekTokens > 0 || u.todayTokensAll > 0 || u.weekTokensAll > 0;
    BOOL hasSessions = u.todaySessions > 0 || u.weekSessions > 0;
    BOOL hasData = hasTokens || hasSessions || u.todayMessages > 0 || u.todayToolCalls > 0;
    if (!hasData) return y;
    NSString *slug = (u.name.length ? u.name : @"AI").lowercaseString;
    NSString *tip = [self detailHistoryTip:u];
    NSString *rowID = [@"details.ai.history." stringByAppendingString:slug];
    NSView *row = [self detailRowAt:y cols:c identifier:rowID tip:tip in:root];
    CGFloat mark = 16;
    NSRect symbol = NSMakeRect(kDetailPad + (kLeadW - mark) / 2.0, (c.rowH - mark) / 2.0, mark, mark);
    NSImage *logo = AIProviderLogo(u.name, mark);
    NSImageView *glyph = [self detailSymbol:[self aiSymbolName:u.name] size:mark
                                       tint:(logo ? nil : NSColor.tertiaryLabelColor)
                                      frame:symbol identifier:[rowID stringByAppendingString:@".symbol"] in:row];
    if (logo) { glyph.image = logo; glyph.contentTintColor = nil; }
    glyph.accessibilityHelp = tip;
    glyph.accessibilityLabel = tip;
    NSString *metric = hasTokens ? @"Tokens" : hasSessions ? @"Sessions" : u.todayMessages > 0 ? @"Messages" : @"Tools";
    long long todayCount = hasTokens ? u.todayTokens : hasSessions ? u.todaySessions : u.todayMessages > 0 ? u.todayMessages : u.todayToolCalls;
    long long weekCount = hasTokens ? u.weekTokens : hasSessions ? u.weekSessions : 0;
    NSFont *metricFont = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    CGFloat metricW = ceil([metric sizeWithAttributes:@{NSFontAttributeName:metricFont}].width) + 4;
    [self detailText:metric font:metricFont
              color:NSColor.secondaryLabelColor frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, metricW, 16)
              align:NSTextAlignmentLeft identifier:[rowID stringByAppendingString:@".metric"] in:row].accessibilityHelp = tip;
    NSString *todayText = FmtCompact(todayCount);
    NSString *weekText = (hasTokens || hasSessions) ? FmtCompact(weekCount) : @"—";
    NSFont *figure = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
    NSFont *tag = [NSFont systemFontOfSize:kDatumFont weight:NSFontWeightRegular];
    // Give "today" its measured width, not 46pt at the expense of the reading.
    // 20.8M used to become "20…" in a 42pt field. Large totals can also use the
    // otherwise empty space after "Tokens", without shrinking the type or adding rows.
    CGFloat tagW = ceil([@"today" sizeWithAttributes:@{NSFontAttributeName:tag}].width) + 4;
    CGFloat todayTagX = c.valueX - c.gap - tagW;
    CGFloat todayValueW = MAX(todayTagX - 4 - c.gaugeX,
                             ceil([todayText sizeWithAttributes:@{NSFontAttributeName:figure}].width) + 4);
    NSTextField *today = [self detailText:todayText font:figure
                                     color:NSColor.labelColor
                                     frame:NSMakeRect(todayTagX - 4 - todayValueW, (c.rowH - c.valueH) / 2.0, todayValueW, c.valueH)
                                     align:NSTextAlignmentRight
                                identifier:[rowID stringByAppendingString:@".today"] in:row];
    today.accessibilityHelp = tip;
    NSTextField *todayTag = [self detailText:@"today" font:tag color:NSColor.tertiaryLabelColor
                                        frame:NSMakeRect(todayTagX, (c.rowH - c.datumH) / 2.0, tagW, c.datumH)
                                        align:NSTextAlignmentLeft
                                   identifier:[rowID stringByAppendingString:@".todayLabel"] in:row];
    todayTag.accessibilityHelp = tip;
    NSTextField *week = [self detailValue:weekText color:((hasTokens || hasSessions) ? NSColor.labelColor : NSColor.tertiaryLabelColor)
           identifier:[rowID stringByAppendingString:@".value"] tip:tip in:row cols:c];
    CGFloat weekW = MAX(c.valueW, ceil(week.attributedStringValue.size.width) + 4);
    week.frame = NSMakeRect(c.valueX, NSMinY(week.frame), weekW, NSHeight(week.frame));
    NSRect weekTagRect = DetailDatumRect(c);
    weekTagRect.origin.x = NSMaxX(week.frame) + c.gap;
    weekTagRect.size.width = c.width - kDetailPad - weekTagRect.origin.x;
    NSTextField *weekTag = [self detailText:@"7d" font:tag color:NSColor.tertiaryLabelColor
                                       frame:weekTagRect align:NSTextAlignmentLeft
                                  identifier:[rowID stringByAppendingString:@".weekLabel"] in:row];
    weekTag.accessibilityHelp = tip;
    return y + c.rowH;
}

- (CGFloat)addDetailSource:(NSString *)name on:(BOOL)on datum:(NSString *)datum tip:(NSString *)tip
                 identifier:(NSString *)identifier to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSView *row = [self detailRowAt:y cols:c identifier:identifier tip:tip in:root];
    NSImageView *mark = [self detailSymbol:(on ? @"checkmark.circle.fill" : @"circle") size:c.symbol
                                      tint:(on ? NSColor.systemGreenColor : NSColor.tertiaryLabelColor)
                                     frame:DetailLeadRect(c)
                                identifier:[identifier stringByAppendingString:@".symbol"] in:row];
    mark.accessibilityHelp = tip;
    mark.accessibilityLabel = tip;
    CGFloat nameW = c.valueX + c.valueW - c.gaugeX - c.gap;
    NSTextField *title = [self detailText:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                     color:NSColor.labelColor
                                     frame:NSMakeRect(c.gaugeX, (c.rowH - 16) / 2.0, nameW, 16)
                                     align:NSTextAlignmentLeft
                                identifier:[identifier stringByAppendingString:@".name"] in:row];
    title.accessibilityHelp = tip;
    [self detailDatum:datum color:(on ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor)
           identifier:[identifier stringByAppendingString:@".datum"] tip:tip in:row cols:c];
    return y + c.rowH;
}

- (CGFloat)addOverviewStorageVolume:(Volume *)volume displayName:(NSString *)displayName
                              stem:(NSString *)stem rowID:(NSString *)rowID
                                to:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSMutableString *tip = [(volume.glanceTooltip.length ? volume.glanceTooltip
        : StorageVolumeTooltip(volume.name, volume.total, volume.available, volume.purgeable)) mutableCopy];
    if (volume.memberPaths.count > 1) {
        [tip appendString:@"\n"];
        [tip appendString:[volume.memberPaths componentsJoinedByString:@"\n"]];
    } else if (volume.path.length) [tip appendFormat:@"\n%@", volume.path];
    NSColor *tint = DiskColor(volume.fraction);
    NSView *row = [self detailRowAt:y cols:c identifier:rowID tip:tip in:root];
    BOOL namesDiffer = volume.name.length && ![displayName isEqual:volume.name];
    if (namesDiffer || volume.hostedNames.count) row.toolTip = tip;
    NSImageView *mark = [self detailSymbol:(volume.isInternal ? @"internaldrive" : @"externaldrive")
                                      size:c.symbol tint:tint frame:DetailLeadRect(c)
                                identifier:[stem stringByAppendingString:@".symbol"] in:row];
    mark.accessibilityHelp = tip;
    NSTextField *volumeName = [self detailText:displayName
                                           font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                          color:NSColor.labelColor
                                          frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                          align:NSTextAlignmentLeft
                                     identifier:[stem stringByAppendingString:@".name"] in:row];
    volumeName.accessibilityHelp = tip;
    if (namesDiffer) volumeName.accessibilityLabel = volume.name;
    [self detailGauge:DetailGaugeRect(c) fraction:volume.fraction color:tint
                label:[NSString stringWithFormat:@"%@ storage used", volume.name ?: @"Volume"]
           identifier:[stem stringByAppendingString:@".gauge"] tip:tip in:row];
    NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(volume.fraction * 100)];
    [self detailValue:pct color:tint identifier:[stem stringByAppendingString:@".value"] tip:tip in:row cols:c];
    [self detailDatum:[NSString stringWithFormat:@"%@ free", CompactByteCount(volume.available)]
                color:NSColor.secondaryLabelColor identifier:[stem stringByAppendingString:@".datum"] tip:tip in:row cols:c];
    return y + c.rowH;
}

- (CGFloat)addOverviewExternalStorageTo:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    NSUInteger index = 1;
    NSFont *nameFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    for (Volume *volume in [self externalGlanceVolumes]) {
        NSString *stem = [NSString stringWithFormat:@"details.overview.storage.%lu", (unsigned long)index];
        NSString *rowID = [NSString stringWithFormat:@"details.overview.row.storage.%lu", (unsigned long)index];
        NSString *full = volume.name.length ? volume.name : @"Disk";
        y = [self addOverviewStorageVolume:volume
                                displayName:VolumeLabelThatFits(full, volume.memberNames, nameFont, c.nameW)
                                       stem:stem rowID:rowID to:root y:y cols:c];
        index++;
    }
    return y;
}

- (NSScrollView *)overviewDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 360)];
    root.accessibilityIdentifier = @"details.overview";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Overview" key:@"overview" to:root y:&y width:kDetailW];

    Volume *v = [self primaryVolume];
    if (!v) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.overview.storage.empty"
                                tip:VolumeScanStatus(_volumesLoading, _volumesUnavailable)
                            problem:(_volumesUnavailable || !_volumesLoading)];
    } else {
        NSDictionary *secondary = [self storageSecondaryNotice];
        NSMutableString *tip = [StorageVolumeTooltip(v.name, v.total, v.available, v.purgeable) mutableCopy];
        if ([secondary[@"text"] isKindOfClass:NSString.class])
            [tip appendFormat:@" · %@", secondary[@"text"]];
        if (_volumesUnavailable)
            [tip appendFormat:@" · Cached %@ · scan unavailable",
                _lastVolumeSuccess ? [self shortAgeForDate:_lastVolumeSuccess] : @"reading"];
        NSColor *tint = secondary ? DiskColor([secondary[@"fraction"] doubleValue]) : DiskColor(v.fraction);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.overview.row.storage" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:(v.isInternal ? @"internaldrive" : @"externaldrive")
                                          size:c.symbol tint:tint frame:DetailLeadRect(c)
                                    identifier:@"details.overview.storage.symbol" in:row];
        mark.accessibilityHelp = tip;
        NSTextField *volumeName = [self detailText:(v.name.length ? v.name : @"Disk")
                                               font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                              color:NSColor.labelColor
                                              frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                              align:NSTextAlignmentLeft
                                         identifier:@"details.overview.storage.name" in:row];
        volumeName.accessibilityHelp = tip;
        [self detailGauge:DetailGaugeRect(c) fraction:v.fraction color:DiskColor(v.fraction)
                    label:[NSString stringWithFormat:@"%@ storage used", v.name]
               identifier:@"details.overview.storage.gauge" tip:tip in:row];
        NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(v.fraction * 100)];
        [self detailValue:pct color:DiskColor(v.fraction) identifier:@"details.overview.storage.value" tip:tip in:row cols:c];
        [self detailDatum:[NSString stringWithFormat:@"%@ free", CompactByteCount(v.available)]
                    color:NSColor.secondaryLabelColor identifier:@"details.overview.storage.datum" tip:tip in:row cols:c];
        y += c.rowH;
    }
    y = [self addOverviewExternalStorageTo:root y:y cols:c];

    {
        NSString *tip = [self batteryPopoverTip];
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.overview.row.battery" tip:tip in:root];
        if (_bat.valid) {
            NSImageView *mark = [self detailSymbol:BatterySymbolName(_bat.percent, NO) size:c.symbol
                                              tint:PowerFlowColor(_bat, NSColor.secondaryLabelColor) frame:DetailLeadRect(c)
                                        identifier:@"details.overview.battery.symbol" in:row];
            [self badgeBatterySymbolView:mark];
            mark.accessibilityHelp = tip;
            NSTextField *batteryName = [self detailText:@"Battery"
                                                    font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                                   color:NSColor.labelColor
                                                   frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                                   align:NSTextAlignmentLeft
                                              identifier:@"details.overview.battery.name" in:row];
            batteryName.accessibilityHelp = tip;
            Gauge *charge = [self detailGauge:DetailGaugeRect(c) fraction:_bat.percent / 100.0 color:BattBarColor(_bat.percent)
                        label:@"Battery charge" identifier:@"details.overview.battery.gauge" tip:tip in:row];
            if ([[self effectiveChargeMode] isEqualToString:@"limit80"]) charge.markerFraction = 0.80;
            [self detailValue:[NSString stringWithFormat:@"%d%%", _bat.percent] color:BattBarColor(_bat.percent)
                   identifier:@"details.overview.battery.value" tip:tip in:row cols:c];
            [self addBatteryTrendTo:row gauge:charge datum:DetailDatumRect(c)
                               stem:@"details.overview.battery" tip:tip];
        } else {
            [self detailSymbol:@"battery.0" size:c.symbol tint:NSColor.tertiaryLabelColor frame:DetailLeadRect(c)
                    identifier:@"details.overview.battery.symbol" in:row];
            [self detailText:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                       color:NSColor.labelColor
                       frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                       align:NSTextAlignmentLeft identifier:@"details.overview.battery.name" in:row];
            [self detailValue:@"—" color:NSColor.tertiaryLabelColor
                   identifier:@"details.overview.battery.value" tip:tip in:row cols:c];
        }
        y += c.rowH;
    }

    {
        NSString *level = SystemPressureLevel(_sys);
        NSString *tip = SystemSummaryText(_sys);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.overview.row.system" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:@"cpu" size:c.symbol tint:SystemPressureColor(level)
                                         frame:DetailLeadRect(c) identifier:@"details.overview.system.symbol" in:row];
        mark.accessibilityHelp = tip;
        NSTextField *systemName = [self detailText:@"System"
                                               font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                              color:NSColor.labelColor
                                              frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                              align:NSTextAlignmentLeft
                                         identifier:@"details.overview.system.name" in:row];
        systemName.accessibilityHelp = tip;
        [self addSystemInstrumentTo:row gauge:DetailGaugeRect(c) value:DetailValueRect(c)
                              datum:DetailDatumRect(c) stem:@"details.overview.system" tip:tip];
        y += c.rowH;
    }
    if ([self heatShowing]) {
        NSString *tip = [self heatTip];
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.overview.row.heat" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:[self heatSymbol] size:c.symbol tint:[self heatSymbolColor]
                                         frame:DetailLeadRect(c) identifier:@"details.overview.heat.symbol" in:row];
        mark.accessibilityHelp = tip;
        NSTextField *heatName = [self detailText:@"Speed" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                           color:NSColor.labelColor
                                           frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                           align:NSTextAlignmentLeft identifier:@"details.overview.heat.name" in:row];
        heatName.accessibilityHelp = tip;
        [self addHeatInstrumentTo:row gauge:DetailGaugeRect(c) value:DetailValueRect(c)
                            datum:DetailDatumRect(c) stem:@"details.overview.heat" tip:tip];
        y += c.rowH;
    }

    if ([_metered[@"onLink"] boolValue]) {
        NSString *link = _metered[@"link"];
        NSDictionary *figures = [self meteredFigures];
        NSString *tip = figures[@"tip"];
        double fraction = [figures[@"fraction"] doubleValue];
        NSColor *color = AIQuotaColor(fraction);
        NSView *row = [self detailRowAt:y cols:c identifier:[NSString stringWithFormat:@"details.overview.row.%@", link] tip:tip in:root];
        [self detailSymbol:MeteredSymbol(link) size:c.symbol tint:color frame:DetailLeadRect(c)
                identifier:[NSString stringWithFormat:@"details.overview.%@.symbol", link] in:row];
        [self detailText:MeteredName(link) font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                   color:NSColor.labelColor frame:NSMakeRect(c.nameX, (c.rowH-16)/2, c.nameW, 16)
                   align:NSTextAlignmentLeft identifier:[NSString stringWithFormat:@"details.overview.%@.name", link] in:row];
        Gauge *gauge = [self detailGauge:DetailGaugeRect(c) fraction:fraction color:color
            label:[MeteredName(link) stringByAppendingString:[figures[@"account"] boolValue] ? @" data remaining" : @" Mac data remaining"] identifier:[NSString stringWithFormat:@"details.overview.%@.gauge", link] tip:tip in:row];
        gauge.markerFraction = -1;
        [self detailValue:figures[@"value"] color:color identifier:[NSString stringWithFormat:@"details.overview.%@.value", link] tip:tip in:row cols:c];
        [self detailDatum:figures[@"datum"] color:[self meteredDatumColor:figures] identifier:[NSString stringWithFormat:@"details.overview.%@.datum", link] tip:tip in:row cols:c];
        for (NSView *child in row.subviews) child.accessibilityHelp = tip;
        y += c.rowH;
    }

    for (AIUsage *u in _aiUsage)
        y = [self addDetailProviderRow:u scope:@"details.overview" to:root y:y cols:c];

    if (_hogsLoading || _procStatsLoading) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.overview.signals.empty"
                                tip:@"Measuring top apps…" problem:NO];
    } else if ((_hogsUnavailable || _procStatsUnavailable) && !_hogs.count && !_topCPU.count && !_topMem.count) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.overview.signals.empty"
                                tip:@"One or more app samplers are unavailable" problem:YES];
    } else {
        NSUInteger n = (_hogs.count ? 1 : 0) + (_topCPU.count ? 1 : 0) + (_topMem.count ? 1 : 0);
        if (n >= 2) [self addDetailHeading:@"Top Signals" key:@"top-signals" to:root y:&y width:kDetailW];
        NSUInteger index = 0;
        if (_hogs.count) {
            NSDictionary *h = _hogs.firstObject;
            double share = HogShare(h, _hogs);
            y = [self addDetailBar:h value:[NSString stringWithFormat:@"%d%%", (int)lround(share * 100)]
                           context:@"energy" fraction:MIN(share, 1.0) color:PressureColor(share)
                        identifier:[NSString stringWithFormat:@"details.overview.signal.%lu", (unsigned long)index]
                                to:root y:y cols:c];
            index++;
        }
        if (_topCPU.count) {
            NSDictionary *h = _topCPU.firstObject;
            double share = GroupCPUShare(h);
            y = [self addDetailBar:h value:[NSString stringWithFormat:@"%d%%", (int)lround(share * 100)]
                           context:@"CPU" fraction:MIN(share, 1.0) color:CPUColor(share)
                        identifier:[NSString stringWithFormat:@"details.overview.signal.%lu", (unsigned long)index]
                                to:root y:y cols:c];
            index++;
        }
        if (_topMem.count) {
            NSDictionary *h = _topMem.firstObject;
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            uint64_t total = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal : bytes;
            double frac = total > 0 ? (double)bytes / (double)total : 0;
            y = [self addDetailBar:h value:FmtMemBytes(bytes) context:@"memory" fraction:MIN(frac, 1.0)
                             color:SystemPressureColor(MemoryPressureLevel(_sys))
                        identifier:[NSString stringWithFormat:@"details.overview.signal.%lu", (unsigned long)index]
                                to:root y:y cols:c];
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (void)revealVolume:(NSButton *)sender {
    NSString *path = sender.identifier;
    if (!path.length) return;
    [NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:path];
}

#include "storage_ui.inc"

- (NSScrollView *)storageDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 420)];
    root.accessibilityIdentifier = @"details.storage";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    BOOL staleScan = _volumesUnavailable && _vols.count > 0;
    if (_vols.count > 1 || staleScan) {
        NSString *tip = staleScan ? @"Volume scan unavailable; showing the last successful reading" : nil;
        if (staleScan && _lastVolumeSuccess)
            tip = [tip stringByAppendingFormat:@" · cached %@", [self shortAgeForDate:_lastVolumeSuccess]];
        [self addDetailHeading:@"Storage" key:@"storage" to:root y:&y width:kDetailW
                          tint:(staleScan ? NSColor.systemOrangeColor : nil) tip:tip];
    }
    if (!_vols.count) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.storage.empty"
                                tip:VolumeScanStatus(_volumesLoading, _volumesUnavailable)
                            problem:(_volumesUnavailable || !_volumesLoading)];
    }
    NSUInteger index = 0;
    for (Volume *volume in _vols) {
        NSMutableString *tip = [StorageVolumeTooltip(volume.name, volume.total, volume.available, volume.purgeable) mutableCopy];
        if (volume.path.length) [tip appendFormat:@"\n%@", volume.path];
        if (volume.purgeable > volume.total / 100)
            [tip appendString:@"\nPurgeable space is thinned on demand, so Finder counts it as free"];
        NSString *rowID = [NSString stringWithFormat:@"details.storage.row.%lu", (unsigned long)index];
        NSView *row = [self detailRowAt:y cols:c identifier:rowID tip:tip in:root];
        NSColor *fill = DiskColor(volume.fraction);
        NSImageView *mark = [self detailSymbol:(volume.isInternal ? @"internaldrive" : @"externaldrive")
                                          size:c.symbol tint:fill frame:DetailLeadRect(c)
                                    identifier:[rowID stringByAppendingString:@".symbol"] in:row];
        mark.accessibilityHelp = tip;
        NSTextField *name = [self detailText:volume.name ?: @"Volume"
                                         font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                        color:NSColor.labelColor
                                        frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16)
                                        align:NSTextAlignmentLeft
                                   identifier:[rowID stringByAppendingString:@".name"] in:row];
        name.accessibilityHelp = tip;
        NSRect gauge = NSMakeRect(c.storageGaugeX, (c.rowH - c.gaugeH) / 2.0, c.storageGaugeW, c.gaugeH);
        [self detailGauge:gauge fraction:volume.fraction color:fill
                    label:[NSString stringWithFormat:@"%@ storage used", volume.name ?: @"Volume"]
               identifier:[rowID stringByAppendingString:@".gauge"] tip:tip in:row];
        NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(volume.fraction * 100)];
        [self detailValue:pct color:fill identifier:[rowID stringByAppendingString:@".value"] tip:tip in:row cols:c];
        NSTextField *free = [self detailText:[NSString stringWithFormat:@"%@ free", CompactByteCount(volume.available)]
                                         font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                        color:NSColor.secondaryLabelColor
                                        frame:NSMakeRect(c.datumX, (c.rowH - c.datumH) / 2.0, c.freeW, c.datumH)
                                        align:NSTextAlignmentLeft
                                   identifier:[rowID stringByAppendingString:@".free"] in:row];
        free.accessibilityHelp = tip;
        NSTextField *cap = [self detailText:CompactByteCount(volume.total)
                                        font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                       color:NSColor.tertiaryLabelColor
                                       frame:NSMakeRect(c.capX, (c.rowH - c.datumH) / 2.0, c.capW, c.datumH)
                                       align:NSTextAlignmentRight
                                  identifier:[rowID stringByAppendingString:@".capacity"] in:row];
        cap.accessibilityHelp = tip;
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
        NSImage *image = [[NSImage imageWithSystemSymbolName:@"arrow.up.forward.square" accessibilityDescription:@"Reveal in Finder"]
                          imageWithSymbolConfiguration:cfg];
        NSButton *reveal = [NSButton buttonWithImage:image target:self action:@selector(revealVolume:)];
        reveal.title = @"";
        reveal.bordered = NO;
        reveal.imagePosition = NSImageOnly;
        reveal.imageScaling = NSImageScaleProportionallyDown;
        reveal.contentTintColor = NSColor.secondaryLabelColor;
        reveal.identifier = volume.path;
        reveal.accessibilityHelp = @"Reveal in Finder";
        reveal.accessibilityLabel = [NSString stringWithFormat:@"Reveal %@ in Finder", volume.name ?: @"volume"];
        reveal.accessibilityIdentifier = [@"details.reveal." stringByAppendingString:volume.path ?: @""];
        reveal.frame = NSMakeRect(c.revealX, (c.rowH - c.revealW) / 2.0, c.revealW, c.revealW);
        [row addSubview:reveal];
        y += c.rowH;
        index++;
    }
    y = [self addStorageBrowserTo:root y:y];
    return [self detailScrollForRoot:root height:y];
}

- (NSTextField *)detailRowName:(NSString *)name cols:(DetailColumns)c identifier:(NSString *)identifier in:(NSView *)row {
    return [self detailText:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                      frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16) align:NSTextAlignmentLeft
                 identifier:identifier in:row];
}

// The Battery tab's burn list on battery: each app's live watts and its Wh since unplug,
// then the screen-and-system remainder, then the total since unplug.
- (CGFloat)addBurnDetailsTo:(NSView *)root y:(CGFloat)y cols:(DetailColumns)c {
    double draw = [self burnDrawWatts];
    if (draw < 0) return y;
    [self addDetailHeading:@"Burn" key:@"burn" to:root y:&y width:kDetailW];
    if (!_burnRows)
        return [self addDetailNoticeTo:root y:y cols:c identifier:@"details.battery.burn.empty"
                                   tip:@"Measuring which apps are drawing power…" problem:NO];
    BOOL hasWh = _energyBaselineAt != nil;
    double scale = MAX(draw, 0.1), apps = 0, appsWh = 0;
    void (^addRow)(CGFloat, NSString *, double, double, NSColor *, NSString *) =
        ^(CGFloat y, NSString *name, double watts, double wh, NSColor *color, NSString *identifier) {
        NSString *tip = hasWh ? [NSString stringWithFormat:@"%@ · %.1f W now · %.2f Wh %@", name, watts, wh,
                                 self->_energyBaselineAtUnplug ? @"since unplug" : @"since launch"]
                              : [NSString stringWithFormat:@"%@ · %.1f W now", name, watts];
        NSView *row = [self detailRowAt:y cols:c identifier:identifier tip:tip in:root];
        [self detailText:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium] color:NSColor.labelColor
                   frame:NSMakeRect(c.barNameX, (c.rowH - 16) / 2.0, c.barNameW, 16) align:NSTextAlignmentLeft
              identifier:[identifier stringByAppendingString:@".name"] in:row].accessibilityHelp = tip;
        [self detailGauge:NSMakeRect(c.barX, (c.rowH - c.barH) / 2.0, c.barW, c.barH) fraction:MIN(watts / scale, 1.0)
                    color:color label:tip identifier:[identifier stringByAppendingString:@".bar"] tip:tip in:row];
        [self detailValue:[NSString stringWithFormat:@"%.1f W", watts] color:NSColor.labelColor
               identifier:[identifier stringByAppendingString:@".value"] tip:tip in:row cols:c];
        if (hasWh)
            [self detailDatum:[NSString stringWithFormat:@"%.1f Wh", wh] color:NSColor.secondaryLabelColor
                   identifier:[identifier stringByAppendingString:@".datum"] tip:tip in:row cols:c];
    };
    NSUInteger index = 0;
    for (NSDictionary *r in _burnRows) {
        double w = [r[@"watts"] doubleValue], wh = [r[@"wh"] doubleValue];
        apps += w; appsWh += wh;
        if (index >= 6) continue;   // the long tail stays in the remainder's company, on the tooltip
        addRow(y, r[@"name"], w, wh, NSColor.systemOrangeColor,
               [NSString stringWithFormat:@"details.battery.burn.%lu", (unsigned long)index]);
        y += c.rowH; index++;
    }
    double since = [self burnSinceBaselineWh];
    addRow(y, @"Screen + system", MAX(0, draw - apps), hasWh && since >= 0 ? MAX(0, since - appsWh) : 0,
           NSColor.systemGrayColor, @"details.battery.burn.system");
    y += c.rowH;
    if (hasWh && since >= 0) {
        int minutes = (int)lround(-_energyBaselineAt.timeIntervalSinceNow / 60.0);
        NSString *label = [self burnSinceLabel];
        NSString *tip = [NSString stringWithFormat:@"%@: %.1f Wh from the battery over %@", label, since, FmtDuration(minutes)];
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.battery.burn.since" tip:tip in:root];
        [self detailText:label font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                   frame:NSMakeRect(c.barNameX, (c.rowH - 16) / 2.0, c.barNameW, 16) align:NSTextAlignmentLeft
              identifier:@"details.battery.burn.since.name" in:row].accessibilityHelp = tip;
        [self detailValue:[NSString stringWithFormat:@"%.1f Wh", since] color:NSColor.labelColor
               identifier:@"details.battery.burn.since.value" tip:tip in:row cols:c];
        [self detailDatum:[@"over " stringByAppendingString:FmtDuration(minutes)] color:NSColor.secondaryLabelColor
               identifier:@"details.battery.burn.since.datum" tip:tip in:row cols:c];
        y += c.rowH;
    }
    return y;
}

- (NSScrollView *)batteryDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 520)];
    root.accessibilityIdentifier = @"details.battery";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    if (!_bat.valid) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.battery.empty"
                                tip:@"No battery detected" problem:YES];
    } else {
        double healthFrac = 0;
        BOOL health = _showHealth && _bat.designCap_mAh > 0;
        if (health) healthFrac = (double)_bat.rawMax_mAh / (double)_bat.designCap_mAh;
        double watts = 0;
        BOOL power = _showWatts && [self batteryWattsKnown:&watts];
        if (health || power)
            [self addDetailHeading:@"Battery" key:@"battery" to:root y:&y width:kDetailW];

        NSString *tip = [self batteryPopoverTip];
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.battery.row.charge" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:BatterySymbolName(_bat.percent, NO) size:c.symbol
                                          tint:PowerFlowColor(_bat, NSColor.secondaryLabelColor) frame:DetailLeadRect(c)
                                    identifier:@"details.battery.charge.symbol" in:row];
        [self badgeBatterySymbolView:mark];
            [self detailRowName:@"Charge" cols:c identifier:@"details.battery.charge.name" in:row];
        mark.accessibilityHelp = tip;
        Gauge *charge = [self detailGauge:DetailGaugeRect(c) fraction:_bat.percent / 100.0 color:BattBarColor(_bat.percent)
                    label:@"Battery charge" identifier:@"details.battery.charge.gauge" tip:tip in:row];
        if ([[self effectiveChargeMode] isEqualToString:@"limit80"]) charge.markerFraction = 0.80;
        [self detailValue:[NSString stringWithFormat:@"%d%%", _bat.percent] color:BattBarColor(_bat.percent)
               identifier:@"details.battery.charge.value" tip:tip in:row cols:c];
        [self addBatteryTrendTo:row gauge:charge datum:DetailDatumRect(c) stem:@"details.battery.charge" tip:tip];
        y += c.rowH;

        BatteryForecast forecast = [self batteryForecast];
        NSString *arrivals = BatteryForecastDetail(forecast, NSDate.date.timeIntervalSince1970, nil);
        if (arrivals.length) {
            if (forecast.hypotheticalFull) arrivals = [arrivals stringByAppendingString:@" · 100% if limit off"];
            NSString *help = BatteryForecastStatus(forecast);
            NSView *etaRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.eta" tip:help in:root];
            [self detailSymbol:@"clock" size:c.symbol tint:NSColor.secondaryLabelColor frame:DetailLeadRect(c)
                    identifier:@"details.battery.eta.symbol" in:etaRow];
            [self detailRowName:@"Forecast" cols:c identifier:@"details.battery.eta.name" in:etaRow];
            NSTextField *times = [self detailText:arrivals font:[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]
                color:NSColor.secondaryLabelColor frame:NSMakeRect(c.gaugeX, (c.rowH-18)/2, c.width-kDetailPad-c.gaugeX, 18)
                align:NSTextAlignmentRight identifier:@"details.battery.eta.arrivals" in:etaRow];
            times.accessibilityHelp = help;
            y += c.rowH;
        }

        if (health) {
            int pct = (int)lround(healthFrac * 100.0);
            NSString *healthTip = [NSString stringWithFormat:@"Health %d%% · %ld of %ld mAh · %ld cycles",
                                   pct, _bat.rawMax_mAh, _bat.designCap_mAh, (long)_bat.cycleCount];
            NSColor *color = HealthColor(healthFrac);
            NSView *healthRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.health" tip:healthTip in:root];
            NSImageView *heart = [self detailSymbol:@"heart" size:c.symbol tint:color frame:DetailLeadRect(c)
                                         identifier:@"details.battery.health.symbol" in:healthRow];
            [self detailRowName:@"Health" cols:c identifier:@"details.battery.health.name" in:healthRow];
            heart.accessibilityHelp = healthTip;
            [self detailGauge:DetailGaugeRect(c) fraction:MIN(healthFrac, 1.0) color:color
                        label:@"Battery health" identifier:@"details.battery.health.gauge" tip:healthTip in:healthRow];
            [self detailValue:[NSString stringWithFormat:@"%d%%", pct] color:color
                   identifier:@"details.battery.health.value" tip:healthTip in:healthRow cols:c];
            [self detailDatum:[NSString stringWithFormat:@"%ld cycles", (long)_bat.cycleCount]
                        color:NSColor.secondaryLabelColor identifier:@"details.battery.health.datum"
                          tip:healthTip in:healthRow cols:c];
            y += c.rowH;
        }
        if (_bat.tempC > 0) {
            BatteryHeat heat = BatteryHeatFor(_bat.tempC);
            NSColor *color = heat == BatteryHeatHot ? NSColor.systemRedColor
                           : heat == BatteryHeatWarm ? NSColor.systemOrangeColor : NSColor.labelColor;
            NSString *heatTip = [NSString stringWithFormat:@"Hottest cell %.1f °C · warm from 38 °C, hot from 42 °C", _bat.tempC];
            NSView *heatRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.heat" tip:heatTip in:root];
            [self detailSymbol:@"thermometer.medium" size:c.symbol
                          tint:(heat == BatteryHeatNone ? NSColor.secondaryLabelColor : color) frame:DetailLeadRect(c)
                    identifier:@"details.battery.heat.symbol" in:heatRow].accessibilityHelp = heatTip;
            [self detailRowName:@"Cells" cols:c identifier:@"details.battery.heat.name" in:heatRow];
            [self detailValue:[NSString stringWithFormat:@"%ld °C", lround(_bat.tempC)] color:color
                   identifier:@"details.battery.heat.value" tip:heatTip in:heatRow cols:c];
            if (_heatGuard == HeatGuardEngaged)
                [self detailDatum:@"Low Power on" color:NSColor.secondaryLabelColor
                       identifier:@"details.battery.heat.datum" tip:heatTip in:heatRow cols:c];
            y += c.rowH;
        }
        // Real units: energy in watt-hours, and the power flow in watts.
        double whNow = BatteryWattHours(_bat.rawCurrent_mAh, _bat.voltage_mV);
        double whFull = BatteryWattHours(_bat.rawMax_mAh, _bat.voltage_mV);
        if (!isnan(whNow)) {
            NSString *energyTip = [self batteryEnergyText] ?: @"";
            NSView *energyRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.energy" tip:energyTip in:root];
            [self detailSymbol:@"battery.100" size:c.symbol tint:NSColor.secondaryLabelColor frame:DetailLeadRect(c)
                    identifier:@"details.battery.energy.symbol" in:energyRow].accessibilityHelp = energyTip;
            [self detailRowName:@"Energy" cols:c identifier:@"details.battery.energy.name" in:energyRow];
            if (!isnan(whFull) && whFull > 0)
                [self detailGauge:DetailGaugeRect(c) fraction:MIN(whNow / whFull, 1.0) color:BattBarColor(_bat.percent)
                            label:@"Battery energy" identifier:@"details.battery.energy.gauge" tip:energyTip in:energyRow];
            [self detailValue:FormatWattHours(whNow) color:NSColor.labelColor
                   identifier:@"details.battery.energy.value" tip:energyTip in:energyRow cols:c];
            if (!isnan(whFull))
                [self detailDatum:[@"of " stringByAppendingString:FormatWattHours(whFull)] color:NSColor.secondaryLabelColor
                       identifier:@"details.battery.energy.datum" tip:energyTip in:energyRow cols:c];
            y += c.rowH;
        }
        if (_showWatts) {
            NSString *flowTip = [self batteryPowerFlowText];
            double bw = BatteryWatts(_bat);
            double loadW = _bat.systemLoad_mW > 0 && _bat.systemLoad_mW != LONG_MIN ? _bat.systemLoad_mW / 1000.0 : 0;
            if (_bat.acConnected && _bat.systemPowerIn_mW > 0 && _bat.systemPowerIn_mW != LONG_MIN) {
                // One flow bar replaces Input / System / Battery rows: grey is the Mac,
                // green is charge going in, and the empty track is charger headroom.
                double inW = _bat.systemPowerIn_mW / 1000.0;
                NSView *inRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.input" tip:flowTip in:root];
                [self detailSymbol:@"powerplug" size:c.symbol tint:NSColor.secondaryLabelColor frame:DetailLeadRect(c)
                        identifier:@"details.battery.input.symbol" in:inRow].accessibilityHelp = flowTip;
                [self detailRowName:@"Power" cols:c identifier:@"details.battery.input.name" in:inRow];
                PowerFlowGauge *flow = [[PowerFlowGauge alloc] initWithFrame:DetailGaugeRect(c)];
                flow.scaleWatts = _bat.adapterWatts > 0 ? _bat.adapterWatts : inW;
                flow.inputWatts = inW;
                flow.systemWatts = loadW;
                flow.batteryWatts = isnan(bw) ? 0 : bw;
                flow.accessibilityIdentifier = @"details.battery.input.gauge";
                flow.accessibilityValue = flowTip;
                flow.accessibilityHelp = flowTip;
                [inRow addSubview:flow];
                [self detailValue:[NSString stringWithFormat:@"%.1f W", inW] color:NSColor.labelColor
                       identifier:@"details.battery.input.value" tip:flowTip in:inRow cols:c];
                if (_bat.adapterWatts > 0)
                    [self detailDatum:[NSString stringWithFormat:@"of %ld W", _bat.adapterWatts]
                                color:NSColor.secondaryLabelColor identifier:@"details.battery.input.datum" tip:flowTip in:inRow cols:c];
                y += c.rowH;
            } else if (loadW > 0) {
                // On battery the Charge row already carries the signed watts; this is the Mac's draw.
                NSView *loadRow = [self detailRowAt:y cols:c identifier:@"details.battery.row.load" tip:flowTip in:root];
                [self detailSymbol:@"laptopcomputer" size:c.symbol tint:NSColor.secondaryLabelColor frame:DetailLeadRect(c)
                        identifier:@"details.battery.load.symbol" in:loadRow].accessibilityHelp = flowTip;
                [self detailRowName:@"System" cols:c identifier:@"details.battery.load.name" in:loadRow];
                [self detailValue:[NSString stringWithFormat:@"%.1f W", loadW] color:NSColor.labelColor
                       identifier:@"details.battery.load.value" tip:flowTip in:loadRow cols:c];
                y += c.rowH;
            }

        }
    }

    if ([self burnDrawWatts] >= 0) {
        y = [self addBurnDetailsTo:root y:y cols:c];
    } else if (_hogsLoading) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.battery.energy.empty"
                                tip:@"Measuring top apps…" problem:NO];
    } else if (_hogsUnavailable && !_hogs.count) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.battery.energy.empty"
                                tip:@"Energy-impact sampler unavailable" problem:YES];
    } else if (_hogs.count) {
        if (_hogs.count >= 2)
            [self addDetailHeading:@"Energy" key:@"energy" to:root y:&y width:kDetailW];
        NSUInteger index = 0;
        for (NSDictionary *h in _hogs) {
            double share = HogShare(h, _hogs);
            y = [self addDetailBar:h value:[NSString stringWithFormat:@"%d%%", (int)lround(share * 100)]
                           context:nil fraction:MIN(share, 1.0) color:PressureColor(share)
                        identifier:[NSString stringWithFormat:@"details.battery.bar.energy.%lu", (unsigned long)index]
                                to:root y:y cols:c];
            index++;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)aiDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    root.accessibilityIdentifier = @"details.ai";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    NSUInteger providerIndex = 0;
    for (AIUsage *u in _aiUsage) {
        if (providerIndex++) y += 6;
        y = [self addDetailProviderRow:u scope:@"details.ai" to:root y:y cols:c];
        y = [self addDetailWindows:u to:root y:y cols:c];
        y = [self addDetailHistory:u to:root y:y cols:c];
    }

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *statusPath = [GBHomeDirectory() stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    BOOL statusFile = [NSFileManager.defaultManager fileExistsAtPath:statusPath];
    BOOL cursor = CursorServicePresent(GBHomeDirectory());
    [self addDetailHeading:@"Sources" key:@"sources" to:root y:&y width:kDetailW];
    BOOL claudeAccount = [ud boolForKey:@"useClaudeAccount"];
    y = [self addDetailSource:@"Claude account" on:claudeAccount
                        datum:(claudeAccount ? @"keychain" : @"off")
                          tip:(claudeAccount ? @"On · Keychain token + api.anthropic.com" : @"Off · no Keychain/API access")
                   identifier:@"details.ai.source.claude-account" to:root y:y cols:c];
    BOOL transcripts = [ud boolForKey:@"useClaudeTranscripts"];
    y = [self addDetailSource:@"Claude transcripts" on:transcripts
                        datum:(transcripts ? @"local" : @"off")
                          tip:(transcripts ? @"On · local ~/.claude/projects JSONL" : @"Off · transcripts not read")
                   identifier:@"details.ai.source.claude-transcripts" to:root y:y cols:c];
    if (cursor) {
        BOOL cursorAccount = [ud boolForKey:@"useCursorAccount"];
        y = [self addDetailSource:@"Cursor account" on:cursorAccount
                            datum:(cursorAccount ? @"session" : @"off")
                              tip:(cursorAccount ? @"On · local Cursor session + api2.cursor.sh"
                                                 : @"Off · no Cursor session/API access")
                       identifier:@"details.ai.source.cursor-account" to:root y:y cols:c];
    }
    y = [self addDetailSource:@"Codex logs" on:YES datum:@"local"
                          tip:@"On · local ~/.codex session JSONL"
                   identifier:@"details.ai.source.codex-logs" to:root y:y cols:c];
    if (statusFile) {
        y = [self addDetailSource:@"Status file" on:YES datum:@"override"
                              tip:@"Present · overrides provider gauges"
                       identifier:@"details.ai.source.status-file" to:root y:y cols:c];
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)systemDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    root.accessibilityIdentifier = @"details.system";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"System" key:@"system" to:root y:&y width:kDetailW];

    {
        BOOL known = _sys.cpuValid;
        double cpu = known ? _sys.cpu : 0;
        NSColor *color = known ? CPUColor(cpu) : NSColor.tertiaryLabelColor;
        NSString *tip = CPUStatusText(_sys);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.system.row.cpu" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:@"cpu" size:c.symbol tint:color frame:DetailLeadRect(c)
                                    identifier:@"details.system.cpu.symbol" in:row];
        mark.accessibilityHelp = tip;
        if (known)
            [self detailGauge:DetailGaugeRect(c) fraction:MIN(cpu, 1.0) color:color label:tip
                   identifier:@"details.system.cpu.gauge" tip:tip in:row];
        [self detailValue:(known ? [NSString stringWithFormat:@"%d%%", (int)lround(cpu * 100)] : @"—")
                    color:color identifier:@"details.system.cpu.value" tip:tip in:row cols:c];
        y += c.rowH;
    }
    {
        NSString *level = MemoryPressureLevel(_sys);
        NSColor *color = SystemPressureColor(level);
        BOOL known = _sys.memValid && _sys.memTotal > 0;
        NSString *tip = MemoryStatusText(_sys);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.system.row.memory" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:@"memorychip" size:c.symbol tint:color frame:DetailLeadRect(c)
                                    identifier:@"details.system.memory.symbol" in:row];
        mark.accessibilityHelp = tip;
        if (known) {
            double frac = (double)_sys.memUsed / (double)_sys.memTotal;
            [self detailGauge:DetailGaugeRect(c) fraction:MIN(frac, 1.0) color:color label:tip
                   identifier:@"details.system.memory.gauge" tip:tip in:row];
        }
        [self detailValue:level color:color identifier:@"details.system.memory.value" tip:tip in:row cols:c];
        if (known)
            [self detailDatum:[NSString stringWithFormat:@"%@ free", FmtMemBytes((long long)_sys.memAvailable)]
                        color:NSColor.secondaryLabelColor identifier:@"details.system.memory.datum" tip:tip in:row cols:c];
        y += c.rowH;
    }
    {
        NSString *value = @"—";
        if (_sys.swapValid) value = _sys.swapUsed == 0 ? @"0 GB" : FmtMemBytes((long long)_sys.swapUsed);
        NSString *tip = SwapStatusText(_sys);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.system.row.swap" tip:tip in:root];
        NSImageView *mark = [self detailSymbol:@"arrow.left.arrow.right" size:c.symbol
                                          tint:NSColor.secondaryLabelColor frame:DetailLeadRect(c)
                                    identifier:@"details.system.swap.symbol" in:row];
        mark.accessibilityHelp = tip;
        [self detailValue:value color:(_sys.swapValid ? NSColor.labelColor : NSColor.tertiaryLabelColor)
               identifier:@"details.system.swap.value" tip:tip in:row cols:c];
        y += c.rowH;
    }

    if (_procStatsLoading) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.system.cpu.empty"
                                tip:@"Measuring top apps…" problem:NO];
    } else if (_procStatsUnavailable && !_topCPU.count) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.system.cpu.empty"
                                tip:@"Process sampler unavailable" problem:YES];
    } else if (_topCPU.count) {
        double rowShare = 0;
        for (NSDictionary *row in _topCPU) rowShare += GroupCPUShare(row);
        NSString *kernelTip = (_sys.cpuValid && _sys.cpu >= 0.5 && _sys.cpu > 2.0 * rowShare)
            ? @"Headline CPU is mostly system-level work (kernel), which per-app sampling can't see" : nil;
        if (_topCPU.count >= 2)
            [self addDetailHeading:@"Top CPU" key:@"top-cpu" to:root y:&y width:kDetailW tint:nil tip:kernelTip];
        NSUInteger index = 0;
        for (NSDictionary *h in _topCPU) {
            double share = GroupCPUShare(h);
            NSString *ident = [NSString stringWithFormat:@"details.system.bar.cpu.%lu", (unsigned long)index];
            y = [self addDetailBar:h value:[NSString stringWithFormat:@"%d%%", (int)lround(share * 100)]
                           context:nil fraction:MIN(share, 1.0) color:CPUColor(share)
                        identifier:ident to:root y:y cols:c];
            if (index == 0 && kernelTip.length && _topCPU.count < 2) {
                NSView *bar = root.subviews.lastObject;
                bar.accessibilityHelp = [NSString stringWithFormat:@"%@\n%@", bar.accessibilityHelp ?: @"", kernelTip];
            }
            index++;
        }
    }

    if (_procStatsLoading) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.system.memory.empty"
                                tip:@"Measuring top apps…" problem:NO];
    } else if (_procStatsUnavailable && !_topMem.count) {
        y = [self addDetailNoticeTo:root y:y cols:c identifier:@"details.system.memory.empty"
                                tip:@"Process sampler unavailable" problem:YES];
    } else if (_topMem.count) {
        if (_topMem.count >= 2)
            [self addDetailHeading:@"Top Memory" key:@"top-memory" to:root y:&y width:kDetailW];
        uint64_t memTotal = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal
            : [_topMem.firstObject[@"bytes"] unsignedLongLongValue];
        NSColor *color = SystemPressureColor(MemoryPressureLevel(_sys));
        NSUInteger index = 0;
        for (NSDictionary *h in _topMem) {
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            double frac = memTotal > 0 ? (double)bytes / (double)memTotal : 0;
            y = [self addDetailBar:h value:FmtMemBytes(bytes) context:nil fraction:MIN(frac, 1.0) color:color
                        identifier:[NSString stringWithFormat:@"details.system.bar.memory.%lu", (unsigned long)index]
                                to:root y:y cols:c];
            index++;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

// Thermal: macOS's pressure as four lamps, each core cluster's clock against its top
// speed, then the hottest core and the battery cells.
- (NSScrollView *)thermalDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 300)];
    root.accessibilityIdentifier = @"details.thermal";
    DetailColumns c = DetailLayout(kDetailW);
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Thermal" key:@"thermal" to:root y:&y width:kDetailW];
    NSString *tip = [self heatTip];
    ThermalLevel level = SystemThermalLevel(_sys);
    NSColor *levelColor = level == ThermalThrottling ? NSColor.systemRedColor
        : level == ThermalNear ? NSColor.systemOrangeColor
        : level == ThermalNominal ? NSColor.systemGreenColor : NSColor.tertiaryLabelColor;
    {
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.thermal.row.pressure" tip:tip in:root];
        [self detailSymbol:@"gauge.with.dots.needle.67percent" size:c.symbol tint:levelColor frame:DetailLeadRect(c)
                identifier:@"details.thermal.pressure.symbol" in:row];
        [self detailText:@"Pressure" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                   frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16) align:NSTextAlignmentLeft
              identifier:@"details.thermal.pressure.name" in:row];
        PressureLamps *lamps = [[PressureLamps alloc] initWithFrame:DetailGaugeRect(c)];
        lamps.lit = _sys.thermalValid ? MIN(MAX(_sys.thermalPressure, 0), 3) + 1 : 0;
        lamps.color = levelColor;
        lamps.accessibilityIdentifier = @"details.thermal.pressure.lamps";
        lamps.accessibilityHelp = tip;
        [row addSubview:lamps];
        [self detailValue:(_sys.thermalValid ? ThermalPressureName(_sys.thermalPressure) : @"—") color:levelColor
               identifier:@"details.thermal.pressure.value" tip:tip in:row cols:c];
        NSString *age = [self heatPressureAge];
        if (age && ![age isEqual:@"—"])
            [self detailDatum:[@"for " stringByAppendingString:age] color:levelColor
                   identifier:@"details.thermal.pressure.datum" tip:tip in:row cols:c];
        y += c.rowH;
    }
    CoreClocks k = _sys.clocks;
    NSArray *clusters = @[@[@"fast", @"P-cores", @"hare", @(k.pMHz), @(k.pMaxMHz)],
                          @[@"efficient", @"E-cores", @"tortoise", @(k.eMHz), @(k.eMaxMHz)]];
    for (NSArray *cl in clusters) {
        double mhz = [cl[3] doubleValue], top = [cl[4] doubleValue];
        BOOL known = k.valid && top > 0;
        NSColor *color = known && mhz > 0 ? [self heatSpeedColor] : NSColor.tertiaryLabelColor;
        if (level == ThermalNominal && known) color = NSColor.systemGreenColor;
        NSString *rowTip = known ? [NSString stringWithFormat:@"%@ averaged %.2f GHz while active, %d%% of the time · top %.2f GHz",
                                    cl[1], mhz / 1000, (int)lround(100 * ([cl[0] isEqual:@"fast"] ? k.pBusy : k.eBusy)), top / 1000]
                             : @"Clock speed unavailable";
        NSString *stem = [@"details.thermal." stringByAppendingString:cl[0]];
        NSView *row = [self detailRowAt:y cols:c identifier:[@"details.thermal.row." stringByAppendingString:cl[0]] tip:rowTip in:root];
        [self detailSymbol:cl[2] size:c.symbol tint:color frame:DetailLeadRect(c)
                identifier:[stem stringByAppendingString:@".symbol"] in:row];
        [self detailText:cl[1] font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                   frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16) align:NSTextAlignmentLeft
              identifier:[stem stringByAppendingString:@".name"] in:row];
        if (known)
            [self detailGauge:DetailGaugeRect(c) fraction:MIN(1, mhz / top) color:color label:rowTip
                   identifier:[stem stringByAppendingString:@".gauge"] tip:rowTip in:row];
        [self detailValue:(known && mhz > 0 ? [NSString stringWithFormat:@"%.1f", mhz / 1000] : @"—") color:color
               identifier:[stem stringByAppendingString:@".value"] tip:rowTip in:row cols:c];
        if (known)
            [self detailDatum:[NSString stringWithFormat:@"of %.1f GHz", top / 1000] color:NSColor.secondaryLabelColor
                   identifier:[stem stringByAppendingString:@".datum"] tip:rowTip in:row cols:c];
        y += c.rowH;
    }
    {
        BOOL known = _sys.tempValid;
        NSColor *color = known ? (level == ThermalNominal ? NSColor.systemGreenColor : levelColor) : NSColor.tertiaryLabelColor;
        NSString *rowTip = ThermalStatusText(_sys);
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.thermal.row.chip" tip:rowTip in:root];
        [self detailSymbol:@"cpu" size:c.symbol tint:color frame:DetailLeadRect(c) identifier:@"details.thermal.chip.symbol" in:row];
        [self detailText:@"Chip" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                   frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16) align:NSTextAlignmentLeft
              identifier:@"details.thermal.chip.name" in:row];
        if (known)
            [self detailGauge:DetailGaugeRect(c) fraction:MAX(0, MIN(1, (_sys.cpuTempC - 30) / 75.0)) color:color label:rowTip
                   identifier:@"details.thermal.chip.gauge" tip:rowTip in:row];
        [self detailValue:(known ? [NSString stringWithFormat:@"%ld°", lround(_sys.cpuTempC)] : @"—") color:color
               identifier:@"details.thermal.chip.value" tip:rowTip in:row cols:c];
        if (known)
            [self detailDatum:@"hottest core" color:NSColor.secondaryLabelColor
                   identifier:@"details.thermal.chip.datum" tip:rowTip in:row cols:c];
        y += c.rowH;
    }
    if (_bat.valid) {
        BOOL known = _bat.tempC > 0;
        BatteryHeat heat = BatteryHeatFor(_bat.tempC);
        NSColor *color = !known ? NSColor.tertiaryLabelColor : heat == BatteryHeatHot ? NSColor.systemRedColor
            : heat == BatteryHeatWarm ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
        NSString *rowTip = known ? [NSString stringWithFormat:@"Battery cells %ld °C · warm from 38 °C, hot from 42 °C", lround(_bat.tempC)]
                                 : @"Cell temperature unavailable";
        NSView *row = [self detailRowAt:y cols:c identifier:@"details.thermal.row.cells" tip:rowTip in:root];
        [self detailSymbol:@"battery.75" size:c.symbol tint:color frame:DetailLeadRect(c) identifier:@"details.thermal.cells.symbol" in:row];
        [self detailText:@"Cells" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                   frame:NSMakeRect(c.nameX, (c.rowH - 16) / 2.0, c.nameW, 16) align:NSTextAlignmentLeft
              identifier:@"details.thermal.cells.name" in:row];
        if (known)
            [self detailGauge:DetailGaugeRect(c) fraction:MAX(0, MIN(1, (_bat.tempC - 20) / 30.0)) color:color label:rowTip
                   identifier:@"details.thermal.cells.gauge" tip:rowTip in:row];
        [self detailValue:(known ? [NSString stringWithFormat:@"%ld°", lround(_bat.tempC)] : @"—") color:color
               identifier:@"details.thermal.cells.value" tip:rowTip in:row cols:c];
        NSString *lp = _heatGuard == HeatGuardEngaged ? @"Low Power for heat" : LowPowerModeEnabled() ? @"Low Power on" : nil;
        if (lp)
            [self detailDatum:lp color:NSColor.secondaryLabelColor identifier:@"details.thermal.cells.datum" tip:rowTip in:row cols:c];
        y += c.rowH;
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)detailViewForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"activity"]) return [self activityDetailsView];
    if ([identifier isEqualToString:@"overview"]) return [self overviewDetailsView];
    if ([identifier isEqualToString:@"storage"]) return [self storageDetailsView];
    if ([identifier isEqualToString:@"battery"]) return [self batteryDetailsView];
    if ([identifier isEqualToString:@"system"]) return [self systemDetailsView];
    if ([identifier isEqualToString:@"thermal"]) return [self thermalDetailsView];
    if ([identifier isEqualToString:@"ai"]) return [self aiDetailsView];
    return nil;
}

- (void)rebuildDetails {
    if (!_detailsWindow) return;
    NSDictionary *focusSnapshot = [self focusSnapshotForWindow:_detailsWindow
                                                       rootView:_detailsWindow.contentView];

    // The tab chrome consumes roughly 60pt at the initial 660pt window width.
    // Grow the document with the window while retaining the original readable
    // minimum, then rebuild rows so wrapping and right-aligned gauges stay exact.
    kDetailW = MAX(kDetailMinW, _detailsWindow.contentView.bounds.size.width - 60.0);

    NSTabViewController *controller = [_detailsWindow.contentViewController isKindOfClass:NSTabViewController.class]
        ? (NSTabViewController *)_detailsWindow.contentViewController : nil;
    NSTabView *tabs = controller.tabView;

    if (!controller) {   // first build: toolbar tabs, same identifiers and documents as before
        controller = [self newDetailsTabController];
        _detailsWindow.contentViewController = controller;
        [self restoreFocus:focusSnapshot inView:_detailsWindow.contentView window:_detailsWindow];
        return;
    }

    // Refresh the visible document only. Each tab keeps its prepared view and
    // scroll position; switching tabs refreshes that document from cached data.
    for (NSTabViewItem *item in tabs.tabViewItems) {
        if(item!=tabs.selectedTabViewItem)continue;
        NSScrollView *fresh = [self detailViewForIdentifier:item.identifier];
        if (!fresh) continue;
        NSRect existingFrame = item.view.frame;
        if (ReconcileViewTree(item.view, fresh)) {
            item.view.frame = existingFrame;  // NSTabView owns the viewport geometry
            continue;
        }
        CGFloat offset = 0;
        if ([item.view isKindOfClass:NSScrollView.class])
            offset = ((NSScrollView *)item.view).contentView.bounds.origin.y;
        item.view = fresh;
        CGFloat maxOffset = MAX(0, fresh.documentView.frame.size.height - fresh.contentView.bounds.size.height);
        [fresh.contentView scrollToPoint:NSMakePoint(0, MIN(offset, maxOffset))];
        [fresh reflectScrolledClipView:fresh.contentView];
    }
    [self restoreFocus:focusSnapshot inView:_detailsWindow.contentView window:_detailsWindow];
}

- (void)showStorageDetails:(id)sender { [self showDetailsTab:@"storage" sender:sender]; }
- (void)showBatteryDetails:(id)sender { [self showDetailsTab:@"battery" sender:sender]; }
- (void)showSystemDetails:(id)sender { [self showDetailsTab:@"system" sender:sender]; }
- (void)showThermalDetails:(id)sender { [self showDetailsTab:@"thermal" sender:sender]; }
- (void)showDetailsTab:(NSString *)tab sender:(id)sender {
    [self showDetails:sender];
    if (!tab.length || ![_detailsWindow.contentViewController isKindOfClass:NSTabViewController.class]) return;
    [((NSTabViewController *)_detailsWindow.contentViewController).tabView selectTabViewItemWithIdentifier:tab];
}

- (void)showDetails:(id)sender {
    if (!_activityPresenting) [self startPowerTick];   // stops itself once neither the popover nor Details is visible
    BOOL didCreateWindow = (_detailsWindow == nil);
    if (!_detailsWindow) {
        _detailsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 520)
                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskClosable |
                                                                NSWindowStyleMaskMiniaturizable |
                                                                NSWindowStyleMaskResizable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        _detailsWindow.title = @"Glancebar Details";
        _detailsWindow.releasedWhenClosed = NO;
        _detailsWindow.delegate = self;
        _detailsWindow.minSize = NSMakeSize(648, 420);
    }
    if(didCreateWindow)[self rebuildDetails];
    if (didCreateWindow) [_detailsWindow center];
    [_detailsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_popover close];
    if ([self activityTabSelected]) {
        [self stopPowerTick];
        [self requestActivitySurveyIfNeeded];
    } else if ([self storageTabSelected]) { [self stopPowerTick]; [self requestStorageScanIfNeeded]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(!self->_detailsWindow.isVisible || self->_terminating)return;
        [self refresh];
        if(![self activityTabSelected] && ![self storageTabSelected])[self beginSampling];
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification; // Global storage indexing survives closing Details.
}

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object != _detailsWindow || !_detailsWindow.isVisible) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuildDetails) object:nil];
    [self performSelector:@selector(rebuildDetails) withObject:nil afterDelay:0.04];
}

@end

#pragma mark - main

static id JSONValue(id value) { return value ?: NSNull.null; }
static NSNumber *JSONBool(BOOL value) { return value ? @YES : @NO; }

static BOOL IsJSONBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSString *ISODateString(NSDate *date) {
    if (!date) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [iso stringFromDate:date];
}

static NSArray<NSDictionary *> *DumpProcessRows(NSArray<NSDictionary *> *rows, BOOL cpuRows) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSDictionary *info = ProcessDisplayInfo(row);
        NSMutableDictionary *item = [@{
            @"name": JSONValue(row[@"name"]),
            @"title": JSONValue(info[@"title"]),
            @"detail": JSONValue(info[@"detail"]),
            @"commands": [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[],
            @"bytes": @([row[@"bytes"] unsignedLongLongValue])
        } mutableCopy];
        if (cpuRows) item[@"cpuPercent"] = @(GroupCPUShare(row) * 100.0);
        [out addObject:item];
    }
    return out;
}

static NSString *RequestedAIAccountError(NSArray<AIUsage *> *usage, BOOL accountRequested) {
    if (!accountRequested) return nil;
    for (AIUsage *item in usage)
        if ([item.name isEqualToString:@"Claude"] && item.limitRefreshError.length)
            return item.limitRefreshError;
    return nil;
}

static NSString *RequestedCursorAccountError(NSArray<AIUsage *> *usage, BOOL accountRequested) {
    if (!accountRequested) return nil;
    for (AIUsage *item in usage)
        if ([item.name isEqualToString:@"Cursor"] && item.limitRefreshError.length)
            return item.limitRefreshError;
    return nil;
}

static NSDictionary *DumpSnapshot(BOOL allowOnline) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"schemaVersion"] = @1;
    snapshot[@"glancebarVersion"] = GBVersion;
    snapshot[@"generatedAt"] = ISODateString(NSDate.date);

    NSArray<Volume *> *volumes = ScanVolumes();
    NSMutableArray *volumeRows = [NSMutableArray array];
    for (Volume *volume in volumes) {
        [volumeRows addObject:@{
            @"name": volume.name ?: @"",
            @"path": volume.path ?: @"",
            @"internal": JSONBool(volume.isInternal),
            @"totalBytes": @(volume.total),
            @"usedBytes": @(volume.used),
            @"availableBytes": @(volume.available),
            @"physicalAvailableBytes": @(volume.physicalAvailable),
            @"purgeableBytes": @(volume.purgeable),
            @"usedPercent": @(volume.fraction * 100.0)
        }];
    }
    snapshot[@"storage"] = @{
        @"available": JSONBool(volumeRows.count > 0),
        @"error": volumeRows.count ? NSNull.null : @"No mounted volume data",
        @"volumes": volumeRows
    };

    BatteryState battery = ReadBattery();
    int minutesTo20 = battery.valid && !battery.acConnected && battery.percent > 20
        ? MinutesTo20(battery, battery.amperage_mA) : -1;
    NSNumber *watts = battery.valid && battery.voltage_mV > 0 && battery.amperage_mA != 0
        ? @(fabs((double)battery.amperage_mA) * battery.voltage_mV / 1e6) : nil;
    NSNumber *health = battery.valid && battery.designCap_mAh > 0 && battery.rawMax_mAh >= 0
        ? @(100.0 * battery.rawMax_mAh / battery.designCap_mAh) : nil;
    snapshot[@"battery"] = @{
        @"available": JSONBool(battery.valid),
        @"error": battery.valid ? NSNull.null : @"No battery detected",
        @"percent": battery.valid ? @(battery.percent) : NSNull.null,
        @"acConnected": JSONBool(battery.valid && battery.acConnected),
        @"charging": JSONBool(battery.valid && battery.isCharging),
        @"fullyCharged": JSONBool(battery.valid && battery.fullyCharged),
        @"atOrBelowReserve": JSONBool(battery.valid && !battery.acConnected && battery.percent <= 20),
        @"minutesUntil20Percent": minutesTo20 >= 0 ? @(minutesTo20) : NSNull.null,
        @"powerWatts": JSONValue(watts),
        @"healthPercent": JSONValue(health),
        @"cycleCount": battery.valid && battery.cycleCount >= 0 ? @(battery.cycleCount) : NSNull.null,
        @"cellTempC": battery.valid && battery.tempC > 0 ? @(battery.tempC) : NSNull.null
    };

    NSArray *hogs = SampleHogs(5);
    double impactTotal = [hogs.firstObject[@"totalImpact"] doubleValue];
    if (impactTotal <= 0) for (NSDictionary *row in hogs) impactTotal += [row[@"impact"] doubleValue];
    NSMutableArray *impactRows = [NSMutableArray array];
    for (NSDictionary *row in hogs) {
        NSDictionary *info = ProcessDisplayInfo(row);
        double share = impactTotal > 0 ? [row[@"impact"] doubleValue] / impactTotal : 0;
        [impactRows addObject:@{
            @"name": JSONValue(row[@"name"]),
            @"title": JSONValue(info[@"title"]),
            @"detail": JSONValue(info[@"detail"]),
            @"commands": [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[],
            @"sampleSharePercent": @(share * 100.0)
        }];
    }
    snapshot[@"sampledEnergyImpact"] = @{
        @"available": JSONBool(impactRows.count > 0),
        @"error": impactRows.count ? NSNull.null : @"Energy-impact sample unavailable",
        @"rows": impactRows
    };

    CPUCounters previous = ReadCPUCounters();
    (void)ReadCoreClocks();   // baseline; ReadSystemState measures the quarter second after it
    [NSThread sleepForTimeInterval:0.25];
    SystemState system = ReadSystemState(&previous);
    NSDictionary *stats = SampleProcessStats(5);
    NSArray *cpuRows = [stats[@"cpu"] isKindOfClass:NSArray.class] ? stats[@"cpu"] : @[];
    NSArray *memoryRows = [stats[@"memory"] isKindOfClass:NSArray.class] ? stats[@"memory"] : @[];
    NSMutableArray<NSString *> *systemErrors = [NSMutableArray array];
    if (!system.cpuValid) [systemErrors addObject:@"CPU sample unavailable"];
    if (!system.memValid) [systemErrors addObject:@"Memory sample unavailable"];
    if (!system.swapValid) [systemErrors addObject:@"Swap sample unavailable"];
    if (!cpuRows.count && !memoryRows.count) [systemErrors addObject:@"Process sample unavailable"];
    snapshot[@"system"] = @{
        @"available": JSONBool(systemErrors.count == 0),
        @"error": systemErrors.count ? [systemErrors componentsJoinedByString:@"; "] : NSNull.null,
        @"pressure": SystemPressureLevel(system),
        @"cpuPercent": system.cpuValid ? @(system.cpu * 100.0) : NSNull.null,
        @"memoryPressure": MemoryPressureLevel(system),
        @"memoryTotalBytes": system.memValid ? @(system.memTotal) : NSNull.null,
        @"memoryUsedBytes": system.memValid ? @(system.memUsed) : NSNull.null,
        @"memoryAvailableBytes": system.memValid ? @(system.memAvailable) : NSNull.null,
        @"swapUsedBytes": system.swapValid ? @(system.swapUsed) : NSNull.null,
        @"cpuTempC": system.tempValid ? @(system.cpuTempC) : NSNull.null,
        @"thermalPressure": system.thermalValid ? ThermalPressureName(system.thermalPressure) : NSNull.null,
        @"processInfoThermalState": @(NSProcessInfo.processInfo.thermalState),
        @"fastCoreMHz": system.clocks.valid && system.clocks.pMHz > 0 ? @(system.clocks.pMHz) : NSNull.null,
        @"fastCoreTopMHz": system.clocks.valid ? @(system.clocks.pMaxMHz) : NSNull.null,
        @"fastCoreBusy": system.clocks.valid ? @(system.clocks.pBusy) : NSNull.null,
        @"efficiencyCoreMHz": system.clocks.valid && system.clocks.eMHz > 0 ? @(system.clocks.eMHz) : NSNull.null,
        @"efficiencyCoreTopMHz": system.clocks.valid && system.clocks.eMaxMHz > 0 ? @(system.clocks.eMaxMHz) : NSNull.null,
        @"topCPU": DumpProcessRows(cpuRows, YES),
        @"topMemory": DumpProcessRows(memoryRows, NO),
        @"processSampleAvailable": JSONBool(cpuRows.count > 0 || memoryRows.count > 0)
    };

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
                                 @"useCursorAccount": @NO}];
    BOOL accountEnabled = [defaults boolForKey:@"useClaudeAccount"];
    BOOL accountRequested = allowOnline && accountEnabled;
    BOOL cursorAccountEnabled = [defaults boolForKey:@"useCursorAccount"];
    BOOL cursorAccountRequested = allowOnline && cursorAccountEnabled;
    AIReader *reader = [[AIReader alloc] initWithHomeDirectory:GBHomeDirectory()];
    // Consent (toggle) controls whether the last-known account cache is used and whether
    // forget runs. Online permission only gates the network fetch — otherwise offline
    // --dump would call forget and wipe the disk cache.
    reader.allowCodexAccountFetch = allowOnline;
    reader.useClaudeAccount = accountEnabled;
    reader.allowClaudeAccountFetch = accountRequested;
    reader.useCursorAccount = cursorAccountEnabled;
    reader.allowCursorAccountFetch = cursorAccountRequested;
    reader.allowClaudeTranscripts = [defaults boolForKey:@"useClaudeTranscripts"];
    NSArray<AIUsage *> *usage = [reader readUntilCaughtUpWithTimeLimit:30.0];
    NSMutableArray *providers = [NSMutableArray array];
    BOOL anyAIAvailable = NO;
    for (AIUsage *item in usage) {
        anyAIAvailable |= item.available || item.limitStatusAvailable;
        BOOL quotaAvailable=item.limitStatusAvailable && item.remainingFraction>=0 && !CodexQuotaUnavailable(item);
        [providers addObject:@{
            @"name": item.name ?: @"AI",
            @"available": JSONBool(item.available),
            @"limitStatusAvailable": JSONBool(quotaAvailable),
            @"limitStale": JSONBool(item.limitStale || CodexQuotaUnavailable(item)),
            @"remainingPercent": quotaAvailable
                ? @(item.remainingFraction * 100.0) : NSNull.null,
            @"limitUpdatedAt": JSONValue(ISODateString(item.limitUpdatedAt)),
            @"limitRefreshError": JSONValue(item.limitRefreshError),
            @"reset": JSONValue(item.resetText),
            @"status": JSONValue(item.statusText),
            @"statusReason": JSONValue(item.statusReason),
            @"statusSource": JSONValue(item.statusSource),
            @"extraUsage": JSONValue(item.extraUsage),
            @"source": JSONValue(item.source),
            @"overageActive": JSONBool(item.overageActive),
            @"todayFreshTokens": @(item.todayTokens),
            @"todayAllTokens": @(item.todayTokensAll),
            @"sevenDayFreshTokens": @(item.weekTokens),
            @"sevenDayAllTokens": @(item.weekTokensAll),
            @"todaySessions": @(item.todaySessions),
            @"sevenDaySessions": @(item.weekSessions),
            @"todayMessages": @(item.todayMessages),
            @"todayToolCalls": @(item.todayToolCalls),
            @"billingNote": JSONValue(item.billingNote),
            @"windows": item.limitWindows ?: @[],
            @"models": item.models ?: @[],
            @"lastActivity": JSONValue(ISODateString(item.lastActivity)),
            @"diagnostics": JSONValue(item.diagnostics)
        }];
    }
    NSString *accountError = RequestedAIAccountError(usage, accountRequested);
    NSString *cursorAccountError = RequestedCursorAccountError(usage, cursorAccountRequested);
    NSMutableArray<NSString *> *aiErrors = [NSMutableArray array];
    if (!anyAIAvailable) [aiErrors addObject:@"No local AI status available"];
    if (reader.totalsIncomplete) [aiErrors addObject:@"AI history indexing incomplete"];
    if (accountError.length) [aiErrors addObject:[@"Claude account: " stringByAppendingString:accountError]];
    if (cursorAccountError.length)
        [aiErrors addObject:[@"Cursor account: " stringByAppendingString:cursorAccountError]];
    snapshot[@"ai"] = @{
        @"available": JSONBool(anyAIAvailable),
        @"error": aiErrors.count ? [aiErrors componentsJoinedByString:@"; "] : NSNull.null,
        @"onlineAllowed": JSONBool(allowOnline),
        @"accountEnabled": JSONBool(accountEnabled),
        @"accountRequested": JSONBool(accountRequested),
        @"cursorAccountEnabled": JSONBool(cursorAccountEnabled),
        @"cursorAccountRequested": JSONBool(cursorAccountRequested),
        @"transcriptsEnabled": JSONBool([defaults boolForKey:@"useClaudeTranscripts"]),
        @"totalsIncomplete": JSONBool(reader.totalsIncomplete),
        @"catchUpProgress": @(reader.catchUpProgress),
        @"catchUpStatus": reader.catchUpStatus,
        @"providers": providers
    };

    NSMutableArray<NSString *> *partialSources = [NSMutableArray array];
    if (!volumes.count) [partialSources addObject:@"storage"];
    if (!battery.valid) [partialSources addObject:@"battery"];
    if (!impactRows.count) [partialSources addObject:@"sampledEnergyImpact"];
    if (!system.cpuValid || !system.memValid) [partialSources addObject:@"system"];
    if (!system.swapValid) [partialSources addObject:@"system.swap"];
    if (!cpuRows.count && !memoryRows.count) [partialSources addObject:@"system.processes"];
    if (reader.totalsIncomplete) [partialSources addObject:@"ai.history"];
    if (!anyAIAvailable) [partialSources addObject:@"ai"];
    if (accountError.length) [partialSources addObject:@"ai.account"];
    if (cursorAccountError.length) [partialSources addObject:@"ai.cursorAccount"];
    snapshot[@"partialSources"] = partialSources;
    snapshot[@"status"] = partialSources.count ? @"partial" : @"complete";
    return snapshot;
}

static const char *UTF8(NSString *string) { return string.UTF8String ?: ""; }

static NSString *DumpBooleanTypeError(NSDictionary *snapshot) {
    NSArray<NSDictionary *> *groups = @[
        @{ @"name": @"storage", @"value": snapshot[@"storage"] ?: @{},
           @"keys": @[@"available"] },
        @{ @"name": @"battery", @"value": snapshot[@"battery"] ?: @{},
           @"keys": @[@"available", @"acConnected", @"charging", @"fullyCharged", @"atOrBelowReserve"] },
        @{ @"name": @"sampledEnergyImpact", @"value": snapshot[@"sampledEnergyImpact"] ?: @{},
           @"keys": @[@"available"] },
        @{ @"name": @"system", @"value": snapshot[@"system"] ?: @{},
           @"keys": @[@"available", @"processSampleAvailable"] },
        @{ @"name": @"ai", @"value": snapshot[@"ai"] ?: @{},
           @"keys": @[@"available", @"onlineAllowed", @"accountEnabled", @"accountRequested",
                       @"cursorAccountEnabled", @"cursorAccountRequested",
                       @"transcriptsEnabled", @"totalsIncomplete"] }
    ];
    for (NSDictionary *group in groups) {
        NSDictionary *value = group[@"value"];
        for (NSString *key in group[@"keys"])
            if (!IsJSONBoolean(value[key]))
                return [NSString stringWithFormat:@"%@.%@ must be a JSON boolean", group[@"name"], key];
    }
    for (NSDictionary *volume in snapshot[@"storage"][@"volumes"] ?: @[])
        if (!IsJSONBoolean(volume[@"internal"])) return @"storage.volumes[].internal must be a JSON boolean";
    for (NSDictionary *provider in snapshot[@"ai"][@"providers"] ?: @[])
        for (NSString *key in @[@"available", @"limitStatusAvailable", @"limitStale", @"overageActive"])
            if (!IsJSONBoolean(provider[key]))
                return [NSString stringWithFormat:@"ai.providers[].%@ must be a JSON boolean", key];
    return nil;
}

static void PrintHumanDump(NSDictionary *snapshot) {
    NSDictionary *storage = snapshot[@"storage"];
    NSArray *volumes = storage[@"volumes"];
    if (!volumes.count) printf("disk  unavailable\n");
    for (NSDictionary *volume in volumes)
        printf("disk  %-16s %3d%%  %s free\n", UTF8(volume[@"name"]),
               (int)lround([volume[@"usedPercent"] doubleValue]),
               UTF8(FmtBytes([volume[@"availableBytes"] longLongValue])));

    NSDictionary *battery = snapshot[@"battery"];
    if (![battery[@"available"] boolValue]) printf("batt  no battery detected\n");
    else {
        printf("batt  %d%% (%s)\n", [battery[@"percent"] intValue],
               [battery[@"acConnected"] boolValue] ? "on AC" : "on battery");
        if ([battery[@"atOrBelowReserve"] boolValue]) printf("      at or below the 20%% reserve\n");
        else if (battery[@"minutesUntil20Percent"] != NSNull.null)
            printf("      %s until 20%%\n", UTF8(FmtDuration([battery[@"minutesUntil20Percent"] intValue])));
        if (battery[@"healthPercent"] != NSNull.null) {
            if (battery[@"cycleCount"] != NSNull.null)
                printf("      health %d%% · %ld cycles\n",
                       (int)lround([battery[@"healthPercent"] doubleValue]),
                       [battery[@"cycleCount"] longValue]);
            else printf("      health %d%%\n", (int)lround([battery[@"healthPercent"] doubleValue]));
        }
        if (battery[@"cellTempC"] != NSNull.null)
            printf("      cells %ld °C\n", lround([battery[@"cellTempC"] doubleValue]));
    }

    printf("sampled energy impact:\n");
    NSArray *impact = snapshot[@"sampledEnergyImpact"][@"rows"];
    if (!impact.count) printf("  unavailable\n");
    for (NSDictionary *row in impact)
        printf("  %3d%%  %-18s %s\n", (int)lround([row[@"sampleSharePercent"] doubleValue]),
               UTF8(row[@"title"]), UTF8(row[@"detail"]));

    NSDictionary *system = snapshot[@"system"];
    NSString *cpu = system[@"cpuPercent"] == NSNull.null ? @"CPU unknown"
        : [NSString stringWithFormat:@"CPU %d%%", (int)lround([system[@"cpuPercent"] doubleValue])];
    NSString *memory = system[@"memoryAvailableBytes"] == NSNull.null ? @"Memory unknown"
        : [NSString stringWithFormat:@"Memory pressure %@ · %@ available", system[@"memoryPressure"],
           FmtMemBytes([system[@"memoryAvailableBytes"] longLongValue])];
    NSString *swap = system[@"swapUsedBytes"] == NSNull.null ? @"Swap unknown"
        : [system[@"swapUsedBytes"] unsignedLongLongValue] == 0 ? @"Swap none"
        : [NSString stringWithFormat:@"Swap %@", FmtMemBytes([system[@"swapUsedBytes"] longLongValue])];
    NSString *heat = [NSString stringWithFormat:@"%@ · thermal %@ (state %@)",
        system[@"cpuTempC"] == NSNull.null ? @"core temp unknown"
            : [NSString stringWithFormat:@"hottest core %ld °C", lround([system[@"cpuTempC"] doubleValue])],
        system[@"thermalPressure"] == NSNull.null ? @"unknown" : system[@"thermalPressure"], system[@"processInfoThermalState"]];
    printf("system %s · %s · %s\n       %s\n", UTF8(cpu), UTF8(memory), UTF8(swap), UTF8(heat));
    if (system[@"fastCoreTopMHz"] != NSNull.null) {
        NSString *(^clock)(NSString *, NSString *, NSString *) = ^NSString *(NSString *label, NSString *now, NSString *top) {
            return system[top] == NSNull.null ? nil : [NSString stringWithFormat:@"%@ %@ of %.1f GHz", label,
                system[now] == NSNull.null ? @"idle" : [NSString stringWithFormat:@"%.1f", [system[now] doubleValue] / 1000],
                [system[top] doubleValue] / 1000];
        };
        NSString *fast = clock(@"fast cores", @"fastCoreMHz", @"fastCoreTopMHz");
        NSString *slow = clock(@"efficiency cores", @"efficiencyCoreMHz", @"efficiencyCoreTopMHz");
        printf("       %s%s%s\n", UTF8(fast), slow ? " · " : "", slow ? UTF8(slow) : "");
    }
    NSArray *topCPU = system[@"topCPU"], *topMemory = system[@"topMemory"];
    if (!topCPU.count && !topMemory.count) printf("top apps unavailable\n");
    if (topCPU.count) {
        printf("top cpu:\n");
        for (NSDictionary *row in topCPU)
            printf("  %3.0f%%  %-18s %s\n", [row[@"cpuPercent"] doubleValue], UTF8(row[@"title"]), UTF8(row[@"detail"]));
    }
    if (topMemory.count) {
        printf("top memory:\n");
        for (NSDictionary *row in topMemory)
            printf("  %6s  %-18s %s\n", UTF8(FmtMemBytes([row[@"bytes"] longLongValue])),
                   UTF8(row[@"title"]), UTF8(row[@"detail"]));
    }

    NSDictionary *ai = snapshot[@"ai"];
    printf("ai toggles: useClaudeAccount=%s · useCursorAccount=%s · useClaudeTranscripts=%s · onlinePermission=%s · accountRequest=%s · cursorAccountRequest=%s\n",
           [ai[@"accountEnabled"] boolValue] ? "on" : "off",
           [ai[@"cursorAccountEnabled"] boolValue] ? "on" : "off",
           [ai[@"transcriptsEnabled"] boolValue] ? "on" : "off",
           [ai[@"onlineAllowed"] boolValue] ? "allowed" : "off",
           [ai[@"accountRequested"] boolValue] ? "enabled" : "off",
           [ai[@"cursorAccountRequested"] boolValue] ? "enabled" : "off");
    printf("ai status: %s\n", UTF8(ai[@"catchUpStatus"]));
    for (NSDictionary *provider in ai[@"providers"]) {
        NSString *remaining = provider[@"remainingPercent"] == NSNull.null ? @"remaining unavailable"
            : [NSString stringWithFormat:@"%d%% remaining", (int)lround([provider[@"remainingPercent"] doubleValue])];
        NSString *reset = provider[@"reset"] == NSNull.null ? @"reset unavailable"
            : [NSString stringWithFormat:@"resets %@", provider[@"reset"]];
        NSString *reason = provider[@"statusReason"] == NSNull.null ? @"" : provider[@"statusReason"];
        // The JSON's staleness, in words: a cached figure older than the poll interval
        // says its age, the same rule the popover row follows.
        NSString *stale = @"";
        NSDate *checked = provider[@"limitUpdatedAt"] != NSNull.null ? DateFromStatusString(provider[@"limitUpdatedAt"]) : nil;
        if ([provider[@"limitStale"] boolValue]) {
            NSTimeInterval age = checked ? -checked.timeIntervalSinceNow : -1;
            if (!checked) stale = @" · cached";
            else if (age >= kAccountPollInterval)
                stale = age < 3600 ? [NSString stringWithFormat:@" · cached %.0fm ago", age / 60]
                      : age < 86400 ? [NSString stringWithFormat:@" · cached %.0fh ago", age / 3600]
                      : [NSString stringWithFormat:@" · cached %.0fd ago", age / 86400];
        }
        printf("  %-7s %s · %s · today %s · 7d %s%s%s%s\n", UTF8(provider[@"name"]), UTF8(remaining), UTF8(reset),
               UTF8(FmtTokenCount([provider[@"todayFreshTokens"] longLongValue])),
               UTF8(FmtTokenCount([provider[@"sevenDayFreshTokens"] longLongValue])),
               reason.length ? " · " : "", UTF8(reason), UTF8(stale));
        for (NSDictionary *window in provider[@"windows"]) {
            NSString *windowReset = window[@"resetsAt"] ? ResetTextFromDate(
                [NSDate dateWithTimeIntervalSince1970:[window[@"resetsAt"] doubleValue]])
                : [window[@"fresh"] boolValue] ? @"not started" : @"not provided";
            NSString *name = [window[@"bucketLabel"] isKindOfClass:NSString.class]
                ? [NSString stringWithFormat:@"%@ (%@)", window[@"window"], window[@"bucketLabel"]] : window[@"window"];
            printf("          %-18s %d%% left · resets %s\n", UTF8(name),
                   (int)lround([window[@"remainingFraction"] doubleValue] * 100), UTF8(windowReset));
        }
        if (provider[@"billingNote"] != NSNull.null)
            printf("          billing: %s\n", UTF8(provider[@"billingNote"]));
        if (provider[@"diagnostics"] != NSNull.null)
            printf("          why: %s\n", UTF8(provider[@"diagnostics"]));
    }
    NSArray *partialSources = snapshot[@"partialSources"];
    if (partialSources.count)
        printf("status partial (%s)\n", UTF8([partialSources componentsJoinedByString:@", "]));
    else printf("status complete\n");
}

static BOOL PrintJSON(NSDictionary *snapshot) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    if (!data) {
        fprintf(stderr, "Glancebar: JSON encoding failed: %s\n", UTF8(error.localizedDescription));
        return NO;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return YES;
}

static BOOL PrintJSONDump(NSDictionary *snapshot) {
    NSString *schemaError = DumpBooleanTypeError(snapshot);
    if (schemaError) {
        fprintf(stderr, "Glancebar: JSON schema validation failed: %s\n", UTF8(schemaError));
        return NO;
    }
    return PrintJSON(snapshot);
}

// One compact JSON line of the machine's state, for a per-minute logger: CPU, memory,
// thermal pressure, core clocks, temperatures and battery. No process or AI sampling.
// A number written with the given decimals, so the JSON says 35.9, not 35.899999999999999.
static NSDecimalNumber *Decimal(double x, int places) {
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.*f", places, x]
                                             locale:@{NSLocaleDecimalSeparator: @"."}];
}

static int PrintSampleLine(void) {
    CPUCounters previous = ReadCPUCounters();
    (void)ReadCoreClocks();   // baseline for the clocks, like --dump
    [NSThread sleepForTimeInterval:0.5];
    SystemState s = ReadSystemState(&previous);
    BatteryState b = ReadBattery();
    double load[3] = {0};
    getloadavg(load, 3);
    double watts = BatteryWatts(b);
    NSMutableDictionary *line = [@{
        @"t": @((long long)NSDate.date.timeIntervalSince1970),
        @"load": @[Decimal(load[0], 2), Decimal(load[1], 2), Decimal(load[2], 2)],
        @"thermal": s.thermalValid ? (ThermalPressureName(s.thermalPressure) ?: NSNull.null) : NSNull.null,
        @"lowPower": JSONBool(LowPowerModeEnabled()),
    } mutableCopy];
    if (s.cpuValid) line[@"cpu"] = Decimal(s.cpu * 100, 1);
    if (s.memValid) { line[@"memUsedGB"] = Decimal(s.memUsed / 1e9, 1); line[@"memTotalGB"] = Decimal(s.memTotal / 1e9, 1); }
    line[@"memPressure"] = MemoryPressureLevel(s);
    if (s.swapValid) line[@"swapGB"] = Decimal(s.swapUsed / 1e9, 1);
    NSDictionary *volume = [[NSURL fileURLWithPath:NSHomeDirectory()] resourceValuesForKeys:
        @[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey] error:nil];
    if ([volume[NSURLVolumeTotalCapacityKey] doubleValue] > 0) {
        line[@"diskFreeGB"] = Decimal([volume[NSURLVolumeAvailableCapacityForImportantUsageKey] doubleValue] / 1e9, 1);
        line[@"diskTotalGB"] = Decimal([volume[NSURLVolumeTotalCapacityKey] doubleValue] / 1e9, 1);
    }
    NSMutableArray *volumeRecords = [NSMutableArray array];
    for (Volume *mounted in ScanVolumes()) [volumeRecords addObject:GlanceRecordForVolume(mounted)];
    NSArray *externalVolumes = GlanceExternalVolumes(volumeRecords);
    if (externalVolumes.count) line[@"volumes"] = externalVolumes;
    if (s.tempValid) line[@"chipC"] = Decimal(s.cpuTempC, 1);
    if (s.clocks.valid) {
        line[@"pMHz"] = @(lround(s.clocks.pMHz)); line[@"pTopMHz"] = @(lround(s.clocks.pMaxMHz));
        line[@"pBusy"] = Decimal(s.clocks.pBusy, 2);
        line[@"eMHz"] = @(lround(s.clocks.eMHz)); line[@"eTopMHz"] = @(lround(s.clocks.eMaxMHz));
        line[@"eBusy"] = Decimal(s.clocks.eBusy, 2);
    }
    if (b.valid) {
        line[@"batt"] = @(b.percent); line[@"ac"] = JSONBool(b.acConnected); line[@"charging"] = JSONBool(b.isCharging);
        if (b.tempC > 0) line[@"cellsC"] = Decimal(b.tempC, 1);
        if (!isnan(watts)) line[@"battW"] = Decimal(watts, 1);
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:nil];
    if (!data) return 70;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return 0;
}

static void PrintUsage(FILE *stream) {
    fprintf(stream,
        "Glancebar %s\n"
        "Usage: Glancebar [--dump [--json] [--strict] [--online]]\n"
        "       Glancebar --sample\n"
        "       Glancebar --show-popover | --show-fleet | --show-battery | --show-ai\n"
        "       Glancebar --version\n"
        "       Glancebar --help\n\n"
        "  --activity-json  Take one read-only app CPU/network snapshot.\n"
        "  --sample   Print one JSON line: CPU, memory, thermal pressure, clocks, temperatures, battery.\n"
        "  --show-fleet    Show and expand configured remote machines for this session.\n"
        "  --show-ai       Open the existing AI details tab.\n"
        "  --show-battery  Open the existing Battery details tab.\n"
        "  --show-popover  Show the existing popover, launching this app if needed; no Accessibility permission.\n"
        "  --dump     Print a local machine and AI status snapshot.\n"
        "  --json     Emit stable JSON (schemaVersion 1) instead of text.\n"
        "  --strict   Exit 2 when any sampled source is partial/unavailable.\n"
        "  --online   Permit the already-opted-in Claude and Cursor account requests.\n",
        UTF8(GBVersion));
}

// Launching an app bundle's executable directly leaves the process anonymous to
// Launch Services. On macOS 26, Control Centre can then persistently file the app's
// status item under the terminal (or another parent app) and inherit that app's
// "Allow in the Menu Bar" setting. Relaunch before NSApplication creates any item.
// CLI modes return above and intentionally remain ordinary direct processes.
static int RelaunchGUIThroughLaunchServicesIfNeeded(BOOL alreadyRelaunched, NSString *showDestination) {
    NSString *expected = NSBundle.mainBundle.bundleIdentifier;
    if (expected.length == 0) {
        fprintf(stderr, "Glancebar: app bundle has no identifier; refusing GUI launch\n");
        return 70;
    }

    NSString *running = NSRunningApplication.currentApplication.bundleIdentifier;
    if (!GUIRequiresLaunchServicesRelaunch(running, expected)) return -1;

    if (alreadyRelaunched) {
        fprintf(stderr, "Glancebar: Launch Services did not establish the app identity; refusing to relaunch again\n");
        return 70;
    }

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if (![[bundleURL.pathExtension lowercaseString] isEqualToString:@"app"]) {
        fprintf(stderr, "Glancebar: GUI mode must be launched from Glancebar.app\n");
        return 70;
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[bundleURL.path, @"--args", @"--glancebar-launch-services-relaunch"]];
    if (showDestination) [arguments addObject:[@"--show-" stringByAppendingString:showDestination]];
    task.arguments = arguments;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Glancebar: could not relaunch through Launch Services: %s\n",
                UTF8(error.localizedDescription));
        return 70;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        fprintf(stderr, "Glancebar: Launch Services relaunch failed (%d)\n",
                task.terminationStatus);
        return 70;
    }
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL dump = NO, json = NO, strict = NO, onlineArgument = NO, alreadyRelaunched = NO, activityJSON = NO, sample = NO;
        NSString *showDestination = nil;
        NSUInteger destinationCount = 0;
        const char *onlineEnvironment = getenv("GLANCEBAR_ALLOW_ACCOUNT");
        BOOL allowOnline = onlineEnvironment && strcmp(onlineEnvironment, "1") == 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--activity-json") == 0) activityJSON = YES;
            else if (strcmp(argv[i], "--show-popover") == 0 || strcmp(argv[i], "--show-fleet") == 0 || strcmp(argv[i], "--show-battery") == 0 || strcmp(argv[i], "--show-ai") == 0) {
                showDestination = [NSString stringWithUTF8String:argv[i] + 7]; destinationCount++;
            }
            else if (strcmp(argv[i], "--sample") == 0) sample = YES;
            else if (strcmp(argv[i], "--dump") == 0) dump = YES;
            else if (strcmp(argv[i], "--json") == 0) json = YES;
            else if (strcmp(argv[i], "--strict") == 0) strict = YES;
            else if (strcmp(argv[i], "--online") == 0) { allowOnline = YES; onlineArgument = YES; }
            else if (strcmp(argv[i], "--glancebar-launch-services-relaunch") == 0)
                alreadyRelaunched = YES;
            else if (strcmp(argv[i], "--version") == 0) { printf("Glancebar %s\n", UTF8(GBVersion)); return 0; }
            else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) { PrintUsage(stdout); return 0; }
            else { fprintf(stderr, "Glancebar: unknown option '%s'\n", argv[i]); PrintUsage(stderr); return 64; }
        }
        if (destinationCount > 1 || (showDestination && (dump || json || strict || onlineArgument || activityJSON || sample))) {
            fprintf(stderr, "Glancebar: show destinations cannot be combined with each other or snapshot options\n");
            return 64;
        }
        if (showDestination) {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.iantodd.glancebar";
            for (NSRunningApplication *owner in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
                if (owner.processIdentifier == getpid() || owner.isTerminated) continue;
                [NSDistributedNotificationCenter.defaultCenter postNotificationName:kShowPopoverNotification
                    object:PopoverRequestObject() userInfo:@{@"destination": showDestination} deliverImmediately:YES];
                return 0; // Request delivered to the user's session; not a visibility receipt.
            }
        }
        if (sample) return PrintSampleLine();
        if (activityJSON) return PrintJSON(GBActivitySurvey()) ? 0 : 70;
        if ((json || strict || onlineArgument) && !dump) {
            fprintf(stderr, "Glancebar: --json, --strict, and --online require --dump\n");
            return 64;
        }
        if (dump) {
            NSDictionary *snapshot = DumpSnapshot(allowOnline);
            if (json) {
                if (!PrintJSONDump(snapshot)) return 70;
            } else PrintHumanDump(snapshot);
            return strict && [snapshot[@"status"] isEqualToString:@"partial"] ? 2 : 0;
        }
        int relaunchResult = RelaunchGUIThroughLaunchServicesIfNeeded(alreadyRelaunched, showDestination);
        if (relaunchResult >= 0) return relaunchResult;
        NSApplication *app = NSApplication.sharedApplication;
        Controller *controller = [Controller new];
        controller.showDestinationOnLaunch = showDestination;
        app.delegate = controller;
        [app run];
    }
    return 0;
}
