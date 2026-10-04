#import "KLCustomProvider.h"

#import "KLHttp.h"
#import "KLJson.h"
#import "KLSource.h"
#import "KLStrings.h"

/**
 * Сколько ждём пользовательский источник.
 *
 * Столько же, сколько штатное зеркало: он встаёт в общий опрос, а общий
 * опрос ждёт не дольше KLMirrorTimeout. Более долгий срок здесь означал бы
 * не терпение, а молчание всего списка из-за одного адреса.
 */
static const NSTimeInterval KLCustomTimeout = 8.0;

/**
 * Потолок на тело ответа.
 *
 * Два мегабайта — это уже неприлично много для ответа, в котором нужна одна
 * строка, но ровно столько берут штатные зеркала, и брать меньше нельзя:
 * чужой сервис вправе отдать список серий целиком.
 */
static const NSUInteger KLCustomBodyLimit = 2 * 1024 * 1024;

static NSString *const KLCustomUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 9_3 like Mac OS X) AppleWebKit/601.1 "
    @"(KHTML, like Gecko) Version/9.0 Mobile Safari/601.1";

@interface KLCustomProvider ()

/** Объявлен здесь, потому что зовётся выше, чем написан. */
+ (NSString *)verdictForPlaylist:(NSString *)text;

@end


/** Обычный GET к пользовательскому адресу. */
static KLHttpResponse *KLCustomGet(NSString *url, NSString *referer) {
    NSMutableURLRequest *request = KLRequest(url, NSURLRequestReloadIgnoringLocalCacheData,
                                             KLCustomTimeout);

    if (request == nil) {
        return nil;
    }

    [request setValue:@"application/json, application/vnd.apple.mpegurl, */*"
   forHTTPHeaderField:@"Accept"];
    [request setValue:KLCustomUserAgent forHTTPHeaderField:@"User-Agent"];

    if ([referer length] > 0) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }

    // Мимо кеша: у источников бывают ссылки, подписанные по времени,
    // и вчерашняя откроется разве что сообщением об ошибке.
    return [KLHttp send:request bodyLimit:KLCustomBodyLimit caching:NO];
}

#pragma mark - Разбор ответа

/** Значение по имени поля; отсутствие ключа и null — одно и то же. */
static id KLCustomValueForKey(id parent, NSString *key) {
    if (![parent isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    id value = [(NSDictionary *)parent objectForKey:key];

    return value == [NSNull null] ? nil : value;
}

/** Значение по номеру в массиве. */
static id KLCustomValueAt(id parent, NSInteger index) {
    if (![parent isKindOfClass:[NSArray class]]) {
        return nil;
    }

    if (index < 0 || index >= (NSInteger)[(NSArray *)parent count]) {
        return nil;
    }

    id value = [(NSArray *)parent objectAtIndex:(NSUInteger)index];

    return value == [NSNull null] ? nil : value;
}

/**
 * Значение по пути вида «sources[0].file».
 *
 * Разбор свой, а не через valueForKeyPath, и это не изобретательство ради
 * изобретательства: valueForKeyPath понимает точку как разделитель и падает
 * исключением на «sources[0]» — там, где у нас стоит индекс. Ловить
 * исключение на разборе чужого ответа — плохой способ разговаривать с сетью.
 *
 * Заодно путь разбирается целиком до конца: часть сервисов отдаёт ссылку
 * в поле с другим именем, а не в другом месте.
 */
static id KLCustomValueAtPath(id root, NSString *path) {
    if ([path length] == 0) {
        return nil;
    }

    id current = root;

    for (NSString *raw in [path componentsSeparatedByString:@"."]) {
        NSString *part = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([part length] == 0) {
            continue;
        }

        while ([part length] > 0) {
            NSRange open = [part rangeOfString:@"["];

            // До первой скобки — имя поля, дальше только номера.
            if (open.location == NSNotFound) {
                current = KLCustomValueForKey(current, part);
                break;
            }

            if (open.location > 0) {
                current =
                    KLCustomValueForKey(current, [part substringToIndex:open.location]);
            }

            NSRange tail = NSMakeRange(open.location, [part length] - open.location);
            NSRange close = [part rangeOfString:@"]" options:0 range:tail];

            if (close.location == NSNotFound) {
                return nil;
            }

            NSString *number = [part substringWithRange:
                NSMakeRange(open.location + 1, close.location - open.location - 1)];

            current = KLCustomValueAt(current, [number integerValue]);
            part = [part substringFromIndex:close.location + 1];
        }

        if (current == nil) {
            return nil;
        }
    }

    return current;
}

/**
 * Ссылка из найденного значения.
 *
 * Три случая, и все три встречаются:
 *
 *   строка — сам адрес;
 *   словарь — адрес лежит внутри, и имя поля у разных сервисов разное,
 *             поэтому смотрим самые частые;
 *   число — не ссылка, но пусть будет строкой: так это увидит проверка
 *             и назовёт вслух, вместо молчаливого «источника нет».
 */
static NSString *KLCustomLinkFrom(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in [NSArray arrayWithObjects:@"file", @"url", @"source",
                                                        @"link", @"src", nil]) {
            NSString *found = KLCustomLinkFrom(KLCustomValueForKey(value, key));

            if ([found length] > 0) {
                return found;
            }
        }
    }

    return nil;
}

/** Абсолютный адрес из относительного: «/x/y.m3u8» против адреса запроса. */
static NSString *KLCustomAbsolute(NSString *link, NSString *base) {
    if ([link length] == 0) {
        return nil;
    }

    if ([link rangeOfString:@"://"].location != NSNotFound) {
        return link;
    }

    NSRange scheme = [base rangeOfString:@"://"];

    if (scheme.location == NSNotFound) {
        return link;
    }

    NSUInteger afterScheme = scheme.location + scheme.length;
    NSRange slash = [base rangeOfString:@"/"
                                options:0
                                  range:NSMakeRange(afterScheme, [base length] - afterScheme)];

    NSString *host = slash.location == NSNotFound ? base : [base substringToIndex:slash.location];

    return [link hasPrefix:@"/"] ? [host stringByAppendingString:link]
                                 : [host stringByAppendingFormat:@"/%@", link];
}

/** Похоже ли тело на плейлист HLS. */
static BOOL KLCustomLooksLikePlaylist(NSString *text) {
    return [text rangeOfString:@"#EXTM3U"].location != NSNotFound;
}

/** Сколько в плейлисте сегментов; у мастера их нет вовсе. */
static NSUInteger KLCustomSegmentCount(NSString *text) {
    NSUInteger count = 0;
    NSRange search = NSMakeRange(0, [text length]);

    while (search.length > 0) {
        NSRange found = [text rangeOfString:@"#EXTINF" options:0 range:search];

        if (found.location == NSNotFound) {
            break;
        }

        count++;

        NSUInteger next = found.location + found.length;
        search = NSMakeRange(next, [text length] - next);
    }

    return count;
}

@implementation KLCustomProvider

#pragma mark - Получение источника

+ (KLSource *)sourceFromEntry:(KLCustomSource *)entry
                    anilistId:(NSInteger)anilistId
                        malId:(NSInteger)malId
                      episode:(NSInteger)episode
                         kind:(NSString *)kind {
    if (entry == nil || ![entry enabled] || episode <= 0) {
        return nil;
    }

    NSString *lang = [kind isEqualToString:@"dub"] ? @"dub" : @"sub";

    NSString *address = [entry addressForAnilistId:anilistId
                                             malId:malId
                                           episode:episode
                                              kind:lang];

    if ([address length] == 0) {
        return nil;
    }

    KLSource *source = [[KLSource alloc] init];

    source.label = [entry name];
    source.kind = lang;
    source.referer = [entry referer];
    source.subtitles = [NSArray array];

    // Прямой вид ничего не спрашивает: адрес и есть ссылка на плейлист.
    if ([entry kind] == KLCustomKindDirect) {
        source.url = address;

        return source;
    }

    KLHttpResponse *response = KLCustomGet(address, [entry referer]);

    if (![response isSuccessful]) {
        NSLog(@"[Кира/Свои] %@ → HTTP %ld", [entry name],
              (long)[response statusCode]);
        return nil;
    }

    // Верхним уровнем бывает и массив — потому parseAny, а не parse.
    id json = [KLJson parseAny:[response body]];
    NSString *link = KLCustomLinkFrom(KLCustomValueAtPath(json, [entry fieldPath]));

    if ([link length] == 0) {
        NSLog(@"[Кира/Свои] %@: поле «%@» не нашлось", [entry name], [entry fieldPath]);
        return nil;
    }

    source.url = KLCustomAbsolute(link, address);

    NSLog(@"[Кира/Свои] %@: %@", [entry name], [source url]);

    return source;
}

#pragma mark - Проверка

+ (NSString *)checkEntry:(KLCustomSource *)entry
               anilistId:(NSInteger)anilistId
                   malId:(NSInteger)malId
                 episode:(NSInteger)episode
                    kind:(NSString *)kind {
    NSMutableArray *report = [NSMutableArray array];

    NSString *lang = [kind isEqualToString:@"dub"] ? @"dub" : @"sub";
    NSString *address = [entry addressForAnilistId:anilistId
                                             malId:malId
                                           episode:episode
                                              kind:lang];

    [report addObject:KLFmt(@"custom.check.address", address ?: @"—")];

    if ([address length] == 0) {
        return [report componentsJoinedByString:@"\n"];
    }

    NSDate *started = [NSDate date];
    KLHttpResponse *response = KLCustomGet(address, [entry referer]);
    NSTimeInterval spent = -[started timeIntervalSinceNow];

    if (response == nil || ![response isSuccessful]) {
        if ([response error] != nil) {
            [report addObject:KLFmt(@"custom.check.net",
                                    [[response error] localizedDescription] ?: @"—")];
        } else {
            [report addObject:KLFmt(@"custom.check.http",
                                    (long)[response statusCode], spent,
                                    (unsigned long)[[response body] length])];
        }

        return [report componentsJoinedByString:@"\n"];
    }

    [report addObject:KLFmt(@"custom.check.http", (long)[response statusCode], spent,
                            (unsigned long)[[response body] length])];

    /**
     * Дальше два вида расходятся, и это единственное место, где проверка
     * знает о них разное. Прямому виду остаётся посмотреть на тело, JSON —
     * сначала достать из него ссылку и сходить по ней ещё раз.
     */
    NSString *link = address;

    if ([entry kind] == KLCustomKindJson) {
        id json = [KLJson parseAny:[response body]];

        if (json == nil) {
            [report addObject:KLStr(@"custom.check.notjson")];

            return [report componentsJoinedByString:@"\n"];
        }

        NSString *found = KLCustomLinkFrom(KLCustomValueAtPath(json, [entry fieldPath]));

        if ([found length] == 0) {
            [report addObject:KLFmt(@"custom.check.nofield", [entry fieldPath] ?: @"—")];

            return [report componentsJoinedByString:@"\n"];
        }

        link = KLCustomAbsolute(found, address);

        [report addObject:KLFmt(@"custom.check.field", [entry fieldPath], link)];

        KLHttpResponse *second = KLCustomGet(link, [entry referer]);

        if (![second isSuccessful]) {
            [report addObject:KLFmt(@"custom.check.http", (long)[second statusCode],
                                    -[started timeIntervalSinceNow],
                                    (unsigned long)[[second body] length])];

            return [report componentsJoinedByString:@"\n"];
        }

        [report addObject:[self verdictForPlaylist:[second text]]];

        return [report componentsJoinedByString:@"\n"];
    }

    [report addObject:[self verdictForPlaylist:[response text]]];

    return [report componentsJoinedByString:@"\n"];
}

/** Что это за тело: плейлист или что-то другое. */
+ (NSString *)verdictForPlaylist:(NSString *)text {
    if (KLCustomLooksLikePlaylist(text)) {
        return KLFmt(@"custom.check.hls", (unsigned long)KLCustomSegmentCount(text));
    }

    NSString *head = text == nil ? @"" : text;

    if ([head length] > 80) {
        head = [head substringToIndex:80];
    }

    head = [head stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return KLFmt(@"custom.check.nothls", [head length] > 0 ? head : @"—");
}

@end
