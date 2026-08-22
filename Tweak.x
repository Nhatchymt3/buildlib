#import <Foundation/Foundation.h>

%hook VIPDetailModel
- (BOOL)is_vip { return YES; }
- (NSInteger)vip_type { return 1; }
- (NSInteger)remaining_count { return 9999; }
- (NSInteger)remaining_compose_count { return 9999; }
- (NSInteger)ai_compose_remaining_count { return 9999; }
- (NSInteger)remaining_filter_count { return 9999; }
- (NSInteger)ai_filter_remaining_count { return 9999; }
%end

%hook _TtC6Follow10VipManager
- (NSInteger)freeAIComposeCount { return 9999; }
- (NSInteger)freeAIFilterCount { return 9999; }
- (NSInteger)freeUseCount { return 9999; }
- (BOOL)validatedEntitlementIsVip { return YES; }
- (BOOL)isVIP { return YES; }
%end

%hook VipManager
- (NSInteger)freeAIComposeCount { return 9999; }
- (NSInteger)freeAIFilterCount { return 9999; }
- (NSInteger)freeUseCount { return 9999; }
- (BOOL)validatedEntitlementIsVip { return YES; }
- (BOOL)isVIP { return YES; }
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

%hook NSUserDefaults

- (NSInteger)integerForKey:(NSString *)defaultName {
    if ([defaultName containsString:@"Count"] || 
        [defaultName containsString:@"count"] || 
        [defaultName containsString:@"limit"]) {
        return 9999;
    }
    return %orig;
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)defaultName {
    if ([defaultName containsString:@"Count"] || 
        [defaultName containsString:@"count"] || 
        [defaultName containsString:@"limit"]) {
        return; // Chặn lưu đếm lượt (decrement) xuống local
    }
    %orig;
}

%end
