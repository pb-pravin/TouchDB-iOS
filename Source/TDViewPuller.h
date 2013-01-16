//
// Created by zsiegel
//



#import <Foundation/Foundation.h>
#import <TouchDB/TouchDB.h>
#import "TDReplicator.h"
#import "TDChangeTracker.h"

@class TDViewTracker;
@class TDBatcher;

@interface TDViewPuller : TDReplicator <TDChangeTrackerClient>
{
    TDViewTracker *_changeTracker;
    NSMutableArray *_revsToPull;
    NSUInteger _httpConnectionCount;
    TDBatcher *_downloadsToInsert;
}


@end