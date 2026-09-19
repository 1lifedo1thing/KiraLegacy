#import "KLHlsProxy.h"

#import "KLStrings.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

#import "KLCertificates.h"
#import "KLHttp.h"
#import "KLStreams.h"

static NSString *const KLDirectPlaybackKey = @"kl_direct_playback";

/**
 * Заголовки для походов наверх.
 *
 * Разрешатель отдаёт сегменты кому угодно, но пустой User-Agent у части
 * посредников на пути — повод ответить отказом. Представляемся тем же,
 * чем представляется веб-версия.
 */
static NSString *const KLUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/15.6 Safari/605.1.15";

@implementation KLHlsVariant

- (NSString *)label {
    return _height > 0 ? [NSString stringWithFormat:@"%ldp", (long)_height] : KLStr(@"player.auto");
}

- (BOOL)playable {
    NSInteger maxHeight = [KLStreams maxVideoHeight];
    NSInteger maxLevel = [KLStreams maxAvcLevel];

    if (_height > 0 && _height > maxHeight) {
        return NO;
    }

    // Уровень проверяем отдельно от высоты: зеркало вполне может отдать
    // 720p в профиле High 5.0, и такую дорожку A5 тоже не осилит.
    NSInteger level = [KLStreams avcLevelIn:_codecs];

    if (level > 0 && level > maxLevel) {
        return NO;
    }

    return YES;
}

@end


@implementation KLHlsProxy {
    int _socket;

    /**
     * Токен → адрес наверху. Плееру мы отдаём короткие локальные адреса вида
     * /s/17.ts, а настоящий адрес держим здесь: ключи источников длинные
     * и в путь без кодирования не лезут.
     */
    NSMutableDictionary *_targets;

    /**
     * Обратная таблица: адрес наверху → уже выданный токен.
     *
     * Без неё один и тот же кусок получал бы новый локальный адрес при
     * каждом разборе плейлиста — см. registerTarget:.
     */
    NSMutableDictionary *_tokens;
    NSInteger _nextToken;

    /** С каким Referer ходить наверх за этим потоком. */
    NSString *_referer;

    /** Разобранные дорожки мастера. */
    NSArray *_variants;

    /** Сообщали ли уже про обёртку — чтобы не писать это на каждый сегмент. */
    BOOL _reportedWrapper;
}

+ (KLHlsProxy *)shared {
    static KLHlsProxy *shared = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ shared = [[KLHlsProxy alloc] init]; });

    return shared;
}

- (id)init {
    self = [super init];
    if (self != nil) {
        _socket = -1;
        _targets = [[NSMutableDictionary alloc] init];
        _tokens = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (NSArray *)variants {
    @synchronized (self) {
        return _variants ?: [NSArray array];
    }
}

+ (BOOL)directPlaybackEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:KLDirectPlaybackKey];
}

+ (void)setDirectPlaybackEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:KLDirectPlaybackKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSURL *)certificateProfileUrl {
    if (![self start]) {
        return nil;
    }

    // Расширение важно: по нему Safari понимает, что перед ним профиль,
    // и передаёт его системной установке, а не показывает как текст.
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"http://127.0.0.1:%lu/cert/kira.mobileconfig", (unsigned long)_port]];
}

#pragma mark - Сервер

- (BOOL)start {
    @synchronized (self) {
        if (_socket >= 0) {
            return YES;
        }

        /**
         * Запись в сокет, который закрыт с той стороны, по умолчанию убивает
         * процесс сигналом SIGPIPE. А закрывается он постоянно: плеер
         * отпускается при уходе с экрана, и в этот момент рабочий поток
         * прокси как раз дописывает ему сегмент. Глушим сигнал на всё
         * приложение и, отдельно, на каждом принятом соединении —
         * SO_NOSIGPIPE ниже.
         */
        signal(SIGPIPE, SIG_IGN);

        int handle = socket(AF_INET, SOCK_STREAM, 0);
        if (handle < 0) {
            NSLog(@"[Кира/Proxy] Не удалось создать сокет");
            return NO;
        }

        int yes = 1;
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));

        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        // Порт 0 — пусть система даст свободный: занимать постоянный номер
        // нельзя, приложение не одно на устройстве.
        address.sin_port = 0;

        if (bind(handle, (struct sockaddr *)&address, sizeof(address)) < 0 ||
            listen(handle, 8) < 0) {
            NSLog(@"[Кира/Proxy] Не удалось занять порт на петле");
            close(handle);
            return NO;
        }

        socklen_t length = sizeof(address);
        getsockname(handle, (struct sockaddr *)&address, &length);

        _socket = handle;
        _port = ntohs(address.sin_port);

        NSLog(@"[Кира/Proxy] Слушаем 127.0.0.1:%lu", (unsigned long)_port);

        [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];

        return YES;
    }
}

- (void)acceptLoop {
    // Соединений у плеера несколько сразу: плейлист перечитывается, пока
    // идут сегменты. Каждое обслуживается своим заданием.
    dispatch_queue_t queue =
        dispatch_queue_create("ru.computershik.kiralegacy.proxy", DISPATCH_QUEUE_CONCURRENT);

    while (YES) {
        int client = accept(_socket, NULL, NULL);

        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }

            /**
             * Приём оборвался — и это самое неприятное, что тут может быть.
             *
             * Поток выходит, а сокет остаётся открытым: start увидел бы
             * _socket >= 0, ответил «уже слушаю» и больше ничего не сделал.
             * Слушать при этом некому, и плеер получал бы отказ соединения —
             * сразу и навсегда, до перезапуска приложения.
             *
             * Поэтому закрываем сокет и обнуляем его: следующий
             * prepareStream поднимет сервер заново.
             */
            NSLog(@"[Кира/Proxy] Приём оборвался: %s", strerror(errno));

            @synchronized (self) {
                close(_socket);
                _socket = -1;
                _port = 0;
            }

            break;
        }

        // Второй рубеж против SIGPIPE — на самом соединении.
        int nosigpipe = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));

        /**
         * Сроки на чтение и запись, и это не мелочь.
         *
         * Тело сегмента мы отдаём прямо из обработчика ответа
         * NSURLConnection, а он крутится на одном-единственном сетевом
         * потоке — общем для всего приложения. Пока сокет без срока,
         * зависшая запись (плеер набрал буфер и перестал читать) держит этот
         * поток намертво, и вместе с ним встаёт вся сеть: обложки, запросы
         * к каталогу, всё.
         *
         * Снаружи это выглядит не как «сегмент не доехал», а как наглухо
         * замерший интерфейс — при том что уже проигрываемый звук идёт
         * дальше, он живёт своими потоками.
         */
        struct timeval limit;
        limit.tv_sec = 20;
        limit.tv_usec = 0;

        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));

        dispatch_async(queue, ^{
            @autoreleasepool {
                [self handleClient:client];
                close(client);
            }
        });
    }
}

#pragma mark - Обслуживание запроса

/** Читает заголовки запроса до пустой строки. */
- (NSString *)readRequest:(int)client {
    NSMutableData *buffer = [NSMutableData data];
    char chunk[1024];

    while ([buffer length] < 8192) {
        ssize_t got = recv(client, chunk, sizeof(chunk), 0);
        if (got <= 0) {
            break;
        }

        [buffer appendBytes:chunk length:got];

        NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        if ([buffer rangeOfData:terminator
                        options:0
                          range:NSMakeRange(0, [buffer length])].location != NSNotFound) {
            break;
        }
    }

    return [[NSString alloc] initWithData:buffer encoding:NSASCIIStringEncoding];
}

/** Возвращает NO, если получатель отвалился: дальше слать уже нечему. */
- (BOOL)sendAll:(int)client data:(NSData *)data {
    const uint8_t *bytes = [data bytes];
    NSUInteger left = [data length];

    while (left > 0) {
        ssize_t sent = send(client, bytes, left, 0);

        if (sent <= 0) {
            if (sent < 0 && errno == EINTR) {
                continue;
            }

            return NO;
        }

        bytes += sent;
        left -= sent;
    }

    return YES;
}

- (void)respond:(int)client
         status:(NSString *)status
           type:(NSString *)type
           body:(NSData *)body {
    NSMutableString *head = [NSMutableString string];

    [head appendFormat:@"HTTP/1.1 %@\r\n", status];
    [head appendFormat:@"Content-Type: %@\r\n", type];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
    [head appendString:@"Accept-Ranges: bytes\r\n"];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendAll:client data:[head dataUsingEncoding:NSASCIIStringEncoding]];
    [self sendAll:client data:body];
}

- (void)handleClient:(int)client {
    NSString *request = [self readRequest:client];
    if ([request length] == 0) {
        return;
    }

    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSArray *parts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];

    if ([parts count] < 2) {
        return;
    }

    NSString *path = [parts objectAtIndex:1];

    /**
     * Запрос записывается в журнал целиком, и это не отладочный мусор.
     *
     * Когда плеер молча висит на «загрузке», единственный способ отличить
     * «не достучался до нас» от «мы ответили не тем» — увидеть, дошёл ли
     * запрос вообще. Строк тут немного: плейлистов за просмотр единицы,
     * а сегменты видны по одной строке на кусок.
     */
    NSLog(@"[Кира/Proxy] → %@", path);

    // Плеер может попросить кусок файла — обычно при перемотке.
    NSString *range = nil;
    for (NSString *line in lines) {
        if ([[line lowercaseString] hasPrefix:@"range:"]) {
            range = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }

    // Профиль с корнями: его открывает Safari, а не плеер.
    if ([path hasPrefix:@"/cert/"]) {
        [self respond:client
               status:@"200 OK"
                 type:@"application/x-apple-aspen-config"
                 body:[KLCertificates configurationProfile]];
        return;
    }

    BOOL isPlaylist = [path hasPrefix:@"/m/"];
    NSString *upstream = [self targetForPath:path];

    if (upstream == nil) {
        NSLog(@"[Кира/Proxy] ← 404: адрес %@ не зарегистрирован", path);

        [self respond:client status:@"404 Not Found" type:@"text/plain" body:[NSData data]];
        return;
    }

    // Плейлист маленький и его надо переписать целиком, поэтому читается
    // в память. Сегмент — наоборот, идёт насквозь.
    if (isPlaylist) {
        NSData *body = [self fetch:upstream];

        if (body == nil) {
            [self respond:client status:@"502 Bad Gateway" type:@"text/plain" body:[NSData data]];
            return;
        }

        [self respond:client
               status:@"200 OK"
                 type:@"application/vnd.apple.mpegurl"
                 body:[self rewritePlaylist:body baseUrl:upstream]];
        return;
    }

    [self streamSegment:upstream toClient:client range:range];
}

/**
 * Сколько байт накопить, прежде чем решать, где начинается поток.
 *
 * Заголовок обёртки — 252 байта, и чтобы убедиться, что дальше настоящий
 * MPEG-TS, надо увидеть подряд девять пакетов по 188 байт. Четыре килобайта
 * покрывают и то, и другое с запасом, а задержка от такого накопления
 * незаметна.
 */
static const NSUInteger KLSegmentProbe = 4096;

/**
 * Где в куске начинается настоящий MPEG-TS.
 *
 * Зеркала отдают сегменты, завёрнутыми в картинку: перед потоком стоит
 * готовый PNG 1×1 — сигнатура, IHDR, IDAT, IEND, — и только потом идут
 * пакеты. Так файл проходит там, где режут видео по типу содержимого.
 *
 * Плееру эта обёртка не нужна и мешает: 0x89 вместо 0x47 в первом байте,
 * и AVPlayer не находит ни одного пакета. Снаружи это выглядит как
 * бесконечная загрузка — он не падает и не жалуется, а просто ждёт
 * данных, которые считает битыми.
 *
 * Ищем не «после PNG», а первую настоящую точку синхронизации: 0x47,
 * повторяющийся через каждые 188 байт. Так работает и с обёрткой, и без
 * неё, и с любой другой, какую придумают завтра.
 */
- (NSUInteger)transportStreamOffsetIn:(NSData *)data {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    // Обычный поток — ничего искать не надо.
    if (length == 0 || bytes[0] == 0x47) {
        return 0;
    }

    NSUInteger limit = MIN(length, (NSUInteger)65536);

    for (NSUInteger i = 0; i < limit; i++) {
        if (bytes[i] != 0x47) {
            continue;
        }

        BOOL matches = YES;

        for (NSUInteger k = 1; k <= 8; k++) {
            NSUInteger at = i + k * 188;

            if (at >= length) {
                // Кусок кончился раньше: трёх совпадений подряд довольно,
                // чтобы не спутать точку синхронизации со случайным 0x47.
                matches = (k > 3);
                break;
            }

            if (bytes[at] != 0x47) {
                matches = NO;
                break;
            }
        }

        if (matches) {
            return i;
        }
    }

    /**
     * Не нашли — отдаём как есть.
     *
     * Отбрасывать наугад нельзя: сегмент может быть и не MPEG-TS вовсе
     * (fMP4 в HLS тоже бывает), и тогда обрезка сломала бы исправный поток.
     * Пусть лучше плеер разбирается сам.
     */
    return 0;
}

/**
 * Отправляет накопленное начало сегмента, отбросив обёртку.
 *
 * Заголовки уходят отсюда, а не из onHeaders, и это обязательно: длину
 * тела мы узнаём только вместе с размером обёртки, а соврать в
 * Content-Length нельзя — клиент будет ждать недостающие байты
 * до самого разрыва.
 */
- (BOOL)flushSegmentHead:(NSData *)head
                  client:(int)client
                  status:(NSInteger)status
                expected:(long long)expected {
    NSUInteger skip = [self transportStreamOffsetIn:head];

    if (skip > 0 && !_reportedWrapper) {
        _reportedWrapper = YES;

        NSLog(@"[Кира/Proxy] Сегменты завёрнуты в картинку — отбрасываем %lu байт",
              (unsigned long)skip);
    }

    NSMutableString *reply = [NSMutableString string];

    [reply appendFormat:@"HTTP/1.1 %@\r\n", status == 206 ? @"206 Partial Content" : @"200 OK"];
    [reply appendString:@"Content-Type: video/MP2T\r\n"];
    [reply appendString:@"Accept-Ranges: none\r\n"];

    if (expected > (long long)skip) {
        [reply appendFormat:@"Content-Length: %lld\r\n", expected - (long long)skip];
    }

    [reply appendString:@"Connection: close\r\n\r\n"];

    if (![self sendAll:client data:[reply dataUsingEncoding:NSASCIIStringEncoding]]) {
        return NO;
    }

    if ([head length] <= skip) {
        return YES;
    }

    NSData *rest = [head subdataWithRange:
        NSMakeRange(skip, [head length] - skip)];

    return [self sendAll:client data:rest];
}

/**
 * Отдаёт сегмент насквозь: байты уходят плееру по мере того, как приходят
 * сверху.
 *
 * Сначала было проще — сегмент читался в память целиком и лишь потом
 * отдавался. Работало, но плеер получал первый байт только после того, как
 * скачался последний, то есть к задержке сети добавлялось всё время загрузки
 * куска. На живом канале это выглядит так: пара секунд воспроизведения,
 * потом буферизация, и так по кругу.
 *
 * Заодно исчезла вторая беда того же решения: сегмент целиком лежал
 * в памяти, а на iPhone 4S это заметно.
 *
 * Диапазон не режем сами, а передаём наверх — CDN отвечает на Range сам,
 * и его ответ просто пересылается дальше.
 */
- (void)streamSegment:(NSString *)upstream toClient:(int)client range:(NSString *)range {
    NSMutableURLRequest *request =
        KLRequest(upstream, NSURLRequestReloadIgnoringLocalCacheData, 30.0);

    if (request == nil) {
        [self respond:client status:@"502 Bad Gateway" type:@"text/plain" body:[NSData data]];
        return;
    }

    [request setValue:KLUserAgent forHTTPHeaderField:@"User-Agent"];

    if (_referer != nil) {
        [request setValue:_referer forHTTPHeaderField:@"Referer"];
    }

    /**
     * Range наверх не передаём, и клиенту отвечаем «диапазоны не умею».
     *
     * Раньше передавали: сегмент шёл насквозь, и байтовые смещения совпадали
     * с точностью до байта. Теперь мы срезаем обёртку, и смещения клиента
     * к исправленному потоку уже не относятся — отданный по ним кусок начался
     * бы не там. Сегмент весит мегабайты, целиком он приходит и так,
     * а перемотка в HLS идёт по сегментам, а не по байтам.
     */

    __block BOOL alive = YES;
    __block BOOL decided = NO;
    __block NSInteger status = 200;
    __block long long expected = -1;

    NSMutableData *head = [NSMutableData dataWithCapacity:KLSegmentProbe + 4096];

    KLHttpResponse *result = [KLHttp stream:request
        onHeaders:^(KLHttpResponse *incoming) {
            // Заголовки только запоминаем: отдать их можно лишь тогда,
            // когда станет известен размер обёртки.
            status = incoming.statusCode;
            expected = incoming.expectedLength;
        }
        onChunk:^BOOL(NSData *chunk) {
            if (!alive) {
                return NO;
            }

            if (decided) {
                alive = [self sendAll:client data:chunk];
                return alive;
            }

            [head appendData:chunk];

            if ([head length] < KLSegmentProbe) {
                return YES;
            }

            decided = YES;
            alive = [self flushSegmentHead:head client:client
                                    status:status expected:expected];
            return alive;
        }];

    // Сегмент оказался короче накопителя — решаем по тому, что пришло.
    if (!decided && alive) {
        [self flushSegmentHead:head client:client status:status expected:expected];
    }

    // Заголовки не ушли вовсе — значит, наверх мы даже не достучались.
    if (result.error != nil && ![result isSuccessful] && result.statusCode == 0) {
        NSLog(@"[Кира/Proxy] Сегмент не пришёл: %@", [result.error localizedDescription]);
    }
}

#pragma mark - Таблица адресов

- (NSString *)targetForPath:(NSString *)path {
    NSArray *pieces = [path componentsSeparatedByString:@"/"];
    if ([pieces count] < 3) {
        return nil;
    }

    NSString *name = [pieces objectAtIndex:2];
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];

    if (dot.location != NSNotFound) {
        name = [name substringToIndex:dot.location];
    }

    @synchronized (self) {
        return [_targets objectForKey:[NSNumber numberWithInteger:[name integerValue]]];
    }
}

/**
 * Локальный адрес для адреса наверху. Один и тот же кусок — один и тот же
 * адрес, сколько бы раз его ни спрашивали.
 *
 * Постоянство здесь важнее, чем кажется. Выдавай мы токены заново при каждом
 * разборе плейлиста, а плейлист AVPlayer при случае перечитывает — после
 * заминки, обрыва или опустевшего запаса, — он получил бы те же куски под
 * новыми адресами. А это для него не тот же плейлист, а другой: куски в HLS
 * различаются именно адресом. Дальше он пересобирает ленту с первого куска,
 * но часы при этом не отматывает — и выходит картинка с начала при полосе
 * на пятой минуте.
 *
 * Заодно перестаёт расти таблица: у длинной серии кусков под тысячу, и
 * каждое перечитывание добавляло бы к ним ещё тысячу мёртвых записей.
 */
- (NSString *)registerTarget:(NSString *)url playlist:(BOOL)playlist {
    NSInteger token;

    // Ключ с видом: один и тот же адрес может понадобиться и плейлистом,
    // и куском — расширения у них разные, и путать их нельзя.
    NSString *key = [(playlist ? @"m|" : @"s|") stringByAppendingString:url];

    @synchronized (self) {
        NSNumber *known = [_tokens objectForKey:key];

        if (known != nil) {
            token = [known integerValue];
        } else {
            token = _nextToken++;

            [_targets setObject:url forKey:[NSNumber numberWithInteger:token]];
            [_tokens setObject:[NSNumber numberWithInteger:token] forKey:key];
        }
    }

    // Расширение в адресе важно: по нему AVPlayer понимает, что перед ним
    // плейлист, а не просто файл.
    return [NSString stringWithFormat:@"http://127.0.0.1:%lu/%@/%ld.%@",
            (unsigned long)_port,
            (playlist ? @"m" : @"s"),
            (long)token,
            (playlist ? @"m3u8" : @"ts")];
}

/** Забирает наверх — через KLHttp, то есть с нашими корнями. */
- (NSData *)fetch:(NSString *)url {
    /**
     * Пятнадцать секунд молчания — и хватит.
     *
     * Это не общий срок на запрос, а срок затишья (см. KLHttp): пока байты
     * идут, никто никого не торопит. Но плейлист — это килобайты текста,
     * и если за пятнадцать секунд от зеркала не пришло ничего, оно и не
     * придёт. Лучше быстро ответить плееру отказом и показать человеку
     * список зеркал, чем держать его перед крутящимся кружком.
     */
    NSMutableURLRequest *request =
        KLRequest(url, NSURLRequestReloadIgnoringLocalCacheData, 15.0);

    if (request == nil) {
        NSLog(@"[Кира/Proxy] Плейлист: адрес не разобрать — %@", url);
        return nil;
    }

    [request setValue:KLUserAgent forHTTPHeaderField:@"User-Agent"];

    if (_referer != nil) {
        [request setValue:_referer forHTTPHeaderField:@"Referer"];
    }

    // Хост в журнале — чтобы по одной строке было видно, к какому зеркалу
    // ушёл запрос: имя в списке и настоящий адрес совпадают не всегда.
    NSLog(@"[Кира/Proxy] ↑ %@", [[request URL] host]);

    // Плейлист небольшой, потолок на тело ему не нужен. В дисковый кеш он
    // при этом не попадает: ключи источников подписаны по времени, и вчерашний
    // плейлист второй раз всё равно не пригодится.
    KLHttpResponse *response = [KLHttp send:request bodyLimit:0 caching:NO];

    if (![response isSuccessful]) {
        NSLog(@"[Кира/Proxy] Плейлист → HTTP %ld, %@", (long)response.statusCode,
              [response.error localizedDescription] ?: @"без ошибки");
        return nil;
    }

    // Исход записывается всегда, не только при отказе: молчание в журнале
    // между «↑» и следующей строкой — единственный признак того, что поход
    // наверх не вернулся вовсе.
    NSLog(@"[Кира/Proxy] ↓ HTTP %ld, %lu байт", (long)response.statusCode,
          (unsigned long)[response.body length]);

    return response.body;
}

#pragma mark - Плейлисты

/** Приводит ссылку из плейлиста к абсолютной. */
- (NSString *)absolute:(NSString *)link base:(NSString *)base {
    if ([link hasPrefix:@"http://"] || [link hasPrefix:@"https://"]) {
        return link;
    }

    NSURL *resolved = [NSURL URLWithString:link relativeToURL:[NSURL URLWithString:base]];

    return [[resolved absoluteURL] absoluteString];
}

/** Подменяет адрес в атрибуте URI="…" — им пользуются ключи шифрования. */
- (NSString *)rewriteUriIn:(NSString *)line base:(NSString *)base playlist:(BOOL)playlist {
    NSRange marker = [line rangeOfString:@"URI=\""];
    if (marker.location == NSNotFound) {
        return line;
    }

    NSUInteger start = marker.location + marker.length;
    NSRange tail = NSMakeRange(start, [line length] - start);
    NSRange closing = [line rangeOfString:@"\"" options:0 range:tail];

    if (closing.location == NSNotFound) {
        return line;
    }

    NSString *uri = [line substringWithRange:NSMakeRange(start, closing.location - start)];
    NSString *address = [self registerTarget:[self absolute:uri base:base] playlist:playlist];

    return [NSString stringWithFormat:@"%@%@%@",
            [line substringToIndex:start],
            address,
            [line substringFromIndex:closing.location]];
}

/** Значение атрибута из строки #EXT-X-STREAM-INF. */
- (NSString *)attribute:(NSString *)name in:(NSString *)info {
    NSRange marker = [info rangeOfString:[name stringByAppendingString:@"="]];
    if (marker.location == NSNotFound) {
        return nil;
    }

    NSUInteger start = marker.location + marker.length;
    NSString *tail = [info substringFromIndex:start];

    // Значение бывает в кавычках (CODECS) и без них (RESOLUTION, BANDWIDTH).
    if ([tail hasPrefix:@"\""]) {
        NSRange closing = [[tail substringFromIndex:1] rangeOfString:@"\""];

        return closing.location == NSNotFound
            ? nil
            : [tail substringWithRange:NSMakeRange(1, closing.location)];
    }

    NSRange comma = [tail rangeOfString:@","];

    return comma.location == NSNotFound ? tail : [tail substringToIndex:comma.location];
}

/** Высота кадра из RESOLUTION=1920x1080. */
- (NSInteger)heightIn:(NSString *)info {
    NSString *resolution = [self attribute:@"RESOLUTION" in:info];

    NSRange cross = [resolution rangeOfString:@"x" options:NSCaseInsensitiveSearch];
    if (cross.location == NSNotFound) {
        return 0;
    }

    return [[resolution substringFromIndex:cross.location + 1] integerValue];
}

/**
 * Какие дорожки оставить в переписанном мастере.
 *
 * Отбор здесь и есть лечение того, из-за чего на iPad 2 трещал звук: зеркало
 * предлагает 1080p, 720p и 360p, а плеер, предоставленный себе, берёт самую
 * жирную, какую пропускает канал, — и упирается не в канал, а в декодер.
 *
 * Поэтому неподъёмные ступени выбрасываются ещё до того, как плеер их
 * увидит. Остальные остаются все: между ними он волен переключаться сам,
 * и это как раз полезно — на плохой сети упадёт до 360p вместо заминок.
 *
 * Если качество выбрано руками, остаётся ровно оно: выбор человека сильнее
 * и таблицы возможностей, и рассуждений про канал.
 */
- (NSArray *)chooseFrom:(NSArray *)found {
    if ([found count] == 0) {
        return found;
    }

    NSMutableArray *kept = [NSMutableArray array];

    if (_pinnedHeight > 0) {
        BOOL pinnedIsPlayable = NO;

        for (KLHlsVariant *variant in found) {
            if (variant.height == _pinnedHeight) {
                [kept addObject:variant];

                pinnedIsPlayable = pinnedIsPlayable || [variant playable];
            }
        }

        if ([kept count] > 0) {
            NSLog(@"[Кира/Proxy] Качество выбрано руками: %ldp", (long)_pinnedHeight);

            /**
             * Если выбранное устройству не по зубам, к нему дописывается
             * запас, и это не самоуправство, а условие того, чтобы выбор
             * вообще имел силу.
             *
             * Плеер отбирает дорожки сам, ещё до первого запроса: читает
             * CODECS в мастере и выбрасывает всё, чего не осилит декодер.
             * У HiAnime дорожка 1080p объявлена как avc1.640032 — High
             * уровня 5.0, — и на iPad 2 после такого отбора не остаётся
             * ничего. Мастер с нулём пригодных дорожек для плеера означает
             * «здесь смотреть нечего», и он отвечает «не удаётся открыть»,
             * не запросив ни одного плейлиста.
             *
             * Снаружи это выглядело так: зеркало живое, ссылка рабочая,
             * а видео мгновенно падает с ошибкой — причём только на этом
             * зеркале и только при выбранном 1080p.
             *
             * Запас идёт после выбранного: если декодер справится
             * с выбранным, плеер возьмёт его, а нет — спустится сам,
             * и человек увидит видео вместо ошибки.
             */
            if (!pinnedIsPlayable) {
                for (KLHlsVariant *variant in found) {
                    if ([variant playable]) {
                        [kept addObject:variant];
                    }
                }

                NSLog(@"[Кира/Proxy] %ldp не по зубам — дописан запас, дорожек %lu",
                      (long)_pinnedHeight, (unsigned long)[kept count]);
            }

            return kept;
        }
    }

    for (KLHlsVariant *variant in found) {
        if ([variant playable]) {
            [kept addObject:variant];
        }
    }

    /**
     * Не подошло ничего — отдаём самую мелкую, а не пустой мастер.
     *
     * Пустой мастер для плеера означает «дорожек нет», и он честно
     * откажется играть. Самая мелкая хотя бы даёт шанс: таблица
     * возможностей может и ошибаться в меньшую сторону, а вот чёрный
     * экран не ошибается никогда.
     */
    if ([kept count] == 0) {
        KLHlsVariant *smallest = [found objectAtIndex:0];

        for (KLHlsVariant *variant in found) {
            if (variant.height > 0 && (smallest.height == 0 || variant.height < smallest.height)) {
                smallest = variant;
            }
        }

        NSLog(@"[Кира/Proxy] Ни одна дорожка не по зубам — берём %@", [smallest label]);
        [kept addObject:smallest];
    }

    // По убыванию: плеер начинает с первой записи, а начинать лучше
    // с лучшего из разрешённого.
    [kept sortUsingComparator:^NSComparisonResult(KLHlsVariant *a, KLHlsVariant *b) {
        if (a.height > b.height) return NSOrderedAscending;
        if (a.height < b.height) return NSOrderedDescending;

        return NSOrderedSame;
    }];

    return kept;
}

/**
 * Переписывает плейлист так, чтобы всё в нём вело на нас.
 *
 * Разбор построчный и простой, и этого достаточно: у HLS каждая строка —
 * либо тег, либо адрес, и адрес всегда стоит на своей строке. Различаем
 * только одно: адрес после #EXT-X-STREAM-INF — это плейлист варианта,
 * всё остальное — сегмент.
 *
 * Мастер приходит не от всякого зеркала: у половины сразу готовая лента
 * сегментов. Зато у HiAnime он есть, и там же лестница 1080p/720p/360p,
 * ради которой весь отбор ниже и заведён.
 */
- (NSData *)rewritePlaylist:(NSData *)data baseUrl:(NSString *)base {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    if (text == nil) {
        // Не UTF-8 — трогать содержимое вслепую нельзя, отдаём как есть.
        // Плеер разберётся сам либо честно откажется.
        NSLog(@"[Кира/Proxy] Плейлист не читается как текст (%lu байт)",
              (unsigned long)[data length]);
        return data;
    }

    NSArray *lines = [text componentsSeparatedByString:@"\n"];

    NSMutableArray *header = [NSMutableArray array];
    NSMutableArray *found = [NSMutableArray array];

    NSString *pendingInfo = nil;
    NSInteger segments = 0;

    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([line length] == 0) {
            continue;
        }

        if ([line hasPrefix:@"#"]) {
            if ([line hasPrefix:@"#EXT-X-STREAM-INF"]) {
                pendingInfo = line;
                continue;
            }

            // I-frame-дорожки плееру ни к чему, а разбирать их как обычные
            // нельзя: там кадры для перемотки, а не поток.
            if ([line hasPrefix:@"#EXT-X-I-FRAME-STREAM-INF"]) {
                continue;
            }

            // Ключ шифрования — такой же адрес, как сегмент, только внутри
            // тега. Без подмены плеер пошёл бы за ним наверх сам.
            [header addObject:[self rewriteUriIn:line base:base playlist:NO]];
            continue;
        }

        if (pendingInfo != nil) {
            KLHlsVariant *variant = [[KLHlsVariant alloc] init];

            variant.info = pendingInfo;
            variant.url = [self absolute:line base:base];
            variant.codecs = [self attribute:@"CODECS" in:pendingInfo];
            variant.bandwidth = [[self attribute:@"BANDWIDTH" in:pendingInfo] integerValue];
            variant.height = [self heightIn:pendingInfo];

            [found addObject:variant];

            pendingInfo = nil;
            continue;
        }

        [header addObject:[self registerTarget:[self absolute:line base:base] playlist:NO]];
        segments++;
    }

    // Обычный плейлист: дорожек нет, всё уже разложено по местам.
    if ([found count] == 0) {
        NSLog(@"[Кира/Proxy] Плейлист разобран: сегментов %ld", (long)segments);

        return [[header componentsJoinedByString:@"\n"]
                dataUsingEncoding:NSUTF8StringEncoding];
    }

    @synchronized (self) {
        _variants = [found copy];
    }

    NSMutableArray *output = [NSMutableArray arrayWithArray:header];
    NSArray *kept = [self chooseFrom:found];

    for (KLHlsVariant *variant in kept) {
        [output addObject:variant.info];
        [output addObject:[self registerTarget:variant.url playlist:YES]];
    }

    NSMutableString *report = [NSMutableString string];

    for (KLHlsVariant *variant in found) {
        [report appendFormat:@"%@%@ ", [variant label], [variant playable] ? @"" : @"(мимо)"];
    }

    NSLog(@"[Кира/Proxy] Мастер разобран: %@— оставлено %lu",
          report, (unsigned long)[kept count]);

    return [[output componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Точка входа

- (NSURL *)prepareStream:(NSString *)upstreamUrl referer:(NSString *)referer {
    if ([upstreamUrl length] == 0) {
        return nil;
    }

    @synchronized (self) {
        _referer = [referer copy];
    }

    if ([[self class] directPlaybackEnabled]) {
        // Прямой режим: корни стоят в системе профилем, и посредник
        // не нужен вовсе.
        NSLog(@"[Кира/Proxy] Прямой режим — отдаём плееру адрес источника");
        return [NSURL URLWithString:upstreamUrl];
    }

    if (![self start]) {
        return nil;
    }

    @synchronized (self) {
        // Новая серия — прежние токены и дорожки больше не нужны.
        [_targets removeAllObjects];
        [_tokens removeAllObjects];
        _variants = nil;
        _reportedWrapper = NO;
    }

    NSString *local = [self registerTarget:upstreamUrl playlist:YES];

    // Адрес, который получит плеер, — по нему в журнале видно и порт,
    // и то, дошло ли вообще до запроса.
    NSLog(@"[Кира/Proxy] Отдаём плееру %@", local);

    return [NSURL URLWithString:local];
}

@end
