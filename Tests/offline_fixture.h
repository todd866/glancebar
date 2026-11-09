// Synthetic bytes only, never a player or a real music library.
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>
static NSDictionary *OfflineFixture(NSString *path, NSString *key) {
    NSDictionary *track = @{@"id": @"fixture-id", @"title": @"Fixture", @"artist": @"Test Artist", @"album": @"Test Album"};
    struct stat st; stat(path.fileSystemRepresentation, &st);
    NSData *data = [NSData dataWithContentsOfFile:path];
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    NSMutableDictionary *record = [track mutableCopy];
    [record addEntriesFromDictionary:@{@"path": path, @"sizeBytes": @(st.st_size), @"sha256": hash,
        @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino],
        @"mtimeNs": [NSString stringWithFormat:@"%lld", (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec]}];
    NSDictionary *request = @{@"key": key, @"title": @"Fixture", @"tracks": @[track]};
    NSDictionary *entry = @{@"key": key, @"requestedTracks": @[track], @"requestedTrackIDs": @[@"fixture-id"], @"tracks": @[record], @"ready": @YES};
    return @{@"request": request, @"manifest": @{@"schemaVersion": @1, @"playlists": @[entry]}};
}
