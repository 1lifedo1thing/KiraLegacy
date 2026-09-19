#import <Foundation/Foundation.h>

#import "KLHttp.h"

/**
 * Дисковый кеш ответов — взамен NSURLCache.
 *
 * Понадобился ровно потому, что своих ответов у системы больше нет:
 * запросы идут через KLHttpClient, а NSURLCache обслуживает только
 * NSURLConnection. Без замены обложки качались бы заново при каждом
 * запуске, а их на главном экране под сотню.
 *
 * Кладём только то, что сервер разрешил держать, и ровно на тот срок,
 * который он назвал в Cache-Control. Своих сроков не выдумываем:
 * обложки AniList отдаются с max-age на год и не меняются никогда,
 * а ответы каталога приходят с no-store — и правильно, ленты обновляются.
 */
@interface KLDiskCache : NSObject

/** Ответ из кеша, если он там есть и ещё не протух. */
+ (KLHttpResponse *)responseForUrl:(NSString *)url;

/** Кладёт ответ, если сервер это разрешил. Иначе не делает ничего. */
+ (void)store:(KLHttpResponse *)response forUrl:(NSString *)url;

/** Сколько места занято, байт — для экрана настроек. */
+ (unsigned long long)size;

+ (void)clear;

@end
