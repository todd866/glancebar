#import "deck_client.h"
#import <fcntl.h>
#import <poll.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static const CFTimeInterval kGBDeckTimeoutSec = 2.0;

static int DeckWaitMS(CFAbsoluteTime deadline) {
    double left = (deadline - CFAbsoluteTimeGetCurrent()) * 1000.0;
    if (left < 1.0) return 0;
    if (left > kGBDeckTimeoutSec * 1000.0) return (int)(kGBDeckTimeoutSec * 1000.0);
    return (int)left;
}

static BOOL DeckConnect(int fd, const struct sockaddr_un *addr, CFAbsoluteTime deadline) {
    int rc = connect(fd, (const struct sockaddr *)addr, (socklen_t)sizeof(*addr));
    if (rc == 0) return YES;
    if (errno != EINPROGRESS && errno != EALREADY) return NO;
    for (;;) {
        int wait = DeckWaitMS(deadline);
        if (wait <= 0) return NO;
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, wait);
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) return NO;
        int soerr = 0;
        socklen_t sl = (socklen_t)sizeof(soerr);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0 || soerr != 0) return NO;
        return YES;
    }
}

static BOOL DeckWriteAll(int fd, NSData *bytes, CFAbsoluteTime deadline) {
    const uint8_t *cursor = bytes.bytes;
    size_t left = (size_t)bytes.length;
    while (left > 0) {
        int wait = DeckWaitMS(deadline);
        if (wait <= 0) return NO;
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, wait);
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) return NO;
        ssize_t n = write(fd, cursor, left);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return NO;
        cursor += (size_t)n;
        left -= (size_t)n;
    }
    return YES;
}

// The first line, without its newline. nil on timeout or a closed socket.
static NSString *DeckReadLine(int fd, CFAbsoluteTime deadline) {
    NSMutableData *got = [NSMutableData data];
    uint8_t buf[4096];
    while (got.length < (NSUInteger)(256 * 1024)) {
        int wait = DeckWaitMS(deadline);
        if (wait <= 0) return nil;
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, wait);
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) return nil;
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return nil;
        [got appendBytes:buf length:(NSUInteger)n];
        const uint8_t *bytes = got.bytes;
        NSUInteger count = got.length;
        for (NSUInteger i = 0; i < count; i++) {
            if (bytes[i] != '\n') continue;
            if (i == 0u) return @"";
            return [[NSString alloc] initWithBytes:bytes length:i encoding:NSUTF8StringEncoding];
        }
    }
    return nil;
}

static NSString *DeckRoundTrip(NSString *socketPath, NSString *commandJSON) {
    const char *path = socketPath.UTF8String;
    if (!path || !commandJSON.length) return nil;
    size_t len = strlen(path);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    if (len == 0 || len + 1 > sizeof(addr.sun_path)) return nil;
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, len + 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, (socklen_t)sizeof(nosig));
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return nil;
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kGBDeckTimeoutSec;
    NSString *line = [commandJSON stringByAppendingString:@"\n"];
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *reply = nil;
    if (bytes.length && DeckConnect(fd, &addr, deadline) && DeckWriteAll(fd, bytes, deadline))
        reply = DeckReadLine(fd, deadline);
    close(fd);
    return reply;
}

static void DeckFinish(void (^completion)(NSString *reply), NSString *reply) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(reply); });
}

void GBDeckSendCommand(NSString *socketPath, NSString *commandJSON,
                       void (^completion)(NSString *reply)) {
    if (!socketPath.length || !commandJSON.length) {
        DeckFinish(completion, nil);
        return;
    }
    NSString *path = [socketPath copy];
    NSString *command = [commandJSON copy];
    void (^done)(NSString *reply) = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *reply = DeckRoundTrip(path, command);
        DeckFinish(done, reply);
    });
}
