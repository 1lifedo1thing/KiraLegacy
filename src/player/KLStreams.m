#import "KLStreams.h"

#import <sys/sysctl.h>

/**
 * Уровень H.264 по высоте кадра — обычной функцией, а не методом класса.
 *
 * Так она написана не для красоты. Раньше это была +maxAvcLevel, и её звали
 * из строки журнала внутри dispatch_once в +maxVideoHeight. А +maxAvcLevel
 * начинается с обращения к +maxVideoHeight — то есть входит в тот же
 * dispatch_once, который в этот момент ещё выполняется.
 *
 * Повторный вход в незавершённый dispatch_once — это вечное ожидание:
 * поток встаёт намертво, без падения и без единой записи. Снаружи это
 * выглядело как «видео не открывается»: прокси получал плейлист, начинал
 * отбирать дорожки по возможностям устройства — и умолкал на первом же
 * обращении к потолку. Плеер ждал ответа, которого уже некому было послать.
 *
 * Обычная функция ни в какой dispatch_once не входит, и звать её можно
 * откуда угодно, в том числе изнутри блока.
 */
static NSInteger KLLevelForHeight(NSInteger height) {
    // Те же ступени, что у высоты кадра: 480p — это Baseline 3.0,
    // 720p — 3.1, 1080p — 4.1.
    if (height <= 480) return 30;
    if (height <= 720) return 31;

    return 41;
}

@implementation KLStreams

+ (NSString *)deviceModel {
    static NSString *model = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        size_t length = 0;
        sysctlbyname("hw.machine", NULL, &length, NULL, 0);

        if (length == 0) {
            model = @"";
            return;
        }

        char *value = malloc(length);
        sysctlbyname("hw.machine", value, &length, NULL, 0);

        model = [NSString stringWithCString:value encoding:NSUTF8StringEncoding];
        free(value);
    });

    return model;
}

+ (NSInteger)maxVideoHeight {
    static NSInteger ceiling = 0;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSString *model = [self deviceModel];

        // Номер поколения внутри семейства: iPad2,1 → 2.
        NSInteger generation = 0;
        NSScanner *scanner = [NSScanner scannerWithString:model];

        [scanner scanCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:NULL];
        [scanner scanInteger:&generation];

        if ([model hasPrefix:@"iPhone"]) {
            /**
             * iPhone2,1 — это 3GS: Baseline 3.1, дальше 640×480 он не идёт.
             * iPhone3,x — «четвёрка» на A4: 720p.
             * iPhone4,1 — 4S на A5, и вот он уже 1080p High 4.1.
             */
            ceiling = generation <= 2 ? 480 : (generation <= 3 ? 720 : 1080);
        } else if ([model hasPrefix:@"iPod"]) {
            // iPod touch 3G и 4G — та же связка, что у 3GS и «четвёрки».
            ceiling = generation <= 3 ? 480 : (generation <= 4 ? 720 : 1080);
        } else if ([model hasPrefix:@"iPad"]) {
            /**
             * Здесь легко ошибиться на одно поколение, и эта ошибка уже была
             * совершена — в Трубаче, откуда таблица и пришла: там 720p
             * отведено только iPad1, а iPad2 отнесён к 1080p.
             *
             * Это неверно. iPad 2 — это A5, и Apple для него объявляет
             * «H.264 до 720p, Main profile уровня 3.1», ровно как для iPad 1
             * на A4. Тысяча восемьдесят появляется только с iPad 3 (A5X).
             * Под тот же A5 попадает и iPad mini первого поколения — он
             * значится как iPad2,5…2,7.
             *
             * Стоила эта единица ровно того, ради чего таблица и заведена:
             * на iPad 2 плеер получал 1080p и захлёбывался.
             */
            ceiling = generation <= 2 ? 720 : 1080;
        } else {
            // Симулятор и всё незнакомое: судим по памяти — у слабых
            // устройств этой эпохи её не больше 256 МБ.
            ceiling = [[NSProcessInfo processInfo] physicalMemory] < 512ULL * 1024 * 1024
                ? 480 : 1080;
        }

        NSLog(@"[Кира/Плеер] %@: потолок %ldp, уровень %ld",
              model, (long)ceiling, (long)KLLevelForHeight(ceiling));
    });

    return ceiling;
}

+ (NSInteger)maxAvcLevel {
    return KLLevelForHeight([self maxVideoHeight]);
}

+ (NSInteger)avcLevelIn:(NSString *)codecs {
    // Строка вида «avc1.640032,mp4a.40.2»: после точки шесть шестнадцатеричных
    // цифр — профиль, ограничения и уровень. Уровень в последних двух.
    NSRange marker = [codecs rangeOfString:@"avc1."];
    if (marker.location == NSNotFound) {
        return 0;
    }

    NSUInteger start = marker.location + marker.length;
    if ([codecs length] < start + 6) {
        return 0;
    }

    NSString *level = [codecs substringWithRange:NSMakeRange(start + 4, 2)];

    unsigned int value = 0;
    if (![[NSScanner scannerWithString:level] scanHexInt:&value]) {
        return 0;
    }

    return (NSInteger)value;
}

@end
