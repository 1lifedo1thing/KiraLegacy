#import <Foundation/Foundation.h>

/** Дорожка субтитров: файл .vtt и подпись к нему. */
@interface KLSubtitleTrack : NSObject

@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *label;

/** Помечена ли зеркалом как включённая по умолчанию. */
@property (nonatomic, assign) BOOL isDefault;

@end


/**
 * Один источник одной серии.
 *
 * Источников у серии несколько, и они разные не по качеству картинки,
 * а по зеркалу: HiAnime, AniWave, AnimeHub, Megavid. Работают они не всегда
 * все сразу — оттого приложение и обходит их по очереди, а не полагается
 * на одно.
 *
 * Адрес бывает двух видов, и это не небрежность, а два разных пути.
 *
 * Зеркала из основного набора отдают прямую ссылку на плейлист — её и кладём
 * в url. Разрешатель на Cloudflare, оставленный последним запасным ходом,
 * прямой ссылки не даёт вовсе: у него непрозрачный ключ, по которому он сам
 * потом отдаёт плейлист. Он ложится в encoded.
 *
 * Referer здесь не для красоты: зеркала проверяют его и на самом плейлисте,
 * и на сегментах. Без нужного заголовка CDN отвечает 403, и поток не
 * открывается — при том что ссылка совершенно правильная.
 */
@interface KLSource : NSObject

/** «HiAnime», «AniWave», «Megavid» — то, что видно в плеере. */
@property (nonatomic, copy) NSString *label;

/** sub или dub. */
@property (nonatomic, copy) NSString *kind;

/** Прямой адрес плейлиста; nil, если источник даёт только ключ. */
@property (nonatomic, copy) NSString *url;

/** Непрозрачный ключ для /m3u8?encoded=… ; nil у прямых источников. */
@property (nonatomic, copy) NSString *encoded;

/** С каким Referer ходить за плейлистом и сегментами. */
@property (nonatomic, copy) NSString *referer;

/** KLSubtitleTrack; пусто — субтитров зеркало не дало. */
@property (nonatomic, strong) NSArray *subtitles;

/** Границы заставки в секундах; обе нули — зеркало их не прислало. */
@property (nonatomic, assign) NSInteger introStart;
@property (nonatomic, assign) NSInteger introEnd;

/** «Озвучка» либо «Субтитры» — подпись рядом с названием зеркала. */
- (NSString *)kindText;

/** Строка для плеера: «HiAnime · субтитры». */
- (NSString *)displayName;

@end
