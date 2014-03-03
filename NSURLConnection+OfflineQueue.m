//
//  NSURLConnection+OfflineQueue.m
//
//  Copyright (c) 2013-2014 @natbro and AppsGuild.
//

#import "NSURLConnection+OfflineQueue.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"
#import "FXReachability.h"
#include <libkern/OSAtomic.h>

#ifdef DDLogError
static const int ddLogLevel = LOG_LEVEL_OFF; // adjust to your liking
#else
#define DDLogError(frmt, ...)
#define DDLogWarn(frmt, ...)
#define DDLogInfo(frmt, ...)
#define DDLogVerbose(frmt, ...)
#endif

#define RATE_PER_MINUTE_WIFI  20.0
#define RATE_PER_MINUTE_WWAN  6.0
#define RATE_PER_MINUTE_NONE  0.0

@implementation NSURLConnection (OfflineQueue)

// TODO: let the caller specify the databaseQueue, backgroundQueue, urlRequest
static FMDatabaseQueue *__databaseQueue;
static dispatch_queue_t __backgroundQueue;
static CGFloat __volatile __queueTargetRate = RATE_PER_MINUTE_NONE;
static NSTimeInterval __lastSent = 0;
static int64_t volatile __queueBusy = 0;
static NSMutableArray *__work;
static NSMutableURLRequest *__urlRequest;
static NSInteger __failedAttempts = 0;


+ (void)load
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
  NSString *libraryDirectory = [paths objectAtIndex:0];
  NSString *dbPath = [libraryDirectory stringByAppendingPathComponent:@"NSURLConnection+OfflineQueue.sqlite"];
  __backgroundQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
  __work = [NSMutableArray arrayWithCapacity:5];
  __urlRequest = [[NSMutableURLRequest alloc] init];
  [__urlRequest setHTTPMethod:@"POST"];
  [__urlRequest setNetworkServiceType:NSURLNetworkServiceTypeBackground];
  [__urlRequest setHTTPShouldUsePipelining:YES];
  [__urlRequest setHTTPShouldHandleCookies:NO];
  __databaseQueue = [FMDatabaseQueue databaseQueueWithPath:dbPath];
  [__databaseQueue inDatabase:^(FMDatabase *db){
    BOOL succeeded;
    succeeded = [db executeUpdate:@"CREATE TABLE IF NOT EXISTS urls (id INTEGER PRIMARY KEY ASC AUTOINCREMENT, url TEXT, added DATETIME DEFAULT CURRENT_TIMESTAMP, expires DATETIME DEFAULT NULL);"];
    NSAssert(succeeded, @"failed to create NSURLConnection+OfflineQueue storage table");
  }];
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(updateNetworkStatus)
                                               name:FXReachabilityStatusDidChangeNotification
                                             object:nil];
  // this is OK to perform sync here, as it only spawns async things
  [self updateNetworkStatus];
}

+ (BOOL)queueAsynchronousRequest:(NSString *)urlString
{
  BOOL __block success = NO;

  [__databaseQueue inDatabase:^(FMDatabase *db){
    success = [db executeUpdate:@"INSERT INTO urls (url) values (?);", urlString];
    if (!success) {
      DDLogWarn(@"NSURLConnection+OfflineQueue: failed to insert!");
    }
  }];

  if (success) {
    [self startQueue];
  }

  return success;
}


#pragma mark -
#pragma mark FXReachability notification

+ (void)updateNetworkStatus
{
  CGFloat rate = RATE_PER_MINUTE_NONE;
  FXReachabilityStatus status = FXReachability.sharedInstance.status;
  
  if (status == FXReachabilityStatusReachableViaWiFi) {
    rate = RATE_PER_MINUTE_WIFI;
  } else if (status == FXReachabilityStatusReachableViaWWAN) {
    rate = RATE_PER_MINUTE_WWAN;
  }
  
  __queueTargetRate = rate;
  
  DDLogVerbose(@"NSURLConnection+OfflineQueue: rate is %f/m", __queueTargetRate);
  
  if (__queueTargetRate != RATE_PER_MINUTE_NONE) {
    [self startQueue];
  }
}


#pragma mark -
#pragma mark Background Work Queue

+ (void)startQueue
{
  // limit a single doWork block at a time, doWork deals with the status
  // of the network and rate limiting at the time it is running and
  // continues, halt, or delays accordingly
  if (OSAtomicCompareAndSwap64(0, 1, &__queueBusy)) {
    dispatch_async(__backgroundQueue, ^{ [self doQueueWork]; });
  }
}

+ (void)doQueueWork
{
  NSAssert(dispatch_get_current_queue() == __backgroundQueue, @"NSURLConnection+OfflineQueue: somehow on the wrong queue");
  
  if (__queueTargetRate == RATE_PER_MINUTE_NONE) {
    NSAssert(__queueBusy == 1, @"NSURLConnection+OfflineQueue: queue gate has been crashed");
    // perform the effective opposite of startQueue, OSAtomicCompareAndSwap64(1, 0, &__queueBusy) but
    // we don't need to compare, we just open the gate for another caller
    __queueBusy = 0;
    //OSAtomicDecrement64(&__queueBusy); // this would be overkill
    return;
  }
  
  NSAssert((__queueTargetRate > 0.0) && (__queueTargetRate < 30), @"NSURLConnection+OfflineQueue: bad queue rate");
  
  // throttle calls to the target rate by delaying this call if it's too soon
  // given the current rate/frequency/period
  NSTimeInterval interval = CFAbsoluteTimeGetCurrent() - __lastSent; // may be negative if clock changes
  NSTimeInterval periodInSeconds = (60.0 / __queueTargetRate);
  if (interval < periodInSeconds) {
    double delayInSeconds = MIN(periodInSeconds - interval, periodInSeconds); // clamp to 0-periodInSeconds
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    // inherits ownership of the __queueBusy gate controlled at startQueue
    dispatch_after(popTime, __backgroundQueue, ^(void){ [self doQueueWork]; });
    return;
  }
  
  // no pre-fetched work in memory? grab some from the database
  if (__work.count == 0) {
    [__databaseQueue inDatabase:^(FMDatabase *db){
      [db executeUpdate:@"DELETE * FROM urls WHERE expires IS NOT NULL AND expires < datetime('now'));"];
      FMResultSet *results = [db executeQuery:@"SELECT id, url FROM urls ORDER BY id ASC limit 10;"];
      while ([results next]) {
        [__work addObject:@[[NSNumber numberWithLong:[results intForColumnIndex:0]], [results stringForColumnIndex:1]]];
      }
    }];
  }
  
  DDLogVerbose(@"NSURLConnection+OfflineQueue: queue length is %d", __work.count);
  
  if (__work.count > 0) {
    NSTimeInterval __block sendTime = CFAbsoluteTimeGetCurrent();
    NSArray *workItem = [__work objectAtIndex:0];
    [__urlRequest setURL:[NSURL URLWithString:workItem[1]]];
    DDLogVerbose(@"NSURLConnection+OfflineQueue: sending (%ld)'%@'", ((NSNumber *)(workItem[0])).longValue, workItem[1]);
    // TODO: below is for POST requests, could do more complicated GET requests here instead depending on the schema
    [NSURLConnection sendAsynchronousRequest:__urlRequest
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error){
                             // TODO: 500 & other errors come through ass success but
                             //  ((NSURLHttpResponse *)response).statusCode shows what happened. in general
                             //  these should probably be retried. in the case of TILE where the backend can
                             //  recover 500's from the log, they can be ignored, but this should be configurable
                             if (error == nil) {
                               [__databaseQueue inDatabase:^(FMDatabase *db){
                                 [db executeUpdate:@"DELETE FROM urls WHERE id=?;", ((NSNumber *)(workItem[0]))];
                               }];
                               [__work removeObjectAtIndex:0];
                               __failedAttempts = 0;
                               __lastSent = sendTime; // use initiation time rather than completion, which would be CFAbsoluteTimeGetCurrent();
                             } else {
                               __failedAttempts++;
                             }
                             // linear back-off any failures in increments of the current period, based on the
                             // initiation, not on the finish of the last call
                             dispatch_time_t popTime = dispatch_time(sendTime, (int64_t)((__failedAttempts + 1) * periodInSeconds * NSEC_PER_SEC));
                             // inherits ownership of the __queueBusy gate controlled at startQueue
                             dispatch_after(popTime, __backgroundQueue, ^(void){ [self doQueueWork]; });
                           }];
  } else {
    NSAssert(__queueBusy == 1, @"NSURLConnection+OfflineQueue: queue gate has been crashed");
    // perform the effective opposite of startQueue, OSAtomicCompareAndSwap64(1, 0, &__queueBusy) but
    // we don't need to compare, we just open the gate for another caller
    __queueBusy = 0;
    //OSAtomicDecrement64(&__queueBusy); // this would be overkill
  }
}

@end
