#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import "../Sources/storage_scan.h"
#import "../Sources/storage_cleanup.h"

static int checks, failures;
static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr,"FAIL %s\n",message.UTF8String); failures++; }
}
static NSString *Write(NSString *root, NSString *name, NSString *text) {
    NSString *path=[root stringByAppendingPathComponent:name];
    Check([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL],@"write disposable fixture");
    return path;
}
static NSDictionary *Entry(NSString *path) { return @{@"path":path,@"identity":GBStorageIdentity(path) ?: @{}}; }
static NSDictionary *Scan(NSString *path) { return [[GBStorageScan new] scanPath:path entryLimit:100 seconds:15]; }
static NSDictionary *Row(NSDictionary *scan, NSString *name) {
    for (NSDictionary *row in scan[@"rows"]) if ([row[@"name"] isEqual:name]) return row;
    return nil;
}
int main(void) { @autoreleasepool {
    // NSString's path resolver abbreviates /private/var back to /var on macOS.
    // Use the physical path so the test never relies on a symlink exception.
    char real[PATH_MAX]; Check(realpath(NSTemporaryDirectory().fileSystemRepresentation,real)!=NULL,@"physical temp directory");
    NSString *home=[[NSString stringWithUTF8String:real] stringByAppendingPathComponent:[@"gb-storage-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *downloads=[home stringByAppendingPathComponent:@"Downloads"];
    NSFileManager *fm=NSFileManager.defaultManager;
    Check([fm createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil error:NULL],@"private fixture home");
    NSString *sparse=[downloads stringByAppendingPathComponent:@"sparse.bin"];
    int fd=open(sparse.fileSystemRepresentation,O_CREAT|O_RDWR,0600);
    Check(fd>=0 && !ftruncate(fd,1048576),@"sparse fixture"); close(fd);
    NSString *text=Write(downloads,@"readme.txt",@"hello\n");
    NSDictionary *scan=Scan(downloads), *row=Row(scan,@"sparse.bin");
    if (!row || [scan[@"limited"] boolValue]) fprintf(stderr,"Sparse scan: entries=%s, limited=%s, error=%s, elapsed=%s\n",[scan[@"entries"] description].UTF8String,[scan[@"limited"] description].UTF8String,[scan[@"error"] description].UTF8String,[scan[@"elapsedSeconds"] description].UTF8String);
    Check(row && [row[@"logicalBytes"] unsignedLongLongValue]>[row[@"allocatedBytes"] unsignedLongLongValue],@"sparse logical and allocated size differ");
    NSString *hard=[downloads stringByAppendingPathComponent:@"hard.txt"];
    Check(!link(text.fileSystemRepresentation,hard.fileSystemRepresentation),@"hardlink fixture");
    scan=Scan(downloads); uint64_t totalLogical=0; NSUInteger unknown=0;
    for (NSDictionary *entry in scan[@"rows"]) { totalLogical += [entry[@"logicalBytes"] unsignedLongLongValue]; if (!entry[@"logicalBytes"]) unknown++; }
    Check(totalLogical==1048576+6 && unknown==1,@"hardlinks counted once regardless of enumeration order");
    NSString *repo=[downloads stringByAppendingPathComponent:@"repo"], *git=[repo stringByAppendingPathComponent:@".git"];
    Check([fm createDirectoryAtPath:git withIntermediateDirectories:YES attributes:nil error:NULL],@"repository fixture");
    NSString *head=Write(git,@"HEAD",@"ref: refs/heads/main");
    NSString *linkPath=[downloads stringByAppendingPathComponent:@"link"];
    Check(!symlink(repo.fileSystemRepresentation,linkPath.fileSystemRepresentation),@"symlink fixture");
    Check(GBStorageBoundaryReason(repo)!=nil,@"repository root is protected");
    Check(GBStorageBoundaryReason(@"/tmp/a/node_modules/x")!=nil,@"developer boundary");
    Check(GBStorageBoundaryReason(@"/tmp/a/Foo.app/x")!=nil,@"application package boundary");
    Check(Scan([linkPath stringByAppendingPathComponent:@".git"])[@"error"]!=nil,@"symlink ancestor is rejected");
    GBStorageScan *cancel=[GBStorageScan new]; cancel.cancelled=YES;
    Check([[cancel scanPath:downloads entryLimit:100 seconds:1][@"cancelled"] boolValue],@"cancelled scan");
    Check([[[GBStorageScan new] scanPath:downloads entryLimit:1 seconds:1][@"limited"] boolValue],@"entry budget reports partial scan");
    NSString *eligible=Write(downloads,@"eligible.txt",@"trash fixture");
    __block NSUInteger opens=0, transports=0;
    GBStorageOpenCheck openCheck=^NSString *(NSString *path) { (void)path; opens++; return nil; };
    GBStorageTrashTransport transport=^BOOL(NSURL *url,NSError **error) { (void)url; (void)error; transports++; return YES; };
    NSDictionary *result=GBStorageTrash(Entry(eligible),home,openCheck,transport);
    Check(!result[@"error"] && opens && transports==1,@"eligible reviewed file reaches injected transport");
    Check([fm fileExistsAtPath:eligible],@"injected Trash transport never deletes");
    NSString *changed=Write(downloads,@"changed.txt",@"before"); NSDictionary *old=Entry(changed);
    Write(downloads,@"changed.txt",@"after"); transports=0;
    Check(GBStorageTrash(old,home,openCheck,transport)[@"error"] && transports==0,@"changed identity denied before transport");
    Check(!GBStorageIdentityMatches(@{},@{}) && !GBStorageIdentityMatches(@{},GBStorageIdentity(changed)),@"malformed identities never match");
    Check(GBStorageTrash(Entry(eligible),home,^NSString *(NSString *path) { (void)path; return @"In use"; },transport)[@"error"] && transports==0,@"in-use file denied");
    Check(GBStorageTrash(Entry(eligible),home,nil,transport)[@"error"] && transports==0,@"missing in-use check fails closed");
    Check(GBStorageCleanupReason(Entry(hard),home,NO)!=nil,@"hardlinks reveal-only");
    Check(GBStorageCleanupReason(Entry(linkPath),home,NO)!=nil,@"symlinks reveal-only");
    Check(GBStorageCleanupReason(Entry(head),home,NO)!=nil,@"repository contents reveal-only");
    Check(GBStorageCleanupReason(Entry(Write(downloads,@"movie.mp4",@"fixture")),home,YES)!=nil,@"compressed media not eligible for ZIP");
    NSString *zipSource=Write(downloads,@"archive.txt",@"compress");
    NSString *collision=Write(downloads,@"archive.txt.zip",@"collision");
    result=GBStorageCompress(Entry(zipSource),home,openCheck,^BOOL { return NO; });
    Check(!result[@"error"] && [result[@"path"] hasSuffix:@"archive.txt-1.zip"],@"verified copy uses a new name");
    Check([[NSString stringWithContentsOfFile:collision encoding:NSUTF8StringEncoding error:NULL] isEqual:@"collision"],@"existing ZIP not overwritten");
    Check([[NSString stringWithContentsOfFile:zipSource encoding:NSUTF8StringEncoding error:NULL] isEqual:@"compress"],@"original contents kept");
    NSString *cancelSource=Write(downloads,@"cancel.txt",@"cancel");
    Check(GBStorageCompress(Entry(cancelSource),home,openCheck,^BOOL { return YES; })[@"error"] && [fm fileExistsAtPath:cancelSource],@"cancel keeps original");
    Check(![fm fileExistsAtPath:[cancelSource stringByAppendingString:@".zip"]],@"cancel publishes no archive");
    NSString *mutableSource=Write(downloads,@"mutable.txt",@"before archive"); __block BOOL mutated=NO;
    result=GBStorageCompress(Entry(mutableSource),home,openCheck,^BOOL {
        if (!mutated) for (NSString *name in [fm contentsOfDirectoryAtPath:downloads error:NULL]) {
            if ([name hasPrefix:@".glancebar-cleanup-"] && [fm fileExistsAtPath:[[downloads stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"copy.zip"]]) {
                mutated=YES; [@"Changed by fixture during archive verification" writeToFile:mutableSource atomically:YES encoding:NSUTF8StringEncoding error:NULL]; break;
            }
        }
        return NO;
    });
    Check(mutated && result[@"error"] && !result[@"path"],@"source changed during archive cannot publish");
    BOOL workspaceLeft=NO;
    for (NSString *name in [fm contentsOfDirectoryAtPath:downloads error:NULL]) if ([name hasPrefix:@".glancebar-cleanup-"]) workspaceLeft=YES;
    Check(!workspaceLeft,@"private workspaces cleaned after success and failure");
    NSString *empty=[downloads stringByAppendingPathComponent:@"empty"];
    Check([fm createDirectoryAtPath:empty withIntermediateDirectories:NO attributes:nil error:NULL],@"empty fixture");
    Check(GBStorageCleanupReason(Entry(empty),home,NO)!=nil && GBStorageCleanupReason(@{@"path":@"/tmp/nope"},home,NO)!=nil,@"directories and outside paths ineligible");
    scan=Scan(downloads);
    row=Row(scan,@"empty"); Check(row[@"allocatedBytes"] && [row[@"allocatedBytes"] unsignedLongLongValue]==0 && ![row[@"partial"] boolValue],@"empty folder is known zero");
    row=Row(scan,@"repo"); Check(row[@"protectedReason"] && !row[@"allocatedBytes"],@"repository not traversed");
    row=Row(scan,@"link"); Check([row[@"isLink"] boolValue] && !row[@"allocatedBytes"],@"link target not traversed");
    Check([scan[@"partial"] boolValue],@"exclusions mark partial totals");
    uint64_t last=UINT64_MAX;
    for (NSDictionary *entry in scan[@"rows"]) if (entry[@"allocatedBytes"]) {
        uint64_t bytes=[entry[@"allocatedBytes"] unsignedLongLongValue]; Check(bytes<=last,@"allocated-size ranking"); last=bytes;
    }
    fd=open(eligible.fileSystemRepresentation,O_RDONLY);
    Check(GBStorageOpenFileReason(eligible)!=nil,@"real in-use check sees fixture descriptor"); close(fd);
    Check(GBStorageOpenFileReason(eligible)==nil,@"real in-use check accepts closed fixture");
    Check([fm removeItemAtPath:home error:NULL],@"fixture cleanup");
    fprintf(stderr,"Storage fixtures: %d checks, %d failures\n",checks,failures);
} return failures ? 1 : 0; }
