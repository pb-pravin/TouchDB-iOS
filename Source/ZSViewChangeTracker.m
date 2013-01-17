//
// Created by zsiegel
//



#import "ZSViewChangeTracker.h"

@implementation ZSViewChangeTracker {
    NSMutableData *_data;
    NSURLConnection *_connection;
}

- (BOOL)start {

    [super start];

    LogTo(ChangeTracker, @"%@: Starting...", self);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.changesFeedURL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    _data = [NSMutableData new];
    _connection = [[NSURLConnection alloc] initWithRequest:request
                                                  delegate:self
                                          startImmediately:YES];

    return YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {

    if (error) {
        Warn(@"%@: Error - %@", self, error);
        self.error = error;
    }

}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_data appendData:data];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [_data setLength:0];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {

    LogTo(ChangeTracker, @"%@: Received complete response from %@", self, self.changesFeedURL);
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:_data
                                                        options:NSJSONReadingMutableLeaves
                                                          error:&error];

    if (error) {
        self.error = error;
        Warn(@"%@: JSON Parse Error - %@", self, error);
    }

    [self receivedChanges:[json objectForKey:@"rows"] errorMessage:nil];

}

- (void)stop {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(start)
                                               object:nil];    // cancel pending retries
    [_connection cancel];
    [super stop];
}


@end