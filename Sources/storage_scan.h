#import <Foundation/Foundation.h>
NSDictionary *GBStorageIdentity(NSString *path);
BOOL GBStorageIdentityMatches(NSDictionary *a, NSDictionary *b);
NSString *GBStorageBoundaryReason(NSString *path);
@interface GBStorageScan : NSObject
@property(atomic, getter=isCancelled) BOOL cancelled;
- (NSDictionary *)scanPath:(NSString *)path entryLimit:(NSUInteger)limit seconds:(double)seconds;
@end
