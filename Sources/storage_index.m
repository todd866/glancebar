#import "storage_index.h"
#import "storage_scan.h"
#import "storage_cleanup.h"
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/resource.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static BOOL Inside(NSString *path,NSString *root) { return [path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]; }
static NSString *Key(struct stat s) { return [NSString stringWithFormat:@"%llu:%llu",(unsigned long long)s.st_dev,(unsigned long long)s.st_ino]; }
static NSComparisonResult Biggest(NSDictionary *a,NSDictionary *b) {
    NSComparisonResult n=[b[@"allocatedBytes"] compare:a[@"allocatedBytes"]];
    return n==NSOrderedSame ? [a[@"path"] localizedStandardCompare:b[@"path"]] : n;
}
NSArray<NSDictionary *> *GBStorageLargestRows(NSArray<NSDictionary *> *rows, NSUInteger limit) {
    if (!limit) return @[];
    NSMutableArray *top=[NSMutableArray arrayWithCapacity:MIN(limit,rows.count)];
    NSComparator compare=^NSComparisonResult(id a,id b){return Biggest(a,b);};
    for (NSDictionary *row in rows) {
        if (top.count==limit && Biggest(row,top.lastObject)!=NSOrderedAscending) continue;
        NSUInteger position=[top indexOfObject:row inSortedRange:NSMakeRange(0,top.count)
                                       options:NSBinarySearchingInsertionIndex usingComparator:compare];
        [top insertObject:row atIndex:position];
        if (top.count>limit) [top removeLastObject];
    }
    return top;
}
NSDictionary *GBStorageMergeSnapshot(NSDictionary *fresh, NSDictionary *previous) {
    if (!previous || [fresh[@"complete"] boolValue] || [fresh[@"limited"] boolValue]) return fresh;
    NSMutableDictionary *result=[fresh mutableCopy]; BOOL retained=NO;
    for (NSString *key in @[@"rows",@"folders"]) {
        NSMutableDictionary *byPath=[NSMutableDictionary dictionary];
        for (NSDictionary *row in previous[key]) {
            NSMutableDictionary *copy=[row mutableCopy]; copy[@"cached"]=@YES;
            byPath[row[@"path"]]=copy;
        }
        for (NSDictionary *row in fresh[key]) {
            NSDictionary *old=byPath[row[@"path"]];
            // A partial directory total is only a lower bound; retain a larger
            // prior measurement until the new pass catches up or finishes.
            if (![row[@"isDirectory"] boolValue] || !old ||
                [row[@"allocatedBytes"] unsignedLongLongValue]>=[old[@"allocatedBytes"] unsignedLongLongValue])
                byPath[row[@"path"]]=row;
        }
        result[key]=GBStorageLargestRows(byPath.allValues,100);
        for (NSDictionary *row in result[key]) if ([row[@"cached"] boolValue]) retained=YES;
    }
    if (retained) result[@"cachedAt"]=previous[@"cachedAt"] ?: previous[@"capturedAt"];
    return result;
}
static BOOL Skip(NSString *name) { return [@[@".Trash",@".Trashes",@".Spotlight-V100",@".fseventsd",@".TemporaryItems",@"CloudStorage",@"Mobile Documents"] containsObject:name]; }
// Opening every path component with O_NOFOLLOW prevents ancestor link races.
static int OpenDirectory(NSString *path) {
    if (!path.isAbsolutePath) return -1;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        if ([part isEqual:@".."] || [part isEqual:@"."]) { close(fd); return -1; }
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd); fd=next; if (fd<0) break;
    }
    return fd;
}
@interface GBStorageWalk : NSObject
@property NSString *path,*group;
@property NSDictionary *identity;
@property DIR *directory;
@property dev_t device;
@property BOOL root;
@end
@implementation GBStorageWalk
- (void)dealloc { if (_directory) closedir(_directory); }
@end

NSArray<NSString *> *GBStorageDefaultRoots(NSString *home) {
    NSMutableArray *roots=[NSMutableArray array];
    // These seeds surface likely large personal files immediately. Directory inode
    // deduplication makes the subsequent whole-home pass nonoverlapping.
    for (NSString *name in @[@"Downloads",@"Movies",@"Desktop",@"Documents",@"Pictures",@"Music"])
        [roots addObject:[home stringByAppendingPathComponent:name]];
    [roots addObjectsFromArray:@[home,@"/Applications",@"/Library",@"/Users/Shared"]];
    NSArray *volumes=[NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeIsLocalKey] options:NSVolumeEnumerationSkipHiddenVolumes];
    for (NSURL *url in volumes) if ([url.path hasPrefix:@"/Volumes/"]) {
        NSNumber *local=nil; [url getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:NULL];
        if (local.boolValue) [roots addObject:url.path];
    }
    return roots;
}

@implementation GBStorageIndex {
    NSArray *_roots;
    NSString *_home;
    NSMutableArray<GBStorageWalk *> *_pending,*_active;
    NSMutableSet *_directories,*_hardlinks;
    NSMutableDictionary<NSString *,NSMutableDictionary *> *_folders,*_groups;
    NSMutableSet<NSString *> *_changedFolders,*_changedGroups;
    NSArray<NSDictionary *> *_folderLeaders,*_groupLeaders;
    NSMutableArray<NSDictionary *> *_files;
    NSMutableDictionary *_eligibility;
    NSUInteger _entries,_errors,_skipped,_cursor;
    BOOL _limited;
    double _started,_activeSeconds;
}
- (instancetype)initWithRoots:(NSArray<NSString *> *)roots home:(NSString *)home {
    if ((self=[super init])) {
        _roots=[roots copy]; _home=[home copy]; _pending=[NSMutableArray array]; _active=[NSMutableArray array];
        _directories=[NSMutableSet set]; _hardlinks=[NSMutableSet set]; _folders=[NSMutableDictionary dictionary];
        _groups=[NSMutableDictionary dictionary]; _eligibility=[NSMutableDictionary dictionary]; _files=[NSMutableArray array]; _started=NSDate.date.timeIntervalSince1970;
        _changedFolders=[NSMutableSet set]; _changedGroups=[NSMutableSet set];
        _folderLeaders=@[]; _groupLeaders=@[];
        for (NSString *path in roots) {
            GBStorageWalk *walk=[GBStorageWalk new]; walk.path=path; walk.root=YES; [_pending insertObject:walk atIndex:0];
        }
    }
    return self;
}
- (BOOL)finished { return _limited || (!_pending.count && !_active.count); }
- (void)markPartial:(NSString *)path {
    for (NSString *key=path; key.length && ![key isEqual:@"/"]; key=key.stringByDeletingLastPathComponent) {
        if (_folders[key]) _folders[key][@"partial"]=@YES;
        if (_groups[key]) _groups[key][@"partial"]=@YES;
    }
}
- (NSMutableDictionary *)folder:(NSString *)path group:(BOOL)group {
    [(group ? _changedGroups : _changedFolders) addObject:path];
    NSMutableDictionary *row=(group ? _groups : _folders)[path];
    if (!row) {
        row=[@{@"path":path,@"name":path.lastPathComponent,@"isDirectory":@YES,@"allocatedBytes":@0,@"logicalBytes":@0} mutableCopy];
        if (group) { row[@"protectedReason"]=GBStorageBoundaryReason(path) ?: @"Protected folder"; row[@"action"]=@"reveal"; }
        (group ? _groups : _folders)[path]=row;
    }
    return row;
}
- (void)addLogical:(int64_t)logical allocated:(int64_t)allocated path:(NSString *)path group:(NSString *)group {
    if (group) {
        NSMutableDictionary *row=[self folder:group group:YES];
        row[@"logicalBytes"]=@(MAX(0,[row[@"logicalBytes"] longLongValue]+logical));
        row[@"allocatedBytes"]=@(MAX(0,[row[@"allocatedBytes"] longLongValue]+allocated));
    }
    NSString *parent=(group ?: path).stringByDeletingLastPathComponent;
    if (group) parent=group;
    while (parent.length && ![parent isEqual:@"/"]) {
        BOOL covered=NO; for (NSString *root in _roots) if (Inside(parent,root)) { covered=YES; break; }
        if (!covered) break;
        NSMutableDictionary *row=[self folder:parent group:NO];
        row[@"logicalBytes"]=@(MAX(0,[row[@"logicalBytes"] longLongValue]+logical));
        row[@"allocatedBytes"]=@(MAX(0,[row[@"allocatedBytes"] longLongValue]+allocated));
        parent=parent.stringByDeletingLastPathComponent;
    }
}
- (void)fillSlotsUntil:(double)until {
    NSUInteger attempts=0;
    while (_active.count<12 && _pending.count && !self.paused && attempts++<24 && NSProcessInfo.processInfo.systemUptime<until) {
        GBStorageWalk *walk=_pending.lastObject; [_pending removeLastObject];
        int fd=OpenDirectory(walk.path); struct stat s; struct statfs fs;
        if (fd<0 || fstat(fd,&s) || fstatfs(fd,&fs) || !(fs.f_flags&MNT_LOCAL) || (walk.identity &&
            (![walk.identity[@"device"] isEqual:@(s.st_dev)] || ![walk.identity[@"inode"] isEqual:@(s.st_ino)]))) {
            if (fd>=0) close(fd); _errors++; [self markPartial:walk.path]; continue;
        }
        NSString *key=Key(s);
        if ([_directories containsObject:key]) { close(fd); continue; }
        [_directories addObject:key]; walk.device=s.st_dev;
        walk.directory=fdopendir(fd);
        if (!walk.directory) { close(fd); _errors++; [self markPartial:walk.path]; continue; }
        if (!walk.group && (walk.root ? GBStorageBoundaryReason(walk.path) : GBStorageBoundaryAtPath(walk.path))) walk.group=walk.path;
        if (walk.group) [self folder:walk.group group:YES];
        [self folder:walk.group ?: walk.path group:NO];
        [_active addObject:walk];
    }
}
- (NSDictionary *)advanceForSeconds:(double)seconds entries:(NSUInteger)budget {
    if (self.paused || self.finished) return [self snapshot];
    double start=NSProcessInfo.processInfo.systemUptime, until=start+MAX(.02,MIN(seconds,2));
    NSUInteger end=_entries+MAX(1,MIN(budget,10000));
    int oldIO=getiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD);
    if (oldIO>=0) setiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD,IOPOL_THROTTLE);
    while (!self.paused && _entries<end && NSProcessInfo.processInfo.systemUptime<until) {
        [self fillSlotsUntil:until]; if (!_active.count) { if (_pending.count) continue; break; }
        _cursor%= _active.count; GBStorageWalk *walk=_active[_cursor]; BOOL done=NO;
        for (NSUInteger batch=0;batch<128 && !self.paused && _entries<end;batch++) {
            if (NSProcessInfo.processInfo.systemUptime>=until) break;
            errno=0; struct dirent *entry=readdir(walk.directory);
            if (!entry) { if (errno) { _errors++; [self markPartial:walk.path]; } done=YES; break; }
            if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
            _entries++;
            NSString *name=[NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
            if (!name || Skip(name)) { _skipped++; [self markPartial:walk.path]; continue; }
            NSString *path=[walk.path stringByAppendingPathComponent:name]; struct stat s;
            if (fstatat(dirfd(walk.directory),entry->d_name,&s,AT_SYMLINK_NOFOLLOW)) { _errors++; [self markPartial:walk.path]; continue; }
            if (S_ISLNK(s.st_mode) || s.st_dev!=walk.device || (s.st_flags&SF_DATALESS)) { _skipped++; [self markPartial:walk.path]; continue; }
            if (S_ISDIR(s.st_mode)) {
                if (path.pathComponents.count>64) { _skipped++; [self markPartial:walk.path]; continue; }
                if (_pending.count+_directories.count>=500000) { _limited=YES; break; }
                GBStorageWalk *child=[GBStorageWalk new]; child.path=path; child.group=walk.group;
                child.identity=@{@"device":@(s.st_dev),@"inode":@(s.st_ino)}; [_pending addObject:child];
            } else if (S_ISREG(s.st_mode)) {
                if (s.st_nlink>1) { NSString *key=Key(s); if ([_hardlinks containsObject:key]) { _skipped++; [self markPartial:walk.path]; continue; } [_hardlinks addObject:key]; }
                uint64_t logical=MAX(0,s.st_size), allocated=MAX(0,s.st_blocks)*512ULL;
                [self addLogical:logical allocated:allocated path:path group:walk.group];
                if (!walk.group) {
                    NSDictionary *identity=GBStorageIdentity(path);
                    if (identity && [identity[@"inode"] isEqual:@(s.st_ino)] && [identity[@"device"] isEqual:@(s.st_dev)])
                        [_files addObject:@{@"path":path,@"name":name,@"identity":identity,@"allocatedBytes":@(allocated),@"logicalBytes":@(logical)}];
                }
                if (_files.count>512) { [_files sortUsingComparator:^NSComparisonResult(id a,id b){ return Biggest(a,b); }]; [_files removeObjectsInRange:NSMakeRange(256,_files.count-256)]; }
            }
            if (_entries>=5000000) { _limited=YES; break; }
        }
        if (done) { closedir(walk.directory); walk.directory=NULL; }
        // A completed stream is closed immediately; active streams retain at most 12 FDs.
        if (done) [_active removeObjectAtIndex:_cursor]; else _cursor++;
        if (_limited) break;
        usleep(1000);
    }
    if (oldIO>=0) setiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_THREAD,oldIO);
    _activeSeconds+=NSProcessInfo.processInfo.systemUptime-start;
    if (_limited) { [_active removeAllObjects]; [_pending removeAllObjects]; }
    return [self snapshot];
}
- (NSDictionary *)snapshot {
    // Totals only increase during traversal. Only changed rows can enter the top
    // 100; re-ranking every visited folder/group per slice becomes quadratic.
    NSMutableDictionary *candidates=[NSMutableDictionary dictionary];
    for (NSDictionary *row in _folderLeaders) candidates[row[@"path"]]=row;
    for (NSString *path in _changedFolders) candidates[path]=_folders[path];
    _folderLeaders=GBStorageLargestRows(candidates.allValues,100); [_changedFolders removeAllObjects];
    [candidates removeAllObjects];
    for (NSDictionary *row in _groupLeaders) candidates[row[@"path"]]=row;
    for (NSString *path in _changedGroups) candidates[path]=_groups[path];
    _groupLeaders=GBStorageLargestRows(candidates.allValues,100); [_changedGroups removeAllObjects];
    NSMutableArray *items=[_files mutableCopy];
    for (NSDictionary *row in _groupLeaders) { NSMutableDictionary *copy=[row mutableCopy]; if (!self.finished || _limited) copy[@"partial"]=@YES; [items addObject:copy]; }
    [items sortUsingComparator:^NSComparisonResult(id a,id b){return Biggest(a,b);}];
    if (items.count>100) [items removeObjectsInRange:NSMakeRange(100,items.count-100)];
    NSMutableArray *files=[NSMutableArray array];
    for (NSDictionary *item in items) {
        NSMutableDictionary *row=[item mutableCopy];
        if (!row[@"isDirectory"]) {
            NSDictionary *cached=_eligibility[row[@"path"]];NSString *reason=nil;
            if(cached && GBStorageIdentityMatches(cached[@"identity"],row[@"identity"]))reason=cached[@"reason"];
            else {
                reason=GBStorageCleanupReason(row,_home,NO) ?: @"";
                if(_eligibility.count>=1024)[_eligibility removeAllObjects];
                _eligibility[row[@"path"]]=@{@"identity":row[@"identity"],@"reason":reason};
            }
            row[@"action"]=reason.length ? @"reveal" : @"trash";
            if(reason.length)row[@"cleanupReason"]=reason;
        }
        [files addObject:row];
    }
    NSMutableArray *folders=[NSMutableArray array];
    // Copy only the visible leaders. Large homes can have hundreds of thousands
    // of folders; copying and sorting all of them on every slice swamps the walk.
    for (NSDictionary *row in _folderLeaders) {
        NSMutableDictionary *copy=[row mutableCopy]; copy[@"action"]=@"reveal";
        if (!self.finished || _limited) copy[@"partial"]=@YES; [folders addObject:copy];
    }
    return @{@"rows":files,@"folders":folders,@"roots":_roots,@"entries":@(_entries),@"errors":@(_errors),@"skipped":@(_skipped),@"complete":@(self.finished&&!_limited),@"limited":@(_limited),@"partial":@(!self.finished||_limited||_errors||_skipped),@"capturedAt":@(NSDate.date.timeIntervalSince1970),@"startedAt":@(_started),@"activeSeconds":@(_activeSeconds),@"directories":@(_directories.count),@"pendingDirectories":@(_pending.count),@"schema":@2};
}
- (void)removeFile:(NSDictionary *)entry {
    NSString *path=entry[@"path"];
    NSIndexSet *matches=[_files indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger i,BOOL *stop){ (void)i;(void)stop;return [row[@"path"] isEqual:path]; }];
    if(!matches.count)return;
    [_files removeObjectsAtIndexes:matches];
    [self addLogical:-[entry[@"logicalBytes"] longLongValue] allocated:-[entry[@"allocatedBytes"] longLongValue] path:path group:nil];
    // A decrease can admit an unchanged runner-up, unlike monotone traversal.
    [_changedFolders addObjectsFromArray:_folders.allKeys];
}
@end

NSDictionary *GBStorageLoadCache(NSString *directory, NSString *home) {
    int parent=OpenDirectory(directory); if(parent<0)return nil;
    int fd=openat(parent,"index.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC); close(parent);
    struct stat s;
    if(fd<0)return nil;
    if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=getuid()||s.st_size>1024*1024||s.st_size<2){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];
    ssize_t length=read(fd,data.mutableBytes,data.length);close(fd);if(length!=(ssize_t)data.length)return nil;
    NSDictionary *object=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![object isKindOfClass:NSDictionary.class]||![object[@"schema"] isEqual:@2]||![object[@"home"] isEqual:home])return nil;
    for(NSString *key in @[@"capturedAt",@"entries",@"errors",@"skipped",@"complete",@"limited",@"partial"])
        if(![object[key] isKindOfClass:NSNumber.class])return nil;
    double age=NSDate.date.timeIntervalSince1970-[object[@"capturedAt"] doubleValue];
    if(age<0||age>86400)return nil;
    for(NSString *key in @[@"rows",@"folders"]) {
        if(![object[key] isKindOfClass:NSArray.class]||[object[key] count]>100)return nil;
        for(NSDictionary *row in object[key]) {
            if(![row isKindOfClass:NSDictionary.class])return nil;
            for(NSString *field in @[@"path",@"name",@"action"])if(![row[field] isKindOfClass:NSString.class])return nil;
            if(![row[@"path"] isAbsolutePath])return nil;
            for(NSString *field in @[@"allocatedBytes",@"logicalBytes"])if(![row[field] isKindOfClass:NSNumber.class])return nil;
            for(NSString *field in @[@"isDirectory",@"partial",@"cached"])if(row[field]&&![row[field] isKindOfClass:NSNumber.class])return nil;
            for(NSString *field in @[@"cleanupReason",@"protectedReason"])if(row[field]&&![row[field] isKindOfClass:NSString.class])return nil;
            if(row[@"identity"]&&![row[@"identity"] isKindOfClass:NSDictionary.class])return nil;
        }
    }
    return object;
}
void GBStorageSaveCache(NSDictionary *snapshot, NSString *directory, NSString *home) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    int parent=OpenDirectory(directory);if(parent<0)return;
    struct stat s;if(fstat(parent,&s)||s.st_uid!=getuid()){close(parent);return;}
    fchmod(parent,0700);
    NSMutableDictionary *record=[snapshot mutableCopy];record[@"home"]=home;
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
    if(!data||data.length>1024*1024){close(parent);return;}
    NSString *name=[@"index-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(parent,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd>=0){ssize_t wrote=write(fd,data.bytes,data.length);close(fd);
        if(wrote==(ssize_t)data.length)renameat(parent,name.fileSystemRepresentation,parent,"index.json");
        unlinkat(parent,name.fileSystemRepresentation,0);
    }close(parent);
}
