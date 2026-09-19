#import "KLImageLoader.h"

#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

#import "KLHttp.h"

static NSString *const KLImageTag = @"KLImageRequestedUrl";

/** Устройство с небольшой памятью: iPhone 3GS, iPod touch 3G, iPad 1. */
static BOOL KLSmallMemory(void) {
    static BOOL small = NO;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        small = [[NSProcessInfo processInfo] physicalMemory] < 512ULL * 1024 * 1024;
    });

    return small;
}

/**
 * Потолок ширины декодирования.
 *
 * Баннер во всю ширину на iPad просит картинку ровно такого размера, а это
 * мегабайты на кадр. По высоте баннеру всё равно нужно немного, и растяжение
 * вдвое на глаз почти незаметно. На устройствах с большой памятью
 * ограничение снимается.
 */
static CGFloat KLMaxDecodeWidth(void) {
    return KLSmallMemory() ? 640.0 : 1280.0;
}

#pragma mark - Очередь с разбором с конца

/**
 * Очередь заданий, которая отдаёт последнее поставленное.
 *
 * NSOperationQueue так не умеет: приоритет там задаётся заранее и не меняет
 * порядок уже стоящих в очереди. Поэтому свой стек и свои рабочие потоки.
 */
@interface KLImageQueue : NSObject {
    NSMutableArray *_stack;
    NSCondition *_condition;
}

- (id)initWithThreads:(NSInteger)threads;
- (void)push:(void (^)(void))block;

@end

@implementation KLImageQueue

- (id)initWithThreads:(NSInteger)threads {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _stack = [[NSMutableArray alloc] init];
    _condition = [[NSCondition alloc] init];

    for (NSInteger i = 0; i < threads; i++) {
        [NSThread detachNewThreadSelector:@selector(work) toTarget:self withObject:nil];
    }

    return self;
}

- (void)push:(void (^)(void))block {
    [_condition lock];
    [_stack addObject:[block copy]];
    [_condition signal];
    [_condition unlock];
}

- (void)work {
    while (YES) {
        @autoreleasepool {
            void (^job)(void) = nil;

            [_condition lock];
            while ([_stack count] == 0) {
                [_condition wait];
            }

            job = [_stack lastObject];
            [_stack removeLastObject];
            [_condition unlock];

            if (job != nil) {
                job();
            }
        }
    }
}

@end


@implementation UIImageView (KLImageTarget)
@end


#pragma mark - Загрузчик

@implementation KLImageLoader

/**
 * Память под картинки. Ключ — только адрес, без размера.
 *
 * Одна и та же обложка нужна в разных местах разного размера (карточка 110,
 * сетка поиска 87, шапка карточки во всю ширину), и если бы каждый размер
 * заводил свою запись, выходили бы лишняя загрузка, лишнее декодирование
 * и лишняя память. Хранится один кадр, а кадр крупнее нужного годится
 * и для мелкого места — вид ужмёт его сам.
 */
+ (NSCache *)cache {
    static NSCache *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];

        unsigned long long memory = [[NSProcessInfo processInfo] physicalMemory];
        NSUInteger limit = (NSUInteger)(memory / (KLSmallMemory() ? 32 : 12));

        // NSCache считает не память процесса, а нашу же оценку в байтах,
        // поэтому доля берётся от физической памяти устройства: понятия
        // «максимальный размер кучи» на iOS попросту нет.
        [cache setTotalCostLimit:MAX(limit, 4 * 1024 * 1024)];
    });

    return cache;
}

/**
 * Адреса, у которых исходник мельче запрошенного. Без этой пометки такая
 * картинка перезагружалась бы при каждом показе, потому что в кеше она
 * всегда «мельче нужного».
 */
+ (NSMutableSet *)exhausted {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ set = [[NSMutableSet alloc] init]; });

    return set;
}

/**
 * Замки по адресам. Одну и ту же картинку нередко просят сразу несколько
 * карточек — без замка каждая полезла бы в сеть сама. Второй поток ждёт
 * первый и берёт готовое из кеша.
 */
+ (id)lockFor:(NSString *)url {
    static NSMutableDictionary *locks = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ locks = [[NSMutableDictionary alloc] init]; });

    @synchronized (locks) {
        id lock = [locks objectForKey:url];

        if (lock == nil) {
            lock = [[NSObject alloc] init];
            [locks setObject:lock forKey:url];
        }

        return lock;
    }
}

/**
 * Сколько картинок тянем одновременно.
 *
 * Двух потоков хватает слабому железу: там больше только отнимало бы время
 * у прокрутки. Считаем при этом не только память, но и ядра: iPhone 4 —
 * это 512 МБ и одно ядро, по памяти он прошёл бы как «не слабый» и получил
 * четыре потока, которые на единственном ядре мешали бы самой прокрутке.
 */
+ (KLImageQueue *)queue {
    static KLImageQueue *queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSUInteger cores = [[NSProcessInfo processInfo] activeProcessorCount];
        NSInteger threads = 2;

        if (cores > 1 && !KLSmallMemory()) {
            threads = MAX(4, MIN(8, (NSInteger)cores));
        }

        NSLog(@"[Кира/Images] Потоков загрузки: %ld", (long)threads);
        queue = [[KLImageQueue alloc] initWithThreads:threads];
    });

    return queue;
}

#pragma mark Кеш

/**
 * Готовый кадр из памяти. Годится и тот, что крупнее нужного: показать его
 * можно как есть, а лишний раз ходить в сеть незачем. Мельче нужного
 * не берём — иначе картинка будет мылом; исключение только для тех,
 * у кого крупнее просто нет.
 */
+ (UIImage *)cachedFor:(NSString *)url pixelWidth:(CGFloat)width {
    UIImage *image = [[self cache] objectForKey:url];
    if (image == nil) {
        return nil;
    }

    // Сравниваем по длинной стороне: именно её ограничивает ImageIO,
    // и именно её мы просили при загрузке.
    CGFloat have = MAX(CGImageGetWidth([image CGImage]),
                       CGImageGetHeight([image CGImage]));

    if (have >= width) {
        return image;
    }

    @synchronized ([self exhausted]) {
        return [[self exhausted] containsObject:url] ? image : nil;
    }
}

#pragma mark Адрес

/**
 * Подменяет ступень обложки в адресе AniList.
 *
 *   medium      230×326    ~25 КБ
 *   large       460×651    ~70 КБ
 *   extraLarge  до 1900×2700  ~350 КБ
 *
 * Ступень записана прямо в пути, между «cover» и именем файла, поэтому
 * подмена — это подмена одного отрезка пути. Менять её вверх мы не пробуем:
 * extraLarge есть не у всякого тайтла, и запрос несуществующей ступени
 * даёт 404. Вниз — безопасно: medium и large есть всегда.
 *
 * На чужих хостах (кадры серий с thetvdb) адрес остаётся нетронутым: там
 * ступеней нет, и любая правка пути превратила бы ссылку в битую.
 */
+ (NSString *)sized:(NSString *)url pixelWidth:(CGFloat)width {
    if ([url rangeOfString:@"anilistcdn"].location == NSNotFound) {
        return url;
    }

    NSString *wanted = width <= 230 ? @"medium" : (width <= 460 ? @"large" : nil);

    // Нужна ступень не ниже присланной — оставляем как есть.
    if (wanted == nil) {
        return url;
    }

    NSArray *steps = [NSArray arrayWithObjects:@"extraLarge", @"large", @"medium", nil];

    for (NSString *step in steps) {
        NSString *from = [NSString stringWithFormat:@"/%@/", step];

        if ([url rangeOfString:from].location == NSNotFound) {
            continue;
        }

        // Ступень уже не крупнее нужной — подменять нечего. Порядок в steps
        // от крупной к мелкой, поэтому «встретили нужную раньше» значит
        // «присланная не крупнее».
        if ([step isEqualToString:wanted]) {
            return url;
        }

        // «large» просят, а пришло «medium» — это тот самый случай: вверх
        // не идём.
        if ([step isEqualToString:@"medium"]) {
            return url;
        }

        return [url stringByReplacingOccurrencesOfString:from
                                              withString:[NSString stringWithFormat:@"/%@/", wanted]];
    }

    return url;
}

#pragma mark Декодирование

/**
 * Разбор с уменьшением. ImageIO задаёт точный потолок стороны, и лишние
 * пиксели в память не попадают вовсе.
 */
/**
 * Какой потолок стороны просить у ImageIO, чтобы после показа «по заполнению»
 * ничего не пришлось растягивать обратно.
 *
 * kCGImageSourceThumbnailMaxPixelSize ограничивает длинную сторону, а нам
 * нужно покрыть обе стороны рамки. Для кадра W×H и рамки w×h после заполнения
 * нужно, чтобы уменьшенный кадр был не меньше рамки по каждой стороне,
 * откуда потолок = max(w·L/W, h·L/H), где L — длинная сторона исходника.
 *
 * Размеры исходника берутся из свойств, а не декодированием: свойства ImageIO
 * читает из заголовка файла, не разбирая пикселей.
 */
+ (CGFloat)decodeLimitFor:(CGImageSourceRef)source target:(CGSize)target {
    CGFloat fallback = MAX(target.width, target.height);

    if (target.width <= 0 || target.height <= 0) {
        return fallback;
    }

    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (properties == NULL) {
        return fallback;
    }

    NSNumber *w = (__bridge NSNumber *)CFDictionaryGetValue(properties,
                                                            kCGImagePropertyPixelWidth);
    NSNumber *h = (__bridge NSNumber *)CFDictionaryGetValue(properties,
                                                            kCGImagePropertyPixelHeight);

    CGFloat sourceWidth = [w doubleValue];
    CGFloat sourceHeight = [h doubleValue];

    CFRelease(properties);

    if (sourceWidth <= 0 || sourceHeight <= 0) {
        return fallback;
    }

    CGFloat longest = MAX(sourceWidth, sourceHeight);

    CGFloat need = MAX(target.width * longest / sourceWidth,
                       target.height * longest / sourceHeight);

    // Крупнее исходника просить бессмысленно: ImageIO всё равно не придумает
    // пикселей, а вот памяти под увеличенный кадр отведёт честно.
    return MIN(need, longest);
}

+ (UIImage *)decode:(NSData *)data target:(CGSize)target {
    CGImageSourceRef source =
        CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);

    if (source == NULL) {
        return nil;
    }

    CGFloat width = [self decodeLimitFor:source target:target];

    // kCGImageSourceShouldCacheImmediately сюда просится — он заставляет
    // разобрать пиксели сразу, в этом самом фоновом потоке, а не при первой
    // отрисовке. Но появился он только в iOS 7, а константа эта — символ,
    // который разрешается при загрузке приложения: на 5.1 и 6 приложение
    // не запустилось бы вовсе с «Symbol not found». Обходимся без него.
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
        [NSNumber numberWithInt:(int)width], (id)kCGImageSourceThumbnailMaxPixelSize,
        nil];

    CGImageRef thumbnail =
        CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);

    CFRelease(source);

    if (thumbnail == NULL) {
        return nil;
    }

    UIImage *image = nil;

    if (KLSmallMemory()) {
        image = [self repack16bit:thumbnail];
    }

    if (image == nil) {
        image = [UIImage imageWithCGImage:thumbnail];
    }

    CGImageRelease(thumbnail);

    return image;
}

/**
 * Перекладывает кадр в 16 бит на пиксель: вдвое меньше памяти, а на
 * фотографии разница не видна.
 *
 * Делается только на устройствах с небольшой памятью: там это разница между
 * работающей лентой и закрытием по памяти. На остальных лишнее
 * преобразование каждого кадра дороже сэкономленного.
 *
 * Картинки с прозрачностью через это не пропускаем: в RGB555 альфы нет
 * вовсе (kCGImageAlphaNoneSkipFirst), а буфер под неё CoreGraphics выдаёт
 * обнулённым, то есть чёрным — прозрачный PNG почернел бы целиком.
 * Обложки и кадры серий прозрачными не бывают, так что экономия не страдает.
 */
+ (UIImage *)repack16bit:(CGImageRef)source {
    size_t width = CGImageGetWidth(source);
    size_t height = CGImageGetHeight(source);

    if (width == 0 || height == 0) {
        return nil;
    }

    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(source);

    BOOL opaque = (alpha == kCGImageAlphaNone ||
                   alpha == kCGImageAlphaNoneSkipFirst ||
                   alpha == kCGImageAlphaNoneSkipLast);

    if (!opaque) {
        // Возвращаем nil — вызывающий оставит картинку как есть.
        return nil;
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    // 5 бит на составляющую при 16 битах на пиксель — это RGB555 с одним
    // неиспользуемым битом.
    CGContextRef context = CGBitmapContextCreate(
        NULL, width, height, 5, width * 2, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Little);

    CGColorSpaceRelease(space);

    if (context == NULL) {
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);

    CGImageRef packed = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    if (packed == NULL) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:packed];
    CGImageRelease(packed);

    return image;
}

#pragma mark Загрузка

+ (UIImage *)fetch:(NSString *)url target:(CGSize)target {
    NSString *address = [self sized:url pixelWidth:MAX(target.width, target.height)];

    NSMutableURLRequest *request =
        KLRequest(address, NSURLRequestUseProtocolCachePolicy, 20.0);

    if (request == nil) {
        return nil;
    }

    // Тем же Safari, что и запросы к каталогу: часть CDN с картинками
    // отбирает по User-Agent охотнее, чем сами API.
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 9_3 like Mac OS X) "
                      @"AppleWebKit/601.1 (KHTML, like Gecko) Version/9.0 Mobile Safari/601.1"
   forHTTPHeaderField:@"User-Agent"];

    KLHttpResponse *response = [KLHttp send:request bodyLimit:0];

    if (![response isSuccessful]) {
        // Уменьшенного варианта не нашлось — берём как есть.
        if (![address isEqualToString:url]) {
            return [self fetch:url target:target];
        }

        return nil;
    }

    return [self decode:response.body target:target];
}

+ (UIImage *)download:(NSString *)url target:(CGSize)target {
    UIImage *image = [self fetch:url target:target];
    if (image == nil) {
        return nil;
    }

    CGFloat width = MAX(target.width, target.height);
    CGFloat have = MAX(CGImageGetWidth([image CGImage]), CGImageGetHeight([image CGImage]));

    // Исходник оказался мельче запрошенного — больше не просим.
    if (have < width) {
        @synchronized ([self exhausted]) {
            [[self exhausted] addObject:url];
        }
    }

    NSUInteger cost = (NSUInteger)(have * CGImageGetHeight([image CGImage]) *
                                   (KLSmallMemory() ? 2 : 4));

    [[self cache] setObject:image forKey:url cost:cost];

    return image;
}

#pragma mark Точки входа

/**
 * Переводит размер показа из точек в пиксели и подрезает по потолку.
 *
 * Потолок применяется к длинной стороне, а пропорция сохраняется: подрезать
 * стороны по отдельности значило бы исказить ту самую пропорцию, ради
 * которой размер и передаётся целиком.
 */
+ (CGSize)pixelSizeFor:(CGSize)target {
    CGFloat scale = 1.0;

    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        scale = [[UIScreen mainScreen] scale];
    }

    CGSize size = CGSizeMake(target.width * scale, target.height * scale);

    CGFloat longest = MAX(size.width, size.height);
    CGFloat ceiling = KLMaxDecodeWidth();

    if (longest > ceiling && longest > 0) {
        CGFloat k = ceiling / longest;
        size = CGSizeMake(size.width * k, size.height * k);
    }

    return size;
}

+ (void)loadInto:(UIView<KLImageTarget> *)view
             url:(NSString *)url
      targetSize:(CGSize)targetSize {
    if (view == nil) {
        return;
    }

    // Какой адрес сейчас ждёт эта карточка. Связанный объект вместо таблицы
    // со слабыми ключами: NSMapTable появилась только в iOS 6, а здесь метка
    // и так живёт ровно столько же, сколько сама карточка.
    objc_setAssociatedObject(view, (__bridge const void *)KLImageTag,
                             url, OBJC_ASSOCIATION_COPY_NONATOMIC);

    if ([url length] == 0) {
        [view setImage:nil];
        return;
    }

    CGSize pixels = [self pixelSizeFor:targetSize];
    CGFloat width = MAX(pixels.width, pixels.height);

    UIImage *ready = [self cachedFor:url pixelWidth:width];
    if (ready != nil) {
        [view setImage:ready];
        return;
    }

    [view setImage:nil];

    __weak UIView<KLImageTarget> *weakView = view;

    [[self queue] push:^{
        @autoreleasepool {
            // Пока запрос ждал очереди, карточку могли отдать другому тайтлу.
            UIView<KLImageTarget> *target = weakView;
            if (target == nil) {
                return;
            }

            NSString *wanted = objc_getAssociatedObject(target,
                                                        (__bridge const void *)KLImageTag);
            if (![wanted isEqualToString:url]) {
                return;
            }

            UIImage *image = nil;

            @synchronized ([self lockFor:url]) {
                // Пока ждали замок, картинку мог принести соседний поток.
                image = [self cachedFor:url pixelWidth:width];
                if (image == nil) {
                    image = [self download:url target:pixels];
                }
            }

            if (image == nil) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                UIView<KLImageTarget> *late = weakView;
                NSString *still = objc_getAssociatedObject(late,
                                                           (__bridge const void *)KLImageTag);

                if ([still isEqualToString:url]) {
                    [late setImage:image];
                }
            });
        }
    }];
}

+ (void)loadUrl:(NSString *)url
     targetSize:(CGSize)targetSize
     completion:(void (^)(UIImage *image))completion {
    if ([url length] == 0) {
        completion(nil);
        return;
    }

    CGSize pixels = [self pixelSizeFor:targetSize];
    CGFloat width = MAX(pixels.width, pixels.height);

    UIImage *ready = [self cachedFor:url pixelWidth:width];
    if (ready != nil) {
        completion(ready);
        return;
    }

    [[self queue] push:^{
        @autoreleasepool {
            UIImage *image = nil;

            @synchronized ([self lockFor:url]) {
                image = [self cachedFor:url pixelWidth:width];
                if (image == nil) {
                    image = [self download:url target:pixels];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    }];
}

+ (void)trim {
    [[self cache] removeAllObjects];
}

@end
