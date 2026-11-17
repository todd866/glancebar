#import "window_restore.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>
#import <string.h>

NSString * const GBWindowRestorePreferenceKey = @"restoreMinimizedOnActivate";
NSString * const GBWindowRestoreDebugKey = @"windowRestoreDebug";

static NSString * const kGBWindowRestoreLogPrefix = @"[Glancebar window-restore]";

BOOL GBWindowRestoreShouldAct(const GBWindowRestoreRow *rows, size_t count) {
    BOOL minimized = NO;
    for (size_t i = 0; i < count; i++) {
        if (!rows[i].standard) continue;
        if (!rows[i].minimized) return NO;
        minimized = YES;
    }
    return minimized;
}

NSInteger GBWindowRestoreSelectTarget(const GBWindowRestoreRow *rows, size_t count, NSInteger rememberedToken) {
    for (size_t i = 0; i < count; i++)
        if (rows[i].standard && rows[i].minimized && rows[i].token == rememberedToken)
            return rememberedToken;
    for (size_t i = 0; i < count; i++)
        if (rows[i].standard && rows[i].minimized) return rows[i].token;
    return NSNotFound;
}

BOOL GBWindowRestorePermitsMutation(pid_t expectedPID, pid_t frontmostPID, pid_t ownPID) {
    return expectedPID > 0 && expectedPID == frontmostPID && expectedPID != ownPID;
}

static BOOL DebugEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:GBWindowRestoreDebugKey];
}

static void DebugLog(NSString *format, ...) {
    if (!DebugEnabled()) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", kGBWindowRestoreLogPrefix, message);
}

static AXError DefaultCopyAttribute(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    return AXUIElementCopyAttributeValue(element, attribute, value);
}

static AXError DefaultSetAttribute(AXUIElementRef element, CFStringRef attribute, CFTypeRef value) {
    return AXUIElementSetAttributeValue(element, attribute, value);
}

static GBWindowRestoreCopyAttributeFn gCopyAttribute = DefaultCopyAttribute;
static GBWindowRestoreSetAttributeFn gSetAttribute = DefaultSetAttribute;

static BOOL UsingTestAXHooks(void) {
    return gCopyAttribute != DefaultCopyAttribute || gSetAttribute != DefaultSetAttribute;
}

#if GLANCEBAR_WINDOW_RESTORE_TEST
void GBWindowRestoreTestSetAXHooks(GBWindowRestoreCopyAttributeFn copyFn,
                                   GBWindowRestoreSetAttributeFn setFn) {
    gCopyAttribute = copyFn ?: DefaultCopyAttribute;
    gSetAttribute = setFn ?: DefaultSetAttribute;
}

void GBWindowRestoreTestResetAXHooks(void) {
    gCopyAttribute = DefaultCopyAttribute;
    gSetAttribute = DefaultSetAttribute;
}
#endif

// The queue lives for the process lifetime. Stopping invalidates queued attempts;
// restarting never resets the generation, so old work cannot become current again.
static dispatch_queue_t gQueue;
static id gObserver;
static _Atomic uint64_t gGeneration;
static _Atomic BOOL gRunning;
static _Atomic pid_t gFrontmostPID;

static pid_t FrontmostOnMainThread(void) {
    if (NSThread.isMainThread)
        return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    __block pid_t front = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    });
    return front;
}

static BOOL Current(pid_t pid, uint64_t generation) {
    pid_t front = atomic_load(&gFrontmostPID);
    if (front <= 0) front = FrontmostOnMainThread();
    return atomic_load(&gRunning) && generation == atomic_load(&gGeneration)
        && [NSUserDefaults.standardUserDefaults boolForKey:GBWindowRestorePreferenceKey]
        && GBWindowRestorePermitsMutation(pid, front, getpid());
}

typedef BOOL (^GBWindowRestoreAliveBlock)(void);

// Inspect role then subrole; skip non-standard and incomplete standard rows without aborting the scan.
static BOOL GBWindowRestoreScanOneWindow(AXUIElementRef window, NSInteger token, GBWindowRestoreRow *outRow,
                                         GBWindowRestoreAliveBlock alive) {
    if (!alive()) return NO;
    if (!window) {
        DebugLog(@"window[%ld] skip null element", (long)token);
        return YES;
    }
    if (!UsingTestAXHooks() && CFGetTypeID(window) != AXUIElementGetTypeID()) {
        DebugLog(@"window[%ld] skip invalid element", (long)token);
        return YES;
    }
    if (!UsingTestAXHooks()) AXUIElementSetMessagingTimeout(window, 0.15f);

    CFTypeRef role = NULL;
    AXError error = gCopyAttribute(window, kAXRoleAttribute, &role);
    if (error == kAXErrorInvalidUIElement || error == kAXErrorCannotComplete) {
        if (role) CFRelease(role);
        DebugLog(@"window[%ld] stale role err=%d", (long)token, error);
        return YES;
    }
    if (error != kAXErrorSuccess || !role) {
        if (role) CFRelease(role);
        DebugLog(@"window[%ld] skip role err=%d", (long)token, error);
        return YES;
    }
    BOOL isWindow = CFGetTypeID(role) == CFStringGetTypeID() && CFEqual(role, kAXWindowRole);
    CFRelease(role);
    if (!isWindow) {
        DebugLog(@"window[%ld] skip non-window role", (long)token);
        return YES;
    }

    CFTypeRef subrole = NULL;
    error = gCopyAttribute(window, kAXSubroleAttribute, &subrole);
    if (error == kAXErrorInvalidUIElement || error == kAXErrorCannotComplete) {
        if (subrole) CFRelease(subrole);
        DebugLog(@"window[%ld] stale subrole err=%d", (long)token, error);
        return YES;
    }
    if (error != kAXErrorSuccess || !subrole) {
        if (subrole) CFRelease(subrole);
        DebugLog(@"window[%ld] skip missing subrole err=%d", (long)token, error);
        return YES;
    }
    BOOL standard = CFGetTypeID(subrole) == CFStringGetTypeID() && CFEqual(subrole, kAXStandardWindowSubrole);
    CFRelease(subrole);
    if (!standard) {
        DebugLog(@"window[%ld] skip auxiliary subrole", (long)token);
        return YES;
    }

    CFTypeRef mini = NULL;
    error = gCopyAttribute(window, kAXMinimizedAttribute, &mini);
    if (error == kAXErrorInvalidUIElement || error == kAXErrorCannotComplete) {
        if (mini) CFRelease(mini);
        DebugLog(@"window[%ld] stale minimized err=%d", (long)token, error);
        return YES;
    }
    if (error != kAXErrorSuccess || !mini || CFGetTypeID(mini) != CFBooleanGetTypeID()) {
        if (mini) CFRelease(mini);
        DebugLog(@"window[%ld] skip missing minimized err=%d", (long)token, error);
        return YES;
    }
    *outRow = (GBWindowRestoreRow){.standard = YES,
        .minimized = CFBooleanGetValue((CFBooleanRef)mini), .token = token};
    DebugLog(@"window[%ld] standard minimized=%d", (long)token, outRow->minimized);
    CFRelease(mini);
    return YES;
}

static BOOL GBWindowRestoreScanWindows(NSArray *windows, GBWindowRestoreRow *rows, size_t capacity,
                                       GBWindowRestoreAliveBlock alive) {
    size_t count = windows.count < capacity ? (size_t)windows.count : capacity;
    memset(rows, 0, capacity * sizeof(GBWindowRestoreRow));
    for (NSUInteger i = 0; i < count; i++) {
        AXUIElementRef window;
        if (UsingTestAXHooks())
            window = (AXUIElementRef)CFArrayGetValueAtIndex((__bridge CFArrayRef)windows, (CFIndex)i);
        else
            window = (__bridge AXUIElementRef)windows[i];
        if (!GBWindowRestoreScanOneWindow(window, (NSInteger)i, &rows[i], alive))
            return NO;
    }
    return YES;
}

static BOOL GBWindowRestoreApplyRestore(NSArray *windows, const GBWindowRestoreRow *rows, size_t count,
                                        pid_t pid, uint64_t generation) {
    if (!GBWindowRestoreShouldAct(rows, count)) {
        DebugLog(@"pid=%d no restore (policy)", pid);
        return NO;
    }
    NSInteger target = GBWindowRestoreSelectTarget(rows, count, NSNotFound);
    if (target == NSNotFound || target < 0 || (NSUInteger)target >= windows.count) return NO;

    pid_t front = FrontmostOnMainThread();
    atomic_store(&gFrontmostPID, front);
    if (!GBWindowRestorePermitsMutation(pid, front, getpid()) || !Current(pid, generation)) {
        DebugLog(@"pid=%d blocked before mutation front=%d", pid, front);
        return NO;
    }

    AXUIElementRef window;
    if (UsingTestAXHooks())
        window = (AXUIElementRef)CFArrayGetValueAtIndex((__bridge CFArrayRef)windows, (CFIndex)target);
    else
        window = (__bridge AXUIElementRef)windows[(NSUInteger)target];
    AXError error = gSetAttribute(window, kAXMinimizedAttribute, kCFBooleanFalse);
    DebugLog(@"pid=%d unminimize token=%ld err=%d", pid, (long)target, error);
    return error == kAXErrorSuccess;
}

static void Schedule(pid_t pid, uint64_t generation, unsigned attempt);

static void TryRestore(pid_t pid, uint64_t generation, unsigned attempt) {
    @autoreleasepool {
        BOOL trusted = AXIsProcessTrusted();
        if (!Current(pid, generation) || !trusted) {
            DebugLog(@"pid=%d attempt=%u skip trusted=%d", pid, attempt, trusted);
            return;
        }
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, 0.15f);
        CFTypeRef raw = NULL;
        AXError error = gCopyAttribute(app, kAXWindowsAttribute, &raw);
        CFRelease(app);
        if (error != kAXErrorSuccess || !raw || CFGetTypeID(raw) != CFArrayGetTypeID()) {
            if (raw) CFRelease(raw);
            DebugLog(@"pid=%d windows err=%d attempt=%u", pid, error, attempt);
            if (attempt < 2 && Current(pid, generation)) Schedule(pid, generation, attempt + 1);
            return;
        }
        NSArray *windows = CFBridgingRelease(raw);
        DebugLog(@"pid=%d windows count=%lu attempt=%u", pid, (unsigned long)windows.count, attempt);
        if (windows.count == 0) {
            if (attempt < 2 && Current(pid, generation)) Schedule(pid, generation, attempt + 1);
            return;
        }
        if (windows.count > 128) {
            DebugLog(@"pid=%d skip huge window list", pid);
            return;
        }
        GBWindowRestoreRow rows[128];
        double deadline = NSProcessInfo.processInfo.systemUptime + 0.6;
        GBWindowRestoreAliveBlock alive = ^BOOL {
            return Current(pid, generation) && NSProcessInfo.processInfo.systemUptime <= deadline;
        };
        if (!GBWindowRestoreScanWindows(windows, rows, windows.count, alive)) return;
        (void)GBWindowRestoreApplyRestore(windows, rows, windows.count, pid, generation);
    }
}

#if GLANCEBAR_WINDOW_RESTORE_TEST
void GBWindowRestoreTestSetFrontmostPID(pid_t pid) { atomic_store(&gFrontmostPID, pid); }

BOOL GBWindowRestoreTestRunRestorePass(NSArray *windows, pid_t expectedPID, pid_t ownPID) {
    if (windows.count > 128) return NO;
    GBWindowRestoreRow rows[128];
    double deadline = NSProcessInfo.processInfo.systemUptime + 60.0;
    GBWindowRestoreAliveBlock alive = ^BOOL { return NSProcessInfo.processInfo.systemUptime <= deadline; };
    if (!GBWindowRestoreScanWindows(windows, rows, windows.count, alive)) return NO;
    if (!GBWindowRestoreShouldAct(rows, windows.count)) return NO;
    if (!GBWindowRestorePermitsMutation(expectedPID, atomic_load(&gFrontmostPID), ownPID)) return NO;
    NSInteger target = GBWindowRestoreSelectTarget(rows, windows.count, NSNotFound);
    if (target == NSNotFound) return NO;
    AXUIElementRef window;
    if (UsingTestAXHooks())
        window = (AXUIElementRef)CFArrayGetValueAtIndex((__bridge CFArrayRef)windows, (CFIndex)target);
    else
        window = (__bridge AXUIElementRef)windows[(NSUInteger)target];
    AXError error = gSetAttribute(window, kAXMinimizedAttribute, kCFBooleanFalse);
    return error == kAXErrorSuccess;
}
#endif

static void Schedule(pid_t pid, uint64_t generation, unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), gQueue, ^{
        TryRestore(pid, generation, attempt);
    });
}

void GBWindowRestoreStart(void) {
    NSCAssert(NSThread.isMainThread, @"Window restore lifecycle must run on main");
    if (gObserver || ![NSUserDefaults.standardUserDefaults boolForKey:GBWindowRestorePreferenceKey]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("com.iantodd.glancebar.window-restore", DISPATCH_QUEUE_SERIAL);
    });
    atomic_store(&gRunning, YES);
    BOOL trusted = AXIsProcessTrusted();
    DebugLog(@"observer install trusted=%d", trusted);
    gObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            uint64_t generation = atomic_fetch_add(&gGeneration, 1) + 1;
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            pid_t pid = app.processIdentifier;
            atomic_store(&gFrontmostPID, pid);
            DebugLog(@"activate bundle=%@ pid=%d policy=%ld gen=%llu", app.bundleIdentifier, pid,
                     (long)app.activationPolicy, generation);
            if (app.activationPolicy != NSApplicationActivationPolicyRegular || pid == getpid()) return;
            Schedule(pid, generation, 0);
        }];
}

void GBWindowRestoreStop(void) {
    NSCAssert(NSThread.isMainThread, @"Window restore lifecycle must run on main");
    atomic_store(&gRunning, NO);
    atomic_fetch_add(&gGeneration, 1);
    if (gObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:gObserver];
    gObserver = nil;
    DebugLog(@"observer removed");
}