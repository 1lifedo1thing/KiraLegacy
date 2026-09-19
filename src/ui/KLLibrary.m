#import "KLLibrary.h"

#import "KLStrings.h"

#import "KLAnime.h"

NSString *const KLStatusNone = @"none";
NSString *const KLStatusPlanning = @"planning";
NSString *const KLStatusWatching = @"watching";
NSString *const KLStatusCompleted = @"completed";
NSString *const KLStatusDropped = @"dropped";

NSString *const KLLibraryChangedNotification = @"KLLibraryChanged";

static NSString *const KLLibraryKey = @"kl_library";

@implementation KLLibraryEntry

- (NSDictionary *)toJson {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInteger:_anilistId], @"id",
        _title ?: @"", @"title",
        _poster ?: @"", @"poster",
        [NSNumber numberWithInteger:_score], @"score",
        _status ?: KLStatusNone, @"status",
        [NSNumber numberWithBool:_favorite], @"favorite",
        [NSNumber numberWithInteger:_progressEpisode], @"progress",
        [NSNumber numberWithDouble:_updatedAt], @"updatedAt",
        nil];
}

+ (KLLibraryEntry *)fromJson:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    KLLibraryEntry *entry = [[KLLibraryEntry alloc] init];

    entry.anilistId = [[json objectForKey:@"id"] integerValue];
    entry.title = [json objectForKey:@"title"];
    entry.poster = [json objectForKey:@"poster"];
    entry.score = [[json objectForKey:@"score"] integerValue];
    entry.status = [json objectForKey:@"status"] ?: KLStatusNone;
    entry.favorite = [[json objectForKey:@"favorite"] boolValue];
    entry.progressEpisode = [[json objectForKey:@"progress"] integerValue];
    entry.updatedAt = [[json objectForKey:@"updatedAt"] doubleValue];

    return entry.anilistId > 0 ? entry : nil;
}

@end


@implementation KLLibrary

/**
 * Весь список одним словарём в настройках.
 *
 * Записей здесь единицы и десятки, не тысячи, поэтому отдельного хранилища
 * заводить незачем — а вот держать их в памяти между обращениями стоит:
 * список спрашивают при каждой отрисовке карточки, и лезть за ним в
 * NSUserDefaults на каждую было бы заметно.
 */
+ (NSMutableDictionary *)entries {
    static NSMutableDictionary *entries = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        entries = [[NSMutableDictionary alloc] init];

        NSDictionary *stored =
            [[NSUserDefaults standardUserDefaults] dictionaryForKey:KLLibraryKey];

        for (NSString *key in stored) {
            KLLibraryEntry *entry = [KLLibraryEntry fromJson:[stored objectForKey:key]];

            if (entry != nil) {
                [entries setObject:entry forKey:key];
            }
        }

        NSLog(@"[Кира/Моё] Записей прочитано: %lu", (unsigned long)[entries count]);
    });

    return entries;
}

+ (void)save {
    NSMutableDictionary *json = [NSMutableDictionary dictionary];

    @synchronized (self) {
        NSMutableDictionary *entries = [self entries];

        for (NSString *key in entries) {
            [json setObject:[[entries objectForKey:key] toJson] forKey:key];
        }
    }

    [[NSUserDefaults standardUserDefaults] setObject:json forKey:KLLibraryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:KLLibraryChangedNotification
                                                        object:nil];
}

+ (NSString *)keyFor:(NSInteger)anilistId {
    return [NSString stringWithFormat:@"%ld", (long)anilistId];
}

+ (KLLibraryEntry *)entryFor:(NSInteger)anilistId {
    @synchronized (self) {
        return [[self entries] objectForKey:[self keyFor:anilistId]];
    }
}

/**
 * Достаёт запись, заводя её при необходимости, и обновляет то, что знает
 * о тайтле каталог.
 *
 * Название и обложку обновляем каждый раз, а не только при заведении:
 * у AniList английское название нет-нет да и появится там, где раньше был
 * один romaji, и список не должен застревать на той версии, что была в день
 * добавления.
 */
+ (KLLibraryEntry *)touch:(KLAnime *)anime {
    if (anime == nil || anime.anilistId <= 0) {
        return nil;
    }

    NSString *key = [self keyFor:anime.anilistId];

    @synchronized (self) {
        NSMutableDictionary *entries = [self entries];
        KLLibraryEntry *entry = [entries objectForKey:key];

        if (entry == nil) {
            entry = [[KLLibraryEntry alloc] init];
            entry.anilistId = anime.anilistId;
            entry.status = KLStatusNone;

            [entries setObject:entry forKey:key];
        }

        if ([anime.title length] > 0) {
            entry.title = anime.title;
        }

        if ([anime.coverUrl length] > 0) {
            entry.poster = anime.coverUrl;
        }

        if (anime.score > 0) {
            entry.score = anime.score;
        }

        entry.updatedAt = [NSDate timeIntervalSinceReferenceDate];

        return entry;
    }
}

/**
 * Убирает запись, если в ней не осталось ничего своего.
 *
 * Снятый статус сам по себе не значит «забудь тайтл»: у него может остаться
 * отметка «любимое» или пройденные серии. Выбрасываем только пустую —
 * иначе список «Продолжить» терял бы место, на котором остановились, стоило
 * сменить статус на «Ничего».
 */
+ (void)pruneIfEmpty:(KLLibraryEntry *)entry {
    if (entry == nil) {
        return;
    }

    BOOL hasStatus = [entry.status length] > 0 &&
                     ![entry.status isEqualToString:KLStatusNone];

    if (hasStatus || entry.favorite || entry.progressEpisode > 0) {
        return;
    }

    @synchronized (self) {
        [[self entries] removeObjectForKey:[self keyFor:entry.anilistId]];
    }
}

#pragma mark Статус

+ (NSString *)statusFor:(NSInteger)anilistId {
    KLLibraryEntry *entry = [self entryFor:anilistId];

    return [entry.status length] > 0 ? entry.status : KLStatusNone;
}

+ (void)setStatus:(NSString *)status forAnime:(KLAnime *)anime {
    KLLibraryEntry *entry = [self touch:anime];
    if (entry == nil) {
        return;
    }

    entry.status = status ?: KLStatusNone;

    [self pruneIfEmpty:entry];
    [self save];
}

#pragma mark Любимое

+ (BOOL)isFavorite:(NSInteger)anilistId {
    return [self entryFor:anilistId].favorite;
}

+ (BOOL)toggleFavorite:(KLAnime *)anime {
    KLLibraryEntry *entry = [self touch:anime];
    if (entry == nil) {
        return NO;
    }

    entry.favorite = !entry.favorite;

    BOOL result = entry.favorite;

    [self pruneIfEmpty:entry];
    [self save];

    return result;
}

#pragma mark Прогресс

+ (void)markProgress:(KLAnime *)anime episode:(NSInteger)episode {
    KLLibraryEntry *entry = [self touch:anime];
    if (entry == nil || episode <= 0) {
        return;
    }

    entry.progressEpisode = episode;

    // Начали смотреть — статус сам становится «Смотрю», но только если
    // его не ставили руками: пересмотр завершённого не должен молча
    // возвращать тайтл в «Смотрю».
    if ([entry.status length] == 0 || [entry.status isEqualToString:KLStatusNone]) {
        entry.status = KLStatusWatching;
    }

    [self save];
}

#pragma mark Списки

+ (NSArray *)list:(NSString *)kind {
    NSMutableArray *result = [NSMutableArray array];

    @synchronized (self) {
        NSMutableDictionary *entries = [self entries];

        for (NSString *key in entries) {
            KLLibraryEntry *entry = [entries objectForKey:key];

            BOOL matches = NO;

            if ([kind isEqualToString:@"continue"]) {
                matches = entry.progressEpisode > 0;
            } else if ([kind isEqualToString:@"favorite"]) {
                matches = entry.favorite;
            } else {
                matches = [entry.status isEqualToString:kind];
            }

            if (matches) {
                [result addObject:entry];
            }
        }
    }

    [result sortUsingComparator:^NSComparisonResult(KLLibraryEntry *a, KLLibraryEntry *b) {
        if (a.updatedAt > b.updatedAt) return NSOrderedAscending;
        if (a.updatedAt < b.updatedAt) return NSOrderedDescending;

        return NSOrderedSame;
    }];

    return result;
}

+ (NSString *)titleForStatus:(NSString *)status {
    if ([status isEqualToString:KLStatusPlanning]) return KLStr(@"status.planning");
    if ([status isEqualToString:KLStatusWatching]) return KLStr(@"status.watching");
    if ([status isEqualToString:KLStatusCompleted]) return KLStr(@"status.completed");
    if ([status isEqualToString:KLStatusDropped]) return KLStr(@"status.dropped");

    return KLStr(@"status.none");
}

@end
