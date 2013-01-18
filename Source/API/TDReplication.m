//
//  TDReplication.m
//  TouchDB
//
//  Created by Jens Alfke on 6/22/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <TouchDB/TouchDB.h>
#import "TDReplication.h"
#import "TouchDBPrivate.h"

#import "TDPusher.h"
#import "TD_Database+Replication.h"
#import "TD_DatabaseManager.h"
#import "TD_Server.h"
#import "TDBrowserIDAuthorizer.h"
#import "MYBlockUtils.h"


#undef RUN_IN_BACKGROUND


NSString* const kTDReplicationChangeNotification = @"TDReplicationChange";


@interface TDReplication ()
@property (copy) id source, target;  // document properties

@property (nonatomic, readwrite) bool running;
@property (nonatomic, readwrite) TDReplicationMode mode;
@property (nonatomic, readwrite) unsigned completed, total;
@property (nonatomic, readwrite, retain) NSError* error;
@end


@implementation TDReplication
{
    NSURL* _remoteURL;
    bool _pull;
    bool _started;
    bool _running;
    unsigned _completed, _total;
    TDReplicationMode _mode;
    NSError* _error;

    NSString* _bg_documentID;           // ONLY used on the server thread
}

// Instantiate a new replication; it is not persistent yet
- (id) initWithDatabase: (TDDatabase*)database
                 remote: (NSURL*)remote
                   pull: (BOOL)pull
{
    NSParameterAssert(database);
    NSParameterAssert(remote);
    TDDatabase* replicatorDB = [database.manager databaseNamed: @"_replicator"];
    self = [super initWithNewDocumentInDatabase: replicatorDB];
    if (self) {
        _remoteURL = remote;
        _pull = pull;
        self.autosaves = NO;
        self.source = pull ? remote.absoluteString : database.name;
        self.target = pull ? database.name : remote.absoluteString;
        // Give the caller a chance to customize parameters like .filter before calling -start,
        // but make sure -start will be run even if the caller doesn't call it.
        [self performSelector: @selector(start) withObject: nil afterDelay: 0.0];
    }
    return self;
}


// Instantiate a persistent replication from an existing document in the _replicator db
- (id) initWithDocument:(TDDocument *)document {
    self = [super initWithDocument: document];
    if (self) {
        if (!self.isNew) {
            // This is a persistent replication being loaded from the database:
            self.autosaves = YES;  // turn on autosave for all persistent replications
            NSString* urlStr = self.sourceURLStr;
            if (isLocalDBName(urlStr))
                urlStr = self.targetURLStr;
            else
                _pull = YES;
            Assert(urlStr);
            _remoteURL = [[NSURL alloc] initWithString: urlStr];
            Assert(_remoteURL);
            
            [self observeReplicatorManager];
        }
    }
    return self;
}


- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


// These are the JSON properties in the replication document:
@dynamic source, target, create_target, continuous, filter, query_params, doc_ids;

@synthesize remoteURL=_remoteURL, pull=_pull;


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@ %@]",
                self.class, (self.pull ? @"from" : @"to"), self.remoteURL];
}


static inline BOOL isLocalDBName(NSString* url) {
    return [url rangeOfString: @":"].length == 0;
}


- (bool) persistent {
    return !self.isNew;  // i.e. if it's been saved to the database, it's persistent
}

- (void) setPersistent:(bool)persistent {
    if (persistent == self.persistent)
        return;
    bool ok;
    NSError* error;
    if (persistent)
        ok = [self save: &error];
    else
        ok = [self deleteDocument: &error];
    if (!ok) {
        Warn(@"Error changing persistence of %@: %@", self, error);
        return;
    }
    self.autosaves = persistent;
    if (persistent)
        [self observeReplicatorManager];
}


- (NSString*) sourceURLStr {
    id source = self.source;
    if ([source isKindOfClass: [NSDictionary class]])
        source = source[@"url"];
    return $castIf(NSString, source);
}


- (NSString*) targetURLStr {
    id target = self.target;
    if ([target isKindOfClass: [NSDictionary class]])
        target = target[@"url"];
    return $castIf(NSString, target);
}


- (TDDatabase*) localDatabase {
    NSString* name = self.sourceURLStr;
    if (!isLocalDBName(name))
        name = self.targetURLStr;
    return [self.database.manager databaseNamed: name];
}


// The 'source' or 'target' dictionary, whichever is remote, if it's a dictionary not a string
- (NSDictionary*) remoteDictionary {
    id source = self.source;
    if ([source isKindOfClass: [NSDictionary class]] 
            && !isLocalDBName(source[@"url"]))
        return source;
    id target = self.target;
    if ([target isKindOfClass: [NSDictionary class]] 
            && !isLocalDBName(target[@"url"]))
        return target;
    return nil;
}


- (void) setRemoteDictionaryValue: (id)value forKey: (NSString*)key {
    BOOL isPull = self.pull;
    id oldRemote = isPull ? self.source : self.target;
    NSMutableDictionary* remote;
    if ([oldRemote isKindOfClass: [NSString class]])
        remote = [NSMutableDictionary dictionaryWithObject: oldRemote forKey: @"url"];
    else
        remote = [NSMutableDictionary dictionaryWithDictionary: oldRemote];
    [remote setValue: value forKey: key];
    if (!$equal(remote, oldRemote)) {
        if (isPull)
            self.source = remote;
        else
            self.target = remote;
        [self restart];
    }
}


- (NSDictionary*) headers {
    return (self.remoteDictionary)[@"headers"];
}

- (void) setHeaders: (NSDictionary*)headers {
    [self setRemoteDictionaryValue: headers forKey: @"headers"];
}

- (NSDictionary*) OAuth {
    NSDictionary* auth = $castIf(NSDictionary, (self.remoteDictionary)[@"auth"]);
    return auth[@"oauth"];
}

- (void) setOAuth: (NSDictionary*)oauth {
    NSDictionary* auth = oauth ? @{@"oauth": oauth} : nil;
    [self setRemoteDictionaryValue: auth forKey: @"auth"];
}

- (NSURL*) browserIDOrigin {
    return [TDBrowserIDAuthorizer originForSite: self.remoteURL];
}

- (NSString*) browserIDEmailAddress {
    NSDictionary* auth = $castIf(NSDictionary, (self.remoteDictionary)[@"auth"]);
    return auth[@"browserid"][@"email"];
}

- (void) setBrowserIDEmailAddress:(NSString *)email {
    NSDictionary* auth = nil;
    if (email)
        auth = @{@"browserid": @{@"email": email}};
    [self setRemoteDictionaryValue: auth forKey: @"auth"];
}

- (bool) registerBrowserIDAssertion: (NSString*)assertion {
    NSString* email = [TDBrowserIDAuthorizer registerAssertion: assertion];
    if (!email) {
        Warn(@"Invalid BrowserID assertion: %@", assertion);
        return false;
    }
    self.browserIDEmailAddress = email;
    [self restart];
    return true;
}


#pragma mark - START/STOP:


- (void) tellDatabaseManager: (void (^)(TD_DatabaseManager*))block {
#if RUN_IN_BACKGROUND
    [self.database.manager.tdServer tellDatabaseManager: block];
#else
    block(self.database.manager.tdManager);
#endif
}


- (void) observeReplicatorManager {
    _bg_documentID = self.document.documentID;
    _mainThread = [NSThread currentThread];
#if RUN_IN_BACKGROUND
    [self.database.manager.tdServer tellDatabaseNamed: self.localDatabase.name
                                                   to: ^(TD_Database* tddb) {
                                                       _bg_serverDatabase = tddb;
                                                   }];
#else
    _bg_serverDatabase = self.localDatabase.tddb;
#endif
    // Observe *all* replication changes:
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(bg_replicationProgressChanged:)
                                                 name: TDReplicatorProgressChangedNotification
                                               object: nil];
}


- (void) start {
    if (self.persistent) {
        // Removing the _replication_state property triggers the replicator manager to start it.
        [self setValue: nil ofProperty: @"_replication_state"];

    } else if (!_started) {
        // Non-persistent replications I run myself:
        _started = YES;
        _mainThread = [NSThread currentThread];

        [self tellDatabaseManager:^(TD_DatabaseManager* dbmgr) {
            // This runs on the server thread:
            [self bg_startReplicator: dbmgr properties: self.currentProperties];
        }];
    }
}


- (void) stop {
    // This is a no-op for persistent replications
    if (self.persistent)
        return;
    [self tellDatabaseManager:^(TD_DatabaseManager* dbmgr) {
        // This runs on the server thread:
        [_bg_replicator stop];
    }];
}


- (void) restart {
    [self setValue: nil ofProperty: @"_replication_state"];
}


@synthesize running = _running, completed=_completed, total=_total, error = _error, mode=_mode;


- (void) updateMode: (TDReplicationMode)mode
              error: (NSError*)error
          processed: (NSUInteger)changesProcessed
            ofTotal: (NSUInteger)changesTotal
{
    BOOL changed = NO;
    if (mode != _mode) {
        self.mode = mode;
        changed = YES;
    }
    BOOL running = (mode > kTDReplicationStopped);
    if (running != _running) {
        self.running = running;
        changed = YES;
    }
    if (!$equal(error, _error)) {
        self.error = error;
        changed = YES;
    }
    if (changesProcessed != _completed) {
        self.completed = changesProcessed;
        changed = YES;
    }
    if (changesTotal != _total) {
        self.total = changesTotal;
        changed = YES;
    }
    if (changed) {
        LogTo(TDReplication, @"%@: mode=%d, completed=%u, total=%u (changed=%d)",
              self, mode, (unsigned)changesProcessed, (unsigned)changesTotal, changed);
        [[NSNotificationCenter defaultCenter]
                        postNotificationName: kTDReplicationChangeNotification object: self];
    }
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


// CAREFUL: This is called on the server's background thread!
- (void) bg_replicationProgressChanged: (NSNotification*)n
{
    TDReplicator* tdReplicator = n.object;
    if (_bg_replicator) {
        AssertEq(tdReplicator, _bg_replicator);
    } else {
        // Persistent replications get this notification for every TDReplicator,
        // so weed out non-matching ones:
        if (!$equal(tdReplicator.documentID, _bg_documentID))
            return;
    }
    [self bg_updateProgress: tdReplicator];
}


// CAREFUL: This is called on the server's background thread!
- (void) bg_updateProgress: (TDReplicator*)tdReplicator {
    TDReplicationMode mode;
    if (!tdReplicator.running)
        mode = kTDReplicationStopped;
    else if (!tdReplicator.online)
        mode = kTDReplicationOffline;
    else
        mode = tdReplicator.active ? kTDReplicationActive : kTDReplicationIdle;
    
    // Communicate its state back to the main thread:
    MYOnThread(_mainThread, ^{
        [self updateMode: mode
                   error: tdReplicator.error
               processed: tdReplicator.changesProcessed
                 ofTotal: tdReplicator.changesTotal];
    });
    
    if (_bg_replicator && mode == kTDReplicationStopped) {
        [[NSNotificationCenter defaultCenter] removeObserver: self name: nil object: _bg_replicator];
        _bg_replicator = nil;
    }
}


@end
