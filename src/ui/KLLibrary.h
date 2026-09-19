#import <Foundation/Foundation.h>

@class KLAnime;

/** Значения статуса. Строками, потому что в таком виде они и хранятся. */
extern NSString *const KLStatusNone;
extern NSString *const KLStatusPlanning;
extern NSString *const KLStatusWatching;
extern NSString *const KLStatusCompleted;
extern NSString *const KLStatusDropped;

/** Шлётся, когда список изменился, — открытые экраны перерисовываются. */
extern NSString *const KLLibraryChangedNotification;


/** Одна запись списка. Хранится независимо от каталога. */
@interface KLLibraryEntry : NSObject

@property (nonatomic, assign) NSInteger anilistId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *poster;
@property (nonatomic, assign) NSInteger score;

@property (nonatomic, copy) NSString *status;
@property (nonatomic, assign) BOOL favorite;

/** На какой серии остановились; 0 — не начинали. */
@property (nonatomic, assign) NSInteger progressEpisode;

@property (nonatomic, assign) NSTimeInterval updatedAt;

@end


/**
 * «Моё»: что запланировано, что смотрится, на какой серии остановились.
 *
 * Всё это живёт только на устройстве и никуда не уходит: входа в приложении
 * нет вовсе — ни AniList, ни разрешатель источников его не требуют и
 * не предлагают. Веб-версия устроена так же (localStorage), и здесь тот же
 * подход, только хранилищем служит NSUserDefaults.
 *
 * Каждая запись хранит название и обложку своей копией, а не ссылкой на
 * каталог. Это выглядит расточительно ровно до первого запуска без сети:
 * тогда «Моё» — единственный экран, которому есть что показать.
 */
@interface KLLibrary : NSObject

+ (KLLibraryEntry *)entryFor:(NSInteger)anilistId;

+ (NSString *)statusFor:(NSInteger)anilistId;
+ (void)setStatus:(NSString *)status forAnime:(KLAnime *)anime;

+ (BOOL)isFavorite:(NSInteger)anilistId;

/** Переключает и возвращает новое состояние. */
+ (BOOL)toggleFavorite:(KLAnime *)anime;

/** Отмечает, что серия начата. Заодно переводит статус в «смотрю». */
+ (void)markProgress:(KLAnime *)anime episode:(NSInteger)episode;

/**
 * Записи по разделу: один из статусов, либо «continue» (всё начатое),
 * либо «favorite». Свежие сверху.
 */
+ (NSArray *)list:(NSString *)kind;

/** Человеческое название статуса — для кнопки и всплывающей панели. */
+ (NSString *)titleForStatus:(NSString *)status;

@end
