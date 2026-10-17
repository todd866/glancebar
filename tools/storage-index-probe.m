// Read-only probe of the same production index, optionally emitting progressive JSON.
#import <Foundation/Foundation.h>
#import "../Sources/storage_index.h"
int main(int argc,const char **argv){@autoreleasepool{
    if(argc<2)return 2;
    NSString *home=NSHomeDirectory().stringByResolvingSymlinksInPath;
    GBStorageIndex *index=[[GBStorageIndex alloc] initWithRoots:GBStorageDefaultRoots(home) home:home];
    NSDictionary *snapshot=nil;double started=NSProcessInfo.processInfo.systemUptime;
    double limit=argc>2 ? MAX(1,atof(argv[2])) : 1800;
    while(!index.finished && NSProcessInfo.processInfo.systemUptime-started<limit){
        @autoreleasepool{
            snapshot=[index advanceForSeconds:.35 entries:3000];
            NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:NULL];
            [data writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
            fprintf(stderr,"entries=%lu rows=%lu active=%.2fs errors=%lu complete=%d limited=%d\n",(unsigned long)[snapshot[@"entries"] unsignedIntegerValue],(unsigned long)[snapshot[@"rows"] count],[snapshot[@"activeSeconds"] doubleValue],(unsigned long)[snapshot[@"errors"] unsignedIntegerValue],[snapshot[@"complete"] boolValue],[snapshot[@"limited"] boolValue]);
            [NSThread sleepForTimeInterval:.1];
        }
    }
    NSLog(@"Observed ranking saved; read-only and no settings changed.");
    return index.finished && ![snapshot[@"limited"] boolValue] ? 0 : 3;
}}
