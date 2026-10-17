// Bounded, read-only process activity. CPU is percent of one core; network is
// socket bytes/s (including local/tunnel traffic), never Internet billing or watts.
#import <Foundation/Foundation.h>

NSDictionary *GBActivitySurvey(void); // call off the main thread
NSArray *GBActivitySortedRows(NSArray *rows, NSString *metric);
NSString *GBActivityRate(NSNumber *value, BOOL partial);
NSString *GBActivityCPU(NSNumber *value, BOOL partial);
// Pure helpers: deterministic snapshots make reset, PID reuse and timing testable.
NSDictionary *GBActivityParseNetwork(NSString *csv);
NSDictionary *GBActivityCompute(NSDictionary *first, NSDictionary *second, double nanosecondsPerTick);
