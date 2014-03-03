NSURLConnection+OfflineQueue
============================

A simple category on NSURLConnection with a persistent/offline queue of pure POST work.

I've written several iOS systems for managing async downloading of assets, async hitting of web-services for data &  analytics, and other bandwidth-throttling mechanisms so when it came time to handle scoring and analytics for [TILE](http://thetilegame.com) I decided to rewrite several old systems to use proper GCD queues and to handle WiFi vs WAN/cellular and set myself up for a common simple system. At this point this one is written to handle sending URL-only data to an analytics server in a single domain using a throttled connection, geared to sustain/reuse a single HTTP/1.1 connection but to limit bandwidth to no more than `RATE_PER_MINUTE_WIFI` calls/minute on a WiFi connection and no more than `RATE_PER_MINUTE_WWAN` calls/minue on WAN/cellular.

Examples of Use
===============

    #include "NSURLConnection+OfflineQueue.h"
    ...
    NSString *analyticsHit = [NSString stringWithFormat:@"http://example.com/api/v1/applicationLaunched/%@", myApplicationIdentifier];
    [NSURLConnection queueAsynchronousRequest:[analyticsHit URLEncodeString]];
    
This queues up the URL into a FIFO+persistent queue (stored in a local SQLite database via `FMDatabase`) and attempts to make the request (within throttling limits) when the network is available.

If you are looking to make more complicated POST requests with more accompanying data, very simple changes are possible:

  * alter the database schema to hold additional data during [`+load`](https://github.com/apps-guild/NSURLConnection-OfflineQueue/blob/master/NSURLConnection+OfflineQueue.m#L39)
  * adjust [`+doQueueWork`](https://github.com/apps-guild/NSURLConnection-OfflineQueue/blob/master/NSURLConnection+OfflineQueue.m#L122) to read the data and submit it

If you are looking to make GET requests which asynchronously populate a local file-system cache or asynchronously notify data availability, very simple changes can accomodate this:

  * alter the database schema to recognize GET vs. POST in [`+load`](https://github.com/apps-guild/NSURLConnection-OfflineQueue/blob/master/NSURLConnection+OfflineQueue.m#L39)
  * adjust [`+doQueueWork`](https://github.com/apps-guild/NSURLConnection-OfflineQueue/blob/master/NSURLConnection+OfflineQueue.m#L167) to use a different form of request for GET vs. POST


External Requirements
=====================
 * Requires [FXReachability](https://github.com/nicklockwood/FXReachability)
 * Requires [FMDatabase](https://github.com/ccgus/fmdb), but pretty easy to adjust to using your own work-queue/database. (It uses deletes to mark work complete, but you could mark rows complete instead if you prefer)
 * Will use [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) if it being used by the project, defaults to `NSLog`
