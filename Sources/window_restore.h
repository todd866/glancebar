// Opt-in: when you Command-Tab to a regular app that has only minimized standard windows,
// raise one of them. Off by default (`restoreMinimizedOnActivate`). Needs Accessibility
// (Glancebar already uses it for fine volume).
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

FOUNDATION_EXPORT NSString * const GBWindowRestorePreferenceKey;
FOUNDATION_EXPORT NSString * const GBWindowRestoreDebugKey;

typedef struct {
    BOOL standard;
    BOOL minimized;
    BOOL focused;
    NSInteger token;
} GBWindowRestoreRow;

// YES when the app has minimized standard windows and no visible standard window.
BOOL GBWindowRestoreShouldAct(const GBWindowRestoreRow *rows, size_t count);

// Minimized standard window to unminimize: last focused token if still minimized, else first.
NSInteger GBWindowRestoreSelectTarget(const GBWindowRestoreRow *rows, size_t count, NSInteger rememberedToken);

// Block stale queued work and never touch Glancebar's own activation.
BOOL GBWindowRestorePermitsMutation(pid_t expectedPID, pid_t frontmostPID, pid_t ownPID);

void GBWindowRestoreStart(void);
void GBWindowRestoreStop(void);

typedef AXError (*GBWindowRestoreCopyAttributeFn)(AXUIElementRef element, CFStringRef attribute,
                                                  CFTypeRef *value);
typedef AXError (*GBWindowRestoreSetAttributeFn)(AXUIElementRef element, CFStringRef attribute,
                                                 CFTypeRef value);

#ifdef GLANCEBAR_WINDOW_RESTORE_TEST
void GBWindowRestoreTestSetAXHooks(GBWindowRestoreCopyAttributeFn copyFn,
                                   GBWindowRestoreSetAttributeFn setFn);
void GBWindowRestoreTestResetAXHooks(void);
void GBWindowRestoreTestSetFrontmostPID(pid_t pid);

// Production scan + policy + single unminimize; hooks must be installed first.
BOOL GBWindowRestoreTestRunRestorePass(NSArray *windows, pid_t expectedPID, pid_t ownPID);
#endif