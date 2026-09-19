#import "KLHttp.h"

#import "KLDiskCache.h"
#import "KLHttpClient.h"

NSString *const KLHttpErrorDomain = @"ru.computershik.kiralegacy.http";

@implementation KLHttpResponse

- (BOOL)isSuccessful {
    return self.error == nil && self.statusCode >= 200 && self.statusCode < 300;
}

- (NSString *)text {
    if ([self.body length] == 0) {
        return @"";
    }

    NSString *value = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    return value ?: @"";
}

@end


Class KLNetworkClass(NSString *name) {
    // Кеш не нужен: NSClassFromString сам ищет по хеш-таблице рантайма,
    // и запросов у нас не столько, чтобы это было заметно.
    return NSClassFromString(name);
}

NSMutableURLRequest *KLRequest(NSString *url,
                               NSURLRequestCachePolicy policy,
                               NSTimeInterval timeout) {
    NSURL *address = [NSURL URLWithString:url];
    if (address == nil) {
        return nil;
    }

    return [KLNetworkClass(@"NSMutableURLRequest") requestWithURL:address
                                                      cachePolicy:policy
                                                  timeoutInterval:timeout];
}


#pragma mark - Клиент

/** Запись кратковременного кеша: тело ответа и время, когда оно получено. */
@interface KLCacheEntry : NSObject
@property (nonatomic, strong) KLHttpResponse *response;
@property (nonatomic, assign) NSTimeInterval storedAt;
@end

@implementation KLCacheEntry
@end


@implementation KLHttp

+ (NSMutableDictionary *)memoryCache {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        cache = [[NSMutableDictionary alloc] init];
    });

    return cache;
}

+ (KLHttpResponse *)send:(NSURLRequest *)request bodyLimit:(NSUInteger)bodyLimit {
    return [self send:request bodyLimit:bodyLimit caching:YES];
}

+ (KLHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
                 caching:(BOOL)caching {
    if ([NSThread isMainThread]) {
        NSLog(@"[Кира/HTTP] Запрос с главного потока: %@", [[request URL] absoluteString]);
    }

    NSString *url = [[request URL] absoluteString];

    // Кеш спрашиваем только у GET: у остальных методов тело запроса
    // участвует в том, что вернётся, а ключ у нас — один адрес.
    BOOL cacheable = caching && [[request HTTPMethod] ?: @"GET" isEqualToString:@"GET"];

    if (cacheable) {
        KLHttpResponse *stored = [KLDiskCache responseForUrl:url];

        if (stored != nil) {
            return stored;
        }
    }

    KLHttpResponse *response = [KLHttpClient perform:request
                                           bodyLimit:bodyLimit
                                           onHeaders:nil
                                             onChunk:nil];

    if (cacheable) {
        [KLDiskCache store:response forUrl:url];
    }

    return response;
}

+ (KLHttpResponse *)stream:(NSURLRequest *)request
                 onHeaders:(void (^)(KLHttpResponse *head))onHeaders
                   onChunk:(BOOL (^)(NSData *chunk))onChunk {
    return [KLHttpClient perform:request bodyLimit:0 onHeaders:onHeaders onChunk:onChunk];
}

+ (KLHttpResponse *)send:(NSURLRequest *)request
               bodyLimit:(NSUInteger)bodyLimit
             cacheForTTL:(NSTimeInterval)ttl {
    if (ttl <= 0) {
        return [self send:request bodyLimit:bodyLimit];
    }

    /**
     * Ключ — адрес и тело вместе.
     *
     * У AniList всё идёт одним POST на graphql.anilist.co, и адрес у четырёх
     * лент главного экрана один и тот же. По одному адресу все четыре
     * попадали бы в одну запись кеша, и «Популярное» показывало бы то же,
     * что «В тренде».
     */
    NSString *key = [[request URL] absoluteString];
    NSData *body = [request HTTPBody];

    if ([body length] > 0) {
        key = [key stringByAppendingFormat:@"#%lu:%lu",
               (unsigned long)[body length], (unsigned long)[body hash]];
    }

    NSMutableDictionary *cache = [self memoryCache];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    @synchronized (cache) {
        KLCacheEntry *entry = [cache objectForKey:key];

        if (entry != nil && now - entry.storedAt < ttl) {
            return entry.response;
        }
    }

    KLHttpResponse *response = [self send:request bodyLimit:bodyLimit];

    if ([response isSuccessful]) {
        KLCacheEntry *entry = [[KLCacheEntry alloc] init];
        entry.response = response;
        entry.storedAt = now;

        @synchronized (cache) {
            // Держать всю историю переходов незачем: кеш нужен на минуты,
            // чтобы возврат назад не перезапрашивал те же ленты.
            if ([cache count] > 32) {
                [cache removeAllObjects];
            }

            [cache setObject:entry forKey:key];
        }
    }

    return response;
}

+ (void)dropMemoryCache {
    NSMutableDictionary *cache = [self memoryCache];

    @synchronized (cache) {
        [cache removeAllObjects];
    }
}

@end
