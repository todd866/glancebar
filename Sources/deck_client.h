#import <Foundation/Foundation.h>

// One JSON command to the deck's Unix stream socket. A newline is added.
// Connect, write and read share a 2 second budget on a background queue.
// `completion` runs on the main queue. `reply` is the first line, or nil when
// the socket cannot be reached or does not answer in time.
void GBDeckSendCommand(NSString *socketPath, NSString *commandJSON,
                       void (^completion)(NSString *reply));
