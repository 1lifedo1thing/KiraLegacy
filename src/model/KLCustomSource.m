#import "KLCustomSource.h"

#import "KLJson.h"
#import "KLStrings.h"

static NSString *const KLNameKey = @"name";
static NSString *const KLKindKey = @"kind";
static NSString *const KLAddressKey = @"address";
static NSString *const KLPathKey = @"path";
static NSString *const KLRefererKey = @"referer";
static NSString *const KLOffsetKey = @"offset";
static NSString *const KLEnabledKey = @"enabled";

@implementation KLCustomSource

+ (KLCustomSource *)fromJson:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    KLCustomSource *entry = [[KLCustomSource alloc] init];

    entry.name = [KLJson textIn:json key:KLNameKey];
    entry.address = [KLJson textIn:json key:KLAddressKey];
    entry.fieldPath = [KLJson textIn:json key:KLPathKey];
    entry.referer = [KLJson textIn:json key:KLRefererKey];

    /**
     * Выключенность хранится в том же словаре, что и всё остальное, а
     * NSUserDefaults переживает смену версии приложения. Записи, сделанной
     * до появления этого поля, ключа не найдёт, и источник окажется
     * выключенным — то есть человек увидит, что добавленное им пропало.
     * Отсутствие ключа поэтому означает «включён», а не «выключен».
     */
    if ([[json allKeys] containsObject:KLEnabledKey]) {
        entry.enabled = [KLJson boolIn:json key:KLEnabledKey];
    } else {
        entry.enabled = YES;
    }

    entry.episodeOffset = [KLJson intIn:json key:KLOffsetKey];

    // Вид хранится числом; всё незнакомое считается прямым — это тот вид,
    // который ничего не разбирает и потому не может сломаться от чужих правок.
    entry.kind = [KLJson intIn:json key:KLKindKey] == KLCustomKindJson
        ? KLCustomKindJson
        : KLCustomKindDirect;

    if ([entry.name length] == 0 || [entry.address length] == 0) {
        return nil;
    }

    return entry;
}

- (NSDictionary *)json {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            self.name ?: @"", KLNameKey,
            [NSNumber numberWithInteger:(NSInteger)self.kind], KLKindKey,
            self.address ?: @"", KLAddressKey,
            self.fieldPath ?: @"", KLPathKey,
            self.referer ?: @"", KLRefererKey,
            [NSNumber numberWithInteger:self.episodeOffset], KLOffsetKey,
            [NSNumber numberWithBool:self.enabled], KLEnabledKey,
            nil];
}

#pragma mark - Подстановка

- (NSString *)addressForAnilistId:(NSInteger)anilistId
                            malId:(NSInteger)malId
                          episode:(NSInteger)episode
                             kind:(NSString *)kind {
    if ([self.address length] == 0) {
        return nil;
    }

    NSString *text = self.address;

    /**
     * Пустая строка вместо нуля.
     *
     * У тайтла, которого нет в MyAnimeList, malId равен нулю, и подстановка
     * нуля отправила бы запрос про тайтл с идентификатором 0 — то есть
     * с большой вероятностью про совсем другой. Пустое значение чужой сервис
     * хотя бы честно отвергнет.
     */
    NSString *mal = malId > 0 ? [NSString stringWithFormat:@"%ld", (long)malId] : @"";
    NSString *ani = anilistId > 0 ? [NSString stringWithFormat:@"%ld", (long)anilistId] : @"";

    NSInteger shifted = episode + self.episodeOffset;
    NSString *number = shifted > 0 ? [NSString stringWithFormat:@"%ld", (long)shifted] : @"";

    text = [text stringByReplacingOccurrencesOfString:@"{aniId}" withString:ani];
    text = [text stringByReplacingOccurrencesOfString:@"{malId}" withString:mal];
    text = [text stringByReplacingOccurrencesOfString:@"{episode}" withString:number];
    text = [text stringByReplacingOccurrencesOfString:@"{kind}"
                                           withString:[kind length] > 0 ? kind : @"sub"];

    return text;
}

- (NSString *)kindText {
    return KLStr(self.kind == KLCustomKindJson ? @"custom.kind.json"
                                               : @"custom.kind.direct");
}

@end
