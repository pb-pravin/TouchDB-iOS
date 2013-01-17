//
// Created by zsiegel
//



#import <Foundation/Foundation.h>
#import "TDChangeTracker.h"
#import "TDView.h"

@interface ZSViewTracker : TDChangeTracker

@property (nonatomic, assign) BOOL deleteDocs;
@property (nonatomic, strong) TDView *localView;
@property (strong, nonatomic) NSDictionary *requestHeaders;
@property (weak, nonatomic) id<TDChangeTrackerClient> client;
@property (strong, nonatomic) NSError* error;

@property (readonly) NSString* changesFeedPath;
@property (readonly) NSURL* changesFeedURL;

- (id)initWithDatabaseURL:(NSURL *)databaseURL client: (id<TDChangeTrackerClient>)client;

@end