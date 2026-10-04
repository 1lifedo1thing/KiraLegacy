#import "KLApi.h"

#import "KLStrings.h"

#import "KLAnime.h"
#import "KLEpisode.h"
#import "KLCustomProvider.h"
#import "KLHttp.h"
#import "KLJson.h"
#import "KLSettings.h"
#import "KLSource.h"

static NSString *const KLAniList = @"https://graphql.anilist.co";
static NSString *const KLWorker = @"https://meggaproxy-api.wholic794.workers.dev";

/**
 * Чем представляемся.
 *
 * Своё имя здесь не каприз. Без этого заголовка его подставляет CFNetwork,
 * и получается что-то вроде «KiraLegacy/1.0 CFNetwork/548.1.4 Darwin/11.0.0» —
 * строка, по которой видно возраст системы. Сегодня оба наших сервера
 * отвечают и на неё, и на пустой заголовок (проверено), но отбор по
 * User-Agent — первое, что включают, когда надоедают роботы, и оказаться
 * отброшенными за древность было бы обидно вдвойне: работает-то всё.
 *
 * Строка — обычный Safari с iOS 9, то есть ровно то, чем мы и являемся:
 * старым устройством Apple.
 */
static NSString *const KLUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 9_3 like Mac OS X) AppleWebKit/601.1 "
    @"(KHTML, like Gecko) Version/9.0 Mobile Safari/601.1";

/**
 * Сколько держать ответ каталога в памяти.
 *
 * AniList считает запросы — тридцать в минуту на адрес — и, перебрав,
 * отвечает 429 на всё подряд, включая то, что уже лежало бы в кеше.
 * Десять минут это ровно тот срок, за который лента не устареет, а возврат
 * из карточки на главный экран не превратится в четыре запроса подряд.
 */
static const NSTimeInterval KLCatalogTTL = 10 * 60;

/**
 * Набор полей, общий для всех лент.
 *
 * extraLarge просим не зря: обложка на этом экране бывает и в карточке
 * 110 точек шириной, и во весь экран баннером, а кеш обложек у нас один
 * на адрес — крупный кадр годится обоим, мелкий второму нет.
 */
static NSString *const KLMediaFields =
    @"id idMal title{english romaji} coverImage{extraLarge large medium} bannerImage "
    @"averageScore episodes format genres description(asHtml:false) startDate{year}";

@implementation KLApi

#pragma mark - Общее

/**
 * Экранирование для строки запроса.
 *
 * stringByAddingPercentEncodingWithAllowedCharacters — это iOS 7, а
 * stringByAddingPercentEscapesUsingEncoding при всей своей древности
 * не трогает &, = и +, то есть ровно то, что и надо экранировать в названии
 * вроде «Fate/stay night» или «Re:Zero». Поэтому CFURL, где набор
 * разрешённого задаётся явно.
 */
static NSString *KLEscape(NSString *value) {
    if ([value length] == 0) {
        return @"";
    }

    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(
        NULL,
        (__bridge CFStringRef)value,
        NULL,
        CFSTR("!*'();:@&=+$,/?%#[]"),
        kCFStringEncodingUTF8);

    if (escaped == NULL) {
        return @"";
    }

    NSString *result = [NSString stringWithString:(__bridge NSString *)escaped];
    CFRelease(escaped);

    return result;
}

/**
 * Обычный GET к разрешателю.
 *
 * ttl = 0 означает не «не класть в наш кеш на время», а «мимо всех кешей
 * вообще» — и второе приходится говорить отдельно. Кешей на пути два:
 * наш собственный, на который ttl и влияет, и дисковый NSURLCache внутри
 * KLHttp. Просьба «не кешировать» без правки политики запроса снимала бы
 * только первый, и ответ преспокойно приезжал бы со второго.
 *
 * Разница видна ровно на одном запросе, зато на важном: ключи источников
 * подписаны по времени, и вчерашний ключ плеер откроет разве что
 * сообщением об ошибке — неотличимым от сломанного зеркала.
 */
+ (id)workerGet:(NSString *)path ttl:(NSTimeInterval)ttl {
    NSString *url = [KLWorker stringByAppendingString:path];

    NSMutableURLRequest *request = KLRequest(url,
        ttl > 0 ? NSURLRequestUseProtocolCachePolicy
                : NSURLRequestReloadIgnoringLocalCacheData,
        ttl > 0 ? 25.0 : KLMirrorTimeout);

    if (request == nil) {
        return nil;
    }

    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:KLUserAgent forHTTPHeaderField:@"User-Agent"];

    KLHttpResponse *response = ttl > 0
        ? [KLHttp send:request bodyLimit:4 * 1024 * 1024 cacheForTTL:ttl]
        : [KLHttp send:request bodyLimit:4 * 1024 * 1024 caching:NO];

    if (![response isSuccessful]) {
        NSLog(@"[Кира/API] %@ → HTTP %ld %@", path, (long)response.statusCode,
              [response.error localizedDescription] ?: @"");
        return nil;
    }

    return [KLJson parseAny:response.body];
}

/**
 * Запрос к AniList с отступом при 429.
 *
 * Перебор лимита у AniList — не редкость, а обычный ход событий: главный
 * экран открывается четырьмя лентами сразу, и стоит пролистать пару карточек
 * туда-обратно, как счётчик кончается. Сервер при этом честно говорит
 * в Retry-After, сколько ждать, и ждать стоит: отказ показать ленту ради
 * экономии одной секунды — плохой размен.
 *
 * Попыток три, и это не «на всякий случай»: первый отступ обычно короткий
 * (секунда-другая), а вот если окно лимита только что закрылось, ждать
 * приходится до минуты — и тогда лучше сдаться и показать то, что уже
 * лежит в памяти, чем держать экран пустым.
 */
+ (NSDictionary *)graphql:(NSString *)query variables:(NSDictionary *)variables {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];

    [payload setObject:query forKey:@"query"];
    [payload setObject:(variables ?: [NSDictionary dictionary]) forKey:@"variables"];

    NSData *body = [KLJson encode:payload];

    for (NSInteger attempt = 0; attempt < 3; attempt++) {
        NSMutableURLRequest *request =
            KLRequest(KLAniList, NSURLRequestReloadIgnoringLocalCacheData, 25.0);

        if (request == nil) {
            return nil;
        }

        [request setHTTPMethod:@"POST"];
        [request setHTTPBody:body];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:KLUserAgent forHTTPHeaderField:@"User-Agent"];

        KLHttpResponse *response =
            [KLHttp send:request bodyLimit:4 * 1024 * 1024 cacheForTTL:KLCatalogTTL];

        if ([response isSuccessful]) {
            NSDictionary *json = [KLJson parse:response.body];
            NSDictionary *data = [KLJson objectIn:json key:@"data"];

            if (data != nil) {
                return data;
            }

            NSString *text = [response text];

            NSLog(@"[Кира/API] AniList ответил без data: %@",
                  [text substringToIndex:MIN((NSUInteger)200, [text length])]);
            return nil;
        }

        if (response.statusCode != 429) {
            NSLog(@"[Кира/API] AniList → HTTP %ld %@", (long)response.statusCode,
                  [response.error localizedDescription] ?: @"");
            return nil;
        }

        // Сервер сам говорит, сколько ждать; если промолчал — удваиваем
        // от секунды, как это делает веб-версия.
        NSString *retryAfter = [response.headers objectForKey:@"Retry-After"];
        NSTimeInterval wait = [retryAfter intValue];

        if (wait <= 0) {
            wait = 1 << (attempt + 1);
        }

        if (wait > 20) {
            NSLog(@"[Кира/API] AniList просит ждать %ld с — не ждём", (long)wait);
            return nil;
        }

        NSLog(@"[Кира/API] AniList 429, ждём %ld с", (long)wait);
        [NSThread sleepForTimeInterval:wait];
    }

    return nil;
}

/** Список media из ответа Page. */
+ (NSArray *)animeFromPage:(NSDictionary *)data {
    NSArray *media = [KLJson arrayIn:[KLJson objectIn:data key:@"Page"] key:@"media"];

    NSMutableArray *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < [media count]; i++) {
        KLAnime *anime = [KLAnime fromJson:[KLJson objectAt:media index:i]];

        if (anime != nil) {
            [result addObject:anime];
        }
    }

    return result;
}

#pragma mark - Каталог

+ (NSArray *)catalog:(NSString *)kind {
    NSString *filter;

    if ([kind isEqualToString:@"popular"]) {
        filter = @"sort:POPULARITY_DESC";
    } else if ([kind isEqualToString:@"movies"]) {
        // Порог оценки нужен: без него в «Фильмы» первыми лезут короткометражки
        // и концертные записи, у которых оценок почти нет, а сортировка
        // по SCORE_DESC ставит их наравне с настоящими полнометражками.
        filter = @"format:MOVIE,sort:SCORE_DESC,averageScore_greater:55";
    } else if ([kind isEqualToString:@"series"]) {
        filter = @"format:TV,sort:SCORE_DESC,averageScore_greater:60";
    } else {
        filter = @"sort:TRENDING_DESC";
    }

    NSString *query = [NSString stringWithFormat:
        @"query{Page(page:1,perPage:20){media(type:ANIME,isAdult:false,%@){%@}}}",
        filter, KLMediaFields];

    return [self animeFromPage:[self graphql:query variables:nil]];
}

+ (NSArray *)search:(NSString *)query {
    if ([query length] == 0) {
        return [NSArray array];
    }

    NSString *gql = [NSString stringWithFormat:
        @"query($q:String){Page(page:1,perPage:30)"
        @"{media(type:ANIME,search:$q,isAdult:false){%@}}}", KLMediaFields];

    NSDictionary *variables = [NSDictionary dictionaryWithObject:query forKey:@"q"];

    return [self animeFromPage:[self graphql:gql variables:variables]];
}

+ (KLAnime *)details:(NSInteger)anilistId {
    if (anilistId <= 0) {
        return nil;
    }

    NSString *gql = [NSString stringWithFormat:
        @"query($id:Int){Media(id:$id,type:ANIME){%@ duration status "
        @"nextAiringEpisode{episode timeUntilAiring} "
        @"characters(sort:ROLE,perPage:12){edges{role "
        @"node{name{full} image{large}} "
        @"voiceActors(language:JAPANESE){name{full}}}}}}", KLMediaFields];

    NSDictionary *variables = [NSDictionary dictionaryWithObject:
        [NSNumber numberWithInteger:anilistId] forKey:@"id"];

    NSDictionary *data = [self graphql:gql variables:variables];

    return [KLAnime fromJson:[KLJson objectIn:data key:@"Media"]];
}

#pragma mark - Источники

+ (NSString *)slugForTitle:(NSString *)title anilistId:(NSInteger)anilistId {
    if ([title length] == 0) {
        return nil;
    }

    NSMutableString *path = [NSMutableString stringWithFormat:
        @"/slug?title=%@", KLEscape(title)];

    // Подсказка по идентификатору: разрешатель ищет по названию, и на тайтлах
    // вроде «Одного игрока» с полудюжиной сезонов одно название даёт
    // несколько попаданий. С aniId он выбирает тот, о котором мы спрашиваем.
    if (anilistId > 0) {
        [path appendFormat:@"&aniId=%ld", (long)anilistId];
    }

    // Slug у тайтла не меняется, а карточку открывают и закрывают по многу
    // раз — час в памяти избавляет от запроса на каждое открытие.
    NSDictionary *json = [self workerGet:path ttl:3600];

    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *slug = [KLJson textIn:json key:@"slug"];

    if (slug == nil) {
        NSLog(@"[Кира/API] Зеркала не знают тайтла «%@»", title);
    }

    return slug;
}

+ (NSArray *)episodesForSlug:(NSString *)slug {
    if ([slug length] == 0) {
        return [NSArray array];
    }

    id json = [self workerGet:[NSString stringWithFormat:@"/episodes?slug=%@",
                               KLEscape(slug)]
                          ttl:600];

    /**
     * Список приходит голым массивом — но не всегда.
     *
     * Обычный ответ это просто [...], однако у части тайтлов разрешатель
     * заворачивает его в объект с полем episodes или data. Веб-версия
     * проверяет оба варианта, и мы тоже: разница между «серий нет» и
     * «серии в обёртке» снаружи неотличима, а стоит она всего списка.
     */
    NSArray *list = nil;

    if ([json isKindOfClass:[NSArray class]]) {
        list = json;
    } else if ([json isKindOfClass:[NSDictionary class]]) {
        list = [KLJson arrayIn:json key:@"episodes"] ?: [KLJson arrayIn:json key:@"data"];
    }

    NSMutableArray *episodes = [NSMutableArray array];

    for (NSUInteger i = 0; i < [list count]; i++) {
        KLEpisode *episode = [KLEpisode fromJson:[KLJson objectAt:list index:i]];

        if (episode != nil) {
            [episodes addObject:episode];
        }
    }

    return episodes;
}

#pragma mark - Источники: зеркала

/**
 * Расшифровка ответа vidnest.
 *
 * Это обычный base64, но с переставленным алфавитом — подстановочный шифр
 * поверх кодировки, не более того. Таблица взята из веб-версии Киры, там же,
 * где и сами адреса зеркал.
 *
 * Считать тут нечего: сотня-другая байт на серию. Ровно поэтому расшифровка
 * и делается на устройстве, хотя всё остальное про зеркала мы у себя
 * не разбираем.
 */
static NSDictionary *KLVidnestDecrypt(NSString *cipher) {
    static const char *alphabet =
        "RB0fpH8ZEyVLkv7c2i6MAJ5u3IKFDxlS1NTsnGaqmXYdUrtzjwObCgQP94hoeW+/=";

    static uint8_t table[128];
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        memset(table, 64, sizeof(table));

        for (uint8_t i = 0; alphabet[i] != 0; i++) {
            table[(uint8_t)alphabet[i]] = i;
        }
    });

    if ([cipher length] == 0) {
        return nil;
    }

    NSData *ascii = [cipher dataUsingEncoding:NSASCIIStringEncoding];
    const uint8_t *text = [ascii bytes];
    NSUInteger length = [ascii length];

    NSMutableData *out = [NSMutableData dataWithCapacity:length * 3 / 4 + 4];

    for (NSUInteger i = 0; i < length; i += 4) {
        uint8_t d[4] = {64, 64, 64, 64};

        for (NSUInteger j = 0; j < 4 && i + j < length; j++) {
            uint8_t c = text[i + j];
            d[j] = c < 128 ? table[c] : 64;
        }

        uint8_t byte = (uint8_t)((d[0] << 2) | (d[1] >> 4));
        [out appendBytes:&byte length:1];

        if (d[2] != 64) {
            byte = (uint8_t)(((d[1] & 15) << 4) | (d[2] >> 2));
            [out appendBytes:&byte length:1];
        }

        if (d[3] != 64) {
            byte = (uint8_t)(((d[2] & 3) << 6) | d[3]);
            [out appendBytes:&byte length:1];
        }
    }

    return [KLJson parse:out];
}

/**
 * Сколько ждём ответа от зеркала.
 *
 * Двадцать пять секунд, стоявшие здесь раньше, — срок для того, от кого
 * ответа ждут во что бы то ни стало. Зеркало не таково: их семь, и молчащее
 * просто не попадёт в список. Зато его молчание раньше растягивало весь
 * опрос: в журнале с устройства между двумя обращениями к megavid.buzz
 * стоит ровно двадцать пять секунд тишины — это одна ссылка, ушедшая
 * в никуда, держала очередь.
 *
 * Восемь секунд — с большим запасом: живое зеркало отвечает за полсекунды
 * даже с iPad 2.
 */
static const NSTimeInterval KLMirrorTimeout = 8.0;

/**
 * Сколько ждём отставших после того, как ответило первое зеркало.
 *
 * Замеры по каждому зеркалу отдельно, два прохода подряд:
 *
 *     HiAnime          0,8 с    0,8 с
 *     AniWave          2,4 с    0,9 с
 *     AnimeHub         2,3 с    0,8 с
 *     Megavid AniWave  8,8 с    0,8 с
 *     Megavid Ani      8,8 с    0,8 с
 *     Megavid по MAL   не отвечает вовсе
 *
 * Разброс не в десятых долях, а в разы, и один маршрут не отвечает никогда:
 * ждать всех означает ждать самого медленного, а при мёртвом маршруте —
 * всегда упираться в потолок. Опрос разом эту беду не лечит, он лишь
 * складывает её из суммы в максимум.
 *
 * Поэтому ждём не всех, а до тех пор, пока это осмысленно: как только
 * ответило хоть одно живое зеркало, у остальных есть две с половиной
 * секунды, чтобы успеть. По замерам в это окно укладывается всё, что вообще
 * отвечает, — и с запасом, когда зеркало прогрето.
 *
 * Отсчёт идёт от первого ответа, а не от начала: отсчитывать от начала
 * значило бы наказывать за медленную сеть, где и первый ответ приходит
 * не сразу.
 */
static const NSTimeInterval KLMirrorPatience = 2.5;

/** Запрос к зеркалу: свои Referer и Origin, мимо всех кешей. */
+ (KLHttpResponse *)fetch:(NSString *)url
                  referer:(NSString *)referer
                   origin:(NSString *)origin {
    NSMutableURLRequest *request =
        KLRequest(url, NSURLRequestReloadIgnoringLocalCacheData, KLMirrorTimeout);

    if (request == nil) {
        return nil;
    }

    [request setValue:KLUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];

    if (referer != nil) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }

    if (origin != nil) {
        [request setValue:origin forHTTPHeaderField:@"Origin"];
    }

    // Ключи и ссылки зеркал подписаны по времени — кешировать их нельзя
    // ни на секунду: вчерашний ответ откроется разве что сообщением
    // об ошибке, неотличимым от сломанного зеркала.
    return [KLHttp send:request bodyLimit:2 * 1024 * 1024 caching:NO];
}

/** Дорожки субтитров из массива tracks, как его отдают зеркала. */
+ (NSArray *)subtitlesFrom:(NSArray *)tracks {
    NSMutableArray *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < [tracks count]; i++) {
        NSDictionary *item = [KLJson objectAt:tracks index:i];

        NSString *file = [KLJson textIn:item key:@"file"];
        if (file == nil) {
            continue;
        }

        /**
         * В том же массиве приходит и раскадровка для полосы перемотки —
         * kind у неё «thumbnails». Как субтитры она не откроется, поэтому
         * пропускаем всё, что не подписано субтитрами.
         *
         * Отсутствующий kind считаем субтитрами: часть зеркал его не ставит
         * вовсе, а кроме субтитров ничего не присылает.
         */
        NSString *kind = [KLJson textIn:item key:@"kind"];

        if (kind != nil &&
            [kind rangeOfString:@"caption"].location == NSNotFound &&
            [kind rangeOfString:@"subtitle"].location == NSNotFound) {
            continue;
        }

        KLSubtitleTrack *track = [[KLSubtitleTrack alloc] init];

        track.url = file;
        track.label = [KLJson textIn:item key:@"label"] ?: KLStr(@"subtitle.default");
        track.isDefault = [KLJson boolIn:item key:@"default"];

        [result addObject:track];
    }

    return result;
}

/**
 * Зеркала vidnest: HiAnime, AniWave, AnimeHub.
 *
 * Лучшие из всех. HiAnime отдаёт мастер-плейлист с 1080p, 720p и 360p —
 * то есть даёт из чего выбирать и на слабом железе, — и вместе с ним
 * дорожку субтитров и границы заставки.
 *
 * Ответ приходит зашифрованным (см. KLVidnestDecrypt), но бывает и открытым:
 * признак encrypted они ставят не всегда, поэтому смотрим не на него,
 * а на то, есть ли в ответе поле data.
 */
+ (KLSource *)vidnest:(NSString *)route
            anilistId:(NSInteger)anilistId
              episode:(NSInteger)episode
                 kind:(NSString *)kind
                label:(NSString *)label {
    if (anilistId <= 0) {
        return nil;
    }

    NSString *url = [route isEqualToString:@"hianime"]
        ? [NSString stringWithFormat:@"https://new.vidnest.fun/hianime/anime/%ld/%ld/%@/hd-2",
           (long)anilistId, (long)episode, kind]
        : [NSString stringWithFormat:@"https://new.vidnest.fun/%@/%ld/%ld/%@",
           route, (long)anilistId, (long)episode, kind];

    KLHttpResponse *response = [self fetch:url referer:@"https://vidnest.fun/" origin:nil];

    if (![response isSuccessful]) {
        return nil;
    }

    NSDictionary *json = [KLJson parse:response.body];
    NSString *packed = [KLJson textIn:json key:@"data"];
    NSDictionary *data = packed != nil ? KLVidnestDecrypt(packed) : json;

    NSDictionary *first = [KLJson objectAt:[KLJson arrayIn:data key:@"sources"] index:0];

    // Поле называется то file, то url — зависит от зеркала.
    NSString *stream = [KLJson textIn:first key:@"file"] ?: [KLJson textIn:first key:@"url"];

    if (stream == nil) {
        return nil;
    }

    KLSource *source = [[KLSource alloc] init];

    source.label = label;
    source.kind = kind;
    source.url = stream;

    // Сегменты лежат на стороннем CDN, и тот проверяет Referer: без него
    // приходит 403 при совершенно правильной ссылке.
    source.referer = @"https://megaplay.buzz/";
    source.subtitles = [self subtitlesFrom:[KLJson arrayIn:data key:@"tracks"]];

    NSDictionary *intro = [KLJson objectIn:data key:@"intro"];

    source.introStart = [KLJson intIn:intro key:@"start"];
    source.introEnd = [KLJson intIn:intro key:@"end"];

    return source;
}

/**
 * Megavid: три маршрута к одному хранилищу.
 *
 * Отдаёт открытый JSON с прямой ссылкой — расшифровывать нечего. Маршруты
 * различаются только тем, каким идентификатором искать: /mal по
 * MyAnimeList, два остальных по AniList.
 */
+ (KLSource *)megavid:(NSString *)path
              episode:(NSInteger)episode
                 kind:(NSString *)kind
                label:(NSString *)label {
    NSString *url = [NSString stringWithFormat:@"https://megavid.buzz/%@/%ld/%@/source",
                     path, (long)episode, kind];

    KLHttpResponse *response = [self fetch:url
                                   referer:@"https://megavid.buzz/"
                                    origin:@"https://megavid.buzz"];

    if (![response isSuccessful]) {
        return nil;
    }

    NSDictionary *json = [KLJson parse:response.body];
    NSString *stream = [KLJson textIn:json key:@"source"];

    if (stream == nil) {
        return nil;
    }

    /**
     * Мастер у Megavid подменяется на первую дорожку.
     *
     * Ровно то же делает веб-версия: по адресу master.m3u8 их CDN отвечает
     * не всегда, а index-f1-v1-a1.m3u8 — та же запись первой дорожкой —
     * отдаётся исправно.
     */
    if ([stream rangeOfString:@"master.m3u8"].location != NSNotFound) {
        stream = [stream stringByReplacingOccurrencesOfString:@"master.m3u8"
                                                   withString:@"index-f1-v1-a1.m3u8"];
    }

    KLSource *source = [[KLSource alloc] init];

    source.label = label;
    source.kind = kind;
    source.url = stream;
    source.referer = @"https://megavid.buzz/";
    source.subtitles = [self subtitlesFrom:[KLJson arrayIn:json key:@"tracks"]];

    return source;
}

/** Разрешатель на Cloudflare — последний запасной ход. */
+ (KLSource *)resolver:(NSString *)slug
               episode:(NSInteger)episode
                  kind:(NSString *)kind {
    if ([slug length] == 0) {
        return nil;
    }

    NSString *path = [NSString stringWithFormat:@"/sources?slug=%@&ep=%ld&lang=%@",
                      KLEscape(slug), (long)episode, kind];

    NSDictionary *json = [self workerGet:path ttl:0];
    NSDictionary *first = [KLJson objectAt:[KLJson arrayIn:json key:@"all"] index:0];

    NSString *encoded = [KLJson textIn:first key:@"url"];

    if (encoded == nil) {
        return nil;
    }

    KLSource *source = [[KLSource alloc] init];

    source.label = [KLJson textIn:first key:@"quality"] ?: KLStr(@"source.resolver");
    source.kind = kind;
    source.encoded = encoded;
    source.subtitles = [NSArray array];

    return source;
}

+ (NSArray *)sourcesForAnilistId:(NSInteger)anilistId
                           malId:(NSInteger)malId
                            slug:(NSString *)slug
                         episode:(NSInteger)episode
                            kind:(NSString *)kind {
    if (episode <= 0) {
        return [NSArray array];
    }

    NSString *lang = [kind isEqualToString:@"dub"] ? @"dub" : @"sub";

    /**
     * Порядок — по убыванию пригодности, а не по алфавиту.
     *
     * HiAnime первым потому, что только он отдаёт мастер-плейлист с тремя
     * качествами и дорожку субтитров: на слабом устройстве это разница между
     * «идёт» и «рвётся», а субтитры больше взять негде.
     *
     * Разрешатель на Cloudflare последним потому, что он не даёт ни того,
     * ни другого — одну дорожку 1080p и никаких субтитров. Совсем убрать
     * его нельзя: бывает, что живой остаётся только эта ссылка.
     *
     * Спрашиваются все, а не до первого удачного: выбор источника
     * показывается человеку, и знать, что есть ещё три, полезно ровно тогда,
     * когда первый не открылся.
     */
    NSMutableArray *asking = [NSMutableArray array];

    [asking addObject:[^KLSource *{
        return [self vidnest:@"hianime" anilistId:anilistId episode:episode
                        kind:lang label:@"HiAnime"];
    } copy]];

    [asking addObject:[^KLSource *{
        return [self vidnest:@"aniwave_hls" anilistId:anilistId episode:episode
                        kind:lang label:@"AniWave"];
    } copy]];

    [asking addObject:[^KLSource *{
        return [self vidnest:@"animehub" anilistId:anilistId episode:episode
                        kind:lang label:@"AnimeHub"];
    } copy]];

    if (malId > 0) {
        [asking addObject:[^KLSource *{
            return [self megavid:[NSString stringWithFormat:@"mal/%ld", (long)malId]
                         episode:episode kind:lang label:@"Megavid"];
        } copy]];
    }

    if (anilistId > 0) {
        [asking addObject:[^KLSource *{
            return [self megavid:[NSString stringWithFormat:@"aniwave/al/%ld", (long)anilistId]
                         episode:episode kind:lang label:@"Megavid AniWave"];
        } copy]];

        [asking addObject:[^KLSource *{
            return [self megavid:[NSString stringWithFormat:@"ani/%ld", (long)anilistId]
                         episode:episode kind:lang label:@"Megavid Ani"];
        } copy]];
    }

    [asking addObject:[^KLSource *{
        return [self resolver:slug episode:episode kind:lang];
    } copy]];

    /**
     * Свои источники — в конце списка, но в том же опросе.
     *
     * В конце, а не в начале: штатные зеркала, когда они живы, дают больше —
     * мастер-плейлист с лестницей качеств и дорожку субтитров. Пока они
     * отвечают, порядок ни на что не влияет, а когда перестанут — их в списке
     * просто не будет, и свои окажутся первыми сами собой.
     *
     * Кому нужно наоборот, тот назначает свой источник умолчанием в
     * настройках: там свои источники стоят в общем списке, и выбор
     * по имени имеет силу над порядком.
     */
    NSArray *mine = [KLSettings enabledCustomSources];

    for (KLCustomSource *entry in mine) {
        [asking addObject:[^KLSource *{
            return [KLCustomProvider sourceFromEntry:entry
                                           anilistId:anilistId
                                               malId:malId
                                             episode:episode
                                                kind:lang];
        } copy]];
    }

    /**
     * Спрашиваем всех разом, а не по очереди.
     *
     * По очереди выходило около десяти секунд, и складывались они не из
     * работы, а из ожидания: семь походов подряд, каждый со своим
     * рукопожатием, и любой запнувшийся добавлял к общему сроку весь свой.
     * Зеркала друг от друга не зависят вовсе — ни одно не нужно, чтобы
     * спросить следующее, — так что очередь тут была не необходимостью,
     * а просто тем, как написалось.
     *
     * Теперь общее время равно времени самого медленного, а не сумме всех.
     * Порядок при этом сохраняется: ответы складываются по своим местам
     * в заранее размеченный список, а не по мере прихода. Порядок здесь
     * не украшение — это и есть «по убыванию пригодности», и первым
     * в списке человек должен видеть HiAnime, кто бы ни ответил быстрее.
     */
    NSUInteger count = [asking count];
    NSMutableArray *answers = [NSMutableArray arrayWithCapacity:count];

    for (NSUInteger i = 0; i < count; i++) {
        [answers addObject:[NSNull null]];
    }

    __block NSUInteger answered = 0;

    dispatch_semaphore_t reported = dispatch_semaphore_create(0);
    dispatch_queue_t queue =
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    for (NSUInteger i = 0; i < count; i++) {
        KLSource *(^ask)(void) = [asking objectAtIndex:i];

        dispatch_async(queue, ^{
            @autoreleasepool {
                KLSource *answer = ask();

                // Места у каждого своё, но список один — замок нужен:
                // NSMutableArray к одновременной записи не готов.
                @synchronized (answers) {
                    if (answer != nil) {
                        [answers replaceObjectAtIndex:i withObject:answer];
                        answered++;
                    }
                }

                // Считаем всех вернувшихся, и с ответом, и без: ждём мы
                // не ответов, а окончания походов.
                dispatch_semaphore_signal(reported);
            }
        });
    }

    /**
     * Ждём до тех пор, пока ожидание осмысленно, — см. KLMirrorPatience.
     *
     * Отставшие при этом не бросаются и не отменяются: они досчитают
     * своё и молча запишут ответ в список, которого мы уже не прочтём.
     * Отменять их было бы правильнее, но дороже: пришлось бы протаскивать
     * признак отмены через весь путь до сокета, а выигрыш — несколько
     * секунд работы двух фоновых потоков, которые всё равно упрутся
     * в свой срок.
     */
    NSDate *started = [NSDate date];
    NSDate *hard = [NSDate dateWithTimeIntervalSinceNow:KLMirrorTimeout + 1.0];
    NSDate *patience = nil;

    NSUInteger returned = 0;

    while (returned < count) {
        NSTimeInterval left = [hard timeIntervalSinceNow];

        if (patience != nil) {
            left = MIN(left, [patience timeIntervalSinceNow]);
        }

        if (left <= 0) {
            break;
        }

        if (dispatch_semaphore_wait(reported,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC))) != 0) {
            break;
        }

        returned++;

        if (patience != nil) {
            continue;
        }

        BOOL haveOne;

        @synchronized (answers) {
            haveOne = answered > 0;
        }

        if (haveOne) {
            patience = [NSDate dateWithTimeIntervalSinceNow:KLMirrorPatience];
        }
    }

    NSMutableArray *found = [NSMutableArray arrayWithCapacity:count];

    @synchronized (answers) {
        for (id answer in answers) {
            if (answer != [NSNull null]) {
                [found addObject:answer];
            }
        }
    }

    NSLog(@"[Кира/API] Серия %ld (%@): зеркал найдено %lu из %lu за %.1f с",
          (long)episode, lang, (unsigned long)[found count],
          (unsigned long)count, -[started timeIntervalSinceNow]);

    return found;
}

+ (NSString *)playlistUrlForSource:(KLSource *)source {
    // Прямая ссылка — у всех зеркал, кроме разрешателя: тот прямой
    // не даёт вовсе, у него только непрозрачный ключ.
    if ([source.url length] > 0) {
        return source.url;
    }

    if ([source.encoded length] == 0) {
        return nil;
    }

    return [NSString stringWithFormat:@"%@/m3u8?encoded=%@", KLWorker, KLEscape(source.encoded)];
}

@end
