#import <Foundation/Foundation.h>

/**
 * Мелкие обёртки над NSJSONSerialization.
 *
 * Смысл у них один: поля от источников сплошь и рядом приходят как null или
 * другого типа, чем ожидается, и разбор не должен от этого падать. У AniList
 * половина полей необязательна по самой схеме (bannerImage, episodes,
 * averageScore — всё это законно бывает null), а разрешатель источников
 * отдаёт episodes то массивом, то объектом с полем episodes внутри.
 * Здесь обе разновидности пустоты — отсутствующий ключ и присланный null —
 * сводятся к nil.
 *
 * Внешней библиотеки нет намеренно: NSJSONSerialization есть в системе
 * с iOS 5.0, то есть ровно с нашей нижней границы.
 */
@interface KLJson : NSObject

/** Разбор тела ответа. Возвращает nil, если верхним уровнем не объект. */
+ (NSDictionary *)parse:(NSData *)data;

/**
 * То же, но верхним уровнем допускается и массив.
 *
 * Нужно ровно одному месту — списку серий: разрешатель отдаёт его голым
 * массивом, без обёртки.
 */
+ (id)parseAny:(NSData *)data;

/** Обратно в данные — для тел запросов. */
+ (NSData *)encode:(NSDictionary *)object;

+ (NSDictionary *)objectIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSArray *)arrayIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSDictionary *)objectAt:(NSArray *)array index:(NSUInteger)index;

/**
 * Строка, но пустая считается отсутствующей.
 *
 * У AniList английское название нередко приходит пустой строкой вместо null,
 * и обычный stringIn отдавал бы её как значение — запасной вариант (romaji)
 * не срабатывал бы, и карточка оставалась без подписи.
 */
+ (NSString *)textIn:(NSDictionary *)parent key:(NSString *)key;

+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSString *)stringIn:(NSDictionary *)parent key:(NSString *)key
              fallback:(NSString *)fallback;

+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key;
+ (NSInteger)intIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(NSInteger)fallback;

+ (double)doubleIn:(NSDictionary *)parent key:(NSString *)key
          fallback:(double)fallback;

+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key;
+ (BOOL)boolIn:(NSDictionary *)parent key:(NSString *)key fallback:(BOOL)fallback;

@end
