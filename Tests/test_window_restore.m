#import <Foundation/Foundation.h>
#import <stdarg.h>
#import "window_restore.h"

static int checks;
static void Check(BOOL yes, NSString *message) {
    checks++;
    if (!yes) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSNumber *, NSDictionary *> *gMocks;
static NSInteger gUnminimizedToken = NSNotFound;

static AXUIElementRef MockRef(NSInteger token) { return (AXUIElementRef)(intptr_t)token; }

static NSDictionary *MockFor(AXUIElementRef element) {
    return gMocks[@((NSInteger)(intptr_t)element)];
}

static void RegisterMock(NSInteger token, NSDictionary *fields) {
    NSMutableDictionary *next = [gMocks mutableCopy] ?: [NSMutableDictionary dictionary];
    next[@(token)] = fields;
    gMocks = next;
}

static AXError MockCopy(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value) {
    NSDictionary *mock = MockFor(element);
    if (!mock) return kAXErrorInvalidUIElement;
    if ([mock[@"stale"] boolValue]) return kAXErrorInvalidUIElement;
    if ([mock[@"notElement"] boolValue]) return kAXErrorInvalidUIElement;
    if (CFEqual(attribute, kAXRoleAttribute)) {
        NSString *role = mock[@"role"];
        if (!role) return kAXErrorAttributeUnsupported;
        *value = CFBridgingRetain(role);
        return kAXErrorSuccess;
    }
    if (CFEqual(attribute, kAXSubroleAttribute)) {
        NSString *subrole = mock[@"subrole"];
        if (!subrole) return kAXErrorNoValue;
        *value = CFBridgingRetain(subrole);
        return kAXErrorSuccess;
    }
    if (CFEqual(attribute, kAXMinimizedAttribute)) {
        NSNumber *mini = mock[@"minimized"];
        if (!mini) return kAXErrorNoValue;
        *value = mini.boolValue ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(*value);
        return kAXErrorSuccess;
    }
    return kAXErrorAttributeUnsupported;
}

static AXError MockSet(AXUIElementRef element, CFStringRef attribute, CFTypeRef value) {
    (void)attribute;
    (void)value;
    NSDictionary *mock = MockFor(element);
    if (!mock || [mock[@"stale"] boolValue]) return kAXErrorInvalidUIElement;
    gUnminimizedToken = (NSInteger)(intptr_t)element;
    return kAXErrorSuccess;
}

// NSArray retains elements; AX test tokens are raw pointers, so use a non-retaining CFArray.
static NSArray *WindowList(NSInteger first, ...) {
    AXUIElementRef refs[32];
    size_t count = 0;
    va_list args;
    va_start(args, first);
    for (NSInteger token = first; token != 0 && count < sizeof(refs) / sizeof(refs[0]); token = va_arg(args, NSInteger))
        refs[count++] = MockRef(token);
    va_end(args);
    CFArrayRef raw = CFArrayCreate(kCFAllocatorDefault, (const void **)refs, (CFIndex)count, NULL);
    return CFBridgingRelease(raw);
}

int main(void) {
    @autoreleasepool {
        const pid_t own = 4242;
        const pid_t finder = 5599;
        Check(!GBWindowRestorePermitsMutation(100, 101, own), @"stale frontmost blocks restore");
        Check(!GBWindowRestorePermitsMutation(own, own, own), @"never while Glancebar is frontmost");
        Check(GBWindowRestorePermitsMutation(100, 100, own), @"matched frontmost permits restore");

        GBWindowRestoreRow visibleOnly[] = {{.standard = YES, .minimized = NO, .token = 1}};
        Check(!GBWindowRestoreShouldAct(visibleOnly, 1), @"visible standard window means no action");

        GBWindowRestoreRow minimizedOnly[] = {{.standard = YES, .minimized = YES, .token = 1},
                                              {.standard = YES, .minimized = YES, .token = 2}};
        Check(GBWindowRestoreShouldAct(minimizedOnly, 2), @"all minimized standards trigger restore");

        GBWindowRestoreRow mixed[] = {{.standard = YES, .minimized = YES, .token = 1},
                                      {.standard = YES, .minimized = NO, .token = 2}};
        Check(!GBWindowRestoreShouldAct(mixed, 2), @"any visible standard blocks restore");

        GBWindowRestoreRow sheet[] = {{.standard = NO, .minimized = YES, .token = 1}};
        Check(!GBWindowRestoreShouldAct(sheet, 1), @"non-standard windows are ignored");

        Check(GBWindowRestoreSelectTarget(minimizedOnly, 2, NSNotFound) == 1, @"first minimized window");
        minimizedOnly[0].focused = YES;
        Check(GBWindowRestoreSelectTarget(minimizedOnly, 2, 2) == 2, @"remembered minimized window");
        Check(GBWindowRestoreSelectTarget(minimizedOnly, 2, 99) == 1,
              @"missing remembered token falls back to first");

        GBWindowRestoreTestSetAXHooks(MockCopy, MockSet);
        GBWindowRestoreTestSetFrontmostPID(finder);
        gMocks = @{};
        gUnminimizedToken = NSNotFound;

        RegisterMock(1, @{@"role" : @"AXWindow"});
        RegisterMock(2, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @YES});
        Check(GBWindowRestoreTestRunRestorePass(WindowList(1, 2, 0), finder, own),
              @"Finder-like desktop missing subrole still restores minimized standard");
        Check(gUnminimizedToken == 2, @"unminimize targets standard window not desktop");

        gMocks = @{};
        RegisterMock(10, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @YES});
        RegisterMock(11, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @NO});
        gUnminimizedToken = NSNotFound;
        Check(!GBWindowRestoreTestRunRestorePass(WindowList(10, 11, 0), finder, own),
              @"visible standard blocks restore");
        Check(gUnminimizedToken == NSNotFound, @"no mutation when blocked");

        gMocks = @{};
        RegisterMock(20, @{@"stale" : @YES});
        RegisterMock(21, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @YES});
        gUnminimizedToken = NSNotFound;
        Check(GBWindowRestoreTestRunRestorePass(WindowList(20, 21, 0), finder, own),
              @"stale window skipped; later minimized standard restores");
        Check(gUnminimizedToken == 21, @"restore hits valid minimized window");

        GBWindowRestoreTestSetFrontmostPID(9999);
        gUnminimizedToken = NSNotFound;
        gMocks = @{};
        RegisterMock(21, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @YES});
        Check(!GBWindowRestoreTestRunRestorePass(WindowList(21, 0), finder, own),
              @"stale activation frontmost blocks mutation");
        Check(gUnminimizedToken == NSNotFound, @"no mutation when frontmost stale");

        GBWindowRestoreTestSetFrontmostPID(finder);
        gMocks = @{};
        RegisterMock(30, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow"});
        RegisterMock(31, @{@"role" : @"AXWindow", @"subrole" : @"AXStandardWindow", @"minimized" : @YES});
        gUnminimizedToken = NSNotFound;
        Check(GBWindowRestoreTestRunRestorePass(WindowList(30, 31, 0), finder, own),
              @"missing minimized on one standard does not block restore");
        Check(gUnminimizedToken == 31, @"restore selects window with known minimized=yes");

        gMocks = @{};
        RegisterMock(40, @{@"role": @"AXWindow", @"subrole": @"AXDialog", @"minimized": @YES});
        RegisterMock(41, @{@"role": @"AXWindow", @"subrole": @"AXFloatingWindow", @"minimized": @NO});
        gUnminimizedToken = NSNotFound;
        Check(GBWindowRestoreTestRunRestorePass(WindowList(40, 41, 0), finder, own),
              @"minimized nonstandard window restores despite visible auxiliary window");
        Check(gUnminimizedToken == 40, @"only the genuinely minimized window is restored");
        RegisterMock(42, @{@"role": @"AXWindow", @"subrole": @"AXStandardWindow", @"minimized": @NO});
        gUnminimizedToken = NSNotFound;
        Check(!GBWindowRestoreTestRunRestorePass(WindowList(40, 42, 0), finder, own),
              @"visible standard still prevents restoring nonstandard minimized window");
        Check(gUnminimizedToken == NSNotFound, @"visible standard prevents mutation");
        GBWindowRestoreTestResetAXHooks();

        printf("window_restore: %d checks passed\n", checks);
    }
    return 0;
}