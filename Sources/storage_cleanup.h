#import <Foundation/Foundation.h>
// Trash requires an explicit file action. Directories, packages,
// developer trees and cloud placeholders are never eligible. No permanent delete.
NSString *GBStorageCleanupReason(NSDictionary *entry, NSString *home, BOOL compress);
NSString *GBStorageOpenFileReason(NSString *path);
typedef NSString *(^GBStorageOpenCheck)(NSString *path);
typedef BOOL (^GBStorageTrashTransport)(NSURL *file, NSURL **resultingURL, NSError **error);
NSDictionary *GBStorageTrash(NSDictionary *entry, NSString *home,
                            GBStorageOpenCheck openCheck, GBStorageTrashTransport transport);
// Pass the unchanged successful Trash result. Undo records are process-local,
// bounded to the latest 16 moves and consumed after a successful restore.
NSDictionary *GBStorageRestore(NSDictionary *record, NSString *home);
NSDictionary *GBStorageCompress(NSDictionary *entry, NSString *home,
                               GBStorageOpenCheck openCheck, BOOL (^cancelled)(void));
