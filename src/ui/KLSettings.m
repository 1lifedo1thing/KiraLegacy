#import "KLSettings.h"

static NSString *const KLSourceKey = @"kl_preferred_source";
static NSString *const KLHeightKey = @"kl_preferred_height";

@implementation KLSettings

+ (NSArray *)knownSources {
    // Тот же порядок, в каком их обходит KLApi, — чтобы список в настройках
    // читался как «первое подходящее сверху вниз».
    return [NSArray arrayWithObjects:
            @"HiAnime", @"AniWave", @"AnimeHub",
            @"Megavid", @"Megavid AniWave", @"Megavid Ani", nil];
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
