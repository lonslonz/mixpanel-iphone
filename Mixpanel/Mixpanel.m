//
// Mixpanel.m
// Mixpanel
//
// Copyright 2012 Mixpanel
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <arpa/inet.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

#import <AdSupport/ASIdentifierManager.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "MPCJSONDataSerializer.h"
#import "Mixpanel.h"
#import "NSData+MPBase64.h"
#import "ODIN.h"

#define VERSION @"1.2.0"

#ifndef IFT_ETHER
#define IFT_ETHER 0x6 // ethernet CSMACD
#endif

#ifdef MIXPANEL_LOG
#define MixpanelLog(...) NSLog(__VA_ARGS__)
#else
#define MixpanelLog(...)
#endif

#ifdef MIXPANEL_DEBUG
#define MixpanelDebug(...) NSLog(__VA_ARGS__)
#else
#define MixpanelDebug(...)
#endif

@interface Mixpanel ()

// re-declare internally as readwrite
@property(nonatomic,retain) MixpanelPeople *people;
@property(nonatomic,copy) NSString *distinctId;

@property(nonatomic,copy)   NSString *apiToken;
@property(nonatomic,retain) NSMutableDictionary *superProperties;
@property(nonatomic,retain) NSTimer *timer;
@property(nonatomic,retain) NSMutableArray *eventsQueue;
@property(nonatomic,retain) NSMutableArray *peopleQueue;
@property(nonatomic,retain) NSArray *eventsBatch;
@property(nonatomic,retain) NSArray *peopleBatch;
@property(nonatomic,retain) NSURLConnection *eventsConnection;
@property(nonatomic,retain) NSURLConnection *peopleConnection;
@property(nonatomic,retain) NSMutableData *eventsResponseData;
@property(nonatomic,retain) NSMutableData *peopleResponseData;
@property(nonatomic,retain) NSOperationQueue *requestQueue;
@property(nonatomic,retain) NSDictionary *survey;

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
@property(nonatomic,assign) UIBackgroundTaskIdentifier taskId;
#endif

@end

@interface MixpanelPeople () <UIAlertViewDelegate>
@property(nonatomic,assign) Mixpanel *mixpanel;
@property(nonatomic,retain) NSMutableArray *unidentifiedQueue;
@property(nonatomic,copy) NSString *distinctId;
- (id)initWithMixpanel:(Mixpanel *)mixpanel;
@end

@protocol MixpanelSurveyQuestionViewControllerDelegate <NSObject>
- (void)mixpanelSurveyQuestionViewController:(UIViewController *)questionViewController didReceiveAnswerProperties:(NSDictionary *)properties;
@end

@interface MixpanelSurveyQuestionViewController : UIViewController <UITextFieldDelegate, UITableViewDelegate, UITableViewDataSource>
@property(nonatomic,assign) id<MixpanelSurveyQuestionViewControllerDelegate> delegate;
@property(nonatomic,retain) NSString *prompt;
@property(nonatomic,retain) NSString *property;
@property(nonatomic,retain) NSArray *choices;
@property(nonatomic,retain) UITableView *tableView;
-(instancetype)initWithPrompt:(NSString *)prompt andChoices:(NSArray *)choices forProperty:(NSString *)property;
@end

@interface MixpanelSurveyNavigationController : UINavigationController <MixpanelSurveyQuestionViewControllerDelegate>
@property(nonatomic,assign) Mixpanel *mixpanel;
@property(nonatomic,retain) NSArray *questionViewControllers;
@property(nonatomic,retain) UILabel *progressLabel;
@property(nonatomic,retain) UIProgressView *progressView;
- (instancetype)initWithMixpanel:(Mixpanel *)mixpanel andQuestionViewControllers:(NSArray *)questionViewControllers;
@end

@implementation Mixpanel

static Mixpanel *sharedInstance = nil;

#pragma mark * Device info

+ (NSDictionary *)deviceInfoProperties
{
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];

    UIDevice *device = [UIDevice currentDevice];

    [properties setValue:@"iphone" forKey:@"mp_lib"];
    [properties setValue:VERSION forKey:@"$lib_version"];

    [properties setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] forKey:@"$app_version"];
    [properties setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] forKey:@"$app_release"];

    [properties setValue:@"Apple" forKey:@"$manufacturer"];
    [properties setValue:[device systemName] forKey:@"$os"];
    [properties setValue:[device systemVersion] forKey:@"$os_version"];
    [properties setValue:[Mixpanel deviceModel] forKey:@"$model"];
    [properties setValue:[Mixpanel deviceModel] forKey:@"mp_device_model"]; // legacy

    CGSize size = [UIScreen mainScreen].bounds.size;
    [properties setValue:[NSNumber numberWithInt:(int)size.height] forKey:@"$screen_height"];
    [properties setValue:[NSNumber numberWithInt:(int)size.width] forKey:@"$screen_width"];

    [properties setValue:[NSNumber numberWithBool:[Mixpanel wifiAvailable]] forKey:@"$wifi"];

    CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
    CTCarrier *carrier = [networkInfo subscriberCellularProvider];
    [networkInfo release];

    if (carrier.carrierName.length) {
        [properties setValue:carrier.carrierName forKey:@"$carrier"];
    }

    if (NSClassFromString(@"ASIdentifierManager")) {
        [properties setValue:ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString forKey:@"$ios_ifa"];
    }

    return [NSDictionary dictionaryWithDictionary:properties];
}

+ (NSString *)deviceModel
{
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    
    char *answer = malloc(size);
    sysctlbyname("hw.machine", answer, &size, NULL, 0);
    
    NSString *results = [NSString stringWithCString:answer encoding:NSUTF8StringEncoding];
    
    free(answer);
    return results;
}

+ (BOOL)wifiAvailable
{
    struct sockaddr_in sockAddr;
    bzero(&sockAddr, sizeof(sockAddr));
    sockAddr.sin_len = sizeof(sockAddr);
    sockAddr.sin_family = AF_INET;

    SCNetworkReachabilityRef nrRef = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&sockAddr);
    SCNetworkReachabilityFlags flags;
    BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(nrRef, &flags);
    if (!didRetrieveFlags) {
        MixpanelDebug(@"%@ unable to fetch the network reachablity flags", self);
    }

    CFRelease(nrRef);

    if (!didRetrieveFlags || (flags & kSCNetworkReachabilityFlagsReachable) != kSCNetworkReachabilityFlagsReachable) {
        // unable to connect to a network (no signal or airplane mode activated)
        return NO;
    }

    if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN) {
        // only a cellular network connection is available.
        return NO;
    }

    return YES;
}

+ (BOOL)inBackground
{
    BOOL inBg = NO;
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    inBg = [[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground;
#endif
    if (inBg) {
        MixpanelDebug(@"%@ in background", self);
    }
    return inBg;
}

#pragma mark * Encoding/decoding utilities

+ (NSData *)JSONSerializeObject:(id)obj
{
    id coercedObj = [Mixpanel JSONSerializableObjectForObject:obj];

    MPCJSONDataSerializer *serializer = [MPCJSONDataSerializer serializer];
    NSError *error = nil;
    NSData *data = nil;
    @try {
        data = [serializer serializeObject:coercedObj error:&error];
    }
    @catch (NSException *exception) {
        NSLog(@"%@ exception encoding api data: %@", self, exception);
    }
    if (error) {
        NSLog(@"%@ error encoding api data: %@", self, error);
    }
    return data;
}

+ (id)JSONSerializableObjectForObject:(id)obj
{
    // valid json types
    if ([obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSNull class]]) {
        return obj;
    }

    // recurse on containers
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id i in obj) {
            [a addObject:[Mixpanel JSONSerializableObjectForObject:i]];
        }
        return [NSArray arrayWithArray:a];
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (id key in obj) {
            NSString *stringKey;
            if (![key isKindOfClass:[NSString class]]) {
                stringKey = [key description];
                NSLog(@"%@ warning: property keys should be strings. got: %@. coercing to: %@", self, [key class], stringKey);
            } else {
                stringKey = [NSString stringWithString:key];
            }
            id v = [Mixpanel JSONSerializableObjectForObject:[obj objectForKey:key]];
            [d setObject:v forKey:stringKey];
        }
        return [NSDictionary dictionaryWithDictionary:d];
    }

    // some common cases
    if ([obj isKindOfClass:[NSDate class]]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss"];
        [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
        NSString *s = [formatter stringFromDate:obj];
        [formatter release];
        return s;
    } else if ([obj isKindOfClass:[NSURL class]]) {
        return [obj absoluteString];
    }

    // default to sending the object's description
    NSString *s = [obj description];
    NSLog(@"%@ warning: property values should be valid json types. got: %@. coercing to: %@", self, [obj class], s);
    return s;
}

+ (NSString *)encodeAPIData:(NSArray *)array
{
    NSString *b64String = @"";
    NSData *data = [Mixpanel JSONSerializeObject:array];
    if (data) {
        b64String = [data mp_base64EncodedString];
        b64String = (id)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                (CFStringRef)b64String,
                                                                NULL,
                                                                CFSTR("!*'();:@&=+$,/?%#[]"),
                                                                kCFStringEncodingUTF8);
    }
    return [b64String autorelease];
}

+ (void)assertPropertyTypes:(NSDictionary *)properties
{
    for (id k in properties) {
        NSAssert([k isKindOfClass: [NSString class]], @"%@ property keys must be NSString. got: %@ %@", self, [k class], k);
        // would be convenient to do: id v = [properties objectForKey:k]; ..but, when the NSAssert's are stripped out in release, it becomes an unused variable error
        NSAssert([[properties objectForKey:k] isKindOfClass:[NSString class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSNumber class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSNull class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSArray class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSDictionary class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSDate class]] ||
                 [[properties objectForKey:k] isKindOfClass:[NSURL class]],
                 @"%@ property values must be NSString, NSNumber, NSNull, NSArray, NSDictionary, NSDate or NSURL. got: %@ %@", self, [[properties objectForKey:k] class], [properties objectForKey:k]);
    }
}

#pragma mark * Initializiation

+ (instancetype)sharedInstanceWithToken:(NSString *)apiToken
{
    @synchronized(self) {
        if (sharedInstance == nil) {
            sharedInstance = [[super alloc] initWithToken:apiToken andFlushInterval:60];
        }
        return sharedInstance;
    }
}

+ (instancetype)sharedInstance
{
    @synchronized(self) {
        if (sharedInstance == nil) {
            NSLog(@"%@ warning sharedInstance called before sharedInstanceWithToken:", self);
        }
        return sharedInstance;
    }
}

- (id)initWithToken:(NSString *)apiToken andFlushInterval:(NSUInteger)flushInterval
{
    if (apiToken == nil) {
        apiToken = @"";
    }
    if ([apiToken length] == 0) {
        NSLog(@"%@ warning empty api token", self);
    }
    if (self = [self init]) {
        self.people = [[[MixpanelPeople alloc] initWithMixpanel:self] autorelease];

        self.apiToken = apiToken;
        self.flushInterval = flushInterval;
        self.flushOnBackground = YES;
        self.showNetworkActivityIndicator = YES;
        self.serverURL = @"https://api.mixpanel.com";
        
        self.distinctId = [self defaultDistinctId];
        self.superProperties = [NSMutableDictionary dictionary];

        self.eventsQueue = [NSMutableArray array];
        self.peopleQueue = [NSMutableArray array];

        self.requestQueue = [[[NSOperationQueue alloc] init] autorelease];
        
        [self addApplicationObservers];
        
        [self unarchive];

    }
    return self;
}

#pragma mark * Identity

- (void)identify:(NSString *)distinctId
{
    @synchronized(self) {
        self.distinctId = distinctId;
        self.people.distinctId = distinctId;
        if (distinctId != nil && distinctId.length != 0 && self.people.unidentifiedQueue.count > 0) {
            for (NSMutableDictionary *r in self.people.unidentifiedQueue) {
                [r setObject:distinctId forKey:@"$distinct_id"];
                [self.peopleQueue addObject:r];
            }
            [self.people.unidentifiedQueue removeAllObjects];
        }
        if ([Mixpanel inBackground]) {
            [self archiveProperties];
            [self archivePeople];
        }
    }
}

#pragma mark * Tracking

- (NSString *)defaultDistinctId
{
    NSString *distinctId = nil;
    if (NSClassFromString(@"ASIdentifierManager")) {
        distinctId = ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString;
    }
    if (!distinctId) {
        distinctId = ODIN1();
    }
    if (!distinctId) {
        NSLog(@"%@ error getting default distinct id: both iOS IFA and ODIN1 failed", self);
    }
    return distinctId;
}

- (void)track:(NSString *)event
{
    [self track:event properties:nil];
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties
{
    @synchronized(self) {
        if (event == nil || [event length] == 0) {
            NSLog(@"%@ mixpanel track called with empty event parameter. using 'mp_event'", self);
            event = @"mp_event";
        }
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        [p addEntriesFromDictionary:[Mixpanel deviceInfoProperties]];
        [p setObject:self.apiToken forKey:@"token"];
        [p setObject:[NSNumber numberWithLong:(long)[[NSDate date] timeIntervalSince1970]] forKey:@"time"];
        if (self.nameTag) {
            [p setObject:self.nameTag forKey:@"mp_name_tag"];
        }
        if (self.distinctId) {
            [p setObject:self.distinctId forKey:@"distinct_id"];
        }
        [p addEntriesFromDictionary:self.superProperties];
        if (properties) {
            [p addEntriesFromDictionary:properties];
        }

        [Mixpanel assertPropertyTypes:properties];

        NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:event, @"event", [NSDictionary dictionaryWithDictionary:p], @"properties", nil];
        MixpanelLog(@"%@ queueing event: %@", self, e);
        [self.eventsQueue addObject:e];
        if ([Mixpanel inBackground]) {
            [self archiveEvents];
        }
    }
}

#pragma mark * Super property methods

- (void)registerSuperProperties:(NSDictionary *)properties
{
    [Mixpanel assertPropertyTypes:properties];
    @synchronized(self) {
        [self.superProperties addEntriesFromDictionary:properties];
        if ([Mixpanel inBackground]) {
            [self archiveProperties];
        }
    }
}

- (void)registerSuperPropertiesOnce:(NSDictionary *)properties
{
    [Mixpanel assertPropertyTypes:properties];
    @synchronized(self) {
        for (NSString *key in properties) {
            if ([self.superProperties objectForKey:key] == nil) {
                [self.superProperties setObject:[properties objectForKey:key] forKey:key];
            }
        }
        if ([Mixpanel inBackground]) {
            [self archiveProperties];
        }
    }
}

- (void)registerSuperPropertiesOnce:(NSDictionary *)properties defaultValue:(id)defaultValue
{
    [Mixpanel assertPropertyTypes:properties];
    @synchronized(self) {
        for (NSString *key in properties) {
            id value = [self.superProperties objectForKey:key];
            if (value == nil || [value isEqual:defaultValue]) {
                [self.superProperties setObject:[properties objectForKey:key] forKey:key];
            }
        }
        if ([Mixpanel inBackground]) {
            [self archiveProperties];
        }
    }
}

- (void)unregisterSuperProperty:(NSString *)propertyName
{
    @synchronized(self) {
        if ([self.superProperties objectForKey:propertyName] != nil) {
            [self.superProperties removeObjectForKey:propertyName];
            if ([Mixpanel inBackground]) {
                [self archiveProperties];
            }
        }
    }
}

- (void)clearSuperProperties
{
    @synchronized(self) {
        [self.superProperties removeAllObjects];
        if ([Mixpanel inBackground]) {
            [self archiveProperties];
        }
    }
}

- (NSDictionary *)currentSuperProperties
{
    @synchronized(self) {
        return [[self.superProperties copy] autorelease];
    }
}

- (void)reset
{
    @synchronized(self) {
        self.distinctId = [self defaultDistinctId];
        self.nameTag = nil;
        self.superProperties = [NSMutableDictionary dictionary];

        self.people.distinctId = nil;
        self.people.unidentifiedQueue = [NSMutableArray array];

        self.eventsQueue = [NSMutableArray array];
        self.peopleQueue = [NSMutableArray array];
        
        [self archive];
    }
}

#pragma mark * Network control

- (void)setFlushInterval:(NSUInteger)interval
{
    @synchronized(self) {
        _flushInterval = interval;
        [self startFlushTimer];
    }
}

- (void)startFlushTimer
{
    @synchronized(self) {
        [self stopFlushTimer];
        if (self.flushInterval > 0) {
            self.timer = [NSTimer scheduledTimerWithTimeInterval:self.flushInterval
                                                          target:self
                                                        selector:@selector(flush)
                                                        userInfo:nil
                                                         repeats:YES];
            MixpanelDebug(@"%@ started flush timer: %@", self, self.timer);
        }
    }
}

- (void)stopFlushTimer
{
    @synchronized(self) {
        if (self.timer) {
            [self.timer invalidate];
            MixpanelDebug(@"%@ stopped flush timer: %@", self, self.timer);
        }
        self.timer = nil;
    }
}

- (void)flush
{
    // If the app is currently in the background but Mixpanel has not requested
    // to run a background task, the flush will be cut short. This can happen
    // when the app forces a flush from within its own background task.
    if ([Mixpanel inBackground] && self.taskId == UIBackgroundTaskInvalid) {
        [self flushInBackgroundTask];
        return;
    }

    @synchronized(self) {
        if ([self.delegate respondsToSelector:@selector(mixpanelWillFlush:)]) {
            if (![self.delegate mixpanelWillFlush:self]) {
                MixpanelDebug(@"%@ delegate deferred flush", self);
                return;
            }
        }
        MixpanelDebug(@"%@ flushing data to %@", self, self.serverURL);
        [self flushEvents];
        [self flushPeople];
    }
}

- (void)flushInBackgroundTask
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    @synchronized(self) {
        if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)] &&
            [[UIApplication sharedApplication] respondsToSelector:@selector(endBackgroundTask:)]) {

            self.taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                MixpanelDebug(@"%@ flush background task %u cut short", self, self.taskId);
                [self cancelFlush];
                [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
                self.taskId = UIBackgroundTaskInvalid;
            }];

            MixpanelDebug(@"%@ starting flush background task %u", self, self.taskId);
            [self flush];

            // connection callbacks end this task by calling endBackgroundTaskIfComplete
        }
    }
#endif
}

- (void)flushEvents
{
    if ([self.eventsQueue count] == 0) {
        MixpanelDebug(@"%@ no events to flush", self);
        return;
    } else if (self.eventsConnection != nil) {
        MixpanelDebug(@"%@ events connection already open", self);
        return;
    } else if ([self.eventsQueue count] > 50) {
        self.eventsBatch = [self.eventsQueue subarrayWithRange:NSMakeRange(0, 50)];
    } else {
        self.eventsBatch = [NSArray arrayWithArray:self.eventsQueue];
    }
    
    NSString *data = [Mixpanel encodeAPIData:self.eventsBatch];
    NSString *postBody = [NSString stringWithFormat:@"ip=1&data=%@", data];
    
    MixpanelDebug(@"%@ flushing %u of %u queued events: %@", self, self.eventsBatch.count, self.eventsQueue.count, self.eventsQueue);

    self.eventsConnection = [self apiConnectionWithEndpoint:@"/track/" andBody:postBody];

    [self updateNetworkActivityIndicator];
}

- (void)flushPeople
{
    if ([self.peopleQueue count] == 0) {
        MixpanelDebug(@"%@ no people to flush", self);
        return;
    } else if (self.peopleConnection != nil) {
        MixpanelDebug(@"%@ people connection already open", self);
        return;
    } else if ([self.peopleQueue count] > 50) {
        self.peopleBatch = [self.peopleQueue subarrayWithRange:NSMakeRange(0, 50)];
    } else {
        self.peopleBatch = [NSArray arrayWithArray:self.peopleQueue];
    }
    
    NSString *data = [Mixpanel encodeAPIData:self.peopleBatch];
    NSString *postBody = [NSString stringWithFormat:@"data=%@", data];
    
    MixpanelDebug(@"%@ flushing %u of %u queued people: %@", self, self.peopleBatch.count, self.peopleQueue.count, self.peopleQueue);

    self.peopleConnection = [self apiConnectionWithEndpoint:@"/engage/" andBody:postBody];

    [self updateNetworkActivityIndicator];
}

- (void)cancelFlush
{
    if (self.eventsConnection == nil) {
        MixpanelDebug(@"%@ no events connection to cancel", self);
    } else {
        MixpanelDebug(@"%@ cancelling events connection", self);
        [self.eventsConnection cancel];
        self.eventsConnection = nil;
    }
    if (self.peopleConnection == nil) {
        MixpanelDebug(@"%@ no people connection to cancel", self);
    } else {
        MixpanelDebug(@"%@ cancelling people connection", self);
        [self.peopleConnection cancel];
        self.peopleConnection = nil;
    }
}

- (void)updateNetworkActivityIndicator
{
    @synchronized(self) {
        BOOL visible = self.showNetworkActivityIndicator && (self.eventsConnection || self.peopleConnection);
        [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:visible];
    }
}

#pragma mark * Persistence

- (NSString *)filePathForData:(NSString *)data
{
    NSString *filename = [NSString stringWithFormat:@"mixpanel-%@-%@.plist", self.apiToken, data];
    return [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject]
            stringByAppendingPathComponent:filename];
}

- (NSString *)eventsFilePath
{
    return [self filePathForData:@"events"];
}

- (NSString *)peopleFilePath
{
    return [self filePathForData:@"people"];
}

- (NSString *)propertiesFilePath
{
    return [self filePathForData:@"properties"];
}

- (void)archive
{
    @synchronized(self) {
        [self archiveEvents];
        [self archivePeople];
        [self archiveProperties];
    }
}

- (void)archiveEvents
{
    @synchronized(self) {
        NSString *filePath = [self eventsFilePath];
        MixpanelDebug(@"%@ archiving events data to %@: %@", self, filePath, self.eventsQueue);
        if (![NSKeyedArchiver archiveRootObject:self.eventsQueue toFile:filePath]) {
            NSLog(@"%@ unable to archive events data", self);
        }
    }
}

- (void)archivePeople
{
    @synchronized(self) {
        NSString *filePath = [self peopleFilePath];
        MixpanelDebug(@"%@ archiving people data to %@: %@", self, filePath, self.peopleQueue);
        if (![NSKeyedArchiver archiveRootObject:self.peopleQueue toFile:filePath]) {
            NSLog(@"%@ unable to archive people data", self);
        }
    }
}

- (void)archiveProperties
{
    @synchronized(self) {
        NSString *filePath = [self propertiesFilePath];
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        [properties setValue:self.distinctId forKey:@"distinctId"];
        [properties setValue:self.nameTag forKey:@"nameTag"];
        [properties setValue:self.superProperties forKey:@"superProperties"];
        [properties setValue:self.people.distinctId forKey:@"peopleDistinctId"];
        [properties setValue:self.people.unidentifiedQueue forKey:@"peopleUnidentifiedQueue"];
        MixpanelDebug(@"%@ archiving properties data to %@: %@", self, filePath, properties);
        if (![NSKeyedArchiver archiveRootObject:properties toFile:filePath]) {
            NSLog(@"%@ unable to archive properties data", self);
        }
    }
}

- (void)unarchive
{
    @synchronized(self) {
        [self unarchiveEvents];
        [self unarchivePeople];
        [self unarchiveProperties];
    }
}

- (void)unarchiveEvents
{
    NSString *filePath = [self eventsFilePath];
    @try {
        self.eventsQueue = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        MixpanelDebug(@"%@ unarchived events data: %@", self, self.eventsQueue);
    }
    @catch (NSException *exception) {
        NSLog(@"%@ unable to unarchive events data, starting fresh", self);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        self.eventsQueue = nil;
    }
    if (!self.eventsQueue) {
        self.eventsQueue = [NSMutableArray array];
    }
}

- (void)unarchivePeople
{
    NSString *filePath = [self peopleFilePath];
    @try {
        self.peopleQueue = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        MixpanelDebug(@"%@ unarchived people data: %@", self, self.peopleQueue);
    }
    @catch (NSException *exception) {
        NSLog(@"%@ unable to unarchive people data, starting fresh", self);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        self.peopleQueue = nil;
    }
    if (!self.peopleQueue) {
        self.peopleQueue = [NSMutableArray array];
    }
}

- (void)unarchiveProperties
{
    NSString *filePath = [self propertiesFilePath];
    NSDictionary *properties = nil;
    @try {
        properties = [NSKeyedUnarchiver unarchiveObjectWithFile:filePath];
        MixpanelDebug(@"%@ unarchived properties data: %@", self, properties);
    }
    @catch (NSException *exception) {
        NSLog(@"%@ unable to unarchive properties data, starting fresh", self);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    }
    if (properties) {
        self.distinctId = [properties objectForKey:@"distinctId"];
        self.nameTag = [properties objectForKey:@"nameTag"];
        self.superProperties = [properties objectForKey:@"superProperties"];
        self.people.distinctId = [properties objectForKey:@"peopleDistinctId"];
        self.people.unidentifiedQueue = [properties objectForKey:@"peopleUnidentifiedQueue"];
    }
}

#pragma mark * Application lifecycle events

- (void)addApplicationObservers
{
    MixpanelDebug(@"%@ adding application observers", self);
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(applicationWillTerminate:)
                               name:UIApplicationWillTerminateNotification
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(applicationWillResignActive:)
                               name:UIApplicationWillResignActiveNotification
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(applicationDidBecomeActive:)
                               name:UIApplicationDidBecomeActiveNotification
                             object:nil];
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)] && &UIBackgroundTaskInvalid) {
        self.taskId = UIBackgroundTaskInvalid;
        if (&UIApplicationDidEnterBackgroundNotification) {
            [notificationCenter addObserver:self
                                   selector:@selector(applicationDidEnterBackground:)
                                       name:UIApplicationDidEnterBackgroundNotification
                                     object:nil];
        }
        if (&UIApplicationWillEnterForegroundNotification) {
            [notificationCenter addObserver:self
                                   selector:@selector(applicationWillEnterForeground:)
                                       name:UIApplicationWillEnterForegroundNotification
                                     object:nil];
        }
    }
#endif
}

- (void)removeApplicationObservers
{
    MixpanelDebug(@"%@ removing application observers", self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application did become active", self);
    @synchronized(self) {
        [self startFlushTimer];
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application will resign active", self);
    @synchronized(self) {
        [self stopFlushTimer];
    }
}

- (void)applicationDidEnterBackground:(NSNotificationCenter *)notification
{
    MixpanelDebug(@"%@ did enter background", self);

    @synchronized(self) {
        if (self.flushOnBackground) {
            [self flushInBackgroundTask];
        }
    }
}

- (void)applicationWillEnterForeground:(NSNotificationCenter *)notification
{
    MixpanelDebug(@"%@ will enter foreground", self);
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    @synchronized(self) {

        if (&UIBackgroundTaskInvalid) {
            if (self.taskId != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
            }
            self.taskId = UIBackgroundTaskInvalid;
        }
        [self cancelFlush];
        [self updateNetworkActivityIndicator];
    }
#endif
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    MixpanelDebug(@"%@ application will terminate", self);
    @synchronized(self) {
        [self archive];
    }
}

- (void)endBackgroundTaskIfComplete
{
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 40000
    // if the os version allows background tasks, the app supports them, and we're in one, end it
    @synchronized(self) {

        if (&UIBackgroundTaskInvalid && [[UIApplication sharedApplication] respondsToSelector:@selector(endBackgroundTask:)] &&
            self.taskId != UIBackgroundTaskInvalid && self.eventsConnection == nil && self.peopleConnection == nil) {
            MixpanelDebug(@"%@ ending flush background task %u", self, self.taskId);
            [[UIApplication sharedApplication] endBackgroundTask:self.taskId];
            self.taskId = UIBackgroundTaskInvalid;
        }
    }
#endif
}

#pragma mark * NSURLConnection callbacks

- (NSURLConnection *)apiConnectionWithEndpoint:(NSString *)endpoint andBody:(NSString *)body
{
    NSURL *url = [NSURL URLWithString:[self.serverURL stringByAppendingString:endpoint]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    MixpanelDebug(@"%@ http request: %@?%@", self, [self.serverURL stringByAppendingString:endpoint], body);
    return [NSURLConnection connectionWithRequest:request delegate:self];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response
{
    MixpanelDebug(@"%@ http status code: %d", self, [response statusCode]);
    if ([response statusCode] != 200) {
        NSLog(@"%@ http error: %@", self, [NSHTTPURLResponse localizedStringForStatusCode:[response statusCode]]);
    } else if (connection == self.eventsConnection) {
        self.eventsResponseData = [NSMutableData data];
    } else if (connection == self.peopleConnection) {
        self.peopleResponseData = [NSMutableData data];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (connection == self.eventsConnection) {
        [self.eventsResponseData appendData:data];
    } else if (connection == self.peopleConnection) {
        [self.peopleResponseData appendData:data];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    @synchronized(self) {
        NSLog(@"%@ network failure: %@", self, error);
        if (connection == self.eventsConnection) {
            self.eventsBatch = nil;
            self.eventsResponseData = nil;
            self.eventsConnection = nil;
            [self archiveEvents];
        } else if (connection == self.peopleConnection) {
            self.peopleBatch = nil;
            self.peopleResponseData = nil;
            self.peopleConnection = nil;
            [self archivePeople];
        }

        [self updateNetworkActivityIndicator];
        
        [self endBackgroundTaskIfComplete];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    @synchronized(self) {
        MixpanelDebug(@"%@ http response finished loading", self);
        if (connection == self.eventsConnection) {
            NSString *response = [[NSString alloc] initWithData:self.eventsResponseData encoding:NSUTF8StringEncoding];
            if ([response intValue] == 0) {
                NSLog(@"%@ track api error: %@", self, response);
            }
            [response release];

            [self.eventsQueue removeObjectsInArray:self.eventsBatch];
            [self archiveEvents];

            self.eventsBatch = nil;
            self.eventsResponseData = nil;
            self.eventsConnection = nil;

        } else if (connection == self.peopleConnection) {
            NSString *response = [[NSString alloc] initWithData:self.peopleResponseData encoding:NSUTF8StringEncoding];
            if ([response intValue] == 0) {
                NSLog(@"%@ engage api error: %@", self, response);
            }
            [response release];

            [self.peopleQueue removeObjectsInArray:self.peopleBatch];
            [self archivePeople];

            self.peopleBatch = nil;
            self.peopleResponseData = nil;
            self.peopleConnection = nil;
        }
        
        [self updateNetworkActivityIndicator];
        
        [self endBackgroundTaskIfComplete];
    }
}

#pragma mark * NSObject

- (NSString *)description
{
    return [NSString stringWithFormat:@"<Mixpanel: %p %@>", self, self.apiToken];
}

- (void)dealloc
{
    [self stopFlushTimer];
    [self removeApplicationObservers];
    
    self.people = nil;
    self.distinctId = nil;
    self.nameTag = nil;
    self.serverURL = nil;
    self.delegate = nil;
    
    self.apiToken = nil;
    self.superProperties = nil;
    self.timer = nil;
    self.eventsQueue = nil;
    self.peopleQueue = nil;
    self.eventsBatch = nil;
    self.peopleBatch = nil;
    self.eventsConnection = nil;
    self.peopleConnection = nil;
    self.eventsResponseData = nil;
    self.peopleResponseData = nil;
    self.requestQueue = nil;
    self.survey = nil;
    
    [super dealloc];
}

@end

#pragma mark * People

@implementation MixpanelPeople

+ (NSDictionary *)deviceInfoProperties
{
    UIDevice *device = [UIDevice currentDevice];
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    [properties setValue:[Mixpanel deviceModel] forKey:@"$ios_device_model"];
    [properties setValue:[device systemVersion] forKey:@"$ios_version"];
    [properties setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] forKey:@"$ios_app_version"];
    [properties setValue:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] forKey:@"$ios_app_release"];
    if (NSClassFromString(@"ASIdentifierManager")) {
        [properties setValue:ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString forKey:@"$ios_ifa"];
    }
    return [NSDictionary dictionaryWithDictionary:properties];
}

- (id)initWithMixpanel:(Mixpanel *)mixpanel
{
    if (self = [self init]) {
        self.mixpanel = mixpanel;
        self.unidentifiedQueue = [NSMutableArray array];
    }
    return self;
}

- (void)addPushDeviceToken:(NSData *)deviceToken
{
    const unsigned char *buffer = (const unsigned char *)[deviceToken bytes];
    if (!buffer) {
        return;
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
    for (NSUInteger i = 0; i < deviceToken.length; i++) {
        [hex appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)buffer[i]]];
    }
    NSArray *tokens = [NSArray arrayWithObject:[NSString stringWithString:hex]];
    NSDictionary *properties = [NSDictionary dictionaryWithObject:tokens forKey:@"$ios_devices"];
    [self addPeopleRecordToQueueWithAction:@"$union" andProperties:properties];
}

- (void)set:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [Mixpanel assertPropertyTypes:properties];
    [self addPeopleRecordToQueueWithAction:@"$set" andProperties:properties];
}

- (void)set:(NSString *)property to:(id)object
{
    NSAssert(property != nil, @"property must not be nil");
    NSAssert(object != nil, @"object must not be nil");
    if (property == nil || object == nil) {
        return;
    }
    [self set:[NSDictionary dictionaryWithObject:object forKey:property]];
}

- (void)setOnce:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [Mixpanel assertPropertyTypes:properties];
    [self addPeopleRecordToQueueWithAction:@"$set_once" andProperties:properties];
}

- (void)increment:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    for (id v in [properties allValues]) {
        NSAssert([v isKindOfClass:[NSNumber class]],
                 @"%@ increment property values should be NSNumber. found: %@", self, v);
    }
    [self addPeopleRecordToQueueWithAction:@"$add" andProperties:properties];
}

- (void)increment:(NSString *)property by:(NSNumber *)amount
{
    NSAssert(property != nil, @"property must not be nil");
    NSAssert(amount != nil, @"amount must not be nil");
    if (property == nil || amount == nil) {
        return;
    }
    [self increment:[NSDictionary dictionaryWithObject:amount forKey:property]];
}

- (void)append:(NSDictionary *)properties
{
    NSAssert(properties != nil, @"properties must not be nil");
    [Mixpanel assertPropertyTypes:properties];
    [self addPeopleRecordToQueueWithAction:@"$append" andProperties:properties];
}

- (void)trackCharge:(NSNumber *)amount
{
    [self trackCharge:amount withProperties:nil];
}

- (void)trackCharge:(NSNumber *)amount withProperties:(NSDictionary *)properties
{
    NSAssert(amount != nil, @"amount must not be nil");
    if (amount != nil) {
        NSMutableDictionary *txn = [NSMutableDictionary dictionaryWithObjectsAndKeys:amount, @"$amount", [NSDate date], @"$time", nil];
        if (properties) {
            [txn addEntriesFromDictionary:properties];
        }
        [self append:[NSDictionary dictionaryWithObject:txn forKey:@"$transactions"]];
    }
}

- (void)clearCharges
{
    [self set:[NSDictionary dictionaryWithObject:[NSArray array] forKey:@"$transactions"]];
}

- (void)deleteUser
{
    [self addPeopleRecordToQueueWithAction:@"$delete" andProperties:[NSDictionary dictionary]];
}

- (void)addPeopleRecordToQueueWithAction:(NSString *)action andProperties:(NSDictionary *)properties
{
    @synchronized(self) {

        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        NSMutableDictionary *p = [NSMutableDictionary dictionary];

        [r setObject:self.mixpanel.apiToken forKey:@"$token"];

        if (![r objectForKey:@"$time"]) {
            // milliseconds unix timestamp
            NSNumber *time = [NSNumber numberWithUnsignedLongLong:(uint64_t)([[NSDate date] timeIntervalSince1970] * 1000)];
            [r setObject:time forKey:@"$time"];
        }

        if ([action isEqualToString:@"$set"] || [action isEqualToString:@"$set_once"]) {
            [p addEntriesFromDictionary:[MixpanelPeople deviceInfoProperties]];
        }

        [p addEntriesFromDictionary:properties];

        [r setObject:[NSDictionary dictionaryWithDictionary:p] forKey:action];

        if (self.distinctId) {
            [r setObject:self.distinctId forKey:@"$distinct_id"];
            MixpanelLog(@"%@ queueing people record: %@", self.mixpanel, r);
            [self.mixpanel.peopleQueue addObject:r];
        } else {
            MixpanelLog(@"%@ queueing unidentified people record: %@", self.mixpanel, r);
            [self.unidentifiedQueue addObject:r];
        }
        if ([Mixpanel inBackground]) {
            [self.mixpanel archivePeople];
        }
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MixpanelPeople: %p %@>", self, self.mixpanel.apiToken];
}

- (void)dealloc
{
    self.mixpanel = nil;
    self.distinctId = nil;
    self.unidentifiedQueue = nil;
    [super dealloc];
}

#pragma mark - Surveys

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    switch (buttonIndex) {
        case 0:
            // no thanks
            break;
        case 1:
            // yes
            [self showSurvey];
            break;
        case 2:
            // maybe later
            break;
        default:
            NSLog(@"%@ error got unknown button index from survey alert: %d", self, buttonIndex);
            break;
    }
}

- (void)checkForSurvey
{
    NSString *URLString = [NSString stringWithFormat:@"http://neil.dev.mixpanel.org/projects/%@/surveys/api", self.mixpanel.apiToken];
    NSURL *URL = [NSURL URLWithString:URLString];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    NSLog(@"%@ surveys request: %@", self, request);
    [NSURLConnection sendAsynchronousRequest:request queue:self.mixpanel.requestQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error)
     {
         if (error != nil) {
             NSLog(@"%@ surveys request error: %@", self, error);
             return;
         }
         NSDictionary *survey = [NSJSONSerialization JSONObjectWithData:data options:nil error:&error];
         if (error != nil) {
             NSLog(@"%@ surveys json error: %@", self, error);
             return;
         }
         if ([survey objectForKey:@"questions"]) {
             self.mixpanel.survey = survey;
             NSLog(@"%@ survey: %@", self, survey);
             [self performSelectorOnMainThread:@selector(requestPermissionToConductSurvey) withObject:self waitUntilDone:NO];
         } else {
             NSLog(@"%@ no survey at this time", self);
         }
     }];
}

- (void)requestPermissionToConductSurvey
{
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Help Us Improve"
                                                        message:@"We're trying to make this app better for you. Would you mind taking a brief survey? It won't take more than a minute. Thanks for your support!"
                                                       delegate:self
                                              cancelButtonTitle:@"No, Thanks"
                                              otherButtonTitles:@"Take Survey", @"Maybe Later", nil];
	[alertView show];
}

- (void)showFakeSurvey
{
    self.mixpanel.survey = @{
                             @"version": @0,
                             @"questions": @[
                                     @{
                                         @"prompt": @"If we discontinued our service, how much would you care?",
                                         @"property": @"Engagement",
                                         @"choices": @[
                                                 @"A lot",
                                                 @"A little",
                                                 @"Not at all",
                                                 @"I'd prefer you didn't exist",
                                                 [NSNull null]
                                                 ]
                                         },
                                     @{
                                         @"prompt": @"How many employees does your company have?",
                                         @"property": @"Company Size",
                                         @"choices": @[
                                                 @1,
                                                 @1.5,
                                                 @100,
                                                 @1000,
                                                 @10000
                                                 ]
                                         },
                                     @{
                                         @"prompt": @"Would you recommend this app to a friend?",
                                         @"property": @"Promoter",
                                         @"choices": @[
                                                 @YES,
                                                 @NO
                                                 ]
                                         },
                                     @{
                                         @"prompt": @"Is this question too long or just long enough to be effective in getting to the exact point we were trying to get across when engaging you in as efficient a manner as possible?",
                                         @"property": @"Promoter",
                                         @"choices": @[
                                                 @YES,
                                                 @NO
                                                 ]
                                         }
                                     ]
                             };
    [self showSurvey];
}

- (void)showSurvey
{
    NSMutableArray *questionViewControllers = [NSMutableArray array];
    for (NSDictionary *question in [self.mixpanel.survey objectForKey:@"questions"]) {
        NSString *prompt = [question objectForKey:@"prompt"];
        NSArray *choices = [question objectForKey:@"choices"];
        NSString *property = [question objectForKey:@"property"];
        MixpanelSurveyQuestionViewController *controller = [[[MixpanelSurveyQuestionViewController alloc] initWithPrompt:prompt andChoices:choices forProperty:property] autorelease];
        [questionViewControllers addObject:controller];
    }
    MixpanelSurveyNavigationController *surveyController = [[MixpanelSurveyNavigationController alloc] initWithMixpanel:self.mixpanel andQuestionViewControllers:questionViewControllers];
    [self.mixpanel.delegate mixpanel:self.mixpanel didReceivePermissionToConductSurvey:surveyController];
    [surveyController release];
}

@end

@implementation MixpanelSurveyQuestionViewController

-(instancetype)initWithPrompt:(NSString *)prompt andChoices:(NSArray *)choices forProperty:(NSString *)property
{
    if (self = [super init]) {
        if (prompt == nil) {
            NSLog(@"%@ error: nil survey question prompt", self);
            return nil;
        }
        if (choices == nil) {
            NSLog(@"%@ error: nil survey question choices", self);
            return nil;
        }
        if (property == nil) {
            NSLog(@"%@ error: nil survey question property", self);
            return nil;
        }
        self.prompt = prompt;
        self.choices = choices;
        self.property = property;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:217/255.0f green:217/255.0f blue:217/255.0f alpha:1.0f];
    CGFloat top = 10.0;
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(10.0, top, self.view.bounds.size.width - 20.0, 50.0)] autorelease];
    label.text = self.prompt;
    label.backgroundColor = [UIColor clearColor];
    label.numberOfLines = 0;
    label.textAlignment = UITextAlignmentCenter;

    label.textColor = [UIColor darkTextColor];
    CGFloat heightToFit = [label.text sizeWithFont:label.font constrainedToSize:CGSizeMake(label.frame.size.width, UINTMAX_MAX) lineBreakMode:label.lineBreakMode].height;
    if (heightToFit > 50.0) {
        label.frame = CGRectMake(label.frame.origin.x, label.frame.origin.y, label.frame.size.width, heightToFit);
    }
    top += label.frame.size.height + 10.0;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:label];
    UITableView *tableView = [[[UITableView alloc] initWithFrame:CGRectMake(0.0, top, self.view.bounds.size.width, self.view.bounds.size.height - top) style:UITableViewStylePlain] autorelease];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.allowsSelection = YES;
    [tableView reloadData];
    self.tableView = tableView;
    [self.view addSubview:tableView];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView flashScrollIndicators];
}

- (NSString *)labelForValue:(id)val
{
    NSString *label;
    if ([val isKindOfClass:[NSString class]]) {
        label = val;
    } else if ([val isKindOfClass:[NSNumber class]]) {
        int i = [val intValue];
        if (CFNumberGetType((CFNumberRef)val) == kCFNumberCharType && (i == 0 || i == 1)) {
            label = i ? @"Yes" : @"No";
        } else {
            NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
            [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
            label = [formatter stringFromNumber:val];
            [formatter release];
        }
    } else if ([val isKindOfClass:[NSNull class]]) {
        label = @"None";
    } else {
        NSLog(@"%@ unexpected value for survey choice: %@", self, val);
        label = [val description];
    }
    return label;
}

#pragma mark - UITableViewControllerDelegate methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.choices count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"MixpanelCellIdentifier";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.textLabel.text = [self labelForValue:[self.choices objectAtIndex:indexPath.row]];
    return cell;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryCheckmark;
    NSDictionary *answer = [NSDictionary dictionaryWithObject:[self.choices objectAtIndex:indexPath.row] forKey:self.property];
    [self.delegate mixpanelSurveyQuestionViewController:self didReceiveAnswerProperties:answer];
}

-(void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;
}

@end

@implementation MixpanelSurveyNavigationController

- (id)initWithMixpanel:(Mixpanel *)mixpanel andQuestionViewControllers:(NSArray *)questionViewControllers
{
    if (self = [super initWithRootViewController:[questionViewControllers objectAtIndex:0]]) {
        self.mixpanel = mixpanel;
        self.questionViewControllers = questionViewControllers;
        [self initQuestionViewControllers];
        [self initNavigationBar];
    }
    return self;
}

- (void)dealloc
{
    self.questionViewControllers = nil;
    self.progressView = nil;
    self.progressLabel = nil;
    [super dealloc];
}

- (void)initQuestionViewControllers
{
    for (MixpanelSurveyQuestionViewController *controller in self.questionViewControllers) {

        controller.delegate = self;

        if (controller == [self.questionViewControllers objectAtIndex:0]) {
            controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(dismiss)];
        }
        if (self.questionViewControllers.count > 1) {
            controller.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Skip" style:UIBarButtonItemStylePlain target:self action:@selector(next)];
        }
    }
}

- (void)initNavigationBar
{
    self.progressLabel = [[[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 150.0, 18.0)] autorelease];
    self.progressLabel.textColor = [UIColor whiteColor];
    self.progressLabel.font = [UIFont boldSystemFontOfSize:13.0];
    self.progressLabel.shadowColor = [UIColor darkGrayColor];
    self.progressLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    self.progressLabel.backgroundColor = [UIColor clearColor];
    self.progressLabel.textAlignment = UITextAlignmentCenter;

    self.progressView = [[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar] autorelease];

    [self.navigationBar addSubview:self.progressLabel];
    [self.navigationBar addSubview:self.progressView];

    [self positionProgressLabelAndView:self.interfaceOrientation];

    [self updateProgress];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self positionProgressLabelAndView:toInterfaceOrientation];
}

- (void)positionProgressLabelAndView:(UIInterfaceOrientation)interfaceOrientation
{
    CGFloat centerX = self.navigationBar.center.x;
    if (interfaceOrientation == UIInterfaceOrientationPortrait || interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown) {
        self.progressLabel.center = CGPointMake(centerX, 14.0);
        self.progressView.center = CGPointMake(centerX, 28.0);
    } else {
        self.progressLabel.center = CGPointMake(centerX, 9.0);
        self.progressView.center = CGPointMake(centerX, 23.0);
    }
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated
{
    UIViewController *controller = [super popViewControllerAnimated:animated];
    [self updateProgress];
    return controller;
}

- (void)dismiss
{
    if (self.mixpanel.delegate && [self.mixpanel.delegate respondsToSelector:@selector(mixpanelDidDismissSurvey:)]) {
        [self.mixpanel.delegate mixpanelDidDismissSurvey:self.mixpanel];
    }
}

- (void)next
{
    if (self.viewControllers.count == self.questionViewControllers.count) {
        // if we're on the last step, we're done, so dismiss the survey
        [self dismiss];
    } else {
        UIViewController *next = [self.questionViewControllers objectAtIndex:self.viewControllers.count];
        [self pushViewController:next animated:YES];
        [self updateProgress];
    }
}

- (void)updateProgress
{
    self.progressLabel.text = [NSString stringWithFormat:@"%d of %d", self.viewControllers.count, self.questionViewControllers.count];
    self.progressView.progress = ((float)self.viewControllers.count) / self.questionViewControllers.count;
}

- (void)mixpanelSurveyQuestionViewController:(UIViewController *)questionViewController didReceiveAnswerProperties:(NSDictionary *)properties
{
    [self.mixpanel.people set:properties];
    [self next];
}

@end
