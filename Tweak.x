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

        // VIP status fields
        for (NSString *key in @[@"is_vip", @"isVip", @"isVIP", @"vip"]) {
            if (dict[key]) dict[key] = @YES;
        }
        if (dict[@"vip_type"]) dict[@"vip_type"] = @(1);
        if (dict[@"membership_level"]) dict[@"membership_level"] = @(1);

        // Quota / remaining count fields
        for (NSString *key in @[
            @"remaining_count",
            @"remaining_compose_count",
            @"ai_compose_remaining_count",
            @"remaining_filter_count",
            @"ai_filter_remaining_count",
            @"free_compose_count",
            @"free_filter_count",
            @"free_use_count",
            @"daily_remaining",
            @"quota_remaining",
            @"used_count",          // patch used→0
            @"daily_used_count"
        ]) {
            if (dict[key] != nil) {
                // used_count fields should be 0, everything else 9999
                if ([key containsString:@"used"]) dict[key] = @(0);
                else dict[key] = @(9999);
            }
        }

        // Error / status codes that trigger mid-session cancel
        // Server returns non-zero code to signal quota exhausted → patch to 0 (success)
        NSNumber *code = dict[@"code"];
        if (code && [code isKindOfClass:[NSNumber class]]) {
            NSInteger c = code.integerValue;
            // Common quota-exhausted codes used by Alibaba Cloud / yindoka backend
            if (c == 429 || c == 4001 || c == 4002 || c == 4003 ||
                c == 1001 || c == 1002 || c == 1003 ||
                c == 10001 || c == 10002 || c == 10003 ||
                c == 20001 || c == 20002 || c == 40001 ||
                c == 403 || c == 402 || c == 401) {
                dict[@"code"] = @(0);
                // Also patch accompanying message/data to look like success
                if (!dict[@"data"] || [dict[@"data"] isKindOfClass:[NSNull class]]) {
                    dict[@"data"] = @{};
                }
            }
        }
        // Same for error_code, status_code, ret, retcode
        for (NSString *errKey in @[@"error_code", @"status_code", @"ret", @"retcode", @"errCode"]) {
            NSNumber *ec = dict[errKey];
            if (ec && [ec isKindOfClass:[NSNumber class]] && ec.integerValue != 0) {
                dict[errKey] = @(0);
            }
        }

        // Recurse into nested dicts/arrays
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

// Shared response patcher — wraps any completion handler to run modifyDict
// on the raw JSON. Safe: modifyDict is a no-op if quota keys are absent.
static void patchHandler(void (^completionHandler)(NSData *, NSURLResponse *, NSError *),
                         NSData *data, NSURLResponse *response, NSError *error) {
    NSData *patched = data;
    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
    NSString *urlStr = httpResp.URL.absoluteString ?: @"(nil)";

    if (data) {
        @try {
            id json = [NSJSONSerialization JSONObjectWithData:data
                                                     options:NSJSONReadingMutableContainers
                                                       error:nil];
            if (json) {
                // LOG: print every JSON response so we can see AI compose traffic
                NSData *prettyData = [NSJSONSerialization dataWithJSONObject:json
                                                                     options:NSJSONWritingPrettyPrinted
                                                                       error:nil];
                NSString *bodyStr = prettyData ? [[NSString alloc] initWithData:prettyData
                                                                       encoding:NSUTF8StringEncoding]
                                               : @"(serialize failed)";
                NSLog(@"[DokaVip] URL=%@ STATUS=%ld BODY=%@",
                      urlStr, (long)httpResp.statusCode, bodyStr);

                id fixed = modifyDict(json);
                NSData *nd = [NSJSONSerialization dataWithJSONObject:fixed options:0 error:nil];
                if (nd) patched = nd;
            } else {
                // Non-JSON response (image, binary) — log URL + size only
                NSLog(@"[DokaVip] URL=%@ STATUS=%ld NON-JSON size=%lu",
                      urlStr, (long)httpResp.statusCode, (unsigned long)data.length);
            }
        } @catch (NSException *e) {}
    } else if (error) {
        NSLog(@"[DokaVip] URL=%@ ERROR=%@", urlStr, error.localizedDescription);
    }
    completionHandler(patched, response, error);
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler) return %orig;
    // Patch ALL JSON responses — obfuscated endpoints (/hi8, /km4 etc) also carry quota data
    void (^newHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *d, NSURLResponse *r, NSError *e) { patchHandler(completionHandler, d, r, e); };
    return %orig(request, newHandler);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler) return %orig;
    void (^newHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *d, NSURLResponse *r, NSError *e) { patchHandler(completionHandler, d, r, e); };
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

// ─── 5. Compose mode & quota-gate hooks ───────────────────────────────────────

// Force local compose mode — disable cloud Plan2 dependency so AI Compose
// runs entirely on-device (face_det + face_align mars models + Apple Vision).
// isAiComposeMultiPlansEnabled=NO → app skips network Plan2 prefetch,
// uses local rule-based framing ("Detect the subject offline and frame it with fixed rules").
%hook ZZCameraController
- (void)showAIComposeUsageTip { }
- (void)showAIFilterUsageTip  { }
- (BOOL)isAiComposeMultiPlansEnabled { return NO; }
- (BOOL)hasActivatedAIComposePlan2   { return YES; }
- (BOOL)hasTriggeredAIComposePlan2Prefetch { return YES; }
- (BOOL)hasCompletedRemoteFetch      { return YES; }
%end

%hook _TtC6Follow18ZZCameraController
- (void)showAIComposeUsageTip { }
- (void)showAIFilterUsageTip  { }
- (BOOL)isAiComposeMultiPlansEnabled { return NO; }
- (BOOL)hasActivatedAIComposePlan2   { return YES; }
- (BOOL)hasTriggeredAIComposePlan2Prefetch { return YES; }
- (BOOL)hasCompletedRemoteFetch      { return YES; }
%end

// NSUserDefaults — also gate the multi-plans feature flag from remote config
// so even if ZZCameraController reads it via UserDefaults it gets NO (local mode)
// and hasActivatedAIComposePlan2 persists as YES across sessions.

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
    // Force local-only compose mode: disable cloud Plan2 feature flag
    if ([key isEqualToString:@"ai_compose_multi_plans_enabled"])       return NO;
    if ([key isEqualToString:@"ai_compose_perf_probe_enabled"])        return NO;
    // Force Plan2 as already activated so app skips Plan2 prefetch entirely
    if ([key isEqualToString:@"hasActivatedAIComposePlan2"])           return YES;
    if ([key isEqualToString:@"hasTriggeredAIComposePlan2Prefetch"])   return YES;
    if ([key isEqualToString:@"hasCompletedRemoteFetch"])              return YES;
    if ([key isEqualToString:@"VipManager.hasSyncedIndependentAIFilterCount"]) return YES;
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
    // Force-write 9999 bypassing our write-block so VipManager disk reads see 9999
    g_seedingDefaults = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:9999 forKey:@"VipManager.freeAIComposeCount"];
    [d setInteger:9999 forKey:@"VipManager.freeAIFilterCount"];
    [d setInteger:9999 forKey:@"VipManager.freeUseCount"];
    [d synchronize];
    g_seedingDefaults = NO;
    %orig;
}
%end

%hook _TtC6Follow18ZZCameraController
- (void)aiComposeMultiPlansButtonTapped {
    g_seedingDefaults = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:9999 forKey:@"VipManager.freeAIComposeCount"];
    [d setInteger:9999 forKey:@"VipManager.freeAIFilterCount"];
    [d setInteger:9999 forKey:@"VipManager.freeUseCount"];
    [d synchronize];
    g_seedingDefaults = NO;
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
