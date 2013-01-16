//
// Created by zsiegel
//



#import <Foundation/Foundation.h>


@interface TDViewTracker : NSObject

@property (nonatomic, assign) BOOL deleteDocs;
@property (nonatomic, strong) TDView *localView;


- (id)init;
- (id)initWithRemoteView:(NSString *)view;

@end