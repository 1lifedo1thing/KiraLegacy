#import "KLJson.h"

/**
 * Достаёт значение по ключу, сводя к nil обе разновидности пустоты:
 * отсутствующий ключ и присланный сервером null (он приходит как NSNull).
 */
static id KLValue(NSDictionary *parent, NSString *key) {
    if (![parent isKindOfClass:[NSDictionary class]] || key == nil) {
        return nil;
    }

    id value = [parent objectForKey:key];
    if (value == nil || value == [NSNull null]) {
        return nil;
    }

    return value;
}

@implementation KLJson

+ (id)parseAny:(NSData *)data {
    if ([data length] == 0) {
        return nil;
    }

    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (result == nil) {
        NSLog(@"[Кира/JSON] Разбор не удался: %@", [error localizedDescription]);
    }

    return result;
}

+ (NSDictionary *)parse:(NSData *)data {
    id result = [self parseAny:data];

    return [result isKindOfClass:[NSDictionary class]] ? result : nil;
}

+ (NSData *)encode:(NSDictionary *)object {
    if (object == nil) {
        object = [NSDictionary dictionary];
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];

    return data ?: [NSData data];
}

+ (NSDictionary *)objectIn:(NSDictionary *)parent key:(NSString *)key {
    id value = KLValue(parent, key);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSArray *)arrayIn:(NSDictionary *)parent key:(NSString *)key {
    id value = KLValue(parent, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

+ (NSDictionary *)objectAt:(NSArray *)array index:(NSUInteger)index {
    if (![array isKindOfClass:[NSArray class]] || index >= [array count]) {
        return nil;
    }

    id value = [array objectAtIndex:index];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSString *)textIn:(NSDictionary *)parent key:(NSString *)key {
    NSString *value = [self stringIn:parent key:key];
    return [value length] > 0 ? value : nil;
}

+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key {
    return [self stringIn:parent key:key fallback:nil];
}

+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key
              fallback:(NSString *)fallback {
    id value = KLValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }

    // Числовые идентификаторы приходят то числом, то строкой — приводим.
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }

    return fallback;
}

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key {
    return [self intIn:parent key:key fallback:0];
}

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(NSInteger)fallback {
    id value = KLValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value integerValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        // integerValue у не-числа даёт 0, а нам нужен именно fallback:
        // «серий ноль» и «поле не пришло» — разные вещи.
        NSScanner *scanner = [NSScanner scannerWithString:value];
        long long parsed = 0;

        if ([scanner scanLongLong:&parsed] && [scanner isAtEnd]) {
            return (NSInteger)parsed;
        }
    }

    return fallback;
}

+ (double)doubleIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(double)fallback {
    id value = KLValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double parsed = 0;

        if ([scanner scanDouble:&parsed] && [scanner isAtEnd]) {
            return parsed;
        }
    }

    return fallback;
}

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key {
    return [self boolIn:parent key:key fallback:NO];
}

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key fallback:(BOOL)fallback {
    id value = KLValue(parent, key);
    if (value == nil) {
        return fallback;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        return [value caseInsensitiveCompare:@"true"] == NSOrderedSame;
    }

    return fallback;
}

@end
