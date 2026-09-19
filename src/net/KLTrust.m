#import "KLTrust.h"

#import <CommonCrypto/CommonDigest.h>

#import "KLCertificates.h"

/** Имя сертификата; определена ниже, а нужна уже в KLBundledAnchors. */
static NSString *KLCertificateName(SecCertificateRef certificate);

/**
 * Системные корни плюс свои. Проверка идёт по очереди: сначала спрашиваем
 * систему, и только если она отказала — добавляем вшитые корни якорями и
 * спрашиваем ещё раз.
 *
 * На новом устройстве отрабатывает первый путь, и поведение приложения ничем
 * не отличается от обычного.
 */
static BOOL KLTrustResultIsOk(SecTrustResultType result) {
    return result == kSecTrustResultUnspecified || result == kSecTrustResultProceed;
}

/** Вшитые корни из Resources/certs. Читаются один раз. */
NSArray *KLBundledAnchors(void) {
    static NSArray *anchors = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSMutableArray *loaded = [NSMutableArray array];

        for (NSString *name in [KLCertificates fileNames]) {
            NSData *data = [KLCertificates dataForName:name];

            if ([data length] == 0) {
                NSLog(@"[Кира/TLS] Корень %@ не найден в связке", name);
                continue;
            }

            SecCertificateRef certificate =
                SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);

            if (certificate != NULL) {
                [loaded addObject:(__bridge_transfer id)certificate];
            } else {
                NSLog(@"[Кира/TLS] Корень %@ не разобран", name);
            }
        }

        NSLog(@"[Кира/TLS] Своих корней подставлено: %lu", (unsigned long)[loaded count]);

        /**
         * Имена пишутся один раз, и не для красоты: если файл подменён
         * или обрезан, разбор пройдёт, а имя окажется чужим — увидеть это
         * можно только так.
         */
        for (id certificate in loaded) {
            NSLog(@"[Кира/TLS]   корень: %@",
                  KLCertificateName((__bridge SecCertificateRef)certificate) ?: @"без имени");
        }

        anchors = [loaded copy];
    });

    return anchors;
}

/** Словами — чтобы в журнале был не голый номер. */
static NSString *KLTrustResultName(SecTrustResultType result) {
    switch (result) {
        case kSecTrustResultInvalid:                 return @"Invalid";
        case kSecTrustResultProceed:                 return @"Proceed";
        case kSecTrustResultDeny:                    return @"Deny";
        case kSecTrustResultUnspecified:             return @"Unspecified";
        case kSecTrustResultRecoverableTrustFailure: return @"RecoverableTrustFailure";
        case kSecTrustResultFatalTrustFailure:       return @"FatalTrustFailure";
        case kSecTrustResultOtherError:              return @"OtherError";
        default:                                     return @"?";
    }
}

/** Имя сертификата — нужно и для журнала, и чтобы сверять звенья с якорями. */
static NSString *KLCertificateName(SecCertificateRef certificate) {
    CFStringRef summary = SecCertificateCopySubjectSummary(certificate);

    if (summary == NULL) {
        return nil;
    }

    NSString *name = [NSString stringWithString:(__bridge NSString *)summary];

    CFRelease(summary);

    return name;
}

/** Сертификаты, которые прислал сервер, в порядке от листа к корню. */
static NSArray *KLChainOf(SecTrustRef trust) {
    NSMutableArray *chain = [NSMutableArray array];

    CFIndex count = SecTrustGetCertificateCount(trust);

    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, i);

        if (certificate != NULL) {
            [chain addObject:(__bridge id)certificate];
        }
    }

    return chain;
}

/**
 * Проверяет цепочку на **свежем** объекте доверия, а не на присланном.
 *
 * Это не перестраховка. SecTrustEvaluate запоминает свой ответ внутри
 * объекта, и повторный вызов после подмены якорей на старых системах
 * возвращает прежний результат — то есть отказ, сколько корней ни добавь.
 * Снаружи это выглядит как «свои корни не работают»: они и не работали,
 * потому что до них дело не доходило.
 *
 * Заодно здесь задаётся своя политика SSL с именем узла: у присланного
 * объекта она уже есть, но, собирая объект заново, её надо поставить
 * самим — иначе имя в сертификате никто не сверит, и проверка станет
 * слабее системной.
 */
static BOOL KLEvaluateWithAnchors(NSArray *chain, NSString *host,
                                  NSArray *anchors, BOOL anchorsOnly) {
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);

    if (policy == NULL) {
        return NO;
    }

    SecTrustRef trust = NULL;

    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)chain,
                                                     policy, &trust);
    CFRelease(policy);

    if (status != errSecSuccess || trust == NULL) {
        NSLog(@"[Кира/TLS] Объект доверия не создан: %ld", (long)status);
        return NO;
    }

    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
    SecTrustSetAnchorCertificatesOnly(trust, anchorsOnly);

    SecTrustResultType result = kSecTrustResultInvalid;

    status = SecTrustEvaluate(trust, &result);

    NSLog(@"[Кира/TLS] Со своими корнями (%@): %@ (код %ld)",
          anchorsOnly ? @"только они" : @"вместе с системными",
          KLTrustResultName(result), (long)status);

    CFRelease(trust);

    return status == errSecSuccess && KLTrustResultIsOk(result);
}

BOOL KLTrustIsValid(SecTrustRef trust, NSString *host) {
    SecTrustResultType result = kSecTrustResultInvalid;

    OSStatus status = SecTrustEvaluate(trust, &result);

    if (status == errSecSuccess && KLTrustResultIsOk(result)) {
        return YES;
    }

    /**
     * Системе цепочка не понравилась. Дальше — свои корни, но прежде стоит
     * записать, что вообще происходит: без этого «цепочка не признана»
     * не отличить от десятка разных причин.
     *
     * Часы пишутся не зря: на устройстве, пролежавшем в ящике, дата
     * сбрасывается, и тогда **любой** сертификат оказывается просроченным
     * или ещё не начавшим действовать. Выглядит это ровно как отказ
     * доверия, а чинится переводом часов.
     */
    NSLog(@"[Кира/TLS] %@: система отвергла — %@ (код %ld), часы устройства %@",
          host, KLTrustResultName(result), (long)status, [NSDate date]);

    NSArray *chain = KLChainOf(trust);

    NSLog(@"[Кира/TLS] Прислано звеньев: %lu", (unsigned long)[chain count]);

    for (NSUInteger i = 0; i < [chain count]; i++) {
        NSString *name =
            KLCertificateName((__bridge SecCertificateRef)[chain objectAtIndex:i]);

        NSLog(@"[Кира/TLS]   %lu: %@", (unsigned long)i, name ?: @"без имени");
    }

    NSArray *anchors = KLBundledAnchors();

    if ([anchors count] == 0 || [chain count] == 0) {
        return NO;
    }

    // Сначала свои корни вместе с системными: так проверка остаётся
    // не слабее обычной.
    if (KLEvaluateWithAnchors(chain, host, anchors, NO)) {
        return YES;
    }

    /**
     * Не вышло — пробуем только свои.
     *
     * Разница не косметическая: пока системные якоря в силе, построитель
     * пути вправе довести цепочку до корня из хранилища и на нём же
     * отказать, не пробуя наш самоподписанный. Запрет на чужие якоря
     * убирает этот тупик.
     *
     * Слабее от этого не становится: наши корни — это и есть те, кем выдано
     * всё, к чему приложение обращается.
     */
    if (KLEvaluateWithAnchors(chain, host, anchors, YES)) {
        return YES;
    }

    /**
     * Последняя ступень: убрать из присланного то, что мешает.
     *
     * Зеркала присылают не только лист и промежуточный, но и
     * **кросс-подписанный** GTS Root R4 — тот, что выдан старым
     * GlobalSign Root CA. Проверено на живых серверах: так отвечают и
     * vidnest, и megavid, и megaplay, и сам AniList. Для нового устройства
     * это подарок — цепочка замыкается на GlobalSign, который в системе есть
     * с незапамятных времён. Для нас помеха: построитель видит в присланном
     * готовое продолжение и тянет путь к GlobalSign, вместо того чтобы
     * остановиться на нашем самоподписанном корне с тем же именем.
     *
     * Поэтому здесь из входного набора выбрасывается всё, чьё имя совпадает
     * с именем одного из наших корней: остаются лист и промежуточные,
     * а замкнуть путь можно только нашим якорем.
     */
    NSMutableSet *anchorNames = [NSMutableSet set];

    for (id certificate in anchors) {
        NSString *name = KLCertificateName((__bridge SecCertificateRef)certificate);

        if (name != nil) {
            [anchorNames addObject:name];
        }
    }

    NSMutableArray *trimmed = [NSMutableArray array];

    for (id certificate in chain) {
        NSString *name = KLCertificateName((__bridge SecCertificateRef)certificate);

        if (name == nil || ![anchorNames containsObject:name]) {
            [trimmed addObject:certificate];
        }
    }

    if ([trimmed count] == 0 || [trimmed count] == [chain count]) {
        // Выбрасывать оказалось нечего — эта ступень ничего не добавит.
        return NO;
    }

    NSLog(@"[Кира/TLS] Пробуем без присланных корней: осталось %lu звеньев",
          (unsigned long)[trimmed count]);

    return KLEvaluateWithAnchors(trimmed, host, anchors, YES);
}

#pragma mark - Память о проверенном

/**
 * Однажды признанная цепочка помнится несколько минут.
 *
 * Проверка стоит недёшево: построение пути, разбор дат, подписи — и всё это
 * на процессоре 2011 года. А повторяется она постоянно и на одном и том же:
 * три зеркала vidnest опрашиваются одновременно и присылают один и тот же
 * сертификат, обложки идут с одного хоста десятками, сегменты видео —
 * сотнями.
 *
 * Ключ — имя узла вместе со свёрткой самого сертификата, а не одно имя.
 * Это принципиально: запомни мы решение по имени, подменивший сертификат
 * получил бы наше доверие даром. А при совпадении и имени, и всех байтов
 * листа решение может быть только тем же, каким было.
 *
 * Помнятся только признанные. Отказ не помнится вовсе: он чаще всего
 * временный — сбитые часы, недоступный посредник, — и повторная проверка
 * после починки должна пройти сразу, а не через десять минут.
 *
 * Десять минут — срок, за который отозванный сертификат перестанет
 * приниматься. Дольше держать нельзя, короче — незачем.
 */
static const NSTimeInterval KLTrustMemory = 600.0;

/** Сколько узлов помним. Их у приложения около десятка. */
static const NSUInteger KLTrustMemorySize = 24;

static NSMutableDictionary *KLTrustSeen(void) {
    static NSMutableDictionary *seen = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ seen = [[NSMutableDictionary alloc] init]; });

    return seen;
}

/** Имя узла и свёртка листа — вместе. */
static NSString *KLTrustKey(NSArray *chain, NSString *host) {
    NSData *leaf = (__bridge_transfer NSData *)
        SecCertificateCopyData((__bridge SecCertificateRef)[chain objectAtIndex:0]);

    if ([leaf length] == 0) {
        return nil;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([leaf bytes], (CC_LONG)[leaf length], digest);

    NSMutableString *key = [NSMutableString stringWithString:host];

    [key appendString:@"|"];

    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [key appendFormat:@"%02x", digest[i]];
    }

    return key;
}

BOOL KLTrustChainIsValid(NSArray *chain, NSString *host) {
    if ([chain count] == 0 || [host length] == 0) {
        return NO;
    }

    NSString *key = KLTrustKey(chain, host);
    NSMutableDictionary *seen = KLTrustSeen();

    if (key != nil) {
        @synchronized (seen) {
            NSDate *when = [seen objectForKey:key];

            if (when != nil) {
                if (-[when timeIntervalSinceNow] < KLTrustMemory) {
                    return YES;
                }

                [seen removeObjectForKey:key];
            }
        }
    }

    /**
     * Сначала — как проверяет система: её якоря и больше ничего.
     *
     * Пустой список якорей означал бы «не доверять никому», поэтому
     * системное хранилище спрашивается отдельным вызовом, без подмены.
     * На новом устройстве этим всё и кончается.
     */
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);

    if (policy != NULL) {
        SecTrustRef trust = NULL;

        OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)chain,
                                                         policy, &trust);
        CFRelease(policy);

        if (status == errSecSuccess && trust != NULL) {
            BOOL ok = KLTrustIsValid(trust, host);

            CFRelease(trust);

            if (ok && key != nil) {
                @synchronized (seen) {
                    // Список короткий и живёт минутами: когда он переполнен,
                    // проще очистить весь, чем искать самую давнюю запись.
                    if ([seen count] >= KLTrustMemorySize) {
                        [seen removeAllObjects];
                    }

                    [seen setObject:[NSDate date] forKey:key];
                }
            }

            return ok;
        }
    }

    return NO;
}
