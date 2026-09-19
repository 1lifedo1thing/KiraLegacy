#import <Foundation/Foundation.h>

/**
 * Серия так, как её описывает разрешатель источников.
 *
 * Список серий приходит не от AniList: тот знает только их количество, а
 * названия и кадры лежат у разрешателя — он сводит воедино thetvdb и
 * собственную разметку зеркал. Оттого и номер здесь сквозной (number),
 * и отдельно номер внутри сезона: у длинных сериалов вроде «Наруто» первое
 * доходит до нескольких сотен, а второе начинается заново каждый сезон.
 */
@interface KLEpisode : NSObject

/** Сквозной номер — им и адресуется запрос источников. */
@property (nonatomic, assign) NSInteger number;

@property (nonatomic, assign) NSInteger seasonNumber;
@property (nonatomic, copy) NSString *seasonName;

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *overview;
@property (nonatomic, copy) NSString *imageUrl;

+ (KLEpisode *)fromJson:(NSDictionary *)json;

/** «Серия 12» либо «Серия 12 — Название». */
- (NSString *)displayTitle;

@end
