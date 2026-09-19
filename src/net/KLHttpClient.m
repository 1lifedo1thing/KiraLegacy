#import "KLHttpClient.h"

#include <zlib.h>

#import "KLTls.h"

/** Сколько переадресаций проходим, прежде чем решить, что это кольцо. */
static const NSInteger KLMaxRedirects = 6;

/** Сколько байт читаем за раз из сокета. */
static const NSUInteger KLReadChunk = 32768;

/** Предел на заголовки ответа — защита от сервера, который их не кончает. */
static const NSUInteger KLMaxHeaderBytes = 64 * 1024;


#pragma mark - Разбор адреса

/**
 * Разбираем адрес сами, строкой, а не через NSURL.
 *
 * NSURL приводит адрес к каноническому виду: где-то переэкранирует знак,
 * где-то уберёт «лишний» слэш. Для ключей источников это смертельно — они
 * подписаны, и подпись считается ровно по той строке, что выдал разрешатель.
 * Один изменённый знак превращает рабочую ссылку в 403.
 */
@interface KLUrlParts : NSObject {
@public
    NSString *scheme;
    NSString *host;
    uint16_t  port;
    NSString *target;   // путь вместе с запросом, как есть
}
@end

@implementation KLUrlParts
@end

static KLUrlParts *KLParseUrl(NSString *url) {
    NSRange separator = [url rangeOfString:@"://"];

    if (separator.location == NSNotFound) {
        return nil;
    }

    KLUrlParts *parts = [[KLUrlParts alloc] init];

    parts->scheme = [[url substringToIndex:separator.location] lowercaseString];

    if (![parts->scheme isEqualToString:@"http"] &&
        ![parts->scheme isEqualToString:@"https"]) {
        return nil;
    }

    NSUInteger start = separator.location + separator.length;
    NSString *rest = [url substringFromIndex:start];

    NSRange slash = [rest rangeOfString:@"/"];

    NSString *authority = slash.location == NSNotFound
        ? rest
        : [rest substringToIndex:slash.location];

    parts->target = slash.location == NSNotFound
        ? @"/"
        : [rest substringFromIndex:slash.location];

    if ([authority length] == 0) {
        return nil;
    }

    // Порт отделяем последним двоеточием: у адреса IPv6 в скобках их много.
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    NSRange bracket = [authority rangeOfString:@"]" options:NSBackwardsSearch];

    BOOL portGiven = colon.location != NSNotFound &&
        (bracket.location == NSNotFound || colon.location > bracket.location);

    if (portGiven) {
        parts->host = [authority substringToIndex:colon.location];
        parts->port = (uint16_t)[[authority substringFromIndex:colon.location + 1] integerValue];
    } else {
        parts->host = authority;
        parts->port = [parts->scheme isEqualToString:@"https"] ? 443 : 80;
    }

    // Скобки у IPv6 нужны в заголовке Host, но не в getaddrinfo.
    if ([parts->host hasPrefix:@"["] && [parts->host hasSuffix:@"]"]) {
        parts->host = [parts->host substringWithRange:
            NSMakeRange(1, [parts->host length] - 2)];
    }

    return [parts->host length] > 0 ? parts : nil;
}


#pragma mark - Разворачивание сжатого ответа

/**
 * Ответ разворачивается целиком и только в накопительном режиме.
 *
 * Сжатие спрашивается лишь там, где тело заведомо текстовое и заведомо
 * невелико: ответы каталога — это десятки килобайт разметки, которые
 * ужимаются раз в пять, и на медленной связи разница заметна. Сегменты
 * видео не сжимаются ничем, просить для них gzip незачем, а разворачивать
 * их на лету означало бы держать ещё одно состояние в потоковом пути.
 */
static NSData *KLInflate(NSData *data) {
    if ([data length] == 0) {
        return data;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    // 16 + MAX_WBITS — «это gzip, а не голый deflate».
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) {
        return nil;
    }

    stream.next_in = (Bytef *)[data bytes];
    stream.avail_in = (uInt)[data length];

    NSMutableData *out = [NSMutableData dataWithCapacity:[data length] * 4];

    unsigned char buffer[16384];
    int status;

    do {
        uInt before = stream.avail_in;

        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);

        status = inflate(&stream, Z_NO_FLUSH);

        if (status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR) {
            inflateEnd(&stream);
            return nil;
        }

        uInt produced = (uInt)sizeof(buffer) - stream.avail_out;

        [out appendBytes:buffer length:produced];

        /**
         * Ни байта на выходе и ни байта на входе — поток оборван.
         *
         * Условие выхода «пока не кончился вход» сюда не годится: последний
         * поданный кусок входа может развернуться в несколько буферов
         * выхода, и цикл, остановленный по входу, потерял бы хвост. А без
         * проверки на отсутствие продвижения оборванный поток крутил бы
         * цикл вечно.
         */
        if (status != Z_STREAM_END && produced == 0 && stream.avail_in == before) {
            // Ни байта не взято на входе и ни байта не отдано на выходе —
            // дальше не будет ничего, кроме бесконечного витка.
            inflateEnd(&stream);
            return nil;
        }
    } while (status != Z_STREAM_END);

    inflateEnd(&stream);

    return out;
}


#pragma mark - Чтение с накоплением

/** Буфер поверх соединения: читает по надобности, отдаёт строками и кусками. */
@interface KLSocketReader : NSObject {
    KLTls *_link;
    NSMutableData *_buffer;
    BOOL _closed;
    NSDate *_deadline;
}
@end

@implementation KLSocketReader

/**
 * Срок на весь ответ — последняя черта, и она нужна.
 *
 * Ниже уже есть срок на сокете, и обычно молчание ловится там. Но журнал
 * с устройства показал ответ, который не пришёл и не оборвался за сорок
 * секунд при сроке в пятнадцать: значит, в каком-то сочетании библиотека
 * и сокет договариваются между собой так, что наружу не выходит ни данных,
 * ни отказа. Часы об этом не знают ничего и потому не подведут.
 *
 * Втрое от заявленного срока плюс пять секунд: медленная, но живая загрузка
 * укладывается, а зависшая — нет.
 */
- (id)initWithLink:(KLTls *)link timeout:(NSTimeInterval)timeout {
    self = [super init];

    if (self != nil) {
        _link = link;
        _buffer = [NSMutableData dataWithCapacity:KLReadChunk];
        _deadline = [NSDate dateWithTimeIntervalSinceNow:timeout * 3 + 5.0];
    }

    return self;
}

- (BOOL)closed {
    return _closed;
}

/** Живо ли соединение и всё ли с него снято ровно по границе ответа. */
- (BOOL)isDrained {
    return !_closed && [_buffer length] == 0;
}

/** Дочитывает из сокета. NO — конец или ошибка. */
- (BOOL)pull:(NSError **)error {
    if (_closed) {
        return NO;
    }

    if ([_deadline timeIntervalSinceNow] < 0) {
        _closed = YES;

        NSLog(@"[Кира/HTTP] Ответ не уложился в срок — обрываем");

        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:KLTlsErrorDomain
                                         code:KLTlsErrorIO
                                     userInfo:[NSDictionary dictionaryWithObject:
                                         @"ответ не уложился в срок"
                                                                           forKey:
                                         NSLocalizedDescriptionKey]];
        }

        return NO;
    }

    char chunk[KLReadChunk];
    NSInteger got = [_link readBytes:chunk maxLength:sizeof(chunk) error:error];

    if (got > 0) {
        [_buffer appendBytes:chunk length:(NSUInteger)got];
        return YES;
    }

    _closed = YES;

    // Молчание дольше срока — это отказ, а не конец ответа: заканчивается
    // ответ либо длиной, либо закрытым соединением, и то и другое приходит
    // из readBytes нулём.
    if (got == KLTlsReadTimedOut && error != NULL && *error == nil) {
        *error = [NSError errorWithDomain:KLTlsErrorDomain
                                     code:KLTlsErrorIO
                                 userInfo:[NSDictionary dictionaryWithObject:@"сервер замолчал"
                                                                      forKey:NSLocalizedDescriptionKey]];
    }

    return NO;
}

/** Строка до CRLF без него. nil — не дождались. */
- (NSString *)readLine:(NSError **)error {
    NSData *terminator = [@"\r\n" dataUsingEncoding:NSASCIIStringEncoding];

    while (1) {
        NSRange found = [_buffer rangeOfData:terminator
                                     options:0
                                       range:NSMakeRange(0, [_buffer length])];

        if (found.location != NSNotFound) {
            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, found.location)];

            [_buffer replaceBytesInRange:NSMakeRange(0, found.location + found.length)
                               withBytes:NULL
                                  length:0];

            return [[NSString alloc] initWithData:line encoding:NSISOLatin1StringEncoding] ?: @"";
        }

        if ([_buffer length] > KLMaxHeaderBytes) {
            return nil;
        }

        if (![self pull:error]) {
            return nil;
        }
    }
}

/** Ровно length байт. nil — не дождались. */
- (NSData *)readExactly:(NSUInteger)length error:(NSError **)error {
    while ([_buffer length] < length) {
        if (![self pull:error]) {
            return nil;
        }
    }

    NSData *out = [_buffer subdataWithRange:NSMakeRange(0, length)];

    [_buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];

    return out;
}

/** Всё накопленное, сколько есть; если пусто — ждёт новой порции. */
- (NSData *)readSome:(NSError **)error {
    if ([_buffer length] == 0 && ![self pull:error]) {
        return nil;
    }

    NSData *out = [NSData dataWithData:_buffer];

    [_buffer setLength:0];

    return [out length] > 0 ? out : nil;
}

@end


#pragma mark - Склад соединений

/**
 * Открытые соединения переживают запрос и достаются следующему.
 *
 * Сначала каждый запрос открывал своё и закрывал за собой — так проще,
 * и казалось, что цена невелика. Журнал с устройства показал обратное:
 * шестьдесят обложек главного экрана дали шестьдесят рукопожатий по трети
 * секунды каждое, и на двух потоках это тридцать секунд ожидания там, где
 * должно быть три. Все шестьдесят — к одному и тому же s4.anilist.co.
 *
 * Поэтому склад. Он нарочно маленький и забывчивый:
 *
 *   - не больше двух соединений на хост: больше и не нужно, потоков-то два;
 *   - десять секунд простоя, и соединение выбрасывается. Сервера закрывают
 *     свои примерно тогда же, и держать дольше — значит копить заведомо
 *     мёртвые;
 *   - кладём только то, что дочитано до конца и по объявленной длине.
 *     Соединение, на котором тело кончилось обрывом или осталось
 *     недочитанным, для следующего запроса непригодно: он получил бы
 *     чужой хвост вместо своих заголовков.
 *
 * И главное: взятое со склада соединение может оказаться уже закрытым
 * с той стороны — сервер вправе сделать это молча в любой момент. Поэтому
 * запрос, сорвавшийся на таком соединении раньше, чем пришла строка
 * состояния, повторяется один раз по свежему. Без этого повтора склад
 * был бы источником случайных отказов вместо ускорения.
 */
@interface KLPooledLink : NSObject {
@public
    KLTls *link;
    NSTimeInterval idleSince;
}
@end

@implementation KLPooledLink
@end

static const NSTimeInterval KLPoolMaxIdle = 10.0;
static const NSUInteger KLPoolPerHost = 2;

static NSMutableDictionary *KLPool(void) {
    static NSMutableDictionary *pool = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ pool = [[NSMutableDictionary alloc] init]; });

    return pool;
}

static KLTls *KLTakeConnection(NSString *key) {
    NSMutableDictionary *pool = KLPool();
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized (pool) {
        NSMutableArray *waiting = [pool objectForKey:key];

        while ([waiting count] > 0) {
            KLPooledLink *entry = [waiting objectAtIndex:0];

            [waiting removeObjectAtIndex:0];

            if (now - entry->idleSince <= KLPoolMaxIdle) {
                return entry->link;
            }

            [entry->link close];
        }
    }

    return nil;
}

static void KLPutConnection(NSString *key, KLTls *link) {
    NSMutableDictionary *pool = KLPool();

    @synchronized (pool) {
        NSMutableArray *waiting = [pool objectForKey:key];

        if (waiting == nil) {
            waiting = [NSMutableArray array];
            [pool setObject:waiting forKey:key];
        }

        if ([waiting count] >= KLPoolPerHost) {
            [link close];
            return;
        }

        KLPooledLink *entry = [[KLPooledLink alloc] init];

        entry->link = link;
        entry->idleSince = [NSDate timeIntervalSinceReferenceDate];

        [waiting addObject:entry];
    }
}


#pragma mark - Клиент

@implementation KLHttpClient

/** Заголовок по имени, не глядя на регистр: сервера пишут их вразнобой. */
static NSString *KLHeader(NSDictionary *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return [headers objectForKey:key];
        }
    }

    return nil;
}

/** Собирает текст запроса. */
static NSData *KLRequestHead(NSURLRequest *request, KLUrlParts *parts,
                             BOOL allowGzip, BOOL keepAlive) {
    NSMutableString *head = [NSMutableString string];

    NSString *method = [request HTTPMethod] ?: @"GET";

    [head appendFormat:@"%@ %@ HTTP/1.1\r\n", method, parts->target];

    // Host с портом, если он не стандартный: без этого виртуальный хостинг
    // не разберёт, к кому мы пришли.
    BOOL standardPort = ([parts->scheme isEqualToString:@"https"] && parts->port == 443) ||
                        ([parts->scheme isEqualToString:@"http"] && parts->port == 80);

    [head appendFormat:@"Host: %@%@\r\n", parts->host,
     standardPort ? @"" : ([NSString stringWithFormat:@":%u", (unsigned)parts->port])];

    NSDictionary *given = [request allHTTPHeaderFields];

    for (NSString *key in given) {
        // Эти заголовки ставим сами и чужих значений не принимаем: вписанный
        // снаружи Host или своя длина тела ломают разбор на той стороне.
        if ([key caseInsensitiveCompare:@"Host"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"Connection"] == NSOrderedSame ||
            [key caseInsensitiveCompare:@"Accept-Encoding"] == NSOrderedSame) {
            continue;
        }

        [head appendFormat:@"%@: %@\r\n", key, [given objectForKey:key]];
    }

    if (KLHeader(given, @"Accept") == nil) {
        [head appendString:@"Accept: */*\r\n"];
    }

    /**
     * Сжатие просим только у запросов с телом — то есть у каталога.
     *
     * Сначала просили везде, где ответ не отдаётся кусками. Вышло боком:
     * мастер-плейлист — это четыреста байт текста, сжатие на нём
     * не экономит ничего, зато сервер в ответ на gzip переходит
     * на chunked и добавляет к разбору два лишних слоя вместо простого
     * тела с объявленной длиной. Проверено на megap.akirax.buzz:
     *
     *     Accept-Encoding: identity -> Content-Length: 420, готовый текст
     *     Accept-Encoding: gzip     -> Transfer-Encoding: chunked,
     *                                  Content-Encoding: gzip, 199 байт
     *
     * Единственное место, где сжатие и правда экономит, — ответы AniList:
     * это десятки килобайт разметки, и они ужимаются раз в пять. Они же
     * единственные уходят с телом (POST), так что различать по нему
     * и достаточно.
     */
    [head appendString:(allowGzip && [[request HTTPBody] length] > 0)
                           ? @"Accept-Encoding: gzip\r\n"
                           : @"Accept-Encoding: identity\r\n"];

    NSData *body = [request HTTPBody];

    if ([body length] > 0) {
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    }

    // Потоковую выдачу тоже держим открытой: сегменты идут подряд с одного
    // хоста, и рукопожатие на каждый — это заминка каждые несколько секунд.
    [head appendString:keepAlive ? @"Connection: keep-alive\r\n\r\n"
                                 : @"Connection: close\r\n\r\n"];

    NSMutableData *out = [NSMutableData dataWithData:
        [head dataUsingEncoding:NSISOLatin1StringEncoding]];

    if ([body length] > 0) {
        [out appendData:body];
    }

    return out;
}

/** Ошибка в готовом виде — чтобы вызывающий получил ответ, а не nil. */
static KLHttpResponse *KLFailure(NSError *error) {
    KLHttpResponse *response = [[KLHttpResponse alloc] init];

    response.expectedLength = -1;
    response.error = error ?: [NSError errorWithDomain:KLTlsErrorDomain
                                                  code:KLTlsErrorIO
                                              userInfo:nil];

    return response;
}

+ (KLHttpResponse *)perform:(NSURLRequest *)request
                  bodyLimit:(NSUInteger)bodyLimit
                  onHeaders:(void (^)(KLHttpResponse *head))onHeaders
                    onChunk:(BOOL (^)(NSData *chunk))onChunk {
    NSString *url = [[request URL] absoluteString];
    NSURLRequest *current = request;

    for (NSInteger hop = 0; hop <= KLMaxRedirects; hop++) {
        KLUrlParts *parts = KLParseUrl(url);

        if (parts == nil) {
            NSLog(@"[Кира/HTTP] Адрес не разобрать: %@", url);

            return KLFailure([NSError errorWithDomain:KLTlsErrorDomain
                                                 code:KLTlsErrorResolve
                                             userInfo:[NSDictionary
                                                 dictionaryWithObject:@"адрес не разобрать"
                                                               forKey:NSLocalizedDescriptionKey]]);
        }

        NSString *location = nil;
        BOOL again = NO;

        KLHttpResponse *response = [self once:current
                                        parts:parts
                                    bodyLimit:bodyLimit
                                    onHeaders:onHeaders
                                      onChunk:onChunk
                                     redirect:&location
                                       pooled:YES
                                        again:&again];

        // Соединение со склада оказалось закрытым — повторяем по свежему.
        if (again) {
            location = nil;

            response = [self once:current
                            parts:parts
                        bodyLimit:bodyLimit
                        onHeaders:onHeaders
                          onChunk:onChunk
                         redirect:&location
                           pooled:NO
                            again:NULL];
        }

        if (location == nil) {
            return response;
        }

        NSLog(@"[Кира/HTTP] %ld → %@", (long)response.statusCode,
              [[NSURL URLWithString:location relativeToURL:[NSURL URLWithString:url]] host]
                  ?: location);

        // Переадресация: адрес может быть и относительным.
        NSURL *next = [NSURL URLWithString:location
                             relativeToURL:[NSURL URLWithString:url]];

        if (next == nil) {
            return response;
        }

        url = [[next absoluteURL] absoluteString];

        /**
         * После переадресации запрос становится GET без тела.
         *
         * Строго по правилам так положено только для 303, а 301 и 302
         * метод сохраняют. На деле все клиенты давно переводят и их тоже,
         * и сервера на это рассчитывают. Единственный POST у нас — запрос
         * к каталогу, и он не переадресуется вовсе.
         */
        NSMutableURLRequest *hopRequest = [current mutableCopy];

        [hopRequest setURL:[next absoluteURL]];
        [hopRequest setHTTPMethod:@"GET"];
        [hopRequest setHTTPBody:nil];

        current = hopRequest;
    }

    NSLog(@"[Кира/HTTP] Переадресации ходят по кругу: %@", url);

    return KLFailure([NSError errorWithDomain:KLTlsErrorDomain
                                         code:KLTlsErrorIO
                                     userInfo:[NSDictionary
                                         dictionaryWithObject:@"переадресации по кругу"
                                                       forKey:NSLocalizedDescriptionKey]]);
}

/** Один заход: соединение, запрос, ответ. */
+ (KLHttpResponse *)once:(NSURLRequest *)request
                   parts:(KLUrlParts *)parts
               bodyLimit:(NSUInteger)bodyLimit
               onHeaders:(void (^)(KLHttpResponse *head))onHeaders
                 onChunk:(BOOL (^)(NSData *chunk))onChunk
                redirect:(NSString **)redirect
                  pooled:(BOOL)allowPooled
                   again:(BOOL *)again {
    NSTimeInterval timeout = [request timeoutInterval] > 0 ? [request timeoutInterval] : 30.0;

    BOOL secure = [parts->scheme isEqualToString:@"https"];
    BOOL streaming = (onChunk != nil);

    NSString *key = [NSString stringWithFormat:@"%@|%@|%u",
                     parts->scheme, parts->host, (unsigned)parts->port];

    NSError *error = nil;

    KLTls *link = allowPooled ? KLTakeConnection(key) : nil;
    BOOL reused = (link != nil);

    if (reused) {
        [link setReadTimeout:timeout];
    } else {
        link = [[KLTls alloc] initWithHost:parts->host port:parts->port secure:secure];

        if (![link connectWithTimeout:timeout error:&error]) {
            return KLFailure(error);
        }
    }

    NSData *head = KLRequestHead(request, parts, !streaming, YES);

    if ([link writeBytes:[head bytes] length:[head length] error:&error] < 0) {
        [link close];

        // Взятое со склада могло закрыться с той стороны, пока лежало.
        if (reused && again != NULL) {
            *again = YES;
        }

        return KLFailure(error);
    }

    KLSocketReader *reader = [[KLSocketReader alloc] initWithLink:link timeout:timeout];

    // --- строка состояния ---

    NSString *statusLine = [reader readLine:&error];

    if ([statusLine length] == 0) {
        [link close];

        if (reused && again != NULL) {
            *again = YES;
        }

        return KLFailure(error);
    }

    KLHttpResponse *response = [[KLHttpResponse alloc] init];

    response.expectedLength = -1;

    NSArray *pieces = [statusLine componentsSeparatedByString:@" "];

    response.statusCode = [pieces count] >= 2 ? [[pieces objectAtIndex:1] integerValue] : 0;

    // --- заголовки ---

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    while (1) {
        NSString *line = [reader readLine:&error];

        if (line == nil) {
            [link close];
            return KLFailure(error);
        }

        if ([line length] == 0) {
            break;
        }

        NSRange colon = [line rangeOfString:@":"];

        if (colon.location == NSNotFound) {
            continue;
        }

        NSString *name = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Повторный заголовок склеиваем через запятую — так велит стандарт,
        // и так приходят Set-Cookie и Via.
        NSString *known = [headers objectForKey:name];

        [headers setObject:known != nil ? [NSString stringWithFormat:@"%@, %@", known, value] : value
                    forKey:name];
    }

    response.headers = headers;

    NSString *lengthText = KLHeader(headers, @"Content-Length");

    if (lengthText != nil) {
        response.expectedLength = [lengthText longLongValue];
    }

    // --- переадресация ---

    if (response.statusCode >= 300 && response.statusCode < 400) {
        NSString *location = KLHeader(headers, @"Location");

        if ([location length] > 0) {
            /**
             * Тело у переадресации обычно есть — короткая страничка «идите
             * туда». Дочитать её обязательно: без этого соединение нельзя
             * ни переиспользовать, ни закрыть, не оборвав сервера на полуслове.
             */
            BOOL chunkedHop = [[KLHeader(headers, @"Transfer-Encoding") ?: @"" lowercaseString]
                               rangeOfString:@"chunked"].location != NSNotFound;

            NSMutableData *sink = [NSMutableData data];

            BOOL read = chunkedHop
                ? [self readChunked:reader into:sink onChunk:nil
                          bodyLimit:0 response:response aborted:NULL error:&error]
                : [self readPlain:reader into:sink onChunk:nil
                        bodyLimit:0 expected:response.expectedLength
                         response:response aborted:NULL error:&error];

            [self recycle:link reader:reader headers:headers
                 complete:(read && response.error == nil) key:key];

            if (redirect != NULL) {
                *redirect = location;
            }

            response.error = nil;

            return response;
        }
    }

    if (onHeaders != nil) {
        onHeaders(response);
    }

    // --- тело ---

    BOOL chunked = [[KLHeader(headers, @"Transfer-Encoding") ?: @"" lowercaseString]
                    rangeOfString:@"chunked"].location != NSNotFound;

    BOOL gzipped = [[KLHeader(headers, @"Content-Encoding") ?: @"" lowercaseString]
                    rangeOfString:@"gzip"].location != NSNotFound;

    NSMutableData *body = streaming ? nil : [NSMutableData data];

    // Ответ без тела по определению: на HEAD, 204 и 304 сервер его не шлёт,
    // и ждать здесь означало бы висеть до срока.
    BOOL bodyless = response.statusCode == 204 || response.statusCode == 304 ||
                    [[request HTTPMethod] caseInsensitiveCompare:@"HEAD"] == NSOrderedSame;

    BOOL stopped = NO;
    BOOL aborted = NO;

    if (!bodyless) {
        if (chunked) {
            stopped = ![self readChunked:reader into:body onChunk:onChunk
                               bodyLimit:bodyLimit response:response
                                 aborted:&aborted error:&error];
        } else {
            stopped = ![self readPlain:reader into:body onChunk:onChunk
                             bodyLimit:bodyLimit expected:response.expectedLength
                              response:response aborted:&aborted error:&error];
        }
    }

    /**
     * Обрыв по воле получателя — не повод хоронить соединение, но и класть
     * его на склад нельзя: в нём остался недочитанный хвост сегмента.
     */
    BOOL complete = !stopped && !aborted && response.error == nil && !bodyless;

    [self recycle:link reader:reader headers:headers complete:complete key:key];

    if (stopped && response.error == nil && error != nil) {
        response.error = error;
    }

    if (!streaming) {
        if (gzipped && [body length] > 0) {
            NSData *plain = KLInflate(body);

            /**
             * Не развернулось — это отказ, и отдавать сжатые байты как тело
             * нельзя. Разборщик JSON увидит мусор и скажет «неверный ответ»,
             * а настоящая причина — что мы сами не справились — потеряется.
             */
            if (plain == nil) {
                NSLog(@"[Кира/HTTP] Сжатый ответ не развернулся (%lu байт)",
                      (unsigned long)[body length]);

                response.error = [NSError errorWithDomain:KLTlsErrorDomain
                                                     code:KLTlsErrorIO
                                                 userInfo:[NSDictionary dictionaryWithObject:
                                                     @"сжатый ответ не развернулся"
                                                                                       forKey:
                                                     NSLocalizedDescriptionKey]];
            }

            response.body = plain;
        } else {
            response.body = body;
        }
    }

    return response;
}

/**
 * Кладёт соединение на склад либо закрывает.
 *
 * Условий для склада три, и каждое обязательно: ответ дочитан до конца,
 * на соединении ничего лишнего не осталось, и сервер не сказал, что
 * закрывает его сам. Нарушено хоть одно — закрываем: следующий запрос
 * получил бы чужие байты вместо своей строки состояния, и разбираться
 * в этом было бы куда дороже сэкономленного рукопожатия.
 */
+ (void)recycle:(KLTls *)link
         reader:(KLSocketReader *)reader
        headers:(NSDictionary *)headers
       complete:(BOOL)complete
            key:(NSString *)key {
    BOOL serverCloses = [[KLHeader(headers, @"Connection") ?: @"" lowercaseString]
                         rangeOfString:@"close"].location != NSNotFound;

    if (!complete || serverCloses || ![reader isDrained]) {
        [link close];
        return;
    }

    KLPutConnection(key, link);
}

/** Тело, нарезанное сервером на куски с длиной в шестнадцатеричном виде. */
+ (BOOL)readChunked:(KLSocketReader *)reader
               into:(NSMutableData *)body
            onChunk:(BOOL (^)(NSData *chunk))onChunk
          bodyLimit:(NSUInteger)bodyLimit
           response:(KLHttpResponse *)response
            aborted:(BOOL *)aborted
              error:(NSError **)error {
    while (1) {
        NSString *header = [reader readLine:error];

        if (header == nil) {
            return NO;
        }

        // После длины через точку с запятой бывают расширения — они нам
        // ни к чему, но обрезать их обязательно.
        NSRange semicolon = [header rangeOfString:@";"];

        if (semicolon.location != NSNotFound) {
            header = [header substringToIndex:semicolon.location];
        }

        NSUInteger size = (NSUInteger)strtoul([[header stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]] UTF8String], NULL, 16);

        if (size == 0) {
            /**
             * Последний кусок нулевой, а за ним идёт хвост: необязательные
             * заголовки и пустая строка. Раньше его не читали — соединение
             * всё равно закрывалось. Теперь читаем до пустой строки: иначе
             * этот хвост остался бы в буфере и достался следующему запросу
             * вместо его собственной строки состояния.
             */
            while (1) {
                NSString *trailer = [reader readLine:error];

                if (trailer == nil || [trailer length] == 0) {
                    break;
                }
            }

            return YES;
        }

        NSData *piece = [reader readExactly:size error:error];

        if (piece == nil) {
            return NO;
        }

        // За каждым куском идёт свой CRLF.
        [reader readLine:error];

        if (onChunk != nil) {
            if (!onChunk(piece)) {
                /**
                 * Остановил получатель — плеер ушёл с экрана. Это не ошибка,
                 * но и не конец тела: на соединении остался недочитанный
                 * хвост, и на склад его класть нельзя. Следующий запрос
                 * принял бы этот хвост за свою строку состояния.
                 */
                if (aborted != NULL) {
                    *aborted = YES;
                }

                return YES;
            }
        } else {
            [body appendData:piece];

            if (bodyLimit > 0 && [body length] > bodyLimit) {
                response.error = [NSError errorWithDomain:KLTlsErrorDomain
                                                     code:KLTlsErrorIO
                                                 userInfo:[NSDictionary dictionaryWithObject:
                                                     @"ответ больше предела"
                                                                                       forKey:
                                                     NSLocalizedDescriptionKey]];
                [body setLength:0];
                return YES;
            }
        }
    }
}

/** Тело по длине из заголовка, а если её нет — до закрытия соединения. */
+ (BOOL)readPlain:(KLSocketReader *)reader
             into:(NSMutableData *)body
          onChunk:(BOOL (^)(NSData *chunk))onChunk
        bodyLimit:(NSUInteger)bodyLimit
         expected:(long long)expected
         response:(KLHttpResponse *)response
          aborted:(BOOL *)aborted
            error:(NSError **)error {
    long long taken = 0;

    while (expected < 0 || taken < expected) {
        NSData *piece = [reader readSome:error];

        if (piece == nil) {
            /**
             * Данные кончились. Это конец ответа, если длины не объявляли
             * или набрали её полностью; иначе — обрыв, и молчать о нём
             * нельзя: недокачанный плейлист разберётся как исправный,
             * просто короткий.
             */
            if (expected >= 0 && taken < expected) {
                /**
                 * Ошибку ставим здесь сами, а не полагаемся на ту, что
                 * пришла из сокета: закрытое соединение ошибкой не считается
                 * и приходит пустым. Без этого недокачанный плейлист
                 * разобрался бы как исправный, просто короткий, — и плеер
                 * получил бы ленту без половины кусков.
                 */
                if (response.error == nil) {
                    response.error =
                        [NSError errorWithDomain:KLTlsErrorDomain
                                            code:KLTlsErrorIO
                                        userInfo:[NSDictionary dictionaryWithObject:
                                            [NSString stringWithFormat:
                                                @"тело оборвалось: %lld из %lld", taken, expected]
                                                                              forKey:
                                            NSLocalizedDescriptionKey]];
                }

                return NO;
            }

            return YES;
        }

        // Сервер может прислать больше объявленного — лишнее отбрасываем.
        if (expected >= 0 && taken + (long long)[piece length] > expected) {
            piece = [piece subdataWithRange:NSMakeRange(0, (NSUInteger)(expected - taken))];
        }

        taken += (long long)[piece length];

        if (onChunk != nil) {
            if (!onChunk(piece)) {
                /**
                 * Остановил получатель — плеер ушёл с экрана. Это не ошибка,
                 * но и не конец тела: на соединении остался недочитанный
                 * хвост, и на склад его класть нельзя. Следующий запрос
                 * принял бы этот хвост за свою строку состояния.
                 */
                if (aborted != NULL) {
                    *aborted = YES;
                }

                return YES;
            }
        } else {
            [body appendData:piece];

            if (bodyLimit > 0 && [body length] > bodyLimit) {
                response.error = [NSError errorWithDomain:KLTlsErrorDomain
                                                     code:KLTlsErrorIO
                                                 userInfo:[NSDictionary dictionaryWithObject:
                                                     @"ответ больше предела"
                                                                                       forKey:
                                                     NSLocalizedDescriptionKey]];
                [body setLength:0];
                return YES;
            }
        }
    }

    return YES;
}

@end
