//
// Created by zsiegel
//



#import <Foundation/Foundation.h>
#import "TDReplication.h"

@interface ZSReplication : TDReplication

- (id) initWithDatabase: (TDDatabase*)database
                 remote: (NSURL*)remote
               viewName: (NSString *)view;
@end