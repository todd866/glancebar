#import <Foundation/Foundation.h>
#import "window_restore.h"

static int checks;
static void Check(BOOL yes, NSString *message) {
  checks++;
  if (!yes) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    const pid_t own = 4242;
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

    printf("window_restore: %d checks passed\n", checks);
  }
  return 0;
}