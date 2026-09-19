#import "KLTls.h"

#include <sys/socket.h>
#include <sys/time.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#import "KLCertificates.h"
#import "KLTrust.h"

NSString *const KLTlsErrorDomain = @"ru.computershik.kiralegacy.tls";
const NSInteger KLTlsReadTimedOut = -2;

static SSL_CTX *gContext = NULL;

/** Ошибка OpenSSL словами; определена ниже, нужна уже в прогреве. */
static NSString *KLTlsOpenSSLError(void);

@implementation KLTls {
    NSString *_host;
    uint16_t  _port;
    BOOL      _secure;
    int       _socket;
    SSL      *_ssl;

    /** Последний заданный срок на чтение — он же потолок для циклов ниже. */
    NSTimeInterval _readTimeout;
}

@synthesize protocolName = _protocolName;
@synthesize cipherName = _cipherName;

#pragma mark - Подготовка библиотеки

/**
 * Прогрев: разбираем один вшитый корень до того, как появится многопоточность.
 *
 * Это не проверка ради проверки. На версии 3.5.4 приложение падало ровно
 * здесь — внутри разбора открытого ключа из сертификата сервера, когда три
 * потока впервые жали руки одновременно и наперегонки поднимали реестр
 * методов. Версию сменили, подсистемы этой больше нет, но правило осталось:
 * первый разбор происходит на одном потоке, внутри dispatch_once, и о его
 * исходе есть строка в журнале.
 *
 * Если библиотека вдруг окажется нерабочей, это видно первой же записью
 * при запуске, а не через полминуты молчания на первой картинке.
 */
static void KLTlsWarmUp(void) {
    NSArray *names = [KLCertificates fileNames];

    if ([names count] == 0) {
        return;
    }

    NSData *der = [KLCertificates dataForName:[names objectAtIndex:0]];

    if ([der length] == 0) {
        NSLog(@"[Кира/TLS] Прогрев: корень не прочитан");
        return;
    }

    const unsigned char *bytes = (const unsigned char *)[der bytes];
    X509 *certificate = d2i_X509(NULL, &bytes, (long)[der length]);

    if (certificate == NULL) {
        NSLog(@"[Кира/TLS] Прогрев: сертификат не разобран — %@", KLTlsOpenSSLError());
        return;
    }

    EVP_PKEY *key = X509_get_pubkey(certificate);

    NSLog(@"[Кира/TLS] Прогрев: ключ %@",
          key != NULL ? @"разобран" : @"НЕ разобран");

    if (key != NULL) {
        EVP_PKEY_free(key);
    }

    X509_free(certificate);
}

+ (void)prepare {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        SSL_library_init();
        SSL_load_error_strings();

        // TLS_client_method — «любая версия, договоримся по ходу».
        // Нижняя граница задаётся отдельно: TLS 1.2. Ниже не пойдёт ни один
        // из наших хостов — проверено, TLS 1.0 у них отключён целиком, —
        // а клиент, предлагающий протокол из девяностых, сам себя объявляет
        // подозрительным.
        gContext = SSL_CTX_new(TLS_client_method());

        if (gContext == NULL) {
            NSLog(@"[Кира/TLS] Контекст не создался");
            return;
        }

        SSL_CTX_set_min_proto_version(gContext, TLS1_2_VERSION);

        /**
         * Проверку цепочки библиотеке не поручаем вовсе.
         *
         * Свой набор корней у OpenSSL был бы ровно тем, что мы в него
         * положим, — семь штук, — и любой хост, сменивший поставщика
         * сертификатов, отвалился бы до новой сборки. Системное хранилище
         * на устройстве новее iOS 9 знает весь мир, и отдавать это даром
         * незачем.
         *
         * Поэтому рукопожатие идёт без проверки, а цепочку разбирает
         * KLTrust уже после — системными якорями, а если те отказали,
         * своими. Соединением при этом ещё не пользовались: первый байт
         * запроса уходит только после того, как проверка прошла.
         */
        SSL_CTX_set_verify(gContext, SSL_VERIFY_NONE, NULL);

        // Сжатие TLS выключено: оно давно признано опасным (CRIME),
        // и современные клиенты его не предлагают — а мы хотим выглядеть
        // современным клиентом.
        SSL_CTX_set_options(gContext, SSL_OP_NO_COMPRESSION);

        /**
         * Набор шифров — как у нынешних мобильных приложений, и порядок
         * здесь такая же примета клиента, как User-Agent.
         *
         * Хвост из CBC оставлен намеренно: сегодня все зеркала их принимают,
         * и если сервер однажды окажется старее нас, соединение не пропадёт.
         */
#if defined(__arm__)
        /**
         * На 32 битах впереди идёт ChaCha20, и это не вкусовщина.
         *
         * Аппаратного AES у armv7 нет вовсе — команды шифрования появились
         * только в ARMv8, то есть на arm64. Значит, AES-GCM там считается
         * обычным кодом, и медленно: перестановки по таблицам плюс умножение
         * в поле Галуа для проверки целостности. ChaCha20-Poly1305 — сложение,
         * поворот, исключающее или; на том же процессоре она выходит в разы
         * быстрее.
         *
         * Заметно это не на видео — там и медленного хватает с запасом, —
         * а на разряде батареи и на нагреве корпуса при долгом просмотре.
         */
        SSL_CTX_set_cipher_list(gContext,
            "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:"
            "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
            "ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:"
            "ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:AES128-GCM-SHA256");

        SSL_CTX_set_ciphersuites(gContext,
            "TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384");
#else
        // На arm64 наоборот: AES там в железе, и он быстрее всего остального.
        SSL_CTX_set_cipher_list(gContext,
            "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
            "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:"
            "ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:"
            "ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:AES128-GCM-SHA256");

        SSL_CTX_set_ciphersuites(gContext,
            "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256");
#endif

        NSLog(@"[Кира/TLS] %s", OpenSSL_version(OPENSSL_VERSION));

        KLTlsWarmUp();
    });
}

+ (NSString *)libraryVersion {
    [self prepare];

    // Строка вида «OpenSSL 3.5.4 30 Sep 2025» — оставляем первые два слова.
    NSArray *words = [[NSString stringWithUTF8String:OpenSSL_version(OPENSSL_VERSION)]
                      componentsSeparatedByString:@" "];

    return [words count] >= 2
        ? [NSString stringWithFormat:@"%@ %@",
           [words objectAtIndex:0], [words objectAtIndex:1]]
        : @"OpenSSL";
}

#pragma mark - Жизненный цикл

- (id)initWithHost:(NSString *)host port:(uint16_t)port secure:(BOOL)secure {
    self = [super init];

    if (self != nil) {
        _host = [host copy];
        _port = port;
        _secure = secure;
        _socket = -1;
    }

    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_ssl != NULL) {
        // Одного вызова достаточно: дожидаться ответного «до свидания»
        // незачем — соединение мы и так закрываем.
        SSL_shutdown(_ssl);
        SSL_free(_ssl);
        _ssl = NULL;
    }

    if (_socket >= 0) {
        close(_socket);
        _socket = -1;
    }
}

#pragma mark - Ошибки

static NSError *KLTlsMakeError(KLTlsErrorCode code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    return [NSError errorWithDomain:KLTlsErrorDomain
                               code:code
                           userInfo:[NSDictionary dictionaryWithObject:text
                                                                forKey:NSLocalizedDescriptionKey]];
}

/**
 * Последняя ошибка OpenSSL человеческими словами.
 *
 * Очередь надо разгребать до конца: иначе следующая операция увидит чужую
 * запись и объяснит происходящее совершенно неверно.
 */
static NSString *KLTlsOpenSSLError(void) {
    NSMutableArray *lines = [NSMutableArray array];
    unsigned long code;

    while ((code = ERR_get_error()) != 0) {
        char buffer[256];

        ERR_error_string_n(code, buffer, sizeof(buffer));
        [lines addObject:[NSString stringWithUTF8String:buffer]];
    }

    return [lines count] > 0 ? [lines componentsJoinedByString:@"; "] : @"нет подробностей";
}

#pragma mark - Соединение

/**
 * Подключение со сроком: сокет переводится в неблокирующий режим, connect
 * возвращает управление сразу, а ждём мы на select.
 *
 * Без этого приложение на плохой связи замирает до системного срока,
 * а он на iOS около минуты с четвертью — за это время человек успевает
 * решить, что всё сломалось.
 */
static int KLTlsConnectWithTimeout(struct addrinfo *address, NSTimeInterval timeout) {
    int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);

    if (fd < 0) {
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int one = 1;

    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // Обрыв соединения не должен убивать процесс сигналом.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    if (connect(fd, address->ai_addr, address->ai_addrlen) == 0) {
        fcntl(fd, F_SETFL, flags);
        return fd;
    }

    if (errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    fd_set writable;
    FD_ZERO(&writable);
    FD_SET(fd, &writable);

    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);

    if (select(fd + 1, NULL, &writable, NULL, &tv) <= 0) {
        close(fd);
        return -1;
    }

    // select сказал «можно писать», но это ещё не значит «подключено»:
    // так же он ведёт себя и при отказе. Настоящий ответ лежит в SO_ERROR.
    int soError = 0;
    socklen_t length = sizeof(soError);

    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) < 0 || soError != 0) {
        close(fd);
        return -1;
    }

    fcntl(fd, F_SETFL, flags);

    return fd;
}

/** Присланная сервером цепочка — списком SecCertificateRef, лист первым. */
static NSArray *KLTlsPeerChain(SSL *ssl) {
    NSMutableArray *chain = [NSMutableArray array];

    STACK_OF(X509) *stack = SSL_get_peer_cert_chain(ssl);

    if (stack == NULL) {
        return chain;
    }

    for (int i = 0; i < sk_X509_num(stack); i++) {
        X509 *certificate = sk_X509_value(stack, i);

        if (certificate == NULL) {
            continue;
        }

        unsigned char *der = NULL;
        int length = i2d_X509(certificate, &der);

        if (length <= 0 || der == NULL) {
            continue;
        }

        NSData *data = [NSData dataWithBytes:der length:(NSUInteger)length];

        OPENSSL_free(der);

        SecCertificateRef converted =
            SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);

        if (converted != NULL) {
            [chain addObject:(__bridge_transfer id)converted];
        }
    }

    return chain;
}

- (BOOL)connectWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    [KLTls prepare];

    if (_secure && gContext == NULL) {
        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorHandshake, @"криптография не поднялась");
        }

        return NO;
    }

    NSDate *started = [NSDate date];

    // --- разрешение имени ---

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));

    hints.ai_family = AF_UNSPEC;          // и IPv4, и IPv6
    hints.ai_socktype = SOCK_STREAM;

    // AI_ADDRCONFIG — не спрашивать адреса того семейства, которого на
    // устройстве нет. Без него резолвер в сети без IPv6 всё равно ходит
    // за AAAA и ждёт своего срока: на старых iOS это лишние секунды
    // молчания перед каждым подключением.
    hints.ai_flags = AI_ADDRCONFIG;

    struct addrinfo *list = NULL;
    NSString *portText = [NSString stringWithFormat:@"%u", (unsigned)_port];

    int rc = getaddrinfo([_host UTF8String], [portText UTF8String], &hints, &list);

    if (rc != 0 || list == NULL) {
        NSLog(@"[Кира/TLS] %@: имя не разрешилось за %.1f с — %s",
              _host, -[started timeIntervalSinceNow], gai_strerror(rc));

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorResolve, @"не разрешилось имя %@", _host);
        }

        return NO;
    }

    // --- сокет ---

    /**
     * Срок делится между адресами, а не отдаётся целиком первому.
     *
     * У каждого нашего хоста два-три адреса, и часть из них с некоторых сетей
     * просто молчит. Раньше первый же молчащий съедал весь срок целиком:
     * в журнале с устройства megavid.buzz подключался 25,3 секунды —
     * двадцать пять из них ушли на ожидание у мёртвого адреса, и только
     * потом дело дошло до живого.
     *
     * Потолок в шесть секунд на попытку — с запасом: рукопожатие с живым
     * адресом на iPad 2 занимает треть секунды даже через сотовую сеть.
     * Нижняя граница в две секунды нужна затем, чтобы при коротком общем
     * сроке и трёх адресах каждому досталось хоть сколько-то.
     */
    NSInteger count = 0;

    for (struct addrinfo *a = list; a != NULL; a = a->ai_next) {
        count++;
    }

    NSTimeInterval each = count > 1 ? timeout / (NSTimeInterval)count : timeout;

    each = MAX(2.0, MIN(each, 6.0));

    NSInteger tried = 0;

    for (struct addrinfo *a = list; a != NULL; a = a->ai_next) {
        _socket = KLTlsConnectWithTimeout(a, each);
        tried++;

        if (_socket >= 0) {
            break;
        }
    }

    if (_socket < 0 && tried > 1) {
        NSLog(@"[Кира/TLS] %@: ни один из %ld адресов не ответил", _host, (long)tried);
    }

    freeaddrinfo(list);

    if (_socket < 0) {
        NSLog(@"[Кира/TLS] %@:%u: сокет не открылся за %.1f с",
              _host, (unsigned)_port, -[started timeIntervalSinceNow]);

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorConnect, @"не подключился к %@:%u",
                                    _host, (unsigned)_port);
        }

        return NO;
    }

    // Дальше работаем блокирующе, но со сроком на каждой операции — иначе
    // молчащий сервер держал бы поток вечно. Это и есть то, чего
    // NSURLConnection на старых системах не обеспечивал.
    [self setReadTimeout:timeout];

    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = 0;
    setsockopt(_socket, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (!_secure) {
        NSLog(@"[Кира/TLS] %@:%u — без шифрования (%.1f с)",
              _host, (unsigned)_port, -[started timeIntervalSinceNow]);
        return YES;
    }

    // --- рукопожатие ---

    _ssl = SSL_new(gContext);

    if (_ssl == NULL) {
        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorHandshake, @"SSL_new: %@", KLTlsOpenSSLError());
        }

        return NO;
    }

    SSL_set_fd(_ssl, _socket);

    // Имя узла в расширении SNI. Без него сервер, держащий на одном адресе
    // сотни имён, не поймёт, чей сертификат показывать, и покажет чужой —
    // а мы его не примем.
    SSL_set_tlsext_host_name(_ssl, [_host UTF8String]);

    /**
     * ALPN: говорим, что умеем HTTP/1.1.
     *
     * Современные клиенты это расширение шлют всегда, и его отсутствие —
     * заметная примета. Просить h2 не станем: своей реализации HTTP/2
     * у нас нет, а сервер, услышав «умею», честно на него и перешёл бы.
     */
    static const unsigned char alpn[] = { 8, 'h','t','t','p','/','1','.','1' };
    SSL_set_alpn_protos(_ssl, alpn, sizeof(alpn));

    if (SSL_connect(_ssl) != 1) {
        NSString *details = KLTlsOpenSSLError();

        NSLog(@"[Кира/TLS] %@: рукопожатие не вышло за %.1f с (errno %d): %@",
              _host, -[started timeIntervalSinceNow], errno, details);

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorHandshake,
                                    @"рукопожатие не состоялось: %@", details);
        }

        return NO;
    }

    _protocolName = [NSString stringWithUTF8String:SSL_get_version(_ssl)];

    const SSL_CIPHER *cipher = SSL_get_current_cipher(_ssl);
    _cipherName = cipher != NULL
        ? [NSString stringWithUTF8String:SSL_CIPHER_get_name(cipher)]
        : @"?";

    // --- цепочка ---

    NSArray *chain = KLTlsPeerChain(_ssl);

    if (![self verifyChain:chain error:error]) {
        return NO;
    }

    NSLog(@"[Кира/TLS] %@:%u — %@, %@ (%.1f с)", _host, (unsigned)_port,
          _protocolName, _cipherName, -[started timeIntervalSinceNow]);

    return YES;
}

/**
 * Проверка цепочки — системным доверием, а не хранилищем OpenSSL.
 *
 * Отказ здесь означает разрыв: соединение уже зашифровано, но собеседник
 * не тот, за кого себя выдаёт, и отправлять ему запрос нельзя. Первый байт
 * уходит только отсюда и только после «да».
 */
- (BOOL)verifyChain:(NSArray *)chain error:(NSError **)error {
    if ([chain count] == 0) {
        NSLog(@"[Кира/TLS] %@: сервер не прислал ни одного сертификата", _host);

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorCertificate, @"сертификат не получен");
        }

        return NO;
    }

    if (KLTrustChainIsValid(chain, _host)) {
        return YES;
    }

    NSLog(@"[Кира/TLS] %@: цепочка не признана — соединение отклонено", _host);

    if (error != NULL) {
        *error = KLTlsMakeError(KLTlsErrorCertificate, @"цепочка %@ не признана", _host);
    }

    return NO;
}

- (void)setReadTimeout:(NSTimeInterval)timeout {
    _readTimeout = timeout;

    if (_socket < 0) {
        return;
    }

    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);

    setsockopt(_socket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

#pragma mark - Обмен

- (NSInteger)writeBytes:(const void *)bytes length:(NSUInteger)length error:(NSError **)error {
    if (_socket < 0) {
        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorIO, @"соединение закрыто");
        }

        return -1;
    }

    NSUInteger sent = 0;

    // Тот же выход из бесконечного «повторить», что и при чтении.
    NSDate *until = _readTimeout > 0
        ? [NSDate dateWithTimeIntervalSinceNow:_readTimeout * 2 + 1.0]
        : nil;

    while (sent < length) {
        if (until != nil && [until timeIntervalSinceNow] < 0) {
            if (error != NULL) {
                *error = KLTlsMakeError(KLTlsErrorIO, @"отправка не кончается");
            }

            return -1;
        }

        ssize_t written;

        if (_ssl != NULL) {
            written = SSL_write(_ssl, (const char *)bytes + sent, (int)(length - sent));

            if (written <= 0) {
                int reason = SSL_get_error(_ssl, (int)written);

                // WANT_READ при записи — не ошибка, а пересогласование
                // ключей: библиотеке нужно прочитать ответ сервера, прежде
                // чем продолжить. Сокет блокирующий, пробуем снова.
                if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
                    continue;
                }

                if (error != NULL) {
                    *error = KLTlsMakeError(KLTlsErrorIO, @"обрыв при отправке: %@",
                                            KLTlsOpenSSLError());
                }

                return -1;
            }
        } else {
            written = send(_socket, (const char *)bytes + sent, length - sent, 0);

            if (written <= 0) {
                if (written < 0 && errno == EINTR) {
                    continue;
                }

                if (error != NULL) {
                    *error = KLTlsMakeError(KLTlsErrorIO, @"обрыв при отправке: %s",
                                            strerror(errno));
                }

                return -1;
            }
        }

        sent += (NSUInteger)written;
    }

    return (NSInteger)sent;
}

- (NSInteger)readBytes:(void *)buffer maxLength:(NSUInteger)length error:(NSError **)error {
    if (_socket < 0) {
        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorIO, @"соединение закрыто");
        }

        return -1;
    }

    if (_ssl == NULL) {
        errno = 0;

        ssize_t got = recv(_socket, buffer, length, 0);

        if (got >= 0) {
            return got;
        }

        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return KLTlsReadTimedOut;
        }

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorIO, @"обрыв при чтении: %s", strerror(errno));
        }

        return -1;
    }

    /**
     * Свой срок поверх сокетного, и он здесь не лишний.
     *
     * Ниже есть «повторить» — на WANT_READ и WANT_WRITE. На сокете со сроком
     * такое приходит редко, но если библиотека вернёт его, не выставив
     * EAGAIN, цикл закрутится вхолостую и навсегда: поток сгорит на месте,
     * а снаружи это будет выглядеть как бесконечная загрузка, которую мы
     * уже однажды ловили. Часы дают выход из любого такого витка.
     *
     * Запас вдвое от сокетного срока: обычный тайм-аут приходит оттуда,
     * и перехватывать его здесь не нужно.
     */
    NSDate *until = _readTimeout > 0
        ? [NSDate dateWithTimeIntervalSinceNow:_readTimeout * 2 + 1.0]
        : nil;

    while (1) {
        errno = 0;

        int got = SSL_read(_ssl, buffer, (int)length);

        if (got > 0) {
            return got;
        }

        if (until != nil && [until timeIntervalSinceNow] < 0) {
            NSLog(@"[Кира/TLS] %@: чтение не кончается — обрываем", _host);
            return KLTlsReadTimedOut;
        }

        int reason = SSL_get_error(_ssl, got);

        // Срок на сокете вышел: данных пока нет, но соединение живо.
        if ((reason == SSL_ERROR_SYSCALL || reason == SSL_ERROR_WANT_READ)
            && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return KLTlsReadTimedOut;
        }

        // Ноль означает конец: либо сервер попрощался по правилам
        // (ZERO_RETURN), либо просто закрыл соединение (SYSCALL без ошибки).
        if (reason == SSL_ERROR_ZERO_RETURN) {
            return 0;
        }

        if (reason == SSL_ERROR_SYSCALL && errno == 0) {
            return 0;
        }

        if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
            continue;
        }

        if (error != NULL) {
            *error = KLTlsMakeError(KLTlsErrorIO, @"обрыв при чтении: %@", KLTlsOpenSSLError());
        }

        return -1;
    }
}

@end
