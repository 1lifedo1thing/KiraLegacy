#import "KLSettings.h"

#import "KLCustomSource.h"

static NSString *const KLSourceKey = @"kl_preferred_source";
static NSString *const KLHeightKey = @"kl_preferred_height";
static NSString *const KLCustomKey = @"kl_custom_sources";

@implementation KLSettings

+ (NSArray *)knownSources {
    // Тот же порядок, в каком их обходит KLApi, — чтобы список в настройках
    // читался как «первое подходящее сверху вниз».
    NSMutableArray *list = [NSMutableArray arrayWithObjects:
            @"HiAnime", @"AniWave", @"AnimeHub",
            @"Megavid", @"Megavid AniWave", @"Megavid Ani", nil];

    /**
     * Свои источники — следом за штатными, и тоже по именам.
     *
     * Иначе выбранное «по умолчанию» нельзя было бы назначить своим
     * источником, а это ровно то, что делают, когда штатные перестали
     * отвечать: ставят свой и больше не хотят видеть список.
     */
    for (KLCustomSource *entry in [self customSources]) {
        if ([entry enabled] && ![list containsObject:[entry name]]) {
            [list addObject:[entry name]];
        }
    }

    return list;
}

#pragma mark - Свои источники

+ (NSArray *)customSources {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:KLCustomKey];
    NSMutableArray *list = [NSMutableArray array];

    // Записи, которую не удалось разобрать, здесь не место: она уже
    // не источник, а мусор в настройках. Молча пропускаем — но именно
    // пропускаем, а не роняем весь список из-за одной.
    for (id item in stored) {
        KLCustomSource *entry = [KLCustomSource fromJson:item];

        if (entry != nil) {
            [list addObject:entry];
        }
    }

    return list;
}

+ (void)setCustomSources:(NSArray *)list {
    NSMutableArray *plain = [NSMutableArray array];

    for (KLCustomSource *entry in list) {
        [plain addObject:[entry json]];
    }

    [[NSUserDefaults standardUserDefaults] setObject:plain forKey:KLCustomKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSArray *)enabledCustomSources {
    NSMutableArray *list = [NSMutableArray array];

    for (KLCustomSource *entry in [self customSources]) {
        if ([entry enabled]) {
            [list addObject:entry];
        }
    }

    return list;
}

+ (NSString *)preferredSource {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    id stored = [defaults objectForKey:KLSourceKey];

    /**
     * По умолчанию — спрашивать.
     *
     * Сначала здесь стоял HiAnime: он единственный даёт и лестницу качеств,
     * и субтитры, и казалось разумным брать его молча. На деле зеркала
     * ложатся и оживают поодиночке, и молчаливый выбор оборачивается
     * ожиданием у мёртвой ссылки без единой подсказки, что рядом есть
     * шесть живых. Список из семи строк показывается за полсекунды
     * и стоит одного нажатия.
     */
    if (stored == nil) {
        return @"";
    }

    return [stored isKindOfClass:[NSString class]] ? stored : @"";
}

+ (void)setPreferredSource:(NSString *)label {
    [[NSUserDefaults standardUserDefaults] setObject:label ?: @"" forKey:KLSourceKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSArray *)knownHeights {
    return [NSArray arrayWithObjects:
            [NSNumber numberWithInteger:0],
            [NSNumber numberWithInteger:360],
            [NSNumber numberWithInteger:720],
            [NSNumber numberWithInteger:1080], nil];
}

+ (NSInteger)preferredHeight {
    return [[NSUserDefaults standardUserDefaults] integerForKey:KLHeightKey];
}

+ (void)setPreferredHeight:(NSInteger)height {
    [[NSUserDefaults standardUserDefaults] setInteger:height forKey:KLHeightKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
