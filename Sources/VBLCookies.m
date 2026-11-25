//
//  VBLCookies.m
//

#import "VBLCookies.h"
#import "VBLJobStore.h"
#import <WebKit/WebKit.h>
#import <Security/Security.h>

static NSString * const VBLKeychainService = @"VolBrainLink volBrain login";
static NSString * const VBLKeychainAccount = @"volbrain.net";

static BOOL VBLIsVolBrainCookie(NSHTTPCookie *cookie)
{
    NSString *domain = [[cookie domain] lowercaseString];
    return [domain isEqualToString:@"volbrain.net"] || [domain hasSuffix:@".volbrain.net"];
}

static NSDictionary *VBLKeychainQuery(void)
{
    return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: VBLKeychainService,
              (__bridge id)kSecAttrAccount: VBLKeychainAccount };
}

@implementation VBLCookies

static BOOL restored;
static NSMutableArray *waiting;

+ (void)restoreThen:(void (^)(void))completion
{
    NSAssert([NSThread isMainThread], @"main thread");
    if (restored) { if (completion) completion(); return; }
    if (waiting) { if (completion) [waiting addObject:[completion copy]]; return; }
    waiting = [NSMutableArray array];
    if (completion) [waiting addObject:[completion copy]];

    NSMutableDictionary *query = [VBLKeychainQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = status == errSecSuccess ? (__bridge_transfer NSData *)result : nil;
    NSArray *saved = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;

    void (^finish)(void) = ^{
        restored = YES;
        NSArray *blocks = waiting;
        waiting = nil;
        for (void (^block)(void) in blocks) block();
    };
    if (![saved isKindOfClass:[NSArray class]] || [saved count] == 0) {
        if (status != errSecItemNotFound && status != errSecSuccess) VBLLog(@"Saved volBrain login not readable (Keychain status %d)", (int)status);
        finish();
        return;
    }

    WKHTTPCookieStore *store = [WKWebsiteDataStore defaultDataStore].httpCookieStore;
    dispatch_group_t group = dispatch_group_create();
    NSUInteger count = 0;
    NSDate *now = [NSDate date];
    for (NSDictionary *properties in saved) {
        if (![properties isKindOfClass:[NSDictionary class]]) continue;
        NSDate *expires = properties[NSHTTPCookieExpires];
        if ([expires isKindOfClass:[NSDate class]] && [expires compare:now] == NSOrderedAscending) continue;   // expired
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        if (!cookie || !VBLIsVolBrainCookie(cookie)) continue;
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
        count++;
    }
    VBLLog(@"Restored %lu volBrain cookie(s) from the Keychain", (unsigned long)count);
    dispatch_group_notify(group, dispatch_get_main_queue(), finish);
}

+ (void)save
{
    if (!restored) return;   // never overwrite the saved login before it has been put back
    [[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray *keep = [NSMutableArray array];
        NSDate *later = [NSDate dateWithTimeIntervalSinceNow:30 * 24 * 3600];
        for (NSHTTPCookie *cookie in cookies) {
            if (!VBLIsVolBrainCookie(cookie)) continue;
            NSMutableDictionary *properties = [[cookie properties] mutableCopy];
            // Session cookies (no expiry) would be dropped when the viewer quits: give them one.
            // volBrain still decides on its side how long the session is valid.
            if (!properties[NSHTTPCookieExpires] || [cookie isSessionOnly]) {
                properties[NSHTTPCookieExpires] = later;
                [properties removeObjectForKey:NSHTTPCookieDiscard];
            }
            // Keep only values a property list can hold.
            NSMutableDictionary *clean = [NSMutableDictionary dictionary];
            [properties enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if ([key isKindOfClass:[NSString class]] &&
                    ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSDate class]] || [value isKindOfClass:[NSNumber class]]))
                    clean[key] = value;
            }];
            [keep addObject:clean];
        }
        NSData *data = [keep count] ? [NSPropertyListSerialization dataWithPropertyList:keep format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL] : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!data) { SecItemDelete((__bridge CFDictionaryRef)VBLKeychainQuery()); return; }
            OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)VBLKeychainQuery(),
                                            (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
            if (status == errSecItemNotFound) {
                NSMutableDictionary *item = [VBLKeychainQuery() mutableCopy];
                item[(__bridge id)kSecValueData] = data;
                item[(__bridge id)kSecAttrLabel] = VBLKeychainService;
                item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
                status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
            }
            if (status != errSecSuccess) VBLLog(@"Could not save the volBrain login in the Keychain (status %d)", (int)status);
        });
    }];
}

+ (void)forget
{
    SecItemDelete((__bridge CFDictionaryRef)VBLKeychainQuery());
}

@end
