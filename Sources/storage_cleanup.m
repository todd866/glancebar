#import "storage_cleanup.h"
#import "storage_scan.h"
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <sys/mount.h>
#import <fcntl.h>
#import <stdio.h>

static NSDictionary *Failure(NSString *message) { return @{@"error":message ?: @"Operation unavailable"}; }
static BOOL Under(NSString *path, NSString *root) {
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
}
static BOOL ValidPath(NSString *path) {
    return [path isKindOfClass:NSString.class] && path.isAbsolutePath &&
        ![path.pathComponents containsObject:@".."] && ![path.pathComponents containsObject:@"."] &&
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL PersonalPath(NSString *path, NSString *home) {
    if (!ValidPath(path) || !ValidPath(home)) return NO;
    for (NSString *folder in @[@"Downloads",@"Desktop",@"Documents",@"Movies",@"Music",@"Pictures"])
        if (Under(path, [home stringByAppendingPathComponent:folder])) return YES;
    return NO;
}
static BOOL SameNode(NSDictionary *a, NSDictionary *b) {
    return [a isKindOfClass:NSDictionary.class] && [b isKindOfClass:NSDictionary.class] &&
        a[@"device"] && a[@"inode"] && [a[@"device"] isEqual:b[@"device"]] && [a[@"inode"] isEqual:b[@"inode"]];
}
static NSString *NoLinks(NSString *path) {
    NSString *part = @"/";
    for (NSString *name in path.pathComponents) {
        if ([name isEqual:@"/"]) continue;
        part = [part stringByAppendingPathComponent:name];
        struct stat s;
        if (lstat(part.fileSystemRepresentation, &s) != 0) return @"The path is no longer accessible. Scan again.";
        if (S_ISLNK(s.st_mode)) return @"Symbolic links and paths through links are reveal-only.";
    }
    return nil;
}
NSString *GBStorageCleanupReason(NSDictionary *entry, NSString *home, BOOL compress) {
    NSString *path = entry[@"path"];
    if (!ValidPath(path) || !ValidPath(home))
        return @"Invalid or changed path. Scan again.";
    if (!PersonalPath(path,home)) return @"Cleanup is limited to individual files in your personal folders.";
    NSString *reason = NoLinks(path) ?: GBStorageBoundaryReason(path);
    if (reason) return reason;
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s) != 0) return @"File unavailable. Scan again.";
    if (!S_ISREG(s.st_mode)) return @"Folders and packages are browse or reveal only.";
    if (s.st_uid != getuid()) return @"Files owned by another account are reveal-only.";
    if (s.st_nlink != 1) return @"Hardlinked files are reveal-only.";
    if (s.st_flags & (UF_IMMUTABLE|SF_IMMUTABLE|UF_APPEND|SF_APPEND|SF_DATALESS))
        return @"Locked files and cloud placeholders are reveal-only.";
    if (!entry[@"identity"] || !GBStorageIdentityMatches(entry[@"identity"], GBStorageIdentity(path)))
        return @"The file changed since the scan. Scan again before cleanup.";
    if (access(path.stringByDeletingLastPathComponent.fileSystemRepresentation, W_OK) != 0)
        return @"The containing folder is not writable.";
    if (compress) {
        if (![@[@"txt",@"log",@"csv",@"tsv",@"json",@"jsonl",@"ndjson",@"xml",@"md",@"sql",@"rtf"] containsObject:path.pathExtension.lowercaseString])
            return @"Compress Copy is available for text, logs and data exports.";
        if (s.st_size <= 0 || s.st_size > 4LL*1024*1024*1024)
            return @"Compress Copy supports nonempty files up to 4 GB.";
    }
    return nil;
}
// Only our launched task can be terminated. Its NSTask object retains the child
// lifecycle; there is no process-name search or signal to another application's PID.
static NSInteger Run(NSString *executable, NSArray *arguments, double timeout,
                     BOOL (^cancelled)(void), NSURL *output, NSURL *error) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:executable]; task.arguments = arguments;
    NSFileHandle *out = output ? [NSFileHandle fileHandleForWritingToURL:output error:NULL] : NSFileHandle.fileHandleWithNullDevice;
    NSFileHandle *err = error ? [NSFileHandle fileHandleForWritingToURL:error error:NULL] : NSFileHandle.fileHandleWithNullDevice;
    if (!out || !err) return -1;
    task.standardOutput = out; task.standardError = err;
    if (![task launchAndReturnError:NULL]) return -1;
    double start = NSProcessInfo.processInfo.systemUptime;
    BOOL stopped = NO;
    while (task.isRunning) {
        if ((cancelled && cancelled()) || NSProcessInfo.processInfo.systemUptime-start > timeout) {
            stopped = YES; [task terminate];
            double grace = NSProcessInfo.processInfo.systemUptime;
            while (task.isRunning && NSProcessInfo.processInfo.systemUptime-grace < 1) [NSThread sleepForTimeInterval:0.02];
            if (task.isRunning) kill(task.processIdentifier, SIGKILL);
            break;
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    [task waitUntilExit]; if (output) [out closeFile]; if (error) [err closeFile];
    return stopped || task.terminationReason != NSTaskTerminationReasonExit ? -1 : task.terminationStatus;
}
static NSString *PrivateDirectory(NSString *parent) {
    NSString *template = [parent stringByAppendingPathComponent:@".glancebar-cleanup-XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation); char *result = mkdtemp(buffer);
    NSString *directory = result ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:result length:strlen(result)] : nil;
    free(buffer); return directory;
}
NSString *GBStorageOpenFileReason(NSString *path) {
    NSString *temp = PrivateDirectory(NSTemporaryDirectory());
    if (!temp) return @"Cannot check whether the file is in use.";
    NSString *out = [temp stringByAppendingPathComponent:@"out"], *err = [temp stringByAppendingPathComponent:@"err"];
    [NSData.data writeToFile:out atomically:NO]; [NSData.data writeToFile:err atomically:NO];
    NSInteger code = Run(@"/usr/sbin/lsof", @[@"-nP",@"-F",@"p",@"--",path], 4, nil,
                         [NSURL fileURLWithPath:out], [NSURL fileURLWithPath:err]);
    NSData *output = [NSData dataWithContentsOfFile:out], *error = [NSData dataWithContentsOfFile:err];
    [NSFileManager.defaultManager removeItemAtPath:temp error:NULL];
    if (output.length || code == 0) return @"The file is open in an application. Close it and scan again.";
    if (code != 1 || error.length) return @"The in-use check was incomplete. Reveal the file in Finder instead.";
    return nil;
}
static NSString *Revalidate(NSDictionary *entry, NSString *home, BOOL compress, GBStorageOpenCheck openCheck) {
    NSString *reason = GBStorageCleanupReason(entry, home, compress);
    if (reason) return reason;
    if (!openCheck) return @"The in-use check is unavailable.";
    reason = openCheck(entry[@"path"]);
    return reason ?: GBStorageCleanupReason(entry, home, compress);
}
// Undo capabilities never leave this process. A caller cannot redirect an issued
// record to another file/path by replacing its public dictionary fields.
static NSMutableDictionary *UndoRecords(void) {
    static NSMutableDictionary *records; static dispatch_once_t once;
    dispatch_once(&once, ^{ records=[NSMutableDictionary dictionary]; }); return records;
}
static NSMutableArray *UndoOrder(void) {
    static NSMutableArray *order; static dispatch_once_t once;
    dispatch_once(&once, ^{ order=[NSMutableArray array]; }); return order;
}
static BOOL InTrash(NSString *path, NSString *home) {
    if (!ValidPath(path) || !ValidPath(home)) return NO;
    NSString *trash=[home stringByAppendingPathComponent:@".Trash"];
    if (!Under(path,trash)) {
        struct statfs volume;
        if (statfs(path.fileSystemRepresentation,&volume)) return NO;
        NSString *mount=[NSFileManager.defaultManager stringWithFileSystemRepresentation:volume.f_mntonname length:strlen(volume.f_mntonname)];
        // The start-up data volume uses the personal Trash. Other volumes have
        // a per-user .Trashes directory at their actual mount point.
        trash=[[mount stringByAppendingPathComponent:@".Trashes"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",getuid()]];
        if (!Under(path,trash)) return NO;
    }
    struct stat s;
    return !NoLinks(path) && !lstat(trash.fileSystemRepresentation,&s) && S_ISDIR(s.st_mode) && s.st_uid==getuid();
}
// Open every ancestor relative to its preceding descriptor. Neither the source
// nor destination can be redirected through a symlink during resolution.
static int OpenDirectory(NSString *path) {
    if (!ValidPath(path)) return -1;
    int fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        if (fd<0) break;
        int next=openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(fd); fd=next;
    }
    return fd;
}
static BOOL DescriptorMatches(int fd, NSDictionary *identity) {
    struct stat s;
    return fd>=0 && identity[@"device"] && identity[@"inode"] && !fstat(fd,&s) &&
        S_ISDIR(s.st_mode) && s.st_dev==[identity[@"device"] longLongValue] && s.st_ino==[identity[@"inode"] unsignedLongLongValue];
}
NSDictionary *GBStorageTrash(NSDictionary *entry, NSString *home, GBStorageOpenCheck openCheck, GBStorageTrashTransport transport) {
    NSString *reason = Revalidate(entry, home, NO, openCheck); if (reason) return Failure(reason);
    NSURL *url = [NSURL fileURLWithPath:entry[@"path"]];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSDictionary *result = nil; NSError *coordinationError = nil;
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMoving error:&coordinationError byAccessor:^(NSURL *current) {
        if (![current.path isEqual:url.path]) { result = Failure(@"The path moved during the operation. Refresh and try again."); return; }
        NSString *problem = Revalidate(entry, home, NO, openCheck);
        if (problem) { result = Failure(problem); return; }
        NSURL *reference = current.fileReferenceURL;
        if (!reference || !GBStorageIdentityMatches(entry[@"identity"],GBStorageIdentity(reference.filePathURL.path))) {
            result = Failure(@"The file identity could not be secured. Scan again."); return;
        }
        NSString *parent=current.path.stringByDeletingLastPathComponent;
        NSDictionary *parentIdentity=GBStorageIdentity(parent);
        NSDictionary *originalIdentity=GBStorageIdentity(current.path);
        if (!parentIdentity || NoLinks(parent)) { result=Failure(@"The containing folder changed. Scan again."); return; }
        if (!GBStorageIdentityMatches(entry[@"identity"],originalIdentity)) { result=Failure(@"The file changed. Scan again."); return; }
        NSError *error = nil;
        NSURL *trashedURL=nil;
        BOOL ok = transport ? transport(reference, &trashedURL, &error) : [NSFileManager.defaultManager trashItemAtURL:reference resultingItemURL:&trashedURL error:&error];
        if (!ok) { result=Failure(error.localizedDescription ?: @"Could not move this file to Trash."); return; }
        NSString *trashedPath=trashedURL.filePathURL.path;
        NSDictionary *trashIdentity=GBStorageIdentity(trashedPath);
        if (SameNode(originalIdentity,GBStorageIdentity(current.path))) {
            result=Failure(@"The file is still at its original path. Trash could not be verified."); return;
        }
        NSMutableDictionary *moved=[@{@"message":@"Moved to Trash. Space is not released until you empty it yourself."} mutableCopy];
        // A successful system Trash operation can occasionally omit a usable
        // destination. Report the move honestly, but offer no speculative Undo.
        if (InTrash(trashedPath,home) && SameNode(originalIdentity,trashIdentity) &&
            [originalIdentity[@"size"] isEqual:trashIdentity[@"size"]] &&
            [originalIdentity[@"mtime"] isEqual:trashIdentity[@"mtime"]] &&
            SameNode(parentIdentity,GBStorageIdentity(parent))) {
            [moved addEntriesFromDictionary:@{@"originalPath":[current.path copy],@"trashedPath":[trashedPath copy],
                @"originalIdentity":originalIdentity,@"parentIdentity":parentIdentity,@"trashIdentity":trashIdentity,
                @"home":[home copy],@"undoToken":NSUUID.UUID.UUIDString}];
            @synchronized (UndoRecords()) {
                UndoRecords()[moved[@"undoToken"]]=[moved copy]; [UndoOrder() addObject:moved[@"undoToken"]];
                while (UndoOrder().count>16) { [UndoRecords() removeObjectForKey:UndoOrder().firstObject]; [UndoOrder() removeObjectAtIndex:0]; }
            }
        }
        result=[moved copy];
    }];
    return result ?: Failure(coordinationError.localizedDescription);
}
static NSDictionary *RestoreIssued(NSDictionary *issued, NSString *home) {
        NSString *original=issued[@"originalPath"], *trashed=issued[@"trashedPath"], *parent=original.stringByDeletingLastPathComponent;
        if (!PersonalPath(original,home) || GBStorageBoundaryReason(original) || !InTrash(trashed,home) ||
            NoLinks(parent) || !SameNode(issued[@"parentIdentity"],GBStorageIdentity(parent)))
            return Failure(@"The original folder or Trash location changed. Use Finder's Trash.");
        NSURL *source=[NSURL fileURLWithPath:trashed], *destination=[NSURL fileURLWithPath:original];
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block NSDictionary *result=nil; NSError *coordinationError=nil;
        [coordinator coordinateWritingItemAtURL:source options:NSFileCoordinatorWritingForMoving
            writingItemAtURL:destination options:0 error:&coordinationError
            byAccessor:^(NSURL *current,NSURL *target) {
            if (![current.path isEqual:trashed] || ![target.path isEqual:original] || !InTrash(trashed,home) ||
                NoLinks(parent) || GBStorageBoundaryReason(original) ||
                !GBStorageIdentityMatches(issued[@"trashIdentity"],GBStorageIdentity(trashed)) ||
                !SameNode(issued[@"parentIdentity"],GBStorageIdentity(parent))) {
                result=Failure(@"The file or its original folder changed. Use Finder's Trash."); return;
            }
            struct stat s;
            if (lstat(trashed.fileSystemRepresentation,&s) || !S_ISREG(s.st_mode) || s.st_uid!=getuid() || s.st_nlink!=1 ||
                (s.st_flags&(UF_IMMUTABLE|SF_IMMUTABLE|UF_APPEND|SF_APPEND|SF_DATALESS))) {
                result=Failure(@"The trashed file is no longer eligible for Undo."); return;
            }
            NSString *sourceParent=trashed.stringByDeletingLastPathComponent;
            NSDictionary *sourceParentIdentity=GBStorageIdentity(sourceParent);
            int from=OpenDirectory(sourceParent), to=OpenDirectory(parent);
            BOOL safe=DescriptorMatches(from,sourceParentIdentity) && DescriptorMatches(to,issued[@"parentIdentity"]);
            struct stat currentStat, destinationStat;
            if (safe) safe=!fstatat(from,trashed.lastPathComponent.fileSystemRepresentation,&currentStat,AT_SYMLINK_NOFOLLOW) &&
                currentStat.st_dev==s.st_dev && currentStat.st_ino==s.st_ino && currentStat.st_ctimespec.tv_sec==s.st_ctimespec.tv_sec &&
                currentStat.st_ctimespec.tv_nsec==s.st_ctimespec.tv_nsec;
            BOOL absent=NO;
            if (safe) { errno=0; absent=fstatat(to,original.lastPathComponent.fileSystemRepresentation,&destinationStat,AT_SYMLINK_NOFOLLOW)<0 && errno==ENOENT; }
            if (!safe || !absent) result=Failure(safe ? @"A file already occupies the original location. Nothing was overwritten." : @"The file or folder changed. Use Finder's Trash.");
            else if (renameatx_np(from,trashed.lastPathComponent.fileSystemRepresentation,to,original.lastPathComponent.fileSystemRepresentation,RENAME_EXCL))
                result=Failure(errno==EEXIST ? @"A file already occupies the original location. Nothing was overwritten." : @"Could not restore this file safely. Use Finder's Trash.");
            else result=@{@"path":original,@"message":@"Restored to its original folder."};
            if (from>=0) close(from); if (to>=0) close(to);
        }];
        return result ?: Failure(coordinationError.localizedDescription);
}
NSDictionary *GBStorageRestore(NSDictionary *record, NSString *home) {
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"undoToken"] isKindOfClass:NSString.class])
        return Failure(@"This move has no available Undo record. Use Finder's Trash.");
    NSDictionary *issued=nil;
    @synchronized (UndoRecords()) {
        issued=UndoRecords()[record[@"undoToken"]];
        if (!issued || ![issued isEqualToDictionary:record] || ![issued[@"home"] isEqual:home])
            return Failure(@"The Undo record is changed or expired. Use Finder's Trash.");
        // Reserve the capability before I/O. Never hold this lock across file
        // coordination: another coordinated Trash may need to issue a record.
        [UndoRecords() removeObjectForKey:issued[@"undoToken"]];
    }
    NSDictionary *result=RestoreIssued(issued,home);
    @synchronized (UndoRecords()) {
        if (result[@"error"] && [UndoOrder() containsObject:issued[@"undoToken"]])
            UndoRecords()[issued[@"undoToken"]]=issued;
        else [UndoOrder() removeObject:issued[@"undoToken"]];
    }
    return result;
}
NSDictionary *GBStorageCompress(NSDictionary *entry, NSString *home, GBStorageOpenCheck openCheck, BOOL (^cancelled)(void)) {
    NSString *reason = Revalidate(entry, home, YES, openCheck); if (reason) return Failure(reason);
    if (cancelled && cancelled()) return Failure(@"Cancelled; original kept.");
    NSURL *url = [NSURL fileURLWithPath:entry[@"path"]];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSDictionary *result = nil; NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *current) {
        if (![current.path isEqual:url.path]) { result = Failure(@"The path moved during the operation. Refresh and try again."); return; }
        NSString *problem = Revalidate(entry, home, YES, openCheck);
        if (problem) { result = Failure(problem); return; }
        NSString *parent = current.path.stringByDeletingLastPathComponent;
        struct statfs volume;
        uint64_t required=[entry[@"identity"][@"size"] unsignedLongLongValue]+256ULL*1024*1024;
        if (statfs(parent.fileSystemRepresentation,&volume) || (uint64_t)volume.f_bavail*volume.f_bsize < required) {
            result = Failure(@"Not enough available space for a safe archive copy; original kept."); return;
        }
        NSDictionary *parentIdentity = GBStorageIdentity(parent);
        NSString *temp = PrivateDirectory(parent);
        if (!temp) { result = Failure(@"Could not create a private archive workspace."); return; }
        NSString *archive = [temp stringByAppendingPathComponent:@"copy.zip"];
        NSInteger code = Run(@"/usr/bin/ditto", @[@"-c",@"-k",@"--sequesterRsrc",@"--keepParent",current.path,archive],120,cancelled,nil,nil);
        if (code == 0) code = Run(@"/usr/bin/unzip",@[@"-tqq",archive],30,cancelled,nil,nil);
        problem = GBStorageCleanupReason(entry, home, YES);
        NSDictionary *newParent = GBStorageIdentity(parent);
        BOOL sameParent = [parentIdentity[@"device"] isEqual:newParent[@"device"]] && [parentIdentity[@"inode"] isEqual:newParent[@"inode"]];
        if (code || problem || !sameParent || (cancelled && cancelled())) {
            result = Failure(problem ?: @"Archive cancelled, changed or could not be verified; original kept.");
        } else {
            NSString *destination = nil;
            for (NSUInteger index = 0; index < 100; index++) {
                if ((cancelled && cancelled()) || GBStorageCleanupReason(entry,home,YES)) break;
                NSString *name = index ? [NSString stringWithFormat:@"%@-%lu.zip",current.lastPathComponent,(unsigned long)index] : [current.lastPathComponent stringByAppendingString:@".zip"];
                NSString *candidate = [parent stringByAppendingPathComponent:name];
                // Atomic, no-overwrite publication on the same filesystem.
                if (link(archive.fileSystemRepresentation,candidate.fileSystemRepresentation) == 0) { destination = candidate; break; }
                if (errno != EEXIST) break;
            }
            result = destination ? @{@"path":destination,@"message":@"Verified ZIP copy created. Original kept; no space has been freed."} : Failure(@"Could not save the archive without overwriting another file; original kept.");
        }
        [NSFileManager.defaultManager removeItemAtPath:temp error:NULL];
    }];
    return result ?: Failure(coordinationError.localizedDescription);
}
