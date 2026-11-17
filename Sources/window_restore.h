// Opt-in: when you Command-Tab to a regular app that has only minimized standard windows,
// raise one of them. Off by default (`restoreMinimizedOnActivate`). Needs Accessibility
// (Glancebar already uses it for fine volume).
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const GBWindowRestorePreferenceKey;

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