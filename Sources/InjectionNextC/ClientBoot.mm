//
//  ClientBoot.m
//  
//
//  Created by John H on 31/05/2024.
//

#if DEBUG || !SWIFT_PACKAGE
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

#import "InjectionImplC.h"
#import "InjectionClient.h"
#import "SimpleSocket.h"

extern "C" {
const char *_insetting(NSString *name);
}

@interface InjectionNext : SimpleSocket
- (BOOL)submitDeveloperReport:(NSDictionary *)metadata image:(NSData *)image;
- (BOOL)completeDeveloperTool:(NSString *)operationID result:(NSDictionary *)result;
- (NSString *)developerConnectionNonce;
@end

@implementation NSObject(InjectionNext)

static SimpleSocket *injectionClient;
static NSCondition *reconnectCondition;
static BOOL reconnectWorkerRunning;
static BOOL executionActive = YES;
static NSUInteger reconnectWakeGeneration;
static BOOL rootReady;
static NSUInteger rootRevision;
static void developerConnectionChanged(void);

static NSCondition *reconnectState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ reconnectCondition = [NSCondition new]; });
    return reconnectCondition;
}

extern "C" NSTimeInterval InjectionReconnectDelay(NSUInteger failureCount) {
    return MIN(16.0, 0.25 * (1UL << MIN(failureCount, (NSUInteger)6)));
}

extern "C" void InjectionWakeConnection(void) {
    NSCondition *condition = reconnectState();
    [condition lock];
    reconnectWakeGeneration++;
    SimpleSocket *client = injectionClient;
    [condition broadcast];
    [condition unlock];
    // shutdown, not close: the owner retains its descriptor until its read and
    // response queues exit, so a recycled descriptor can never be signalled.
    [client disconnect];
}

extern "C" void InjectionSetExecutionActive(BOOL active) {
    NSCondition *condition = reconnectState();
    [condition lock];
    executionActive = active;
    reconnectWakeGeneration++;
    SimpleSocket *client = active ? nil : injectionClient;
    [condition broadcast];
    [condition unlock];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SWIFT_SIM_CLIENT_STATE_CHANGED" object:nil];
    developerConnectionChanged();
    [client disconnect];
}

extern "C" void InjectionSetRootReady(BOOL ready, NSUInteger revision) {
    NSCondition *condition = reconnectState();
    [condition lock];
    rootReady = ready;
    rootRevision = MAX(rootRevision, revision);
    [condition broadcast];
    [condition unlock];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SWIFT_SIM_CLIENT_STATE_CHANGED" object:nil];
    developerConnectionChanged();
}

extern "C" BOOL InjectionWaitForRootReady(NSTimeInterval expiresAt) {
    NSCondition *condition = reconnectState();
    NSDate *deadline = [NSDate dateWithTimeIntervalSince1970:expiresAt];
    [condition lock];
    while (!executionActive || !rootReady) {
        if (![condition waitUntilDate:deadline]) break;
    }
    BOOL ready = executionActive && rootReady && [deadline timeIntervalSinceNow] > 0;
    [condition unlock];
    return ready;
}

extern "C" NSDictionary *InjectionClientExecutionState(void) {
    NSCondition *condition = reconnectState();
    [condition lock];
    NSDictionary *state = @{ @"is_active": @(executionActive), @"root_ready": @(rootReady), @"root_revision": @(rootRevision) };
    [condition unlock];
    return state;
}

extern "C" NSDictionary *InjectionDeveloperConnectionState(void) {
    NSCondition *condition = reconnectState();
    [condition lock];
    NSMutableDictionary *state = [@{ @"connected": @(injectionClient != nil),
        @"is_active": @(executionActive), @"root_ready": @(rootReady), @"root_revision": @(rootRevision) } mutableCopy];
    InjectionNext *client = (InjectionNext *)injectionClient;
    if ([client respondsToSelector:@selector(developerConnectionNonce)]) {
        state[@"connection_nonce"] = [client developerConnectionNonce];
    }
    [condition unlock];
    return state;
}

extern "C" BOOL InjectionDeveloperConnectionIsCurrent(NSObject *client) {
    NSCondition *condition = reconnectState();
    [condition lock];
    BOOL current = injectionClient == client && executionActive;
    [condition unlock];
    return current;
}

extern "C" BOOL InjectionSubmitDeveloperReport(NSDictionary *metadata, NSData *image) {
    NSCondition *condition = reconnectState();
    [condition lock];
    InjectionNext *client = executionActive ? (InjectionNext *)injectionClient : nil;
    [condition unlock];
    return [client respondsToSelector:@selector(submitDeveloperReport:image:)] &&
        [client submitDeveloperReport:metadata image:image];
}

extern "C" BOOL InjectionCompleteDeveloperTool(NSString *operationID, NSDictionary *result) {
    NSCondition *condition = reconnectState();
    [condition lock];
    InjectionNext *client = (InjectionNext *)injectionClient;
    [condition unlock];
    return [client respondsToSelector:@selector(completeDeveloperTool:result:)] &&
        [client completeDeveloperTool:operationID result:result];
}

static void developerConnectionChanged(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SWIFT_SIM_DEVELOPER_CONNECTION_CHANGED"
        object:nil userInfo:InjectionDeveloperConnectionState()];
}

extern "C" NSString *InjectionImageUUID(BOOL debugDylib) {
    NSString *path = NSBundle.mainBundle.executablePath;
    if (debugDylib) path = [path stringByAppendingString:@".debug.dylib"];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || ![path isEqualToString:[NSString stringWithUTF8String:name]]) continue;
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) return @"";
        const uint8_t *position = (const uint8_t *)header + sizeof(struct mach_header_64);
        const uint8_t *end = position + header->sizeofcmds;
        if (header->ncmds > 4096) return @"";
        for (uint32_t command = 0; command < header->ncmds; command++) {
            if ((size_t)(end - position) < sizeof(struct load_command)) return @"";
            const struct load_command *load = (const struct load_command *)position;
            if (load->cmdsize < sizeof(struct load_command) || load->cmdsize > (size_t)(end - position)) return @"";
            if (load->cmd == LC_UUID && load->cmdsize >= sizeof(struct uuid_command)) {
                return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)load)->uuid].UUIDString.lowercaseString;
            }
            position += load->cmdsize;
        }
    }
    return @"";
}


/// Called on load of image containing this code
+ (void)load {
    #ifdef INJECTION_RECONNECT_TESTING
    return;
    #endif
    if (getenv("SWIFT_SIM_DISABLE_CLIENT_AUTOCONNECT")) return;
    if ([InjectionNext InjectionBoot_inPreview]) return;
    #if !TARGET_OS_MAC
    [self performSelectorOnMainThread:@selector(connectInBackground)
                           withObject:nil waitUntilDone:NO];
}

+ (void)connectInBackground {
    #endif
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    #if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION
    [notifications addObserverForName:@"UIApplicationDidBecomeActiveNotification"
        object:nil queue:nil usingBlock:^(NSNotification *note) { InjectionSetExecutionActive(YES); }];
    [notifications addObserverForName:@"UIApplicationDidEnterBackgroundNotification"
        object:nil queue:nil usingBlock:^(NSNotification *note) { InjectionSetExecutionActive(NO); }];
    #else
    (void)notifications;
    #endif
    [self performSelectorInBackground:@selector(connectToInjection:)
                           withObject:[InjectionNext self]];
}

/// Attempt to connect to InjectionNext.app
+ (void)connectToInjection:(Class)clientClass {
    #ifdef INJECTION_HOST_SETTING
    if (!getenv(INJECTION_HOST))
        setenv(INJECTION_HOST, INJECTION_HOST_SETTING, 1);
    #endif
    #ifdef INJECTION_NOSTANDALONE_SETTING
    if (!getenv(INJECTION_NOSTANDALONE))
        setenv(INJECTION_NOSTANDALONE, INJECTION_NOSTANDALONE_SETTING, 1);
    #endif
    const char *hostip = getenv(INJECTION_HOST) ?: "127.0.0.1";

    if (const char *settingsValue = _insetting(@INJECTION_HOST)) {
        NSLog(@APP_PREFIX"Connecting to %s setting %s",
              INJECTION_HOST, settingsValue);
        hostip = settingsValue;
    }
    else
    // Do we need to use broadcasts to find devlepers Mac on the network
    #if !TARGET_IPHONE_SIMULATOR && !TARGET_OS_OSX
    if (@available(iOS 14.0, *)) if (![NSProcessInfo processInfo].isiOSAppOnMac) {
        printf(APP_PREFIX APP_NAME": Locating developer's Mac. Have you selected \"Enable Devices\"?\n");
        hostip = [SimpleSocket getMulticastService:HOTRELOADING_MULTICAST port:HOTRELOADING_PORT
                                           message:APP_PREFIX"Connecting to %s (%s)...\n"].UTF8String;
    }
    #else
    ;
    #endif

    NSString *socketAddr = [NSString stringWithFormat:@"%s%s", hostip, INJECTION_ADDRESS];
    // Only one worker owns a socket and its command reader. A disconnect ends
    // that reader before a replacement socket is admitted.
    NSCondition *condition = reconnectState();
    [condition lock];
    if (reconnectWorkerRunning) { [condition unlock]; return; }
    reconnectWorkerRunning = YES;
    [condition unlock];
    const BOOL reconnectEnabled = getenv(INJECTION_HOST) || _insetting(@INJECTION_HOST);
    NSUInteger failures = 0;
    do {
        @autoreleasepool {
            [condition lock];
            while (!executionActive) [condition wait];
            const NSUInteger attemptGeneration = reconnectWakeGeneration;
            [condition unlock];
            SimpleSocket *client = [clientClass connectTo:socketAddr timeout:3.0];
            if (client) {
                [condition lock];
                BOOL current = executionActive && attemptGeneration == reconnectWakeGeneration;
                if (current) injectionClient = client;
                [condition unlock];
                if (current) {
                    developerConnectionChanged();
                    failures = 0;
                    [client runInBackground];
                }
                [client disconnect];
                [condition lock];
                BOOL removed = injectionClient == client;
                if (removed) injectionClient = nil;
                [condition unlock];
                if (removed) developerConnectionChanged();
            }
            if (!reconnectEnabled) break;
            [condition lock];
            const NSUInteger waitGeneration = reconnectWakeGeneration;
            if (attemptGeneration == waitGeneration && executionActive) {
                [condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:InjectionReconnectDelay(failures++)]];
            }
            [condition unlock];
        }
    } while (reconnectEnabled);
    [condition lock];
    reconnectWorkerRunning = NO;
    [condition unlock];

    #if TARGET_IPHONE_SIMULATOR || TARGET_OS_MAC
    // If InjectionLite class present, start it up.
    if (_insetting(@INJECTION_NOSTANDALONE)) return;
    if (Class InjectionLite = objc_getClass("InjectionLite")) {
        printf(APP_PREFIX"Unable to connect to app, running standalone... "
               "Set env var " INJECTION_NOSTANDALONE " to avoid this.\n");
        static NSObject *singleton;
        singleton = [[InjectionLite alloc] init];
    }
    #endif
}

@end
#endif
