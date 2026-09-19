#import <Foundation/Foundation.h>

/**
 * Собирает запрос.
 *
 * Казалось бы, ради этого не нужна отдельная функция — но нужна, и вот
 * почему. Мы собираемся против SDK 9.3, а работать должны начиная с iOS 5.1,
 * и за эти версии Apple переселила всё семейство NSURL из Foundation
 * в CFNetwork. Компоновщик при двухуровневом пространстве имён записывает
 * в бинарник не просто имя символа, а «искать в такой-то библиотеке» — и
 * берёт эту библиотеку из SDK. Получается ссылка на NSMutableURLRequest
 * «в CFNetwork», а на iOS 7 этот класс лежит в Foundation, и приложение
 * не запускается вовсе:
 *
 *     Symbol not found: _NSURLAuthenticationMethodServerTrust
 *     Expected in: /System/Library/Frameworks/CFNetwork.framework/CFNetwork
 *
 * Лечится тем, что ссылки на классы этого семейства заменены на поиск
 * по имени через рантайм: тогда в бинарнике нет ни символа, ни привязки
 * к библиотеке, а класс находится там, где он на этой системе и лежит.
 * Затронуты NSMutableURLRequest, NSURLConnection, NSURLCache,
 * NSURLCredential и NSHTTPURLResponse — полный список того, что переехало.
 */
NSMutableURLRequest *KLRequest(NSString *url,
                               NSURLRequestCachePolicy policy,
                               NSTimeInterval timeout);

/** Тот же обход для классов, которые нужны по имени в других файлах. */
Class KLNetworkClass(NSString *name);


/** Ответ сервера. Тело уже прочитано целиком либо оборвано по лимиту. */
@interface KLHttpResponse : NSObject

@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, strong) NSDictionary *headers;

/** Сетевая ошибка либо превышение лимита тела; nil, если ответ пришёл. */
@property (nonatomic, strong) NSError *error;

/** Сколько байт обещает сервер; -1, если он этого не сказал. */
@property (nonatomic, assign) long long expectedLength;

@property (nonatomic, readonly) BOOL isSuccessful;

/** Тело строкой в UTF-8. */
@property (nonatomic, readonly) NSString *text;

@end


/**
 * Один HTTP-клиент на всё приложение: и запросы к каталогу, и обложки, и
 * сегменты плеера идут через него — значит, и через одну проверку
 * сертификатов.
 *
 * Ради этой проверки он и написан свой. Приложению нужны четыре хоста, и
 * ни один из них не удостоверяется корнем, который есть в хранилище
 * iOS 5–9:
 *
 *   graphql.anilist.co  → GTS Root R4 (Google Trust Services, 2016)
 *   s4.anilist.co       → GTS Root R4 — там же лежат обложки
 *   *.workers.dev       → GTS Root R4 — на Cloudflare живёт разрешатель
 *                         источников и через него же идут сегменты видео
 *   artworks.thetvdb.com → Amazon Root CA 1 (2015) — кадры серий
 *
 * Хранилище iOS 5 собрано в 2011 году и заморожено: ни того, ни другого корня
 * там нет и не появится. Системная проверка отказывает на всех четырёх, то
 * есть без своих якорей приложение не смогло бы даже открыть главный экран.
 * Поэтому корни лежат в Resources/certs и подставляются дополнительными
 * якорями; системные при этом остаются главными — на новом устройстве
 * отрабатывает обычный путь, и поведение ничем не отличается от штатного.
 *
 * Сам протокол тоже свой: запросы идут через KLHttpClient поверх KLTls,
 * то есть через OpenSSL, а не через Secure Transport. Раньше хватало
 * системного — iOS 5.1 согласовывает TLS 1.2 сам, — но набор шифров там
 * застыл на CBC и SHA-1, и задать другой нельзя никак. Подробности,
 * и вторая причина перехода, — в src/net/KLTls.h.
 */
@interface KLHttp : NSObject

/**
 * Выполняет запрос и ждёт ответа. Вызывать только с фоновой очереди:
 * на главном потоке это заморозит интерфейс на время запроса.
 *
 * bodyLimit — потолок на тело; 0 означает «без ограничения».
 */
+ (KLHttpResponse *)send:(NSURLRequest *)request bodyLimit:(NSUInteger)bodyLimit;

/**
 * То же, но с указанием, класть ли ответ в дисковый кеш.
 *
 * По умолчанию кладём: кеш заведён ради обложек. А вот сегменты видео туда
 * попадать не должны — каждый весит мегабайты, они не повторяются, и запись
 * их на диск во время воспроизведения это лишняя работа ровно тогда, когда
 * её меньше всего можно себе позволить.
 */
+ (KLHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
                 caching:(BOOL)caching;

/**
 * Потоковое чтение: заголовки отдаются, как только пришли, а тело — кусками
 * по мере получения, без накопления целиком.
 *
 * Нужно ровно одному месту — прокси плеера. Пока сегмент читался в память
 * целиком и лишь потом отдавался, плеер получал первый байт только после
 * того, как скачался последний, и уходил в буферизацию на каждом куске.
 *
 * onChunk возвращает NO, если получатель отвалился, — тогда загрузка
 * обрывается и мы не тянем остаток впустую. Оба блока зовутся с сетевого
 * потока, не с главного.
 */
+ (KLHttpResponse *)stream:(NSURLRequest *)request
                 onHeaders:(void (^)(KLHttpResponse *head))onHeaders
                   onChunk:(BOOL (^)(NSData *chunk))onChunk;

/**
 * То же, что send:bodyLimit:, но ответ на несколько секунд запоминается
 * в памяти по адресу.
 *
 * Каталог на главном экране полезно подержать: возврат из карточки сериала
 * не должен перезапрашивать четыре ленты подряд — AniList считает запросы
 * и отвечает 429, когда их становится слишком много.
 */
+ (KLHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
             cacheForTTL:(NSTimeInterval)ttl;

/** Сбрасывает кратковременный кеш ответов — например, по жесту обновления. */
+ (void)dropMemoryCache;

@end
