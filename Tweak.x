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
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"]) {
        return 9999;
    }
    return %orig;
}

- (id)objectForKey:(NSString *)key {
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"]) {
        return @(9999);
    }
    if ([key localizedCaseInsensitiveContainsString:@"isvip"]) {
        return @YES;
    }
    return %orig;
}

- (BOOL)boolForKey:(NSString *)key {
    if ([key localizedCaseInsensitiveContainsString:@"isvip"]) {
        return YES;
    }
    return %orig;
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"]) {
        return; 
    }
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if ([key localizedCaseInsensitiveContainsString:@"count"] || 
        [key localizedCaseInsensitiveContainsString:@"limit"]) {
        return; 
    }
    %orig;
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
