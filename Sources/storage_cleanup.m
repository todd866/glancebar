#import "storage_cleanup.h"
#import "storage_scan.h"
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <sys/mount.h>

static NSDictionary *Failure(NSString *message) { return @{@"error":message ?: @"Operation unavailable"}; }
static BOOL Under(NSString *path, NSString *root) {
    return [path hasPrefix:[root stringByAppendingString:@"/"]];
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
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath || [path.pathComponents containsObject:@".."] || [path.pathComponents containsObject:@"."])
        return @"Invalid or changed path. Scan again.";
    BOOL allowed = NO;
    for (NSString *folder in @[@"Downloads",@"Desktop",@"Documents",@"Movies",@"Music",@"Pictures"])
        if (Under(path, [home stringByAppendingPathComponent:folder])) allowed = YES;
    if (!allowed) return @"Cleanup is limited to individual files in your personal folders.";
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
NSDictionary *GBStorageTrash(NSDictionary *entry, NSString *home, GBStorageOpenCheck openCheck, GBStorageTrashTransport transport) {
    NSString *reason = Revalidate(entry, home, NO, openCheck); if (reason) return Failure(reason);
    NSURL *url = [NSURL fileURLWithPath:entry[@"path"]];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSDictionary *result = nil; NSError *coordinationError = nil;
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMoving error:&coordinationError byAccessor:^(NSURL *current) {
        if (![current.path isEqual:url.path]) { result = Failure(@"The path moved during review. Scan again."); return; }
        NSString *problem = Revalidate(entry, home, NO, openCheck);
        if (problem) { result = Failure(problem); return; }
        NSURL *reference = current.fileReferenceURL;
        if (!reference || !GBStorageIdentityMatches(entry[@"identity"],GBStorageIdentity(reference.filePathURL.path))) {
            result = Failure(@"The file identity could not be secured. Scan again."); return;
        }
        NSError *error = nil;
        BOOL ok = transport ? transport(reference, &error) : [NSFileManager.defaultManager trashItemAtURL:reference resultingItemURL:NULL error:&error];
        result = ok ? @{@"message":@"Moved to Trash. Space is not released until you empty it yourself."} : Failure(error.localizedDescription ?: @"Could not move this file to Trash.");
    }];
    return result ?: Failure(coordinationError.localizedDescription);
}
NSDictionary *GBStorageCompress(NSDictionary *entry, NSString *home, GBStorageOpenCheck openCheck, BOOL (^cancelled)(void)) {
    NSString *reason = Revalidate(entry, home, YES, openCheck); if (reason) return Failure(reason);
    if (cancelled && cancelled()) return Failure(@"Cancelled; original kept.");
    NSURL *url = [NSURL fileURLWithPath:entry[@"path"]];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSDictionary *result = nil; NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *current) {
        if (![current.path isEqual:url.path]) { result = Failure(@"The path moved during review. Scan again."); return; }
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
