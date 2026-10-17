#import <Foundation/Foundation.h>
#import "activity.h"
static int checks;
static void Check(BOOL yes, NSString *message) { checks++; if (!yes) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
static NSDictionary *Process(int pid, int start, NSString *group, NSNumber *user, NSNumber *system) {
    NSMutableDictionary *p=[@{@"pid":@(pid),@"start":@(start),@"name":@"App",@"group":group} mutableCopy];
    if(user)p[@"user"]=user; if(system)p[@"system"]=system; return p;
}
static NSDictionary *Snapshot(NSDictionary *p,double time,NSDictionary *net) {
    NSMutableDictionary *s=[@{@"processes":p,@"cpuAt":@(time),@"networkAt":@(time),@"capturedAt":@1000} mutableCopy];
    if(net)s[@"network"]=net;return s;
}
static NSDictionary *OneRow(NSDictionary *a,NSDictionary *b,double scale) { return [GBActivityCompute(a,b,scale)[@"rows"] firstObject]; }
int main(void) { @autoreleasepool {
    NSDictionary *net=GBActivityParseNetwork(@",bytes_in,bytes_out,\nnode.12,100,200,\ncom.foo.bar.34,0,18446744073709551615,\n\"a,b.56\",12,33,\n");
    Check(net.count==3,@"observed header and quoted comma process");
    Check([net[@12][@"in"] unsignedLongLongValue]==100,@"parse bytes");
    Check([net[@34][@"out"] unsignedLongLongValue]==ULLONG_MAX,@"preserve uint64");
    for(NSString *invalid in @[@"",@"error",@",bytes_out,bytes_in,\n",@",bytes_in,bytes_out,\np.1,-1,2,\n",@",bytes_in,bytes_out,\np.1,1e3,2,\n",@",bytes_in,bytes_out,\np.1,1.5,2,\n",@",bytes_in,bytes_out,\np.1,18446744073709551616,2,\n",@",bytes_in,bytes_out,\np.1,1,2,extra\n",@",bytes_in,bytes_out,\np.1,1,2,\np.1,3,4,\n",@",bytes_in,bytes_out,\n\"unterminated.1,1,2,\n"])
        Check(!GBActivityParseNetwork(invalid),@"malformed network is unavailable");
    Check(GBActivityParseNetwork(@",bytes_in,bytes_out,\n").count==0,@"valid empty snapshot is distinct from failure");
    NSDictionary *p0=@{@1:Process(1,1,@"a",@0,@0)}, *p1=@{@1:Process(1,1,@"a",@1000000000,@0)};
    NSDictionary *n0=@{@1:@{@"in":@100,@"out":@200}},*n1=@{@1:@{@"in":@3100,@"out":@4200}};
    NSDictionary *a=Snapshot(p0,10,n0),*b=Snapshot(p1,12,n1),*r=OneRow(a,b,1);
    Check(fabs([r[@"cpu"] doubleValue]-50)<1e-9,@"one billion ns over2s is50percent");
    Check([r[@"download"] doubleValue]==1500 && [r[@"upload"] doubleValue]==2000,@"counter deltas divided by measured interval");
    NSDictionary *mach=Snapshot(@{@1:Process(1,1,@"a",@24000000,@0)},12,n1);
    Check(fabs([OneRow(a,mach,125.0/3)[@"cpu"] doubleValue]-50)<1e-9,@"Mach125/3 conversion");
    NSDictionary *multi=Snapshot(@{@1:Process(1,1,@"a",@6000000000,@0)},12,n1);
    Check([OneRow(a,multi,1)[@"cpu"] doubleValue]==300,@"multicore rates exceed100");
    NSDictionary *reuse=Snapshot(@{@1:Process(1,2,@"a",@6000000000,@0)},12,n1);
    Check([GBActivityCompute(a,reuse,1)[@"rows"] count]==0,@"PIDreuse dropsbothdeltas");
    Check([GBActivityCompute(a,Snapshot(@{},12,@{}),1)[@"rows"] count]==0,@"exit is notzeroactivity");
    NSDictionary *resetA=Snapshot(@{@1:Process(1,1,@"a",@500,@500)},10,n1);
    NSDictionary *resetB=Snapshot(@{@1:Process(1,1,@"a",@400,@600)},12,n0);
    Check([GBActivityCompute(resetA,resetB,1)[@"rows"] count]==0,@"eachcounterresetrejectswithoutunsignedunderflow");
    for(NSNumber *time in @[@10,@9,@26,@(NAN)]) {
        NSDictionary *bad=Snapshot(p1,time.doubleValue,n1);
        Check([GBActivityCompute(a,bad,1)[@"rows"] count]==0,@"invalid/stalledintervalunavailable");
    }
    Check(!OneRow(a,b,NAN)[@"cpu"] && OneRow(a,b,NAN)[@"download"],@"invalidtimebaseonlydisablesCPU");
    r=OneRow(Snapshot(p0,10,nil),Snapshot(p1,12,nil),1);
    Check(r[@"cpu"] && !r[@"download"] && [r[@"networkPartial"] boolValue],@"missingnetisnotzero");
    NSMutableDictionary *bp=[p1 mutableCopy]; bp[@2]=Process(2,2,@"a",nil,nil);
    r=OneRow(a,Snapshot(bp,12,n1),1);
    Check([r[@"cpu"] doubleValue]==50 && [r[@"cpuPartial"] boolValue] && [r[@"networkPartial"] boolValue],@"new/inaccessiblehelpermakesgroupapartiallowerbound");
    NSDictionary *two0=@{@1:Process(1,1,@"/one/App.app",@0,@0),@2:Process(2,2,@"/two/App.app",@0,@0)};
    NSDictionary *two1=@{@1:Process(1,1,@"/one/App.app",@2000000000,@0),@2:Process(2,2,@"/two/App.app",@1000000000,@0)};
    Check([GBActivityCompute(Snapshot(two0,10,nil),Snapshot(two1,12,nil),1)[@"rows"] count]==2,@"identicallynamedappskeepdistinctidentities");
    NSDictionary *group0=@{@1:Process(1,1,@"same",@0,@0),@2:Process(2,2,@"same",@0,@0)};
    NSDictionary *group1=@{@1:Process(1,1,@"same",@1000000000,@0),@2:Process(2,2,@"same",@2000000000,@0)};
    r=OneRow(Snapshot(group0,10,nil),Snapshot(group1,12,nil),1);
    Check([r[@"cpu"] doubleValue]==150 && ![r[@"cpuPartial"] boolValue],@"groupCPUaddsreadablehelpers");
    r=OneRow(Snapshot(group0,10,nil),Snapshot(@{@1:group1[@1]},12,nil),1);
    Check([r[@"cpuPartial"] boolValue],@"exitedhelpermarksremaininggroup partial");
    NSArray *sort=@[@{@"name":@"C",@"group":@"c"},@{@"name":@"B",@"group":@"b",@"cpu":@50},@{@"name":@"A",@"group":@"a",@"cpu":@50}];
    NSArray *sorted=GBActivitySortedRows(sort,@"cpu");
    Check([sorted[0][@"name"] isEqual:@"A"] && [sorted.lastObject[@"name"] isEqual:@"C"],@"descending with stable names and unknownlast");
    Check([GBActivityCPU(@50,NO) isEqual:@"50.0%"],@"percentformat");
    Check([GBActivityCPU(@0.01,NO) isEqual:@"<0.1%"],@"smallpositiveisnotzero");
    Check([GBActivityCPU(@50,YES) isEqual:@"≥50.0%"],@"partialCPUlowerbound");
    Check([GBActivityRate(@1500,NO) isEqual:@"1.5 kB/s"],@"rateunits");
    Check([GBActivityRate(@0,NO) isEqual:@"0 B/s"],@"measuredzero");
    Check([GBActivityRate(@1599,YES) isEqual:@"≥1.5 kB/s"],@"lowerboundneverroundsup");
    Check([GBActivityRate(nil,NO) isEqual:@"—"] && [GBActivityCPU(@(NAN),NO) isEqual:@"—"],@"unknownandnonfiniteformat");
    fprintf(stderr,"Activity telemetry: %d checks passed\n",checks);
} return 0; }
