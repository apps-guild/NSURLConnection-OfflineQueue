//
//  NSURLConnection+OfflineQueue.h
//
//  Copyright (c) 2013 @natbro and AppsGuild.
//

#import <Foundation/Foundation.h>

@interface NSURLConnection (OfflineQueue)

+ (BOOL)queueAsynchronousRequest:(NSString *)urlString;

@end