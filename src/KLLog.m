#import "KLLog.h"

/**
 * Здесь NSLog нужен настоящий.
 *
 * Ключ -include подставляет KLLog.h в самое начало каждого файла, включая
 * этот, — раньше любых наших строк. Поэтому объявить что-либо «до» подмены
 * нельзя, её можно только снять, и делается это здесь.
 */
#undef NSLog

/**
 * Потолок на размер журнала.
 *
 * Приложение пишет немало — каждый запрос к каталогу, каждая порция обложек, —
 * и без потолка файл рос бы неограниченно. По достижении предела он
 * откладывается в сторону и начинается новый: так под рукой всегда есть
 * не меньше полумегабайта истории, а больше двух файлов журнал не занимает.
 */
static const unsigned long long KLLogLimit = 512 * 1024;

static NSString *KLLogFolder(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

NSString *KLLogPath(void) {
    return [KLLogFolder() stringByAppendingPathComponent:@"kiralegacy.log"];
}

static NSString *KLLogPreviousPath(void) {
    return [KLLogFolder() stringByAppendingPathComponent:@"kiralegacy-prev.log"];
}

/** Очередь одна на всё: писать в файл из нескольких потоков разом нельзя. */
static dispatch_queue_t KLLogQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ru.computershik.kiralegacy.log",
                                      DISPATCH_QUEUE_SERIAL);
    });

    return queue;
}

static NSDateFormatter *KLLogClock(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"HH:mm:ss.SSS"];
    });

    return formatter;
}

void KLLogClear(void) {
    dispatch_sync(KLLogQueue(), ^{
        NSFileManager *manager = [NSFileManager defaultManager];

        [manager removeItemAtPath:KLLogPath() error:NULL];
        [manager removeItemAtPath:KLLogPreviousPath() error:NULL];
    });
}

void KLLogWrite(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);

    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    // В системный журнал тоже: при отладке через 3uTools или SSH удобнее
    // видеть строки сразу, а не доставать файл.
    NSLog(@"%@", message);

    dispatch_async(KLLogQueue(), ^{
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                              [KLLogClock() stringFromDate:[NSDate date]], message];

            NSFileManager *manager = [NSFileManager defaultManager];
            NSString *path = KLLogPath();

            if (![manager fileExistsAtPath:path]) {
                [manager createFileAtPath:path contents:nil attributes:nil];
            }

            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
            if (file == nil) {
                return;
            }

            unsigned long long size = [file seekToEndOfFile];
            [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [file closeFile];

            if (size + [line length] < KLLogLimit) {
                return;
            }

            // Предел достигнут: нынешний файл становится предыдущим.
            [manager removeItemAtPath:KLLogPreviousPath() error:NULL];
            [manager moveItemAtPath:path toPath:KLLogPreviousPath() error:NULL];
        }
    });
}
