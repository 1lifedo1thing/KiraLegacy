#import "KLCertificates.h"

#import "KLStrings.h"

/**
 * Base64 своей рукой: штатный base64EncodedStringWithOptions появился
 * в iOS 7, а нижняя граница здесь 5.1. Алфавит обычный, с добивкой.
 */
static NSString *KLBase64(NSData *data) {
    static const char *alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];

    NSMutableString *result = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];

    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger remaining = length - i;

        uint32_t chunk = (uint32_t)bytes[i] << 16;
        if (remaining > 1) chunk |= (uint32_t)bytes[i + 1] << 8;
        if (remaining > 2) chunk |= (uint32_t)bytes[i + 2];

        [result appendFormat:@"%c%c", alphabet[(chunk >> 18) & 63], alphabet[(chunk >> 12) & 63]];
        [result appendFormat:@"%c", remaining > 1 ? alphabet[(chunk >> 6) & 63] : '='];
        [result appendFormat:@"%c", remaining > 2 ? alphabet[chunk & 63] : '='];
    }

    return result;
}

static NSString *KLUuid(void) {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef text = CFUUIDCreateString(NULL, uuid);

    NSString *value = [NSString stringWithString:(__bridge NSString *)text];

    CFRelease(text);
    CFRelease(uuid);

    return value;
}

@implementation KLCertificates

+ (NSArray *)fileNames {
    /**
     * Семь корней на десяток хостов.
     *
     * GTS Root R4 закрывает почти всё: AniList с обложками, разрешатель
     * на Cloudflare и все зеркала видео — megavid, vidnest, megaplay,
     * zokoanime — вместе с их CDN. Проверено разбором цепочек: у всех
     * промежуточный WE1, и его сервер присылает сам, нам нужен корень.
     *
     * GTS Root R1…R3 сегодня не нужны ни одному из хостов, и лежат здесь
     * как страховка. Google Trust Services выпускает не из одного корня:
     * промежуточный WE1 подписан R4, а WR2 — первым, и какой из них
     * окажется у зеркала завтра, решаем не мы. Цена вопроса — по килобайту
     * на корень; цена ошибки — приложение, которое в один день перестаёт
     * открывать всё подряд, и починить это можно только новой сборкой.
     *
     * Amazon Root CA 1 — кадры серий с thetvdb.
     *
     * ISRG Root X2 — файлы субтитров: они лежат отдельно от видео,
     * и площадка у них своя, с сертификатом Let's Encrypt. Через него же
     * идёт AniWave: echovideo отвечает цепочкой X2 ← X1.
     *
     * ISRG Root X1 — тот же Let's Encrypt, но старший корень. Нужен и сам
     * по себе, и как страховка: X2 кросс-подписан им, и если зеркало
     * пришлёт цепочку через X1, она сойдётся тоже.
     */
    return [NSArray arrayWithObjects:
            @"gts_root_r1", @"gts_root_r2", @"gts_root_r3", @"gts_root_r4",
            @"amazon_root_ca1",
            @"isrg_root_x1", @"isrg_root_x2", nil];
}

+ (NSString *)titleForName:(NSString *)name {
    if ([name isEqualToString:@"gts_root_r1"]) return @"GTS Root R1";
    if ([name isEqualToString:@"gts_root_r2"]) return @"GTS Root R2";
    if ([name isEqualToString:@"gts_root_r3"]) return @"GTS Root R3";
    if ([name isEqualToString:@"gts_root_r4"]) return @"GTS Root R4";
    if ([name isEqualToString:@"amazon_root_ca1"]) return @"Amazon Root CA 1";
    if ([name isEqualToString:@"isrg_root_x1"]) return @"ISRG Root X1";
    if ([name isEqualToString:@"isrg_root_x2"]) return @"ISRG Root X2";

    return name;
}

+ (NSString *)purposeForName:(NSString *)name {
    // Ключ собирается из имени файла: список корней и список переводов
    // тогда не могут разойтись молча — недостающий перевод виден сразу.
    return KLStr([NSString stringWithFormat:@"cert.%@", name]);
}

+ (NSData *)dataForName:(NSString *)name {
    NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                     ofType:@"der"
                                                inDirectory:@"certs"];

    return path != nil ? [NSData dataWithContentsOfFile:path] : nil;
}

+ (NSData *)configurationProfile {
    NSMutableString *payloads = [NSMutableString string];

    for (NSString *name in [self fileNames]) {
        NSData *data = [self dataForName:name];
        if ([data length] == 0) {
            NSLog(@"[Кира/Certs] Корень %@ не найден в связке", name);
            continue;
        }

        NSString *title = [self titleForName:name];

        [payloads appendString:@"\t\t<dict>\n"];
        [payloads appendString:@"\t\t\t<key>PayloadType</key>\n"
                               @"\t\t\t<string>com.apple.security.root</string>\n"];
        [payloads appendString:@"\t\t\t<key>PayloadVersion</key>\n\t\t\t<integer>1</integer>\n"];
        [payloads appendFormat:@"\t\t\t<key>PayloadIdentifier</key>\n"
                               @"\t\t\t<string>ru.computershik.kiralegacy.root.%@</string>\n", name];
        [payloads appendFormat:@"\t\t\t<key>PayloadUUID</key>\n\t\t\t<string>%@</string>\n",
                               KLUuid()];
        [payloads appendFormat:@"\t\t\t<key>PayloadDisplayName</key>\n\t\t\t<string>%@</string>\n",
                               title];
        [payloads appendFormat:@"\t\t\t<key>PayloadCertificateFileName</key>\n"
                               @"\t\t\t<string>%@.cer</string>\n", name];
        [payloads appendFormat:@"\t\t\t<key>PayloadContent</key>\n\t\t\t<data>\n%@\n\t\t\t</data>\n",
                               KLBase64(data)];
        [payloads appendString:@"\t\t</dict>\n"];
    }

    NSString *profile = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\">\n"
        @"<dict>\n"
        @"\t<key>PayloadContent</key>\n"
        @"\t<array>\n%@\t</array>\n"
        @"\t<key>PayloadType</key>\n\t<string>Configuration</string>\n"
        @"\t<key>PayloadVersion</key>\n\t<integer>1</integer>\n"
        @"\t<key>PayloadIdentifier</key>\n"
        @"\t<string>ru.computershik.kiralegacy.roots</string>\n"
        @"\t<key>PayloadUUID</key>\n\t<string>%@</string>\n"
        @"\t<key>PayloadOrganization</key>\n\t<string>Кира</string>\n"
        @"\t<key>PayloadDisplayName</key>\n\t<string>Корни для Киры</string>\n"
        @"\t<key>PayloadDescription</key>\n"
        @"\t<string>Корневые сертификаты, которых нет в хранилище старых iOS: "
        @"GTS Root R4 (каталог AniList и все зеркала видео), "
        @"Amazon Root CA 1 (кадры серий), ISRG Root X2 (файлы субтитров) "
        @"и ISRG Root X1. Нужны, чтобы плеер мог забирать видео напрямую, "
        @"без прокси на петле.</string>\n"
        @"\t<key>PayloadRemovalDisallowed</key>\n\t<false/>\n"
        @"</dict>\n"
        @"</plist>\n", payloads, KLUuid()];

    return [profile dataUsingEncoding:NSUTF8StringEncoding];
}

@end
