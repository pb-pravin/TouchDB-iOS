//
// Created by zsiegel
//



#import <TouchDB/TouchDB.h>
#import "ZSViewTracker.h"
#import "TDSocketChangeTracker.h"
#import "TDMisc.h"
#import "TDStatus.h"
#import "ZSViewChangeTracker.h"

#define kInitialRetryDelay 2.0      // Initial retry delay (doubles after every subsequent failure)
#define kMaxRetryDelay 300.0        // ...but will never get longer than this

@implementation ZSViewTracker {

}

@synthesize deleteDocs = _deleteDocs;
@synthesize localView = _localView;
@synthesize remoteView = _remoteView;

- (id)initWithDatabaseURL:(NSURL *)databaseURL client: (id<TDChangeTrackerClient>)client {
    self = [super init];
    if (self) {

        if([self class] == [ZSViewTracker class]) {
            // ZSViewTracker is abstract; instantiate a concrete subclass instead.
            return [[ZSViewChangeTracker alloc] initWithDatabaseURL: databaseURL
                                                               client: client];
        }

        _databaseURL = databaseURL;
        _client = client;
    }

    return self;
}

- (NSString*) changesFeedPath {
    return self.remoteView;
}

- (NSURL*) changesFeedURL {
    NSMutableString* urlStr = [_databaseURL.absoluteString mutableCopy];
    if (![urlStr hasSuffix: @"/"])
        [urlStr appendString: @"/"];
    [urlStr appendString: self.changesFeedPath];
    return [NSURL URLWithString: urlStr];
}

- (void) dealloc {
    [self stop];
}

- (void) setUpstreamError: (NSString*)message {
    Warn(@"%@: Server error: %@", self, message);
    self.error = [NSError errorWithDomain: @"TDChangeTracker" code: kTDStatusUpstreamError userInfo: nil];
}

- (BOOL) start {
    self.error = nil;
    return NO;
}

- (void) stop {
    [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(retry)
                                               object: nil];    // cancel pending retries
    [self stopped];
}

- (void)retry {

}

@end