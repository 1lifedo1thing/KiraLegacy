#import "KLDiskCache.h"

#include <openssl/sha.h>

/** Сколько всего держим на диске. */
static const unsigned long long KLDiskCacheLimit = 48 * 1024 * 1024;

/** Через сколько записей проверять, не пора ли подчистить. */
static const NSInteger KLDiskCacheCheckEvery = 64;

/**
 * Заголовок записи — фиксированной длины, чтобы читать его одним куском.
 *
 * Разбирать заголовок текстом было бы удобнее, но запись тогда перестала бы
 * быть одним файлом с известным смещением тела: пришлось бы либо искать
 * разделитель, либо держать второй файл. А тело у обложки — сотни
 * килобайт, и лишнее чтение с флеш-памяти телефона 2011 года не бесплатно.
 */
typedef struct {
    uint32_t magic;
    uint32_t status;
    double   stored;      // время получения
    double   maxAge;      // сколько секунд он годен
    uint32_t typeLength;  // длина Content-Type следом за заголовком
    uint32_t reserved;
} KLDiskCacheHead;

static const uint32_t KLDiskCacheMagic = 0x4B4C4331;   // «KLC1»

@implementation KLDiskCache

+ (NSString *)directory {
    static NSString *directory = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSArray *paths =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);

        directory = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"kiralegacy-http"];

        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });

    return directory;
}

/**
 * Имя файла — свёртка адреса.
 *
 * Брать сам адрес нельзя: в нём косые черты, и длина ключа источника
 * доходит до полукилобайта, а предел на имя файла — 255 знаков.
 * SHA-1 здесь не про безопасность, а про равномерность: совпадение
 * двух разных адресов нам не угрожает ничем, кроме показанной не той
 * картинки, но и оно невероятно.
 */
+ (NSString *)pathForUrl:(NSString *)url {
    const char *bytes = [url UTF8String];

    unsigned char digest[SHA_DIGEST_LENGTH];
    SHA1((const unsigned char *)bytes, strlen(bytes), digest);

    NSMutableString *name = [NSMutableString stringWithCapacity:SHA_DIGEST_LENGTH * 2];

    for (int i = 0; i < SHA_DIGEST_LENGTH; i++) {
        [name appendFormat:@"%02x", digest[i]];
    }

    return [[self directory] stringByAppendingPathComponent:name];
}

/** Сколько секунд ответ годен по мнению сервера. Ноль — не хранить. */
+ (NSTimeInterval)lifetimeOf:(KLHttpResponse *)response {
    NSString *control = nil;

    for (NSString *key in response.headers) {
        if ([key caseInsensitiveCompare:@"Cache-Control"] == NSOrderedSame) {
            control = [[response.headers objectForKey:key] lowercaseString];
            break;
        }
    }

    if (control == nil) {
        return 0;
    }

    if ([control rangeOfString:@"no-store"].location != NSNotFound ||
        [control rangeOfString:@"no-cache"].location != NSNotFound ||
        [control rangeOfString:@"private"].location != NSNotFound) {
        return 0;
    }

    NSRange marker = [control rangeOfString:@"max-age="];

    if (marker.location == NSNotFound) {
        return 0;
    }

    NSString *tail = [control substringFromIndex:marker.location + marker.length];

    NSTimeInterval seconds = [tail doubleValue];

    /**
     * Больше месяца не держим, сколько бы ни обещал сервер.
     *
     * Обложки отдаются с max-age на год — и это честно, они не меняются.
     * Но кеш на год означает, что однажды испорченная запись останется
     * испорченной до переустановки приложения, а места на старом телефоне
     * мало. Месяц — срок, за который запись всё равно вытеснится.
     */
    return MIN(seconds, 30.0 * 24 * 3600);
}

+ (KLHttpResponse *)responseForUrl:(NSString *)url {
    NSString *path = [self pathForUrl:url];

    NSData *raw = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];

    if ([raw length] < sizeof(KLDiskCacheHead)) {
        return nil;
    }

    KLDiskCacheHead head;
    [raw getBytes:&head length:sizeof(head)];

    if (head.magic != KLDiskCacheMagic) {
        return nil;
    }

    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - head.stored;

    if (age < 0 || age > head.maxAge) {
        // Протухло — убираем сразу, чтобы не накапливать мёртвое.
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        return nil;
    }

    NSUInteger offset = sizeof(KLDiskCacheHead) + head.typeLength;

    if ([raw length] < offset) {
        return nil;
    }

    KLHttpResponse *response = [[KLHttpResponse alloc] init];

    response.statusCode = (NSInteger)head.status;
    response.body = [raw subdataWithRange:NSMakeRange(offset, [raw length] - offset)];
    response.expectedLength = (long long)[response.body length];

    if (head.typeLength > 0) {
        NSData *type = [raw subdataWithRange:
            NSMakeRange(sizeof(KLDiskCacheHead), head.typeLength)];

        NSString *text = [[NSString alloc] initWithData:type encoding:NSUTF8StringEncoding];

        if (text != nil) {
            response.headers = [NSDictionary dictionaryWithObject:text
                                                           forKey:@"Content-Type"];
        }
    }

    return response;
}

+ (void)store:(KLHttpResponse *)response forUrl:(NSString *)url {
    if (![response isSuccessful] || [response.body length] == 0) {
        return;
    }

    NSTimeInterval lifetime = [self lifetimeOf:response];

    if (lifetime <= 0) {
        return;
    }

    /**
     * Крупное на диск не кладём.
     *
     * Предел в восемь мегабайт отсекает не обложки — те укладываются
     * в сотни килобайт, — а случайно попавший сюда кусок видео: одна такая
     * запись вытеснила бы половину картинок разом.
     */
    if ([response.body length] > 8 * 1024 * 1024) {
        return;
    }

    NSString *type = nil;

    for (NSString *key in response.headers) {
        if ([key caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
            type = [response.headers objectForKey:key];
            break;
        }
    }

    NSData *typeData = [(type ?: @"") dataUsingEncoding:NSUTF8StringEncoding];

    KLDiskCacheHead head;
    memset(&head, 0, sizeof(head));

    head.magic = KLDiskCacheMagic;
    head.status = (uint32_t)response.statusCode;
    head.stored = [NSDate timeIntervalSinceReferenceDate];
    head.maxAge = lifetime;
    head.typeLength = (uint32_t)[typeData length];

    NSMutableData *file = [NSMutableData dataWithCapacity:
        sizeof(head) + [typeData length] + [response.body length]];

    [file appendBytes:&head length:sizeof(head)];
    [file appendData:typeData];
    [file appendData:response.body];

    [file writeToFile:[self pathForUrl:url] atomically:YES];

    [self noteWrite];
}

/** Считает записи и время от времени подчищает. */
+ (void)noteWrite {
    static NSInteger writes = 0;

    @synchronized (self) {
        if (++writes < KLDiskCacheCheckEvery) {
            return;
        }

        writes = 0;
    }

    [self trim];
}

/**
 * Выбрасывает самое давнее, пока не уложимся в предел.
 *
 * По времени последнего обращения, а не создания: обложка, которую
 * показывают на главном экране каждый запуск, должна пережить ту,
 * что открыли однажды и забыли.
 */
+ (void)trim {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [self directory];

    NSArray *names = [manager contentsOfDirectoryAtPath:directory error:NULL];

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[names count]];

    unsigned long long total = 0;

    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];

        if (attributes == nil) {
            continue;
        }

        unsigned long long size = [attributes fileSize];

        total += size;

        [entries addObject:[NSArray arrayWithObjects:
            path, [attributes fileModificationDate] ?: [NSDate distantPast],
            [NSNumber numberWithUnsignedLongLong:size], nil]];
    }

    if (total <= KLDiskCacheLimit) {
        return;
    }

    [entries sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[a objectAtIndex:1] compare:[b objectAtIndex:1]];
    }];

    for (NSArray *entry in entries) {
        if (total <= KLDiskCacheLimit / 2) {
            break;
        }

        [manager removeItemAtPath:[entry objectAtIndex:0] error:NULL];

        total -= [[entry objectAtIndex:2] unsignedLongLongValue];
    }

    NSLog(@"[Кира/Кеш] Подчищено до %llu КБ", total / 1024);
}

+ (unsigned long long)size {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [self directory];

    unsigned long long total = 0;

    for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:NULL]) {
        NSDictionary *attributes = [manager
            attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];

        total += [attributes fileSize];
    }

    return total;
}

+ (void)clear {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [self directory];

    for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:NULL]) {
        [manager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
    }
}

@end
