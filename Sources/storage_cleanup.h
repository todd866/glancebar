#import <Foundation/Foundation.h>
// Destructive operations require an explicit reviewed row. Directories, packages,
// developer trees and cloud placeholders are never eligible. No permanent delete.
NSString *GBStorageCleanupReason(NSDictionary *entry, NSString *home, BOOL compress);
NSString *GBStorageOpenFileReason(NSString *path);
typedef NSString *(^GBStorageOpenCheck)(NSString *path);
typedef BOOL (^GBStorageTrashTransport)(NSURL *file, NSError **error);
NSDictionary *GBStorageTrash(NSDictionary *entry, NSString *home,
                            GBStorageOpenCheck openCheck, GBStorageTrashTransport transport);
NSDictionary *GBStorageCompress(NSDictionary *entry, NSString *home,
                               GBStorageOpenCheck openCheck, BOOL (^cancelled)(void));
