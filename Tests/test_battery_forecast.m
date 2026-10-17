#import <Foundation/Foundation.h>
#import "pure.h"
static int failures, checks;
static void check(BOOL condition, NSString *name) {
    checks++; if (!condition) { failures++; fprintf(stderr, "FAIL %s\n", name.UTF8String); }
}
static BatteryState Battery(BOOL ac) {
    return (BatteryState){.valid=YES, .percent=60, .acConnected=ac, .isCharging=ac,
        .voltage_mV=12000, .amperage_mA=ac ? 1000 : -1000, .rawMax_mAh=5000,
        .rawCurrent_mAh=3000, .minutesToEmpty=-1, .minutesToFull=-1};
}
static BatteryForecast Warm(BatteryForecastTracker *t, BatteryState b, BOOL limit, double now) {
    BatteryForecast f = {0};
    for (int sec=0; sec<=60; sec+=15) f = [t update:b limit80:limit at:now+sec];
    return f;
}
int main(void) { @autoreleasepool {
    BatteryState b = Battery(NO);
    NSDictionary *ps = @{@"Power Source State":@"Battery Power", @"Is Charging":@NO,
                         @"Time to Empty":@120, @"Time to Full Charge":@99};
    BatteryApplySystemTimes(&b, ps);
    check(b.minutesToEmpty == 120 && b.minutesToFull == -1, @"IOPS discharge direction and minute units");
    b.acConnected = YES; b.isCharging = YES;
    BatteryApplySystemTimes(&b, ps);
    check(b.minutesToEmpty == -1 && b.minutesToFull == -1, @"IOPS transition mismatch is unknown");
    ps = @{@"Power Source State":@"AC Power", @"Is Charging":@YES, @"Time to Full Charge":@120};
    BatteryApplySystemTimes(&b, ps);
    check(b.minutesToFull == 120 && b.minutesToEmpty == -1, @"IOPS full means full, not empty");
    for (NSNumber *v in @[@(-1), @0, @65535, @(-65536), @1441]) {
        BatteryApplySystemTimes(&b, @{@"Is Charging":@YES, @"Time to Full Charge":v});
        check(b.minutesToFull == -1, @"invalid system estimates rejected");
    }
    BatteryApplySystemTimes(&b, @{@"Is Charging":@YES, @"Time to Full Charge":@"120"});
    check(b.minutesToFull == -1, @"non-numeric system estimate rejected");
    b = Battery(NO); b.minutesToEmpty = 120;
    BatteryForecastTracker *t = [BatteryForecastTracker new];
    BatteryForecast f = [t update:b limit80:NO at:10000];
    check(f.thresholdTime == 14800 && f.endpointTime == 17200, @"system empty=120 min, reserve=80 min available immediately");
    check(f.thresholdPercent == 20 && f.endpointPercent == 0, @"discharge targets");
    b.minutesToEmpty = 119;
    f = [t update:b limit80:NO at:10015];
    check(f.endpointTime < 17200 && f.endpointTime > 17155, @"small jitter smoothed");
    b.minutesToEmpty = 45;
    f = [t update:b limit80:NO at:10030];
    check(f.endpointTime == 12730, @"large load revision is immediate, not stale");
    b.minutesToEmpty = -1;
    f = [t update:b limit80:NO at:10045];
    check(f.endpointTime == 0, @"missing system value clears before fallback is ready");
    b = Battery(NO); t = [BatteryForecastTracker new];
    check([t update:b limit80:NO at:20000].endpointTime == 0, @"startup does not extrapolate one current sample");
    for (int i=0;i<20;i++) f = [t update:b limit80:NO at:20000+i];
    check(f.endpointTime == 0, @"frequent renders do not fake a minute of samples");
    t = [BatteryForecastTracker new]; f = Warm(t,b,NO,20000);
    check(fabs(f.endpointTime-30860) < 1 && fabs(f.thresholdTime-27260) < 1, @"steady discharge fallback after 60 sec");
    b.amperage_mA=-2000; f = [t update:b limit80:NO at:20075];
    check(f.endpointTime == 0, @"load step clears current fallback");
    f = Warm(t,b,NO,20090);
    check(f.endpointTime > 25000 && f.endpointTime < 26000, @"new load earns fresh fallback");
    f = [t update:b limit80:NO at:20500];
    check(f.endpointTime == 0, @"sleep or long gap clears fallback");
    b = Battery(YES); t = [BatteryForecastTracker new]; f = Warm(t,b,NO,30000);
    check(f.thresholdTime == 33660 && f.endpointTime == 0, @"80% from stable current; no linear 100% estimate");
    b.minutesToFull=180; f = [t update:b limit80:NO at:30075];
    check(f.endpointTime == 40875 && f.thresholdTime > 0, @"system tapered full and measured 80 coexist");
    check(ChargeMinutesToTarget(b,100)==180, @"legacy full uses system taper");
    b.minutesToFull=-1;
    check(ChargeMinutesToTarget(b,100)==-1, @"legacy full cannot invent linear ETA");
    f = [t update:b limit80:YES at:30090];
    check(f.endpointTime == 0 && f.thresholdTime == 0, @"limit change clears forecasts and suppresses full");
    f=Warm(t,b,YES,30105); check(f.thresholdTime > 0 && f.endpointTime == 0, @"limited charging shows only 80 ETA");
    b.isCharging=NO; b.amperage_mA=0; b.percent=80;
    f = [t update:b limit80:YES at:30180];
    check(f.thresholdReached && !f.endpointReached && f.endpointTime == 0, @"optimized or limited 80 hold has no full forecast");
    b.percent=70; b.amperage_mA=-500;
    f = [t update:b limit80:NO at:30200];
    check(f.thresholdTime == 0 && f.endpointTime == 0 && f.endpointPercent==100, @"plugged but draining offers no charge prediction");
    b=Battery(YES); b.percent=95; b.amperage_mA=200; b.minutesToFull=70;
    f = [t update:b limit80:NO at:30300];
    check(f.thresholdReached && f.thresholdTime==0 && f.endpointTime==34500, @"taper near full uses 70min system ETA");
    b.percent=100; b.fullyCharged=YES;
    f=[t update:b limit80:NO at:30315];
    check(f.endpointReached && f.thresholdReached && f.endpointTime==0, @"full has no future clock");
    b=Battery(NO); b.percent=12; b.minutesToEmpty=30;
    f=[t update:b limit80:NO at:30400];
    check(f.thresholdReached && f.thresholdTime==0 && f.endpointTime==32200, @"below reserve keeps only empty clock");
    b.percent=20; f=[t update:b limit80:NO at:30415]; check(f.thresholdTime==0, @"at reserve has no past prediction");
    b.percent=0; f=[t update:b limit80:NO at:30430]; check(f.endpointReached && f.endpointTime==0, @"empty has no future clock");
    b=Battery(NO); b.minutesToEmpty=90; b.telemetryTimestamp=30000;
    f=[t update:b limit80:NO at:30500]; check(f.endpointTime==0, @"stale hardware timestamp invalidates predictions");
    b.telemetryTimestamp=30600; f=[t update:b limit80:NO at:30500]; check(f.endpointTime==0, @"future hardware timestamp invalidates predictions");
    b=Battery(YES); b.minutesToFull=20; t=[BatteryForecastTracker new];
    f=Warm(t,b,NO,40000); check(f.thresholdTime==0 && f.endpointTime>0, @"contradictory pre80 prediction withheld");
    b.valid=NO; f=[t update:b limit80:NO at:40075]; check(f.endpointTime==0 && f.thresholdTime==0, @"invalid battery clears all predictions");
    NSTimeZone *utc=[NSTimeZone timeZoneForSecondsFromGMT:0];
    double late=1792278900; // 2026-10-17 23:15 UTC
    check([BatteryForecastClock(late,utc) isEqual:@"2315"], @"24-hour HHmm format");
    check([BatteryForecastClock(late+61,utc) isEqual:@"2315"], @"clocks rounded to five minutes");
    check([BatteryForecastClock(late+3600,utc) isEqual:@"0015"], @"midnight wraps normally");
    f=(BatteryForecast){.thresholdPercent=20,.endpointPercent=0,.thresholdTime=late+3600,.endpointTime=late+7200};
    check([BatteryForecastDetail(f,late,utc) containsString:@"+1d"], @"tooltip disambiguates next day");
    check([BatteryForecastClock(late,[NSTimeZone timeZoneForSecondsFromGMT:8*3600]) isEqual:@"0715"], @"clock respects local timezone");
    check([BatteryForecastClock(NAN,utc) isEqual:@"—"], @"nonfinite arrival unavailable");
    f.thresholdTime=late-60; f.endpointTime=late-120;
    check([BatteryForecastDetail(f,late,utc) isEqual:@"20% — · 0% —"], @"expired arrival never becomes a positive ETA");
    b=Battery(NO); t=[BatteryForecastTracker new];
    for (int i=0;i<9;i++) { b.amperage_mA=i%2 ? -2500 : -500; f=[t update:b limit80:NO at:50000+i*15]; }
    check(f.endpointTime==0, @"unstable loads do not earn a fallback");
    b=Battery(NO); b.rawMax_mAh=0; t=[BatteryForecastTracker new]; f=Warm(t,b,NO,51000);
    check(f.endpointTime==0, @"unknown capacity blocks measured fallback");
    b=Battery(YES); b.isCharging=NO; b.minutesToFull=90; t=[BatteryForecastTracker new]; f=Warm(t,b,NO,52000);
    check(f.endpointTime==0 && f.thresholdTime==0, @"lagging positive current without charging confirmation cannot invent an ETA");
    b=Battery(NO); t=[BatteryForecastTracker new]; f=Warm(t,b,NO,53000);
    f=[t update:b limit80:NO at:52900]; check(f.endpointTime==0, @"backward clock adjustment clears sampled history");
    struct { double minutes; const char *text; } durationCases[] = {
        {0.01,"<5m"},{2.5,"<5m"},{4.99,"<5m"},{5,"5m"},{7.49,"5m"},{7.5,"10m"},
        {44,"45m"},{45,"45m"},{54,"55m"},{57.49,"55m"},{57.5,"1h"},{59.99,"1h"},{60,"1h"},
        {62.99,"1h"},{63,"1.1h"},{90,"1.5h"},{120,"2h"},{594,"9.9h"},{596.99,"9.9h"},
        {597,"10h"},{600,"10h"},{629.99,"10h"},{630,"11h"},{1440,"24h"},
        {0,"—"},{-1,"—"},{1441,"—"},{NAN,"—"},{INFINITY,"—"}
    };
    for (NSUInteger i=0;i<sizeof durationCases/sizeof durationCases[0];i++) {
        NSString *expected=[NSString stringWithUTF8String:durationCases[i].text];
        NSString *actual=BatteryForecastDuration(late+durationCases[i].minutes*60,late);
        check([actual isEqual:expected],[NSString stringWithFormat:@"duration %.2f minutes => %@",durationCases[i].minutes,expected]);
    }
    check([BatteryForecastDuration(0,late) isEqual:@"—"],@"unknown duration stays unavailable");
    check([BatteryForecastDuration(late,NAN) isEqual:@"—"],@"invalid now stays unavailable");
    check([BatteryForecastDuration(late+90*60,late) isEqual:@"1.5h"],@"duration is unchanged across midnight");
    f=(BatteryForecast){.thresholdPercent=20,.endpointPercent=0,.thresholdTime=late+3600,.endpointTime=late+7200};
    check([BatteryForecastDetail(f,late,utc) isEqual:@"20% ~0015 +1d · 0% ~0115 +1d"],@"tooltip retains arrival clocks behind compact durations");
    fprintf(stderr,"Battery forecast: %d checks, %d failures\n",checks,failures);
    return failures ? 1 : 0;
} }
