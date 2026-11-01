#import <Foundation/Foundation.h>
#import "SimpleSocket.h"
#import "InjectionClient.h"

@interface NSObject (ReconnectTests)
+ (void)connectToInjection:(Class)clientClass;
@end
@interface InjectionNext: SimpleSocket
@end
@implementation InjectionNext
@end

extern "C" const char *_insetting(NSString *name) {
    return [name isEqualToString:@"INJECTION_HOST"] ? "127.0.0.1" : NULL;
}

static NSCondition *state;
static int attempts, activeReaders, peakReaders;
static BOOL offline;
@interface FixtureSocket: SimpleSocket
@property BOOL disconnected;
@end
@implementation FixtureSocket
+ (instancetype)connectTo:(NSString *)address timeout:(NSTimeInterval)timeout {
    [state lock];
    attempts++;
    BOOL unavailable = offline;
    [state broadcast];
    [state unlock];
    return unavailable ? nil : [FixtureSocket new];
}
- (void)runInBackground {
    [state lock];
    activeReaders++;
    peakReaders = MAX(peakReaders, activeReaders);
    [state broadcast];
    while (!self.disconnected) [state wait];
    activeReaders--;
    [state broadcast];
    [state unlock];
}
- (void)disconnect {
    [state lock];
    self.disconnected = YES;
    [state broadcast];
    [state unlock];
}
@end

static void require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAILED: %s\n", message); exit(1); }
}
static BOOL await(BOOL (^predicate)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    [state lock];
    while (!predicate()) if (![state waitUntilDate:deadline]) break;
    BOOL result = predicate();
    [state unlock];
    return result;
}
extern "C" void RunSocketFrameTests(void);
int main() {
    @autoreleasepool {
        RunSocketFrameTests();
        state = [NSCondition new];
        require(InjectionReconnectDelay(0) == .25, "initial backoff");
        require(InjectionReconnectDelay(6) == 16 && InjectionReconnectDelay(100) == 16, "capped backoff");
        [NSObject performSelectorInBackground:@selector(connectToInjection:) withObject:FixtureSocket.class];
        require(await(^BOOL { return activeReaders == 1; }), "initial connection");
        require([InjectionDeveloperConnectionState()[@"connected"] boolValue], "developer snapshot observes actual socket owner");
        require(!InjectionSubmitDeveloperReport(@{@"schema_version": @1, @"report_id": NSUUID.UUID.UUIDString}, NSData.data), "unnegotiated fixture cannot accept report");
        for (int i=0; i<12; i++) {
            [NSObject performSelectorInBackground:@selector(connectToInjection:) withObject:FixtureSocket.class];
        }
        [NSThread sleepForTimeInterval:.05];
        require(peakReaders == 1 && attempts == 1, "one client despite concurrent starts");
        InjectionWakeConnection();
        require(await(^BOOL { return attempts >= 2 && activeReaders == 1; }), "network/helper disconnect reconnects");
        InjectionSetExecutionActive(NO);
        require(await(^BOOL { return activeReaders == 0; }), "background reader closes");
        int paused = attempts;
        [NSThread sleepForTimeInterval:.4];
        require(attempts == paused, "no active background retry loop");
        InjectionSetExecutionActive(YES);
        require(await(^BOOL { return attempts > paused && activeReaders == 1; }), "foreground reconnects without manual retry");
        [state lock]; offline = YES; [state unlock];
        InjectionWakeConnection();
        require(await(^BOOL { return activeReaders == 0; }), "network loss exits reader");
        [NSThread sleepForTimeInterval:.05];
        [state lock]; offline = NO; [state unlock];
        InjectionWakeConnection();
        require(await(^BOOL { return activeReaders == 1; }), "network restoration wakes backoff");
        InjectionSetRootReady(YES, 8);
        InjectionSetRootReady(YES, 2);
        NSDictionary *execution = InjectionClientExecutionState();
        require([execution[@"root_revision"] unsignedIntegerValue] == 8, "root revision cannot go backwards");
        require([execution[@"is_active"] boolValue] && [execution[@"root_ready"] boolValue], "root readiness state");
        require(peakReaders == 1, "no duplicate command readers");
        InjectionSetExecutionActive(NO);
        require(await(^BOOL { return activeReaders == 0; }), "final owned reader stops");
        require(![InjectionDeveloperConnectionState()[@"is_active"] boolValue], "developer snapshot tracks foreground execution");
        puts("Native reconnect lifecycle checks passed");
    }
    return 0;
}
