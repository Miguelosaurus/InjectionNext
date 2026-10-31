//
//  SimpleSocket.h
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/include/SimpleSocket.h#16 $
//

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdio.h>
#import "PreparedProofPointer.h"

@interface SimpleSocket : NSObject {
@protected
    int clientSocket;
}

@property BOOL isLocalClient;

+ (void)startServer:(NSString *_Nonnull)address;
+ (void)runServer:(NSNumber *_Nonnull)socket;
+ (int)error:(NSString *_Nonnull)message;
+ (void)stopLastServer;

+ (instancetype _Nullable)connectTo:(NSString *_Nonnull)address;
+ (instancetype _Nullable)connectTo:(NSString *_Nonnull)address timeout:(NSTimeInterval)timeout;
- (void)disconnect;
+ (BOOL)parseV4Address:(NSString *_Nonnull)address into:(struct sockaddr_storage *_Nonnull)serverAddr;

+ (void)multicastServe:(const char *_Nonnull)multicast port:(const char *_Nonnull)port;
+ (NSString *_Nonnull)getMulticastService:(const char *_Nonnull)multicast
                                     port:(const char *_Nonnull)port
                                  message:(const char *_Nonnull)format;

- (instancetype _Nonnull)initSocket:(int)socket;
- (FILE *_Nullable)fdopenForMode:(const char * _Nonnull)mode;

- (void)run;
- (void)runInBackground;

- (int)readInt;
- (void * _Nullable)readPointer;
- (NSData *_Nullable)readData;
- (NSString *_Nullable)readString;
- (NSData *_Nullable)readDataWithMaxLength:(size_t)maxLength NS_SWIFT_NAME(readData(maxLength:));
- (NSString *_Nullable)readStringWithMaxLength:(size_t)maxLength NS_SWIFT_NAME(readString(maxLength:));
- (BOOL)readBytes:(void * _Nonnull)buffer length:(size_t)length cmd:(SEL _Nonnull)cmd;

- (BOOL)writeInt:(int)length;
- (BOOL)writeCStr:(const char *_Nonnull)string;
- (BOOL)writePointer:(void * _Nullable)pointer;
- (BOOL)writeData:(NSData *_Nonnull)data;
- (BOOL)writeString:(NSString *_Nonnull)string;
- (BOOL)writeCommand:(int)command withString:(NSString *_Nullable)string;
- (BOOL)writePreparedCommand:(int)command metadata:(NSString *_Nonnull)metadata data:(NSData *_Nonnull)data timeout:(NSTimeInterval)timeout NS_SWIFT_NAME(writePrepared(command:metadata:data:timeout:));
- (BOOL)sendFile:(NSString *_Nonnull)path;
- (BOOL)recvFile:(NSString *_Nonnull)path;

@end

@interface SimpleService: SimpleSocket
typedef void (^_Nonnull SimpleCallback)(int socket);
+ (void)startServer:(NSString *_Nonnull)address callback:(SimpleCallback)callback;
@end

@interface SimpleHTTP: SimpleService
+ (void)startServer:(NSString *_Nonnull)address callback:(NSData *_Nullable (^_Nonnull)(char *_Nonnull header))callback;
@end
