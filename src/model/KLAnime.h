#import <Foundation/Foundation.h>

/** Персонаж и тот, кто его озвучивает. Показывается только в карточке. */
@interface KLCastMember : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *imageUrl;
@property (nonatomic, copy) NSString *actor;
@property (nonatomic, copy) NSString *role;

@end


/**
 * Сериал или фильм — то, что каталог AniList зовёт Media.
 *
 * Идентификаторов здесь два, и оба нужны: зеркала ищут тайтл по разным.
 * HiAnime, AniWave и AnimeHub — по AniList, Megavid — по MyAnimeList,
 * а разрешатель на Cloudflare по своему slug, который сам же и выдаёт
 * по названию.
 */
@interface KLAnime : NSObject

@property (nonatomic, assign) NSInteger anilistId;

/**
 * Идентификатор MyAnimeList; 0, если AniList его не знает.
 *
 * Нужен зеркалам Megavid: их маршрут /mal ищет только по нему. Остальные
 * зеркала обходятся идентификатором AniList, но Megavid по нему находит
 * не всё, и без idMal часть тайтлов теряла бы один источник из четырёх.
 */
@property (nonatomic, assign) NSInteger malId;

/** Английское, если есть; иначе romaji. То, что видно в карточке. */
@property (nonatomic, copy) NSString *title;

/** Romaji — по нему разрешатель ищет лучше, чем по английскому. */
@property (nonatomic, copy) NSString *romajiTitle;

@property (nonatomic, copy) NSString *coverUrl;
@property (nonatomic, copy) NSString *bannerUrl;

/** Оценка в сотых долях, как её отдаёт AniList: 84 значит 8,4. 0 — нет. */
@property (nonatomic, assign) NSInteger score;

@property (nonatomic, assign) NSInteger episodeCount;
@property (nonatomic, assign) NSInteger year;

/** TV, MOVIE, OVA, ONA, SPECIAL — как пришло. */
@property (nonatomic, copy) NSString *format;

@property (nonatomic, strong) NSArray *genres;
@property (nonatomic, copy) NSString *synopsis;

#pragma mark Только в карточке

/** Длительность серии в минутах; 0 — не сказано. */
@property (nonatomic, assign) NSInteger duration;

/** RELEASING, FINISHED, NOT_YET_RELEASED. */
@property (nonatomic, copy) NSString *status;

/** Номер следующей серии и сколько до неё секунд; оба 0 — ничего не ждём. */
@property (nonatomic, assign) NSInteger nextEpisode;
@property (nonatomic, assign) NSInteger nextEpisodeIn;

/** KLCastMember. */
@property (nonatomic, strong) NSArray *cast;

/** Разбор одного элемента media из ответа AniList. */
+ (KLAnime *)fromJson:(NSDictionary *)json;

/** «8.4» либо nil, если оценки нет. */
- (NSString *)scoreText;

/** «TV · 2002 · 220 серий» — строка под названием. */
- (NSString *)metaText;

/** Что показать в строке жанров: три первых через точку. */
- (NSString *)genresText;

@end
