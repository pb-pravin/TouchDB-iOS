//
// Created by zsiegel
//



#import "ZSReplication.h"
#import "TouchDBPrivate.h"
#import "TDReplicator.h"
#import "MYBlockUtils.h"
#import "TouchDBPrivate.h"
#import "TD_DatabaseManager.h"

@implementation ZSReplication {
    NSString *_view;
}


- (id) initWithDatabase: (TDDatabase*)database
                 remote: (NSURL*)remote
               viewName: (NSString *)view
{

    self = [super initWithDatabase:database remote:remote pull:YES];
    if (self) {
        _view = view;
    }
    return self;

}



#pragma mark - BACKGROUND OPERATIONS:

// CAREFUL: This is called on the server's background thread!
- (void) bg_startReplicator: (TD_DatabaseManager*)server_dbmgr
                 properties: (NSDictionary*)properties
{
    // The setup should use properties, not ivars, because the ivars may change on the main thread.
    TDStatus status;
    TDReplicator* repl = [server_dbmgr replicatorWithProperties: properties status: &status];
    if (!repl) {
        MYOnThread(_mainThread, ^{
            [self updateMode: kTDReplicationStopped
                       error: TDStatusToNSError(status, nil)
                   processed: 0 ofTotal: 0];
        });
        return;
    }
    _bg_replicator = repl;
    _bg_serverDatabase = repl.db;
    [repl start];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(bg_replicationProgressChanged:)
                                                 name: TDReplicatorProgressChangedNotification
                                               object: _bg_replicator];
    [self bg_updateProgress: _bg_replicator];
}

@end