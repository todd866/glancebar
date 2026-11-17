#import "window_restore.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdatomic.h>

NSString * const GBWindowRestorePreferenceKey = @"restoreMinimizedOnActivate";

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

// The queue lives for the process lifetime. Stopping invalidates queued attempts;
// restarting never resets the generation, so old work cannot become current again.
static dispatch_queue_t gQueue;
static id gObserver;
static _Atomic uint64_t gGeneration;
static _Atomic BOOL gRunning;

static BOOL Current(pid_t pid, uint64_t generation) {
    return atomic_load(&gRunning) && generation == atomic_load(&gGeneration)
        && [NSUserDefaults.standardUserDefaults boolForKey:GBWindowRestorePreferenceKey]
        && GBWindowRestorePermitsMutation(pid,
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, getpid());
}

static void Schedule(pid_t pid, uint64_t generation, unsigned attempt);

static void TryRestore(pid_t pid, uint64_t generation, unsigned attempt) {
    @autoreleasepool {
        if (!Current(pid, generation) || !AXIsProcessTrusted()) return;
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, 0.15f);
        CFTypeRef raw = NULL;
        AXError error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &raw);
        CFRelease(app);
        if (error != kAXErrorSuccess || !raw || CFGetTypeID(raw) != CFArrayGetTypeID()) {
            if (raw) CFRelease(raw);
            if (attempt < 2 && Current(pid, generation)) Schedule(pid, generation, attempt + 1);
            return;
        }
        NSArray *windows = CFBridgingRelease(raw);
        if (windows.count == 0) {
            if (attempt < 2 && Current(pid, generation)) Schedule(pid, generation, attempt + 1);
            return;
        }
        // Fail closed for huge or slow window lists; never stall the app's UI.
        if (windows.count > 128) return;
        GBWindowRestoreRow rows[128] = {0};
        double deadline = NSProcessInfo.processInfo.systemUptime + 0.6;
        for (NSUInteger i = 0; i < windows.count; i++) {
            if (!Current(pid, generation) || NSProcessInfo.processInfo.systemUptime > deadline) return;
            CFTypeRef element = (__bridge CFTypeRef)windows[i];
            if (CFGetTypeID(element) != AXUIElementGetTypeID()) return;
            AXUIElementRef window = (AXUIElementRef)element;
            AXUIElementSetMessagingTimeout(window, 0.15f);
            CFTypeRef subrole = NULL;
            error = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute, &subrole);
            if (error != kAXErrorSuccess || !subrole) {
                if (subrole) CFRelease(subrole);
                return;
            }
            BOOL standard = CFEqual(subrole, kAXStandardWindowSubrole);
            CFRelease(subrole);
            if (!standard) continue;
            CFTypeRef mini = NULL;
            error = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute, &mini);
            if (error != kAXErrorSuccess || !mini || CFGetTypeID(mini) != CFBooleanGetTypeID()) {
                if (mini) CFRelease(mini);
                return;
            }
            rows[i] = (GBWindowRestoreRow){.standard = YES,
                .minimized = CFBooleanGetValue((CFBooleanRef)mini), .token = (NSInteger)i};
            CFRelease(mini);
        }
        if (!GBWindowRestoreShouldAct(rows, windows.count)) return;
        NSInteger target = GBWindowRestoreSelectTarget(rows, windows.count, NSNotFound);
        if (target == NSNotFound || !Current(pid, generation)) return;
        // Unminimizing already exposes the window. No extra raise/activate call
        // that could pull focus back after the user has moved to a different app.
        AXUIElementSetAttributeValue((__bridge AXUIElementRef)windows[(NSUInteger)target],
                                    kAXMinimizedAttribute, kCFBooleanFalse);
    }
}

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
    gObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            uint64_t generation = atomic_fetch_add(&gGeneration, 1) + 1;
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.processIdentifier == getpid()) return;
            Schedule(app.processIdentifier, generation, 0);
        }];
}

void GBWindowRestoreStop(void) {
    NSCAssert(NSThread.isMainThread, @"Window restore lifecycle must run on main");
    atomic_store(&gRunning, NO);
    atomic_fetch_add(&gGeneration, 1);
    if (gObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:gObserver];
    gObserver = nil;
}
