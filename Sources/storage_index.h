#import <Foundation/Foundation.h>
// Single serial background owner. Pause is atomic; advance resumes the same walk.
@interface GBStorageIndex : NSObject
@property(atomic) BOOL paused;
@property(readonly) BOOL finished;
- (instancetype)initWithRoots:(NSArray<NSString *> *)roots home:(NSString *)home;
- (NSDictionary *)advanceForSeconds:(double)seconds entries:(NSUInteger)entries;
- (NSDictionary *)snapshot;
- (void)removeFile:(NSDictionary *)entry;
@end
NSArray<NSString *> *GBStorageDefaultRoots(NSString *home);
// Retains only the largest limit rows; returned entries are the input objects.
NSArray<NSDictionary *> *GBStorageLargestRows(NSArray<NSDictionary *> *rows, NSUInteger limit);
// Publish fresh progress without losing previously known leaders mid-pass.
// Retained values are explicitly marked cached; completion retires them.
NSDictionary *GBStorageMergeSnapshot(NSDictionary *fresh, NSDictionary *previous);
// Private local cache; call on the same background queue as the index.
NSDictionary *GBStorageLoadCache(NSString *directory, NSString *home);
void GBStorageSaveCache(NSDictionary *snapshot, NSString *directory, NSString *home);
