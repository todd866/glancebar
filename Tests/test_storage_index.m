#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import "../Sources/storage_index.h"
static int checks;
static int OpenFDs(void){int count=0;for(int fd=0;fd<1024;fd++)if(fcntl(fd,F_GETFD)>=0)count++;return count;}
static void Check(BOOL ok,NSString *message){checks++;if(!ok){fprintf(stderr,"FAIL %s\n",message.UTF8String);exit(1);}}
static NSString *Dir(NSString *root,NSString *name){NSString *p=[root stringByAppendingPathComponent:name];Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL],@"fixture directory");return p;}
static NSString *File(NSString *root,NSString *name,NSUInteger size){NSString *p=[root stringByAppendingPathComponent:name];NSMutableData *d=[NSMutableData dataWithLength:size];memset(d.mutableBytes,0x67,size);Check([d writeToFile:p atomically:YES],@"fixture data");return p;}
static NSDictionary *Row(NSArray *rows,NSString *path){for(NSDictionary *r in rows)if([r[@"path"] isEqual:path])return r;return nil;}
static unsigned long long Allocated(NSString *p){struct stat s;Check(!lstat(p.fileSystemRepresentation,&s),@"independent stat");return s.st_blocks*512ULL;}
static NSDictionary *Finish(GBStorageIndex *index){NSDictionary *s=nil;for(int n=0;n<10000&&!index.finished;n++)s=[index advanceForSeconds:.05 entries:13];Check(index.finished,@"bounded fixture completes");return s ?: [index snapshot];}
int main(void){@autoreleasepool{
    NSMutableArray *ranking=[NSMutableArray array];
    for(NSUInteger n=0;n<20000;n++)[ranking addObject:@{@"path":[NSString stringWithFormat:@"/folder-%lu",(unsigned long)n],@"allocatedBytes":@((n*7919)%101)}];
    NSArray *sorted=[ranking sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        NSComparisonResult bytes=[b[@"allocatedBytes"] compare:a[@"allocatedBytes"]];
        return bytes==NSOrderedSame ? [a[@"path"] localizedStandardCompare:b[@"path"]] : bytes;
    }];
    for(NSNumber *limit in @[@0,@1,@37,@100,@25000]) {
        NSUInteger count=MIN(limit.unsignedIntegerValue,ranking.count);
        Check([GBStorageLargestRows(ranking,limit.unsignedIntegerValue) isEqual:[sorted subarrayWithRange:NSMakeRange(0,count)]],@"bounded top rows equal complete sort, including size ties");
    }
    char resolved[PATH_MAX];Check(realpath(NSTemporaryDirectory().fileSystemRepresentation,resolved)!=NULL,@"canonical fixture parent");
    NSString *home=Dir([NSString stringWithUTF8String:resolved],[@"storage-index-" stringByAppendingString:NSUUID.UUID.UUIDString]);
    NSString *downloads=Dir(home,@"Downloads"), *deep=Dir(downloads,@"nested/deep"), *repo=Dir(home,@"repo");Dir(repo,@".git");
    NSString *app=Dir(home,@"Video.app/Contents"), *outside=Dir(home,@"outside-scope");
    NSString *large=File(deep,@"big.mov",3*1024*1024), *other=File(downloads,@"other.zip",1024*1024);
    NSString *repoFile=File(repo,@"objects.bin",2*1024*1024), *appFile=File(app,@"binary",1024*1024);
    NSString *sparse=File(downloads,@"sparse",4096);int fd=open(sparse.fileSystemRepresentation,O_WRONLY);Check(!ftruncate(fd,64*1024*1024),@"sparse fixture");close(fd);
    NSString *hard=File(downloads,@"hard.dat",16384);Check(!link(hard.fileSystemRepresentation,[downloads stringByAppendingPathComponent:@"hard-copy.dat"].fileSystemRepresentation),@"hardlink fixture");
    File(outside,@"outside.bin",4*1024*1024);
    Check(!symlink(outside.fileSystemRepresentation,[downloads stringByAppendingPathComponent:@"outside-link"].fileSystemRepresentation),@"link fixture");
    // Non-root denied directory verifies partial coverage without a permission grant.
    NSString *denied=Dir(downloads,@"denied");File(denied,@"hidden.bin",65536);chmod(denied.fileSystemRepresentation,0000);
    int descriptors=OpenFDs();
    GBStorageIndex *index=[[GBStorageIndex alloc] initWithRoots:@[downloads,repo,app.stringByDeletingLastPathComponent,downloads] home:home];
    NSDictionary *first=[index advanceForSeconds:.05 entries:2];
    for(int attempt=0;attempt<10 && ![first[@"entries"] unsignedIntegerValue] && !index.finished;attempt++)first=[index advanceForSeconds:.05 entries:2];
    NSUInteger entries=[first[@"entries"] unsignedIntegerValue];Check(entries>0&&entries<=2,@"entry slices are bounded");
    Check(OpenFDs()<=descriptors+12,@"at most twelve retained directory streams");
    index.paused=YES;Check([[[index advanceForSeconds:1 entries:1000] objectForKey:@"entries"] unsignedIntegerValue]==entries,@"paused index does no traversal");index.paused=NO;
    NSDictionary *snapshot=Finish(index);NSArray *rows=snapshot[@"rows"];
    Check(OpenFDs()==descriptors,@"completed scan closes every directory stream");
    Check([rows.firstObject[@"path"] isEqual:large],@"deep largest file ranks globally above immediate children");
    Check([Row(rows,repo)[@"allocatedBytes"] unsignedLongLongValue]==Allocated(repoFile),@"repository is measured as one protected group");
    Check(Row(rows,repoFile)==nil && [Row(rows,repo)[@"action"] isEqual:@"reveal"],@"repository internals never become cleanup rows");
    Check([Row(rows,app.stringByDeletingLastPathComponent)[@"allocatedBytes"] unsignedLongLongValue]==Allocated(appFile),@"application package measured safely");
    Check([Row(rows,sparse)[@"logicalBytes"] unsignedLongLongValue]>[Row(rows,sparse)[@"allocatedBytes"] unsignedLongLongValue],@"logical and allocated sparse sizes remain distinct");
    unsigned long long expected=Allocated(large)+Allocated(other)+Allocated(sparse)+Allocated(hard);
    Check([Row(snapshot[@"folders"],downloads)[@"allocatedBytes"] unsignedLongLongValue]==expected,@"overlapping roots and hardlinks never double count; links and denied content excluded");
    Check([snapshot[@"errors"] unsignedIntegerValue]>0&&[snapshot[@"partial"] boolValue],@"denied directory is partial, not fabricated zero coverage");
    Check([Row(rows,large)[@"action"] isEqual:@"trash"],@"eligible ordinary file exposes direct Trash action");
    [index removeFile:Row(rows,large)];Check(!Row([index snapshot][@"rows"],large),@"removed file leaves ranking");
    Check([Row([index snapshot][@"folders"],downloads)[@"allocatedBytes"] unsignedLongLongValue]==expected-Allocated(large),@"removed file updates ancestor totals");
    NSString *bundle=Dir(downloads,@"Backup.sparsebundle/bands");
    NSString *band=File(bundle,@"0",8192);
    GBStorageIndex *packages=[[GBStorageIndex alloc] initWithRoots:@[downloads] home:home];
    NSDictionary *packageSnapshot=Finish(packages);
    Check(Row(packageSnapshot[@"rows"],band)==nil && [Row(packageSnapshot[@"rows"],bundle.stringByDeletingLastPathComponent)[@"action"] isEqual:@"reveal"],@"disk-image package bands stay inside protected aggregate");
    NSString *small=Dir(home,@"small-only");
    for(int n=0;n<110;n++)File(small,[NSString stringWithFormat:@"tiny-%03d",n],4096);
    NSString *last=File(small,@"largest-created-last",900000);
    GBStorageIndex *smallIndex=[[GBStorageIndex alloc] initWithRoots:@[small] home:home];NSDictionary *smallSnap=Finish(smallIndex);
    Check([smallSnap[@"rows"][0][@"path"] isEqual:last],@"top ranking includes late sub-megabyte files");
    NSString *cache=[home stringByAppendingPathComponent:@"cache"];GBStorageSaveCache(snapshot,cache,home);
    Check(GBStorageLoadCache(cache,home)!=nil,@"private cache round trip");struct stat st;lstat(cache.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0700,@"cache directory private");
    NSString *cacheFile=[cache stringByAppendingPathComponent:@"index.json"];lstat(cacheFile.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0600,@"cache file private");
    Check(GBStorageLoadCache(cache,@"/different-home")==nil,@"cache scoped to home");
    NSMutableDictionary *expired=[snapshot mutableCopy];expired[@"capturedAt"]=@(NSDate.date.timeIntervalSince1970-90000);GBStorageSaveCache(expired,cache,home);Check(!GBStorageLoadCache(cache,home),@"expired cache rejected");
    [@"{}" writeToFile:cacheFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];Check(!GBStorageLoadCache(cache,home),@"malformed cache rejected");
    chmod(denied.fileSystemRepresentation,0700);Check([NSFileManager.defaultManager removeItemAtPath:home error:NULL],@"fixture-only cleanup");
    fprintf(stderr,"Global storage: %d checks passed\n",checks);
}return 0;}
