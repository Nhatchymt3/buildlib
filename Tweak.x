/*
 * Doka Follow Camera — Pro Unlock Tweak v2
 * Target: com.ydgn.dokacamera / Follow (v1.8.25, ARM64)
 *
 * Changes from v1:
 *  - Removed NSDate hook (broke timer/network; app uses NSCalendar day-component comparison)
 *  - NSUserDefaults: switched to EXACT key match with "VipManager." prefix (confirmed in binary)
 *  - NSUserDefaults: write-block is now exact-key only, not broad containsString (v1 blocked
 *    all system counter writes → app reset to 0 on init)
 *  - Added VipManager setter hooks to block in-memory counter decrement
 *  - Added URLSession intercept for vip-detail / check-subscription-status / validate-receipt
 *  - Added usage-tip confirm handler hooks to swallow the deduction callchain
 *  - Kept all original ObjC model hooks (ZZCheckSubscriptionStatusModel, FWStoreKitManager)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ─── JSON patcher (shared by NSJSONSerialization hook + URLSession hook) ──────

static id modifyDict(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [obj mutableCopy];

        for (NSString *key in @[@"is_vip", @"isVip", @"isVIP"]) {
            if (dict[key]) dict[key] = @YES;
        }
        if (dict[@"vip_type"]) dict[@"vip_type"] = @(1);

        for (NSString *key in @[
            @"remaining_count",
            @"remaining_compose_count",
            @"ai_compose_remaining_count",
            @"remaining_filter_count",
            @"ai_filter_remaining_count"
        ]) {
            if (dict[key] != nil) dict[key] = @(9999);
        }

        for (NSString *key in [dict.allKeys copy]) {
            id val = dict[key];
            if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                dict[key] = modifyDict(val);
            }
        }
        return dict;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [(NSArray *)obj mutableCopy];
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

// ─── 1. JSON layer ────────────────────────────────────────────────────────────

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id orig = %orig;
    if (orig) {
        @try { return modifyDict(orig); } @catch(NSException *e) {}
    }
    return orig;
}
%end

// ─── 2. Network response intercept ───────────────────────────────────────────
// Patches raw NSData before NSJSONSerialization runs, catching the case where
// the app uses a custom JSON deserialiser that bypasses our NSJSONSerialization hook.

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler) return %orig;
    NSString *urlStr = request.URL.absoluteString;
    BOOL needsPatch = ([urlStr containsString:@"apple/vip-detail"] ||
                       [urlStr containsString:@"apple/check-subscription-status"] ||
                       [urlStr containsString:@"apple/validate-receipt"]);
    if (!needsPatch) return %orig(request, completionHandler);

    void (^newHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *patched = data;
            if (data) {
                @try {
                    id json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:NSJSONReadingMutableContainers
                                                               error:nil];
                    if (json) {
                        id fixed = modifyDict(json);
                        NSData *newData = [NSJSONSerialization dataWithJSONObject:fixed
                                                                          options:0
                                                                            error:nil];
                        if (newData) patched = newData;
                    }
                } @catch (NSException *e) {}
            }
            completionHandler(patched, response, error);
        };
    return %orig(request, newHandler);
}
%end

// ─── 3. ObjC model classes ───────────────────────────────────────────────────

%hook ZZCheckSubscriptionStatusModel
- (BOOL)is_vip    { return YES; }
- (BOOL)isVip     { return YES; }
- (NSInteger)vip_type { return 1; }
- (NSInteger)vipType  { return 1; }
%end

%hook FWStoreKitManager
- (BOOL)isVIP { return YES; }
%end

// ─── 4. VipManager (Swift class with ObjC bridging) ──────────────────────────
// Two class names: "VipManager" (ObjC alias) and "_TtC6Follow10VipManager" (mangled).
// We hook both. The setter hooks are critical — they prevent the in-memory counter
// from being decremented after each AI use, which was the root cause of the 5-use limit.

%hook VipManager
- (BOOL)validatedEntitlementIsVip       { return YES; }
- (NSInteger)freeAIComposeCount         { return 9999; }
- (NSInteger)freeAIFilterCount          { return 9999; }
- (NSInteger)freeUseCount               { return 9999; }
- (void)setFreeAIComposeCount:(NSInteger)v { }
- (void)setFreeAIFilterCount:(NSInteger)v  { }
- (void)setFreeUseCount:(NSInteger)v       { }
- (NSInteger)debugMembershipMode        { return 1; }
%end

%hook _TtC6Follow10VipManager
- (BOOL)validatedEntitlementIsVip       { return YES; }
- (NSInteger)freeAIComposeCount         { return 9999; }
- (NSInteger)freeAIFilterCount          { return 9999; }
- (NSInteger)freeUseCount               { return 9999; }
- (void)setFreeAIComposeCount:(NSInteger)v { }
- (void)setFreeAIFilterCount:(NSInteger)v  { }
- (void)setFreeUseCount:(NSInteger)v       { }
- (NSInteger)debugMembershipMode        { return 1; }
%end

// ─── 5. Usage-tip confirm handlers ───────────────────────────────────────────
// These are called when the "No Free AI Attempts Left" overlay is shown and
// the user taps confirm. Swallowing them prevents the deduction call-chain.

%hook AIFilterSelectionViewController
- (void)handleAIFilterUsageTipConfirmButtonTap { }
%end

%hook AIComposeEffectSettingsViewController
- (void)handleAIComposeUsageTipConfirmButtonTap { }
%end

// ─── 6. NSUserDefaults — exact-key override ──────────────────────────────────
// Binary confirms the actual stored keys have "VipManager." prefix.
// v1 used containsString which was correct for reads but the write-block was
// too broad (blocked all keys with "count"/"limit"/"remaining") causing the app
// to read 0 on the next launch because those writes were eaten before being saved.

%hook NSUserDefaults

- (NSInteger)integerForKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.debugMembershipMode"]) return 1;
    if ([key isEqualToString:@"VipManager.freeAIComposeCount"])  return 9999;
    if ([key isEqualToString:@"VipManager.freeAIFilterCount"])   return 9999;
    if ([key isEqualToString:@"VipManager.freeUseCount"])        return 9999;
    return %orig;
}

- (id)objectForKey:(NSString *)key {
    if ([key isEqualToString:@"debug.vip.override"])                    return @YES;
    if ([key isEqualToString:@"VipManager.freeAIComposeCount"])         return @(9999);
    if ([key isEqualToString:@"VipManager.freeAIFilterCount"])          return @(9999);
    if ([key isEqualToString:@"VipManager.freeUseCount"])               return @(9999);
    if ([key isEqualToString:@"VipManager.validatedEntitlementIsVip"])  return @YES;
    if ([key isEqualToString:@"VipManager.debugMembershipMode"])        return @(1);
    if ([key localizedCaseInsensitiveContainsString:@"isvip"])          return @YES;
    return %orig;
}

- (BOOL)boolForKey:(NSString *)key {
    if ([key isEqualToString:@"debug.vip.override"])                   return YES;
    if ([key isEqualToString:@"VipManager.validatedEntitlementIsVip"]) return YES;
    if ([key localizedCaseInsensitiveContainsString:@"isvip"])         return YES;
    return %orig;
}

// Block writes only for the three counter keys — not broadly
- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.freeAIComposeCount"]) return;
    if ([key isEqualToString:@"VipManager.freeAIFilterCount"])  return;
    if ([key isEqualToString:@"VipManager.freeUseCount"])       return;
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:@"VipManager.freeAIComposeCount"]) return;
    if ([key isEqualToString:@"VipManager.freeAIFilterCount"])  return;
    if ([key isEqualToString:@"VipManager.freeUseCount"])       return;
    %orig;
}

%end

// ─── 7. Device identifier randomisation ──────────────────────────────────────

%hook UIDevice
- (NSUUID *)identifierForVendor {
    static NSUUID *randomUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ randomUUID = [NSUUID UUID]; });
    return randomUUID;
}
%end

%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    static NSUUID *randomUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ randomUUID = [NSUUID UUID]; });
    return randomUUID;
}
%end

// ─── 8. Keychain — block UUID / DeviceID persistence ─────────────────────────

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
