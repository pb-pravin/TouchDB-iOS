//
// Created by zsiegel
//



#import <Foundation/Foundation.h>
#import <TouchDB/TouchDB.h>
#import "TDReplicator.h"
#import "TDChangeTracker.h"

@class ZSViewTracker;
@class TDBatcher;
@class ZSViewChangeTracker;

@interface ZSViewPuller : TDReplicator
{
    ZSViewTracker *_changeTracker;
    NSMutableArray *_revsToPull;
    NSMutableArray* _bulkRevsToPull;
    NSMutableArray *_revsToDelete;
    NSUInteger _httpConnectionCount;
    TDBatcher *_downloadsToInsert;
}


@end