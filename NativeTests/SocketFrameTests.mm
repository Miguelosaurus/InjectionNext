#import <Foundation/Foundation.h>
#import "SimpleSocket.h"
#import <sys/socket.h>
#import <unistd.h>
#import <netinet/in.h>

static void check(BOOL value) { if (!value) { fputs("FAILED: bounded socket frame\n", stderr); exit(1); } }
static SimpleSocket *fixture(int *writer) {
    int pair[2]; check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    *writer = pair[1];
    return [[SimpleSocket alloc] initSocket:pair[0]];
}
extern "C" void RunSocketFrameTests(void) {
    @autoreleasepool {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        check(listener >= 0);
        struct sockaddr_in address = {};
        address.sin_len = sizeof(address); address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        check(bind(listener, (struct sockaddr *)&address, sizeof address) == 0);
        check(listen(listener, 1) == 0);
        socklen_t addressLength = sizeof address;
        check(getsockname(listener, (struct sockaddr *)&address, &addressLength) == 0);
        NSString *endpoint = [NSString stringWithFormat:@"127.0.0.1:%d", ntohs(address.sin_port)];
        SimpleSocket *connected = [SimpleSocket connectTo:endpoint timeout:.25];
        check(connected != nil);
        int accepted = accept(listener, NULL, NULL); check(accepted >= 0);
        [connected disconnect]; close(accepted); close(listener);
        check([SimpleSocket connectTo:endpoint timeout:.25] == nil);

        int writer;
        SimpleSocket *socket = fixture(&writer);
        int oversized = INT32_MAX;
        check(write(writer, &oversized, sizeof oversized) == sizeof oversized);
        check([socket readDataWithMaxLength:16 * 1024] == nil);
        char byte; check(read(writer, &byte, 1) == 0); // framing error closed stream
        close(writer);

        socket = fixture(&writer);
        int negative = -2;
        check(write(writer, &negative, sizeof negative) == sizeof negative);
        check([socket readStringWithMaxLength:16] == nil);
        close(writer);

        socket = fixture(&writer);
        int length = 8;
        check(write(writer, &length, sizeof length) == sizeof length);
        check(write(writer, "ab", 2) == 2);
        shutdown(writer, SHUT_WR);
        check([socket readDataWithMaxLength:16] == nil);
        close(writer);

        socket = fixture(&writer);
        length = 1;
        check(write(writer, &length, sizeof length) == sizeof length);
        unsigned char invalid = 0xff;
        check(write(writer, &invalid, 1) == 1);
        check([socket readStringWithMaxLength:16] == nil);
        check(read(writer, &byte, 1) == 0);
        close(writer);

        socket = fixture(&writer);
        NSData *value = [@"fixture 🧪" dataUsingEncoding:NSUTF8StringEncoding];
        length = (int)value.length;
        check(write(writer, &length, sizeof length) == sizeof length);
        check(write(writer, value.bytes, value.length) == value.length);
        check([[socket readStringWithMaxLength:64] isEqualToString:@"fixture 🧪"]);
        close(writer);

        socket = fixture(&writer);
        length = 0;
        check(write(writer, &length, sizeof length) == sizeof length);
        check([[socket readStringWithMaxLength:0] isEqualToString:@""]);
        [socket disconnect];
        check([socket readDataWithMaxLength:16] == nil); // negative read result safely ends
        close(writer);
        socket = fixture(&writer);
        SimpleSocket *reader = [[SimpleSocket alloc] initSocket:writer];
        dispatch_semaphore_t complete = dispatch_semaphore_create(0);
        NSData *patch = [@"signed-fixture" dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            check([reader readInt] == 11);
            check([[reader readStringWithMaxLength:16384] isEqualToString:@"{}"]);
            check([[reader readDataWithMaxLength:64] isEqualToData:patch]);
            dispatch_semaphore_signal(complete);
        });
        check([socket writePreparedCommand:11 metadata:@"{}" data:patch timeout:.5]);
        check(dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        [socket disconnect]; [reader disconnect];

        socket = fixture(&writer);
        int smallBuffer = 4096;
        setsockopt(writer, SOL_SOCKET, SO_RCVBUF, &smallBuffer, sizeof smallBuffer);
        NSData *large = [NSMutableData dataWithLength:4 * 1024 * 1024];
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        check(![socket writePreparedCommand:11 metadata:@"{}" data:large timeout:.05]);
        check(NSProcessInfo.processInfo.systemUptime - started < 1.0);
        close(writer);
        puts("Bounded socket framing and backpressure checks passed");
    }
}
