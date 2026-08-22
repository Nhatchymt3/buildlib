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
                       [urlStr containsString:@"apple/validate-receipt"] ||
                       [urlStr containsString:@"vip-detail"] ||
                       [urlStr containsString:@"vip_detail"] ||
                       [urlStr containsString:@"user/info"] ||
                       [urlStr containsString:@"ai_compose"]);
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

// Swift URLSession.shared.dataTask(with: URL) resolves to this variant
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler) return %orig;
    NSString *urlStr = url.absoluteString;
    BOOL needsPatch = ([urlStr containsString:@"vip-detail"] ||
                       [urlStr containsString:@"vip_detail"] ||
                       [urlStr containsString:@"ai_compose"] ||
                       [urlStr containsString:@"user/info"]);
    if (!needsPatch) return %orig(url, completionHandler);

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
    return %orig(url, newHandler);
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

// ─── 5. Usage-tip & quota-gate hooks ─────────────────────────────────────────

// ZZCameraController.showAI*UsageTip — tip overlay no-ops
%hook ZZCameraController
- (void)showAIComposeUsageTip { }
- (void)showAIFilterUsageTip  { }
%end

%hook _TtC6Follow18ZZCameraController
- (void)showAIComposeUsageTip { }
- (void)showAIFilterUsageTip  { }
%end

// UIAlertController intercept — catches the "Today's free AI composition
// attempts are used up" and "Today's free AI filter attempts are used up"
// dialogs that appear when the count-gate fires internally.
// This is the fallback for cases where Swift's direct ivar access bypasses
// our ObjC VipManager getter hooks.
%hook UIViewController
- (void)presentViewController:(UIViewController *)vc
                      animated:(BOOL)animated
                    completion:(void (^)(void))completion {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        NSString *msg = alert.message ?: @"";
        NSString *title = alert.title ?: @"";
        NSString *combined = [NSString stringWithFormat:@"%@ %@", title, msg];
        // Strings confirmed in binary
        if ([combined containsString:@"free AI composition attempts"] ||
            [combined containsString:@"free AI filter attempts"] ||
            [combined containsString:@"free AI uses are exhausted"] ||
            [combined containsString:@"attempts are used up"]) {
            // Silently dismiss without presenting — call completion so caller doesn't hang
            if (completion) completion();
            return;
        }
    }
    %orig;
}
%end

// ─── 6. NSUserDefaults — exact-key override ──────────────────────────────────
// Read hooks always return 9999 for free-count keys and YES for VIP flags.
// Write hooks REDIRECT counter writes to 9999 (not block) so that VipManager's
// cached ivar is always reset to max after any decrement attempt.

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

%end

// g_seedingDefaults: set to YES in %ctor so UserDefaults seeding bypasses the write-block
static BOOL g_seedingDefaults = NO;

%hook NSUserDefaults
- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if (!g_seedingDefaults) {
        if ([key isEqualToString:@"VipManager.freeAIComposeCount"]) return;
        if ([key isEqualToString:@"VipManager.freeAIFilterCount"])  return;
        if ([key isEqualToString:@"VipManager.freeUseCount"])       return;
    }
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (!g_seedingDefaults) {
        if ([key isEqualToString:@"VipManager.freeAIComposeCount"]) return;
        if ([key isEqualToString:@"VipManager.freeAIFilterCount"])  return;
        if ([key isEqualToString:@"VipManager.freeUseCount"])       return;
    }
    %orig;
}
%end

// ─── 7. ZZCameraController — AI Compose button tap gate bypass ────────────────
// aiComposeMultiPlansButtonTapped is the IBAction for the AI Comp button.
// Inside it, Swift reads freeAIComposeCount via possibly-direct ivar access.
// We force-write 9999 to disk immediately before the gate check so even if
// VipManager re-reads from disk mid-method, it gets 9999.
%hook ZZCameraController
- (void)aiComposeMultiPlansButtonTapped {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:9999 forKey:@"VipManager.freeAIComposeCount"];
    [d setInteger:9999 forKey:@"VipManager.freeAIFilterCount"];
    [d setInteger:9999 forKey:@"VipManager.freeUseCount"];
    %orig;
}
%end

%hook _TtC6Follow18ZZCameraController
- (void)aiComposeMultiPlansButtonTapped {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:9999 forKey:@"VipManager.freeAIComposeCount"];
    [d setInteger:9999 forKey:@"VipManager.freeAIFilterCount"];
    [d setInteger:9999 forKey:@"VipManager.freeUseCount"];
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

    // Seed UserDefaults at load time — use bypass flag to skip the write-block hook
    g_seedingDefaults = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:9999 forKey:@"VipManager.freeAIComposeCount"];
    [d setInteger:9999 forKey:@"VipManager.freeAIFilterCount"];
    [d setInteger:9999 forKey:@"VipManager.freeUseCount"];
    [d setBool:YES forKey:@"VipManager.validatedEntitlementIsVip"];
    [d setInteger:1 forKey:@"VipManager.debugMembershipMode"];
    [d synchronize];
    g_seedingDefaults = NO;
}
