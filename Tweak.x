#import <Foundation/Foundation.h>

static id modifyDict(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [obj mutableCopy];
        NSArray *keysToBoolTrue = @[@"is_vip", @"isVip", @"isVIP"];
        for (NSString *key in keysToBoolTrue) {
            if (dict[key]) {
                dict[key] = @(YES);
            }
        }
        
        NSArray *keysTo9999 = @[@"remaining_count", @"remaining_compose_count", @"ai_compose_remaining_count", @"remaining_filter_count", @"ai_filter_remaining_count"];
        for (NSString *key in keysTo9999) {
            if (dict[key]) {
                dict[key] = @(9999);
            }
        }

        if (dict[@"vip_type"]) {
            dict[@"vip_type"] = @(1);
        }

        for (NSString *key in dict.allKeys) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                dict[key] = modifyDict(val);
            }
        }
        return dict;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [obj mutableCopy];
        for (NSUInteger i = 0; i < arr.count; i++) {
            id val = arr[i];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                arr[i] = modifyDict(val);
            }
        }
        return arr;
    }
    return obj;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id orig = %orig;
    if (orig) {
        @try {
            return modifyDict(orig);
        } @catch(NSException *e) {}
    }
    return orig;
}

%end

%hook NSUserDefaults

- (NSInteger)integerForKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.debugMembershipMode"]) {
        return 1;
    }
    if ([key containsString:@"freeAIComposeCount"] || 
        [key containsString:@"freeAIFilterCount"] || 
        [key containsString:@"freeUseCount"]) {
        return 0;
    }
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"] ||
        [key localizedCaseInsensitiveContainsString:@"remaining"]) {
        return 9999;
    }
    return %orig;
}

- (id)objectForKey:(NSString *)key {
    if ([key isEqualToString:@"debug.vip.override"]) {
        return @YES;
    }
    if ([key containsString:@"freeAIComposeCount"] || 
        [key containsString:@"freeAIFilterCount"] || 
        [key containsString:@"freeUseCount"]) {
        return @(0);
    }
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"] ||
        [key localizedCaseInsensitiveContainsString:@"remaining"]) {
        return @(9999);
    }
    if ([key localizedCaseInsensitiveContainsString:@"isvip"]) {
        return @YES;
    }
    return %orig;
}

- (BOOL)boolForKey:(NSString *)key {
    if ([key isEqualToString:@"debug.vip.override"]) {
        return YES;
    }
    if ([key localizedCaseInsensitiveContainsString:@"isvip"]) {
        return YES;
    }
    return %orig;
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if ([key containsString:@"freeAIComposeCount"] || 
        [key containsString:@"freeAIFilterCount"] || 
        [key containsString:@"freeUseCount"]) {
        return;
    }
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"] ||
        [key localizedCaseInsensitiveContainsString:@"remaining"]) {
        return; 
    }
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if ([key containsString:@"freeAIComposeCount"] || 
        [key containsString:@"freeAIFilterCount"] || 
        [key containsString:@"freeUseCount"]) {
        return;
    }
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"] ||
        [key localizedCaseInsensitiveContainsString:@"remaining"]) {
        return; 
    }
    %orig;
}

- (BOOL)synchronize {
    return NO;
}

%end

%hook NSDate
- (NSTimeInterval)timeIntervalSince1970 {
    // If it's doing daily limit checks, spoofing time to next day might help, but let's just make it old
    return 1609459200; // 2021-01-01
}
+ (NSDate *)date {
    return [NSDate dateWithTimeIntervalSince1970:1609459200];
}
%end

%hook ZZCheckSubscriptionStatusModel
- (BOOL)is_vip { return YES; }
- (BOOL)isVip { return YES; }
- (NSInteger)vip_type { return 1; }
- (NSInteger)vipType { return 1; }
%end

%hook FWStoreKitManager
- (BOOL)isVIP { return YES; }
%end

%hook VipManager
- (BOOL)validatedEntitlementIsVip { return YES; }
- (NSInteger)freeAIComposeCount { return 0; }
- (NSInteger)freeAIFilterCount { return 0; }
- (NSInteger)freeUseCount { return 0; }
%end

%hook _TtC6Follow10VipManager
- (BOOL)validatedEntitlementIsVip { return YES; }
- (NSInteger)freeAIComposeCount { return 0; }
- (NSInteger)freeAIFilterCount { return 0; }
- (NSInteger)freeUseCount { return 0; }
%end

%hook UIDevice
- (NSUUID *)identifierForVendor {
    static NSUUID *randomUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        randomUUID = [NSUUID UUID];
    });
    return randomUUID;
}
%end

#include <Security/Security.h>
#import <substrate.h>

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *queryDict = (__bridge NSDictionary *)query;
    if (queryDict && [queryDict[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]) {
        NSString *service = queryDict[(__bridge id)kSecAttrService];
        if ([service containsString:@"WeChatOpenSDK"] || [service containsString:@"DeviceID"] || [service containsString:@"UUID"]) {
            return errSecItemNotFound;
        }
    }
    return orig_SecItemCopyMatching(query, result);
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary *attrDict = (__bridge NSDictionary *)attributes;
    if (attrDict && [attrDict[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]) {
        NSString *service = attrDict[(__bridge id)kSecAttrService];
        if ([service containsString:@"WeChatOpenSDK"] || [service containsString:@"DeviceID"] || [service containsString:@"UUID"]) {
            return errSecSuccess;
        }
    }
    return orig_SecItemAdd(attributes, result);
}

%ctor {
    MSHookFunction((void *)SecItemCopyMatching, (void *)hook_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
    MSHookFunction((void *)SecItemAdd, (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd);
}

%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    static NSUUID *randomUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        randomUUID = [NSUUID UUID];
    });
    return randomUUID;
}
%end
