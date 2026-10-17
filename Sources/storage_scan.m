#import "storage_scan.h"
#import <sys/stat.h>
#import <sys/resource.h>
#import <sys/mount.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static NSDictionary *Identity(NSString *path, struct stat s) {
    return @{@"path":path, @"device":@(s.st_dev), @"inode":@(s.st_ino), @"size":@(s.st_size),
        @"mtime":@(s.st_mtimespec.tv_sec*1000000000LL+s.st_mtimespec.tv_nsec),
        @"ctime":@(s.st_ctimespec.tv_sec*1000000000LL+s.st_ctimespec.tv_nsec),
        @"mode":@(s.st_mode), @"uid":@(s.st_uid), @"links":@(s.st_nlink), @"flags":@(s.st_flags)};
}
NSDictionary *GBStorageIdentity(NSString *path) {
    struct stat s; return path && !lstat(path.fileSystemRepresentation,&s) ? Identity(path,s) : nil;
}
BOOL GBStorageIdentityMatches(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"path",@"device",@"inode",@"size",@"mtime",@"ctime",@"mode",@"uid",@"links",@"flags"])
        if (!a[key] || !b[key] || ![a[key] isEqual:b[key]]) return NO;
    return YES;
}
NSString *GBStorageBoundaryAtPath(NSString *part) {
    static NSSet *reserved, *packages; static dispatch_once_t once;
    dispatch_once(&once, ^{
        reserved = [NSSet setWithArray:@[@".git",@".hg",@".svn",@"node_modules",@"build",@".build",@"dist",@".Trash",@"CloudStorage",@"Mobile Documents",@".codex",@".cursor",@".claude"]];
        packages = [NSSet setWithArray:@[@"app",@"bundle",@"framework",@"photoslibrary",@"photolibrary",@"musiclibrary",@"pvm",@"vmwarevm",@"sparsebundle",@"backupbundle",@"fcpbundle",@"imovielibrary",@"logicx",@"band",@"garageband",@"xcarchive",@"xcodeproj",@"xcworkspace",@"playground",@"pages",@"numbers",@"key",@"scriv"]];
    });
    NSString *name=part.lastPathComponent;
    if ([reserved containsObject:name] || [part hasSuffix:@"/Documents/Codex"])
        return @"Protected developer, cloud or system folder";
    if ([packages containsObject:name.pathExtension.lowercaseString]) return @"Application or library package";
    struct stat directory;
    if(!lstat(part.fileSystemRepresentation,&directory) && S_ISDIR(directory.st_mode)) {
        if([name hasPrefix:@"."])return @"Hidden application or configuration folder";
        // Third-party document packages may have registered extensions we do not know.
        if(name.pathExtension.length){NSNumber *package=nil;
            [[NSURL fileURLWithPath:part] getResourceValue:&package forKey:NSURLIsPackageKey error:NULL];
            if(package.boolValue)return @"Application or document package";
        }
        struct stat head,objects;
        if(!lstat([part stringByAppendingPathComponent:@"HEAD"].fileSystemRepresentation,&head) && S_ISREG(head.st_mode) &&
           !lstat([part stringByAppendingPathComponent:@"objects"].fileSystemRepresentation,&objects) && S_ISDIR(objects.st_mode))return @"Repository data";
    }
    for (NSString *marker in @[@".git",@".hg",@".svn"]) {
        struct stat s;
        if (!lstat([part stringByAppendingPathComponent:marker].fileSystemRepresentation,&s)) return @"Repository or worktree";
    }
    return nil;
}
NSString *GBStorageBoundaryReason(NSString *path) {
    NSString *part = @"/";
    for (NSString *name in path.pathComponents) {
        if ([name isEqual:@"/"]) continue;
        part = [part stringByAppendingPathComponent:name];
        NSString *reason=GBStorageBoundaryAtPath(part); if (reason) return reason;
    }
    return nil;
}

@implementation GBStorageScan {
    NSUInteger _entries, _limit, _errors, _skipped;
    double _deadline;
    dev_t _device;
    BOOL _limited;
    NSMutableSet *_seen;
}
- (BOOL)stop {
    if (self.cancelled) return YES;
    if (_entries >= _limit || NSProcessInfo.processInfo.systemUptime >= _deadline) { _limited = YES; return YES; }
    return NO;
}
// Descriptor-relative traversal never follows links, even if a child is swapped
// between enumeration and open. Only metadata is read; file contents stay cold.
- (BOOL)walkFD:(int)fd path:(NSString *)path depth:(NSUInteger)depth budget:(NSUInteger)budget
        logical:(uint64_t *)logical allocated:(uint64_t *)allocated {
    DIR *directory = fdopendir(fd);
    if (!directory) { close(fd); _errors++; return NO; }
    BOOL complete = YES; struct dirent *entry;
    while (YES) {
        if ([self stop] || _entries >= budget || depth >= 64) { complete = NO; _limited = YES; break; }
        errno=0; entry=readdir(directory);
        if (!entry) { if (errno) { _errors++; complete=NO; } break; }
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        _entries++;
        if (!(_entries % 128)) usleep(1000);
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        NSString *child = [path stringByAppendingPathComponent:name]; struct stat s;
        if (fstatat(dirfd(directory),entry->d_name,&s,AT_SYMLINK_NOFOLLOW)) { _errors++; complete=NO; continue; }
        if (s.st_dev != _device || S_ISLNK(s.st_mode) || (s.st_flags & SF_DATALESS) || GBStorageBoundaryAtPath(child)) {
            _skipped++; complete=NO; continue;
        }
        if (S_ISDIR(s.st_mode)) {
            int next = openat(dirfd(directory),entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            struct stat opened;
            if (next < 0 || fstat(next,&opened) || opened.st_dev != s.st_dev || opened.st_ino != s.st_ino) {
                if (next >= 0) close(next); _errors++; complete=NO; continue;
            }
            if (![self walkFD:next path:child depth:depth+1 budget:budget logical:logical allocated:allocated]) complete=NO;
        } else if (S_ISREG(s.st_mode)) {
            NSString *key = [NSString stringWithFormat:@"%llu:%llu",(unsigned long long)s.st_dev,(unsigned long long)s.st_ino];
            if ([_seen containsObject:key]) { _skipped++; complete=NO; continue; }
            [_seen addObject:key]; *logical += MAX(0,s.st_size); *allocated += MAX(0,s.st_blocks)*512ULL;
        } else { _skipped++; complete=NO; }
    }
    closedir(directory); return complete;
}
- (NSDictionary *)scanPath:(NSString *)path entryLimit:(NSUInteger)limit seconds:(double)seconds {
    double start = NSProcessInfo.processInfo.systemUptime;
    _entries=0; _errors=0; _skipped=0; _limited=NO; _seen=[NSMutableSet set];
    _limit=MAX(1,MIN(limit,100000)); _deadline=start+MAX(0.001,MIN(seconds,15));
    // A cancelled queued scan must not enter even its first filesystem call.
    if (self.cancelled) return @{@"path":path ?: @"",@"rows":@[],@"entries":@0,@"errors":@0,@"skipped":@0,
        @"cancelled":@YES,@"limited":@NO,@"partial":@YES,@"elapsedSeconds":@0,@"capturedAt":@(NSDate.date.timeIntervalSince1970)};
    NSMutableArray *rows=[NSMutableArray array]; NSString *problem=nil;
    if (!path.isAbsolutePath || [path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."]) problem=@"Choose an absolute folder path.";
    NSString *part=@"/";
    for (NSString *name in path.pathComponents) {
        if ([self stop]) { problem=self.cancelled ? @"Scan cancelled" : @"Scan limit reached"; break; }
        if ([name isEqual:@"/"]) continue;
        part=[part stringByAppendingPathComponent:name]; struct stat s;
        if (lstat(part.fileSystemRepresentation,&s) || S_ISLNK(s.st_mode)) { problem=@"Folder unavailable or reached through a symbolic link."; break; }
    }
    problem=problem ?: GBStorageBoundaryReason(path);
    int fd=problem ? -1 : open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat rootStat;
    if (fd >= 0 && fstat(fd,&rootStat)) { close(fd); fd=-1; }
    struct statfs rootVolume;
    if (fd >= 0 && (fstatfs(fd,&rootVolume) || !(rootVolume.f_flags & MNT_LOCAL))) {
        close(fd); fd=-1; problem=@"Only local folders can be scanned.";
    }
    if (fd < 0 && !problem) problem=@"Folder unavailable with current access.";
    // Controller dispatches on a background queue. Do not overwrite a GCD
    // worker's pthread QoS: an unspecified requested class cannot be restored.
    int previousIO=getiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD);
    if (previousIO >= 0) setiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD,IOPOL_THROTTLE);
    if (fd >= 0) {
        _device=rootStat.st_dev; DIR *directory=fdopendir(fd); struct dirent *entry;
        if (!directory) { close(fd); problem=@"Folder could not be read."; }
        while (directory && ![self stop]) {
            errno=0; entry=readdir(directory);
            if (!entry) { if (errno) _errors++; break; }
            if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
            _entries++;
            NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
            NSString *child=[path stringByAppendingPathComponent:name]; struct stat s;
            if (fstatat(dirfd(directory),entry->d_name,&s,AT_SYMLINK_NOFOLLOW)) { _errors++; continue; }
            NSMutableDictionary *row=[@{@"name":name,@"path":child,@"isDirectory":@(S_ISDIR(s.st_mode)),@"isLink":@(S_ISLNK(s.st_mode)),@"identity":Identity(child,s)} mutableCopy];
            NSString *boundary=GBStorageBoundaryAtPath(child);
            if (boundary) row[@"protectedReason"]=boundary;
            BOOL complete=YES, measured=YES; uint64_t logical=0,allocated=0;
            if (boundary || S_ISLNK(s.st_mode) || s.st_dev != _device || (s.st_flags & SF_DATALESS)) {
                row[@"problem"]=boundary ?: @"Link, other volume or cloud placeholder"; complete=NO; measured=NO; _skipped++;
            } else if (S_ISDIR(s.st_mode)) {
                int next=openat(dirfd(directory),entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); struct stat opened;
                if (next < 0 || fstat(next,&opened) || opened.st_dev != s.st_dev || opened.st_ino != s.st_ino) {
                    if (next >= 0) close(next); _errors++; measured=NO; complete=NO; row[@"problem"]=@"Access unavailable";
                } else complete=[self walkFD:next path:child depth:1 budget:MIN(_limit,_entries+4000) logical:&logical allocated:&allocated];
            } else if (S_ISREG(s.st_mode)) {
                NSString *key=[NSString stringWithFormat:@"%llu:%llu",(unsigned long long)s.st_dev,(unsigned long long)s.st_ino];
                if ([_seen containsObject:key]) { complete=NO; measured=NO; _skipped++; row[@"problem"]=@"Hardlink counted elsewhere"; }
                else { [_seen addObject:key]; logical=MAX(0,s.st_size); allocated=MAX(0,s.st_blocks)*512ULL; }
            } else { complete=NO; measured=NO; _skipped++; row[@"problem"]=@"Special file"; }
            if (measured) { row[@"logicalBytes"]=@(logical); row[@"allocatedBytes"]=@(allocated); }
            row[@"partial"]=@(!complete); [rows addObject:row];
        }
        if (directory) closedir(directory);
    }
    if (previousIO >= 0) setiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD,previousIO);
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSNumber *aa=a[@"allocatedBytes"],*bb=b[@"allocatedBytes"];
        if (!aa && bb) return NSOrderedDescending; if (aa && !bb) return NSOrderedAscending;
        NSComparisonResult size=[bb compare:aa]; return size == NSOrderedSame ? [a[@"name"] localizedStandardCompare:b[@"name"]] : size;
    }];
    NSMutableDictionary *result=[@{@"path":path ?: @"",@"rows":rows,@"entries":@(_entries),@"errors":@(_errors),@"skipped":@(_skipped),
        @"cancelled":@(self.cancelled),@"limited":@(_limited),@"partial":@(_limited||self.cancelled||_errors||_skipped||problem!=nil),
        @"elapsedSeconds":@(NSProcessInfo.processInfo.systemUptime-start),@"capturedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    if (problem) result[@"error"]=problem;
    return result;
}
@end
