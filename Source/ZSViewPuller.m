//
// Created by zsiegel
//



#import "ZSViewPuller.h"
#import "TD_Database+Insertion.h"
#import "TDBatcher.h"
#import "TDMultipartDownloader.h"
#import "TDInternal.h"
#import "ZSViewChangeTracker.h"
#import "TDMisc.h"
#import "ExceptionUtils.h"
#import "TD_Database+LocalDocs.h"

@interface ZSViewPuller () <TDChangeTrackerClient>
@end

// Maximum number of revisions to fetch simultaneously. (CFNetwork will only send about 5
// simultaneous requests, but by keeping a larger number in its queue we ensure that it doesn't
// run out, even if the TD thread doesn't always have time to run.)
#define kMaxOpenHTTPConnections 12

@implementation ZSViewPuller {

}


- (void)beginReplicating {

    if (!_downloadsToInsert) {
        // Note: This is a ref cycle, because the block has a (retained) reference to 'self',
        // and _downloadsToInsert retains the block, and of course I retain _downloadsToInsert.
        _downloadsToInsert = [[TDBatcher alloc] initWithCapacity:200 delay:1.0
                                                       processor:^(NSArray *downloads) {
                                                           [self insertDownloads:downloads];
                                                       }];
    }

    [self asyncTaskStarted];   // task: waiting to catch up
    [self startChangeTracker];
}

- (void)startChangeTracker {
    Assert(!_changeTracker);

    LogTo(SyncVerbose, @"%@: Starting tracker", self);
    _changeTracker = [[ZSViewTracker alloc] initWithDatabaseURL:self.remote client:self];
    _changeTracker.remoteView = self.viewName;

    NSMutableDictionary *headers = $mdict({@"User-Agent", [TDRemoteRequest userAgentHeader]});
    [headers addEntriesFromDictionary:_requestHeaders];
    _changeTracker.requestHeaders = headers;

    [_changeTracker start];

}

- (void)stop {

    if (!_running)
        return;

    if (_changeTracker) {
        _changeTracker.client = nil;  // stop it from calling my -changeTrackerStopped
    }

    _changeTracker = nil;
    _revsToPull = nil;

    [super stop];
    [self deleteOldDocuments];
    [_downloadsToInsert flushAll];
}

- (void)retry {

    [super retry];
    [_changeTracker stop];
    [self beginReplicating];
}

- (void)stopped {

    _downloadsToInsert = nil;
    if (_revsToPull.count == 0) {
        [self deleteOldDocuments];
    }
    [super stopped];
}


- (BOOL)goOnline {
    if ([super goOnline])
        return YES;
    // If we were already online (i.e. server is reachable) but got a reachability-change event,
    // tell the tracker to retry in case it's in retry mode after a transient failure. (I.e. the
    // state of the network might be better now.)
    if (_running && _online)
        [_changeTracker retry];
    return NO;
}


- (BOOL)goOffline {
    if (![super goOffline])
        return NO;
    [_changeTracker stop];
    return YES;
}

- (void)changeTrackerReceivedChange:(NSDictionary *)change {

    NSString *docID = change[@"id"];
    if (!docID || ![TD_Database isValidDocumentID:docID])
        return;

    TD_Revision *rev = [[TD_Revision alloc] initWithDocID:change[@"id"] revID:change[@"value"][@"rev"] deleted:NO];
    [self addToInbox:rev];
    self.changesTotal += 1;

}

- (void)changeTrackerReceivedChanges:(NSArray *)changes {

    NSArray *remoteDocIDs = [changes valueForKey:@"id"];
    NSArray *localDocs = [_db getAllDocs:nil];
    NSArray *localDocIDs = [localDocs valueForKey:@"docID"];
    _revsToDelete = [NSMutableArray arrayWithArray:localDocIDs];
    [_revsToDelete removeObjectsInArray:remoteDocIDs];

    if (remoteDocIDs.count > 0) {

        //Check the changes list to find only the documents that need to be updated
        NSMutableArray *changedDocuments = [NSMutableArray new];
        for (NSDictionary *change in changes) {
            TD_RevisionList *revs = [_db getAllRevisionsOfDocumentID:change[@"id"] onlyCurrent:YES];
            if (revs.count != 1) {
                [changedDocuments addObject:change];
            } else if (revs.count == 1) {
                TD_Revision *rev = [revs objectAtIndexedSubscript:0];
                if (![rev.revID isEqualToString:change[@"value"][@"rev"]]) {
                    [changedDocuments addObject:change];
                }
            }
        }

        changes = [NSArray arrayWithArray:changedDocuments];

    }

    //If there are no changes, make sure we delete any old documents right away
    if (changes.count == 0) {

        LogTo(Sync, @"%@: No new items to sync", self);

        [self deleteOldDocuments];
        [super stopped];

    } else {
        for (NSDictionary *change in changes) {
            [self changeTrackerReceivedChange:change];
        }
    }

    [self asyncTasksFinished:1];
}

- (void)deleteOldDocuments {
    for (NSString *docID in _revsToDelete) {
        TD_RevisionList *list = [_db getAllRevisionsOfDocumentID:docID onlyCurrent:YES];
        for (TD_Revision *rev in list) {
            TD_Revision *revToDelete = [[TD_Revision alloc] initWithDocID:rev.docID revID:nil deleted:YES];

            TDStatus status = 0;
            TD_Revision *deletedRev = [_db putRevision:revToDelete prevRevisionID:rev.revID allowConflict:NO status:&status];

            if (TDStatusIsError(status)) {
                Warn(@"%@: Cant delete rev %@", self, rev);
            } else {
                LogTo(Sync, @"%@: Doc deleted %@", self, deletedRev);
            }

        }
    }
    _revsToDelete = nil;
}

- (void)changeTrackerStopped:(TDChangeTracker *)tracker {
    LogTo(Sync, @"%@: Sync stopped", self);
}

- (void)processInbox:(TD_RevisionList *)inbox {

    for (TD_Revision *rev in inbox.allRevisions) {
        [self queueRemoteRevision:rev];
    }

    [self pullRemoteRevisions];

}

// Start up some HTTP GETs, within our limit on the maximum simultaneous number
- (void)pullRemoteRevisions {
    while (_db && _httpConnectionCount < kMaxOpenHTTPConnections) {

        NSMutableArray *queue = _revsToPull;
        if (queue.count == 0) {
            break;  // both queues are empty
        }
        [self pullRemoteRevision:queue[0]];
        [queue removeObjectAtIndex:0];

    }
}

// Add a revision to the appropriate queue of revs to individually GET
- (void)queueRemoteRevision:(TD_Revision *)rev {

    if (!_revsToPull)
        _revsToPull = [[NSMutableArray alloc] initWithCapacity:100];

    [_revsToPull addObject:rev];

}

// Fetches the contents of a revision from the remote db, including its parent revision ID.
// The contents are stored into rev.properties.
- (void)pullRemoteRevision:(TD_Revision *)rev {
    [self asyncTaskStarted];
    ++_httpConnectionCount;

    // Construct a query. We want the revision history, and the bodies of attachments that have
    // been added since the latest revisions we have locally.
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#GET
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#Getting_Attachments_With_a_Document
    NSString *path = $sprintf(@"/%@?rev=%@&revs=true&attachments=true",
            TDEscapeID(rev.docID), TDEscapeID(rev.revID));

    LogTo(SyncVerbose, @"%@: GET .%@", self, path);
    NSString *urlStr = [_remote.absoluteString stringByAppendingString:path];

    // Under ARC, using variable dl directly in the block given as an argument to initWithURL:...
    // results in compiler error (could be undefined variable)
    __weak ZSViewPuller *weakSelf = self;
    __block TDMultipartDownloader *dl = nil;
    dl = [[TDMultipartDownloader alloc] initWithURL:[NSURL URLWithString:urlStr]
                                           database:_db
                                     requestHeaders:self.requestHeaders
                                       onCompletion:
                                               ^(TDMultipartDownloader *download, NSError *error) {
                                                   __strong ZSViewPuller *strongSelf = weakSelf;
                                                   // OK, now we've got the response revision:
                                                   if (error) {
                                                       strongSelf.error = error;
                                                       [strongSelf revisionFailed];
                                                       strongSelf.changesProcessed++;
                                                   } else {
                                                       TD_Revision *gotRev = [TD_Revision revisionWithProperties:download.document];
                                                       gotRev.sequence = rev.sequence;
                                                       // Add to batcher ... eventually it will be fed to -insertRevisions:.
                                                       [_downloadsToInsert queueObject:gotRev];
                                                       [strongSelf asyncTaskStarted];
                                                   }

                                                   // Note that we've finished this task:
                                                   [strongSelf removeRemoteRequest:dl];
                                                   [strongSelf asyncTasksFinished:1];
                                                   --_httpConnectionCount;
                                                   // Start another task if there are still revisions waiting to be pulled:
                                                   [strongSelf pullRemoteRevisions];
                                               }
    ];
    [self addRemoteRequest:dl];
    dl.authorizer = _authorizer;
    [dl start];
}

// This will be called when _downloadsToInsert fills up:
- (void)insertDownloads:(NSArray *)downloads {
    LogTo(SyncVerbose, @"%@ inserting %u revisions...", self, (unsigned) downloads.count);
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();

    [_db beginTransaction];
    BOOL success = NO;
    @try {
        downloads = [downloads sortedArrayUsingSelector:@selector(compareSequences:)];
        for (TD_Revision *rev in downloads) {
            @autoreleasepool {

                NSArray *history = [TD_Database parseCouchDBRevisionHistory:rev.properties];
                if (!history && rev.generation > 1) {
                    Warn(@"%@: Missing revision history in response for %@", self, rev);
                    self.error = TDStatusToNSError(kTDStatusUpstreamError, nil);
                    [self revisionFailed];
                    continue;
                }
                //LogTo(SyncVerbose, @"%@ inserting %@ %@", self, rev.docID, [history my_compactDescription]);

                // Insert the revision:
                int status = [_db forceInsert:rev revisionHistory:history source:_remote];
                if (TDStatusIsError(status)) {
                    if (status == kTDStatusForbidden)
                        LogTo(Sync, @"%@: Remote rev failed validation: %@", self, rev);
                    else {
                        Warn(@"%@ failed to write %@: status=%d", self, rev, status);
                        [self revisionFailed];
                        self.error = TDStatusToNSError(status, nil);
                        continue;
                    }
                }

            }
        }

        LogTo(SyncVerbose, @"%@ finished inserting %u revisions", self, (unsigned) downloads.count);

        success = YES;
    } @catch (NSException *x) {
        MYReportException(x, @"%@: Exception inserting revisions", self);
    } @finally {
        [_db endTransaction:success];
    }

    time = CFAbsoluteTimeGetCurrent() - time;
    LogTo(Sync, @"%@ inserted %u revs in %.3f sec (%.1f/sec)",
            self, (unsigned) downloads.count, time, downloads.count / time);

    [self asyncTasksFinished:downloads.count];
    self.changesProcessed += downloads.count;
}

@end