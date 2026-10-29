//
//  SimpleSocket.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/SimpleSocket.mm#63 $
//
//  Server and client primitives for networking through sockets
//  more esailly written in Objective-C than Swift. Subclass to
//  implement service or client that runs on a background thread
//  implemented by overriding the "runInBackground" method.
//

#if DEBUG || !SWIFT_PACKAGE
#import "SimpleSocket.h"

#include <sys/socket.h>
#include <poll.h>
#include <time.h>
#include <math.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <sys/stat.h>

#if 0
#define SLog NSLog
#else
#define SLog while(0) NSLog
#endif

#define MAX_PACKET 16384
#define EOS ~0

NSString *INJECTION_KEY = @__FILE__;

typedef union {
    struct {
        __uint8_t       sa_len;         /* total length */
        sa_family_t     sa_family;      /* [XSI] address family */
    };
    struct sockaddr_storage any;
    struct sockaddr_in ip4;
    struct sockaddr addr;
} sockaddr_union;

@implementation SimpleSocket

#if !SWIFT_PACKAGE
+ (void)initialize { // Pre-built bundles (+InjectionNext.app)
    INJECTION_KEY = [NSBundle bundleForClass:self]
        .infoDictionary[@"UserHome"] ?: [NSBundle mainBundle]
        .infoDictionary[@"InjectionUserHome"] ?: NSHomeDirectory();
}
#endif

+ (int)error:(NSString *)message {
    NSLog([@"%@/" stringByAppendingString:message],
          self, strerror(errno));
    return -1;
}

+ (void)forEachInterface:(void (^)(ifaddrs *ifa, in_addr_t addr, in_addr_t mask))handler {
    ifaddrs *addrs;
    if (getifaddrs(&addrs) < 0) {
        [self error:@"Could not getifaddrs: %s"];
        return;
    }
    for (ifaddrs *ifa = addrs; ifa; ifa = ifa->ifa_next)
        if (ifa->ifa_addr->sa_family == AF_INET)
            handler(ifa, ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr,
                    ((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
    freeifaddrs(addrs);
}

static NSMutableDictionary<NSString *,NSNumber *> *lastSockets;

+ (NSNumber *)setLastServerSocket:(int)socket {
    if (!lastSockets)
        lastSockets = [NSMutableDictionary new];
    return lastSockets[NSStringFromClass(self)] = @(socket);
}

+ (void)startServer:(NSString *)address {
    sockaddr_union serverAddr;
    [self parseV4Address:address into:&serverAddr.any];

    int serverSocket = [self newSocket:serverAddr.sa_family];
    if (serverSocket < 0)
        return;

    if (bind(serverSocket, &serverAddr.addr, serverAddr.sa_len) < 0)
        [self error:@"Could not bind service socket: %s"];
    else if (listen(serverSocket, 50) < 0)
        [self error:@"Service socket would not listen: %s"];
    else
        [self performSelectorInBackground:@selector(runServer:)
                               withObject:[self setLastServerSocket:serverSocket]];
}

+ (void)runServer:(NSNumber *)socket {
        int serverSocket = socket.intValue;
        while (serverSocket) {
            sockaddr_union clientAddr;
            socklen_t addrLen = sizeof clientAddr;

            int clientSocket = accept(serverSocket, &clientAddr.addr, &addrLen);
            if (clientSocket > 0) {
                int yes = 1;
                if (setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes) < 0)
                    [self error:@"Could not set SO_NOSIGPIPE: %s"];
                @autoreleasepool {
                    struct sockaddr_in *v4Addr = &clientAddr.ip4;
                    printf("%s: Connection from %s:%d\n", object_getClassName(self),
                           inet_ntoa(v4Addr->sin_addr), ntohs(v4Addr->sin_port));
                    SimpleSocket *client = [[self alloc] initSocket:clientSocket];
                    client.isLocalClient =
                        v4Addr->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
                    [self forEachInterface:^(ifaddrs *ifa, in_addr_t addr, in_addr_t mask) {
                        if (v4Addr->sin_addr.s_addr == addr)
                            client.isLocalClient = TRUE;
                    }];
                    [client run];
                }
            }
            else if (lastSockets[NSStringFromClass(self)] == socket) {
                NSLog(@"Bad accept %s", strerror(errno));
                [NSThread sleepForTimeInterval:.5];
            }
            else
                break;
        }

    close(serverSocket);
}

+ (void)stopLastServer {
    NSString *className = NSStringFromClass(self);
    if (int lastServerSocket = lastSockets[className].intValue)
        close(lastServerSocket);
    [lastSockets removeObjectForKey:className];
    [NSThread sleepForTimeInterval:.5];
}

+ (instancetype)connectTo:(NSString *)address {
    return [self connectTo:address timeout:3.0];
}

+ (instancetype)connectTo:(NSString *)address timeout:(NSTimeInterval)timeout {
    sockaddr_union serverAddr;
    if (![self parseV4Address:address into:&serverAddr.any]) return nil;
    int socketFD = [self newSocket:serverAddr.sa_family];
    if (socketFD < 0) return nil;
    int flags = fcntl(socketFD, F_GETFL, 0);
    BOOL connected = NO;
    if (flags >= 0 && fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0) {
        int result = connect(socketFD, &serverAddr.addr, serverAddr.sa_len);
        if (result == 0) connected = YES;
        else if (errno == EINPROGRESS) {
            // poll has no FD_SETSIZE stack limit. Bound interrupted waits
            // against a monotonic deadline rather than restarting the timeout.
            struct timespec started; clock_gettime(CLOCK_MONOTONIC, &started);
            double wait = isfinite(timeout) ? MAX(.01, MIN(timeout, 30.0)) : 3.0;
            double deadline = started.tv_sec + started.tv_nsec / 1e9 + wait;
            struct pollfd writable = { socketFD, POLLOUT, 0 };
            int result;
            do {
                struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
                double remaining = deadline - now.tv_sec - now.tv_nsec / 1e9;
                if (remaining <= 0) { result = 0; break; }
                result = poll(&writable, 1, (int)ceil(remaining * 1000));
            } while (result < 0 && errno == EINTR);
            if (result > 0) {
                int error = 0; socklen_t length = sizeof(error);
                connected = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
                if (!connected) errno = error;
            }
        }
    }
    if (!connected || fcntl(socketFD, F_SETFL, flags) < 0) {
        close(socketFD);
        return nil;
    }
    int keepAlive = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, sizeof(keepAlive));
    int idle = 15, interval = 3, probes = 3;
    setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
    setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPCNT, &probes, sizeof(probes));
    return [[self alloc] initSocket:socketFD];
}

- (void)disconnect {
    shutdown(clientSocket, SHUT_RDWR);
}

+ (int)newSocket:(sa_family_t)addressFamily {
    int newSocket, yes = 1;
    if ((newSocket = socket(addressFamily, SOCK_STREAM, 0)) < 0)
        [self error:@"Could not open service socket: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) < 0)
        [self error:@"Could not set SO_REUSEADDR: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes) < 0)
        [self error:@"Could not set SO_NOSIGPIPE: %s"];
    else if (setsockopt(newSocket, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes) < 0)
        [self error:@"Could not set TCP_NODELAY: %s"];
    else if (fcntl(newSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set FD_CLOEXEC: %s"];
    else
        return newSocket;
    return -1;
}

/**
 * Available formats
 * @"<host>[:<port>]"
 * where <host> can be NNN.NNN.NNN.NNN or hostname, empty for localhost or * for all interfaces
 * The default port is 80 or a specific number to bind or an empty string to allocate any port
 */
+ (BOOL)parseV4Address:(NSString *)address into:(struct sockaddr_storage *)serverAddr {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@":"];

    struct sockaddr_in *v4Addr = (struct sockaddr_in *)serverAddr;
    bzero(v4Addr, sizeof *v4Addr);

    v4Addr->sin_family = AF_INET;
    v4Addr->sin_len = sizeof *v4Addr;
    v4Addr->sin_port = htons(parts.count > 1 ? parts[1].intValue : 80);

    const char *host = parts[0].UTF8String;

    if (!host[0])
        v4Addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (host[0] == '*')
        v4Addr->sin_addr.s_addr = htonl(INADDR_ANY);
    else if (isdigit(host[0]))
        v4Addr->sin_addr.s_addr = inet_addr(host);
    else if (struct hostent *hp = gethostbyname2(host, v4Addr->sin_family))
        memcpy(&v4Addr->sin_addr, hp->h_addr, hp->h_length);
    else {
        [self error:[NSString stringWithFormat:@"Unable to look up host for %@", address]];
        return FALSE;
    }

    return TRUE;
}

- (instancetype)initSocket:(int)socket {
    if ((self = [super init])) {
        clientSocket = socket;
        int noSignal = 1;
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    }
    return self;
}

- (FILE *_Nullable)fdopenForMode:(const char * _Nonnull)mode {
    return fdopen(clientSocket, mode);
}

- (void)run {
    [self performSelectorInBackground:@selector(runInBackground) withObject:nil];
}

- (void)runInBackground {
    [[self class] error:@"-[SimpleSocket runInBackground] not implemented in subclass"];
}

typedef ssize_t (*io_func)(int, void *, size_t);

- (BOOL)perform:(io_func)io ofBytes:(const void *)buffer
         length:(size_t)length cmd:(SEL)cmd {
    size_t ptr = 0;
    while (ptr < length) {
        ssize_t bytes = io(clientSocket, (char *)buffer + ptr, MIN(length - ptr, MAX_PACKET));
        if (bytes > 0) ptr += (size_t)bytes;
        else if (bytes < 0 && errno == EINTR) continue;
        else return FALSE;
    }
    return TRUE;
}

- (BOOL)readBytes:(void *)buffer length:(size_t)length cmd:(SEL)cmd {
    return [self perform:read ofBytes:buffer length:length cmd:cmd];
}

- (int)readInt {
    int32_t anint = EOS;
    if (![self readBytes:&anint length:sizeof anint cmd:_cmd])
        return EOS;
    SLog(@"#%d <- %d", clientSocket, anint);
    return anint;
}

- (void *)readPointer {
    void *aptr = (void *)EOS;
    if (![self readBytes:&aptr length:sizeof aptr cmd:_cmd])
        return aptr;
    SLog(@"#%d <- %p", clientSocket, aptr);
    return aptr;
}

- (NSData *)readData {
    return [self readDataWithMaxLength:INT32_MAX];
}

- (NSData *)readDataWithMaxLength:(size_t)maxLength {
    int length = [self readInt];
    // Validate the signed wire length before allocation. A malformed frame
    // invalidates the stream; reconnect starts from a clean framing boundary.
    if (length < 0 || (size_t)length > maxLength) {
        [self disconnect];
        return nil;
    }
    void *bytes = malloc(length ? (size_t)length : 1);
    if (!bytes || ![self readBytes:bytes length:(size_t)length cmd:_cmd]) {
        free(bytes);
        [self disconnect];
        return nil;
    }
    return [NSData dataWithBytesNoCopy:bytes length:(size_t)length freeWhenDone:YES];
}

- (NSString *)readString {
    return [self readStringWithMaxLength:INT32_MAX];
}

- (NSString *)readStringWithMaxLength:(size_t)maxLength {
    NSData *data = [self readDataWithMaxLength:maxLength];
    if (!data) return nil;
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!string) [self disconnect];
    return string;
}

static double monotonicSeconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

- (BOOL)writePreparedCommand:(int)command metadata:(NSString *)metadata data:(NSData *)data timeout:(NSTimeInterval)timeout {
    NSData *encoded = [metadata dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded || encoded.length > 16 * 1024 || data.length > 256 * 1024 * 1024) return NO;
    int32_t commandValue = command, metadataLength = (int32_t)encoded.length, dataLength = (int32_t)data.length;
    NSArray<NSData *> *frames = @[[NSData dataWithBytes:&commandValue length:sizeof commandValue],
        [NSData dataWithBytes:&metadataLength length:sizeof metadataLength], encoded,
        [NSData dataWithBytes:&dataLength length:sizeof dataLength], data];
    double deadline = monotonicSeconds() + (isfinite(timeout) ? MAX(.01, MIN(timeout, 30.0)) : 3.0);
    struct timeval previousTimeout = {};
    socklen_t previousLength = sizeof(previousTimeout);
    if (getsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &previousTimeout, &previousLength) < 0) {
        [self disconnect]; return NO;
    }
    @try {
        for (NSData *frame in frames) {
            size_t offset = 0;
            while (offset < frame.length) {
                double remaining = deadline - monotonicSeconds();
                if (remaining <= 0) { [self disconnect]; return NO; }
                // Darwin AF_UNIX can block send despite MSG_DONTWAIT. A scoped
                // socket timeout bounds the syscall without changing the
                // concurrently blocked reader's O_NONBLOCK mode.
                struct timeval budget = { (time_t)remaining, (suseconds_t)ceil((remaining - floor(remaining)) * 1e6) };
                if (budget.tv_usec >= 1000000) { budget.tv_sec++; budget.tv_usec -= 1000000; }
                if (setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &budget, sizeof budget) < 0) {
                    [self disconnect]; return NO;
                }
                ssize_t count = send(clientSocket, (const char *)frame.bytes + offset,
                                     MIN(frame.length - offset, MAX_PACKET), 0);
                if (count > 0) { offset += (size_t)count; continue; }
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    remaining = deadline - monotonicSeconds();
                    if (remaining > 0) {
                        struct pollfd writable = { clientSocket, POLLOUT, 0 };
                        int result = poll(&writable, 1, (int)ceil(remaining * 1000));
                        if (result > 0 || (result < 0 && errno == EINTR)) continue;
                    }
                }
                [self disconnect];
                return NO;
            }
        }
        return YES;
    } @finally {
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &previousTimeout, sizeof previousTimeout);
    }
}

- (BOOL)writeBytes:(const void *)buffer length:(size_t)length cmd:(SEL)cmd {
    return [self perform:(io_func)write ofBytes:buffer length:length cmd:cmd];
}

- (BOOL)writeInt:(int)length {
    SLog(@"#%d %d ->", clientSocket, length);
    return [self writeBytes:&length length:sizeof length cmd:_cmd];
}

- (BOOL)writeCStr:(const char *)string {
    uint32_t len = (uint32_t)strlen(string);
    SLog(@"#%d %d '%s' ->", clientSocket, (int)len, string);
    return [self writeInt:len] && [self writeBytes:string length:len cmd:_cmd];
}

- (BOOL)writePointer:(void *)ptr {
    SLog(@"#%d %p ->", clientSocket, ptr);
    return [self writeBytes:&ptr length:sizeof ptr cmd:_cmd];
}

- (BOOL)writeData:(NSData *)data {
    uint32_t length = (uint32_t)data.length;
    SLog(@"#%d [%d] ->", clientSocket, length);
    return [self writeInt:length] &&
        [self writeBytes:data.bytes length:length cmd:_cmd];
}

- (BOOL)writeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    SLog(@"#%d %d '%@' ->", clientSocket, (int)data.length, string);
    return [self writeData:data];
}

- (BOOL)writeCommand:(int)command withString:(NSString *)string {
    return [self writeInt:command] &&
        (!string || [self writeString:string]);
}

- (BOOL)failed:(SEL)sel file:(id)file {
    NSLog(@"-[%@ %s \"%@\"]: Could not fopen(), %s",
          self, sel_getName(sel), file, strerror(errno));
    return FALSE;
}

- (BOOL)sendFile:(NSString *)path {
    struct stat st;
    FILE *input = fopen(path.UTF8String, "r");
    if (!input || fstat(fileno(input), &st))
        return [self writeInt:INT_MAX] &&
            [self writeString:[NSString stringWithFormat:
             @"-[%@ %s \"%@\"]: Could not open to send, %s",
             self, sel_getName(_cmd), path, strerror(errno)]] &&
            [self failed:_cmd file:path];
    [self writeInt:(int)st.st_size];
    off_t pos = 0, chunk;
    char buffer[MAX_PACKET];
    while ((chunk = MIN(st.st_size-pos, sizeof buffer)) > 0 &&
           (chunk = fread(buffer, 1, chunk, input)) > 0 &&
           [self writeBytes:buffer length:chunk cmd:_cmd])
        pos += chunk;
    fclose(input);
    return pos == st.st_size;
}

- (BOOL)recvFile:(NSString *)path {
    FILE *output = fopen(path.UTF8String, "w");
    if (!output) return [self failed:_cmd file:path];
    off_t sz = [self readInt], pos = 0, chunk;
    if (sz == INT_MAX)
        return [self failed:_cmd file:[self readString]];
    char buffer[MAX_PACKET];
    while ((chunk = MIN(sz-pos, sizeof buffer)) > 0 &&
           [self readBytes:buffer length:chunk cmd:_cmd] &&
           (chunk = fwrite(buffer, 1, chunk, output)) > 0)
        pos += chunk;
    fclose(output);
    return pos == sz;
}

- (void)dealloc {
    close(clientSocket);
}

/// Hash used to differentiate InjectionNext users broadcasting.
/// Hash derived from path to user's home directory determined
/// from path to this source file in project's DerivedData or for
/// pre-built bundles, home directory taken from a value patched
/// into the bundle's Info.plist as it is copied into client app.
+ (int)multicastHash {
    #if SWIFT_PACKAGE
    NSString *file = @__FILE__;
    INJECTION_KEY = [file
       stringByReplacingOccurrencesOfString: @"(/Users/[^/]+).*"
           withString: @"$1" options: NSRegularExpressionSearch
               range: NSMakeRange(0, file.length)];
    #endif
    const char *key = INJECTION_KEY.UTF8String;
    int hash = 0;
    for (size_t i=0, len = strlen(key); i<len; i++)
        hash = hash*5 ^ (i+3)%15*key[i];
    return hash;
}

struct multicast_socket_packet {
    int version, hash;
    char host[256];
};

/// Used for HotReloading clients to find their controlling Mac.
/// @param multicast MULTICAST address to use
/// @param port Port identifier of form ":NNNN"
+ (void)multicastServe:(const char *)multicast port:(const char *)port {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return;
    #endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); /* N.B.: differs from sender */
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = htons(atoi(port));

    /* create what looks like an ordinary UDP socket */
    int multicastSocket, yes = 1;
    if ((multicastSocket = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
        [self error:@"Could not get mutlicast socket: %s"];
    else if (fcntl(multicastSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set close exec: %s"];
    else if (setsockopt(multicastSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) < 0)
        [self error:@"Could not reuse mutlicast socket addr: %s"];
    else if (bind(multicastSocket, (struct sockaddr *)&addr, sizeof addr) < 0)
        [self error:@"Could not bind mutlicast socket addr: %s. "
         "Once this starts occuring, a reboot may be necessary. "
         "Or, you can hardcode the IP address of your Mac as the "
         "the value for 'hostname' in HotReloading/Package.swift."];
    else
        [self performSelectorInBackground:@selector(multicastListen:)
                               withObject:[NSNumber numberWithInt:multicastSocket]];
}

/// Listens for clients looking to connect and if the hash matches, replies.
/// @param socket Multicast socket as NSNumber
+ (void)multicastListen:(NSNumber *)socket {
    int multicastSocket = [socket intValue];
    while (multicastSocket) {
        struct sockaddr_in addr;
        socklen_t addrlen = sizeof addr;
        struct multicast_socket_packet msgbuf;

        if (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                     (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
            [self error:@"Could not receive from multicast: %s"];
            sleep(1);
            continue;
        }

        NSLog(@"%@: Multicast recvfrom %s (%s) %u c.f. %u\n",
              self, msgbuf.host, inet_ntoa(addr.sin_addr),
              [self multicastHash], msgbuf.hash);

        gethostname(msgbuf.host, sizeof msgbuf.host);
        if ([self multicastHash] == msgbuf.hash &&
            sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, addrlen) < sizeof msgbuf) {
            [self error:@"Could not send to multicast: %s"];
            sleep(1);
        }
    }
}

/// Client end of multicast means of determining address of server
/// @param multicast Multicast IP address to use.
/// @param port Port number as string.
/// @param format Format for connecting message.
+ (NSString *)getMulticastService:(const char *)multicast
    port:(const char *)port message:(const char *)format {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return @DEVELOPER_HOST;
    #else
    #define DEVELOPER_HOST "127.0.0.1"
    #endif

    static struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = 0;

    // For a real device, we have to use multicast
    // to locate the developer's Mac to connect to.
    int multicastSocket, yes = 1;
    if ((multicastSocket = socket(addr.sin_family, SOCK_DGRAM, 0)) < 0) {
        [self error:@"Could not get broadcast socket: %s"];
        return @DEVELOPER_HOST;
    }
    if (setsockopt(multicastSocket, SOL_SOCKET, SO_BROADCAST, &yes, sizeof yes) < 0) {
        [self error:@"Could not setsockopt: %s"];
        close(multicastSocket);
        return @DEVELOPER_HOST;
    }

    struct multicast_socket_packet msgbuf;
    msgbuf.version = 1;
    msgbuf.hash = [self multicastHash];
    gethostname(msgbuf.host, sizeof msgbuf.host);

    addr.sin_port = htons(atoi(port));
    [self forEachInterface:^(ifaddrs *ifa, in_addr_t laddr, in_addr_t nmask) {
        switch (ntohl(laddr) >> 24) {
            case 10: // mobile network
//            case 172: // hotspot
            case 127: // loopback
                return;
        }
        int idx = if_nametoindex(ifa->ifa_name);
        setsockopt(multicastSocket, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx);
        addr.sin_addr.s_addr = laddr | ~nmask;
        printf("Broadcasting to %s#%d:%s to locate Injection host...\n",
               ifa->ifa_name, idx, inet_ntoa(addr.sin_addr));
        if (sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, sizeof addr) < 0)
            [self error:@"Could not send broadcast ping: %s"];
        if (sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, sizeof addr) < 0)
            [self error:@"Could not send broadcast ping: %s"];
    }];

    socklen_t addrlen = sizeof addr;
    while (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                    (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
        [self error:@"%s: Error receiving from broadcast: %s"];
        sleep(1);
    }

    const char *ipaddr = inet_ntoa(addr.sin_addr);
    printf(format, msgbuf.host, ipaddr);
    close(multicastSocket);
    return [NSString stringWithUTF8String:ipaddr];
}

@end

@implementation SimpleService

static NSMutableDictionary<NSString *,SimpleCallback> *callbacks;

+ (void)startServer:(NSString *_Nonnull)address callback:(SimpleCallback)callback {
    if (!callbacks)
        callbacks = [NSMutableDictionary new];
    callbacks[address] = callback;
    [super startServer:address];
}

- (void)runInBackground {
    sockaddr_union addr;
    socklen_t len = sizeof addr;
    if (getsockname(clientSocket, &addr.addr, &len) < 0)
        [[self class] error:@"getsockname failed %s"];

    NSString *address = [NSString stringWithFormat:@"*:%d", ntohs(addr.ip4.sin_port)];
    if (SimpleCallback callback = callbacks[address])
        callback(clientSocket);
    else
        [[self class] error:@"Missing callback"];
}
@end

@implementation SimpleHTTP
+ (void)startServer:(NSString *_Nonnull)address callback:(NSData *_Nullable (^_Nonnull)(char *_Nonnull header))callback {
    [super startServer:address callback:^(int socket) {
        FILE *stream = fdopen(socket, "r+");
        size_t bsize = 1000, length;
        char *header = (char *)malloc(bsize), *hptr = header;

        while ((length = strlen(fgets(hptr, (int)(bsize - (hptr-header)),
                    stream)?:"")) > 2 || (length && strcmp(hptr-2, "\r\n\r\n")))
            if ((hptr += length)-header == bsize-1) {
                char *newbuff = (char *)realloc(header, bsize *= 2);
                hptr = newbuff + (hptr - header);
                header = newbuff;
            }

        NSData *body = callback(header) ?: [NSData new];

        fprintf(stream, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n"
                "Content-Length: %ld\r\n\r\n", body.length);
        fwrite(body.bytes, body.length, 1, stream);
        fclose(stream);
        free(header);
    }];
}
@end
#endif
