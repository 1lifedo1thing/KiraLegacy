#import "KLStrings.h"

NSString *const KLLanguageChangedNotification = @"KLLanguageChanged";

static NSString *const KLLanguageKey = @"kl_language";

/**
 * Языки, на которых приложение умеет говорить.
 *
 * Русский первым потому, что на нём написан исходный текст: остальные —
 * переводы с него, и когда перевода не хватает, подставляется именно
 * русская строка, а не ключ.
 *
 * Набор — крупнейшие языки плюс японский и китайский: для клиента аниме
 * они уместнее иных более многочисленных.
 */
static NSArray *KLLanguageCodes(void) {
    return [NSArray arrayWithObjects:
            @"ru", @"en", @"es", @"pt", @"ja", @"zh-Hans", nil];
}

@implementation KLStrings

+ (NSArray *)available {
    return KLLanguageCodes();
}

+ (NSString *)nameForLanguage:(NSString *)code {
    NSDictionary *names = [NSDictionary dictionaryWithObjectsAndKeys:
        @"Русский", @"ru",
        @"English", @"en",
        @"Español", @"es",
        @"Português", @"pt",
        @"日本語", @"ja",
        @"中文（简体）", @"zh-Hans",
        nil];

    return [names objectForKey:code] ?: code;
}

+ (NSString *)language {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:KLLanguageKey];

    return [value length] > 0 ? value : nil;
}

+ (void)setLanguage:(NSString *)code {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([code length] > 0) {
        [defaults setObject:code forKey:KLLanguageKey];
    } else {
        [defaults removeObjectForKey:KLLanguageKey];
    }

    [defaults synchronize];

    @synchronized (self) {
        [self clearCache];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:KLLanguageChangedNotification
                                                        object:nil];
}

/**
 * На каком языке говорит устройство — из того, что мы умеем.
 *
 * `preferredLanguages` отдаёт коды вида «ru», «pt-BR», «zh-Hans-CN». Точного
 * совпадения ждать нельзя, поэтому сравниваем по началу: «pt-BR» находит
 * «pt», а «zh-Hans-CN» — «zh-Hans». Порядок перебора — от длинного кода
 * к короткому, иначе «zh-Hans-CN» совпал бы с несуществующим «zh» раньше,
 * чем с настоящим «zh-Hans».
 */
+ (NSString *)systemLanguage {
    NSArray *preferred = [NSLocale preferredLanguages];

    for (NSString *wanted in preferred) {
        NSString *lower = [wanted lowercaseString];

        NSArray *sorted = [KLLanguageCodes() sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
                if ([a length] > [b length]) return NSOrderedAscending;
                if ([a length] < [b length]) return NSOrderedDescending;

                return NSOrderedSame;
            }];

        for (NSString *code in sorted) {
            if ([lower hasPrefix:[code lowercaseString]]) {
                return code;
            }
        }
    }

    // Ни один не подошёл — английский: он понятнее русского тому,
    // у кого в системе стоит что-то третье.
    return @"en";
}

+ (NSString *)effectiveLanguage {
    return [self language] ?: [self systemLanguage];
}

#pragma mark Связки

+ (NSMutableDictionary *)bundles {
    static NSMutableDictionary *bundles = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ bundles = [[NSMutableDictionary alloc] init]; });

    return bundles;
}

+ (void)clearCache {
    [[self bundles] removeAllObjects];
}

/** Связка перевода для кода; nil, если папки нет. */
+ (NSBundle *)bundleFor:(NSString *)code {
    if ([code length] == 0) {
        return nil;
    }

    NSMutableDictionary *cache = [self bundles];

    id known = [cache objectForKey:code];
    if (known != nil) {
        return known == [NSNull null] ? nil : known;
    }

    NSString *path = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    NSBundle *bundle = path != nil ? [NSBundle bundleWithPath:path] : nil;

    [cache setObject:bundle ?: (id)[NSNull null] forKey:code];

    return bundle;
}

+ (NSString *)stringForKey:(NSString *)key {
    if ([key length] == 0) {
        return @"";
    }

    @synchronized (self) {
        // Метка отсутствия своя, а не сам ключ: у localizedStringForKey:
        // значение по умолчанию возвращается и тогда, когда перевод есть,
        // но пуст, — а пустая строка на экране это тоже ошибка перевода.
        static NSString *const missing = @"<KLMissing>";

        NSBundle *chosen = [self bundleFor:[self effectiveLanguage]];
        NSString *value = [chosen localizedStringForKey:key value:missing table:nil];

        if (![value isEqualToString:missing]) {
            return value;
        }

        // Перевода нет — берём русский: там текст исходный и точно есть.
        NSBundle *base = [self bundleFor:@"ru"];
        value = [base localizedStringForKey:key value:missing table:nil];

        if (![value isEqualToString:missing]) {
            return value;
        }

        NSLog(@"[Кира/Языки] Нет перевода для «%@»", key);

        return key;
    }
}

@end

NSString *KLStr(NSString *key) {
    return [KLStrings stringForKey:key];
}

NSString *KLFmt(NSString *key, ...) {
    NSString *format = [KLStrings stringForKey:key];

    va_list arguments;
    va_start(arguments, key);

    NSString *result = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    return result;
}
