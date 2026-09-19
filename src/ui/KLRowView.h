#import <UIKit/UIKit.h>

/**
 * Ряд карточек с заголовком: «В тренде», «Продолжить» и все остальные.
 *
 * Карточки создаются заново на каждое наполнение, а не берутся из пула.
 * Для списка на сотни строк так делать нельзя, но здесь их два десятка
 * и ряд наполняется один раз за загрузку — экономия обернулась бы лишь
 * усложнением.
 *
 * Прокрутка горизонтальная и своя у каждого ряда. Из-за неё ряды и не
 * сложены в UITableView: ячейка таблицы с вложенной прокруткой на iOS 5
 * требует ручной передачи нажатий, а вертикальная прокрутка страницы
 * при этом ничего не выигрывает — рядов на экране пять, не пятьсот.
 */
@interface KLRowView : UIView

/** Высота ряда при заданной ширине карточки. */
+ (CGFloat)heightForCardWidth:(CGFloat)cardWidth;

- (id)initWithTitle:(NSString *)title
              width:(CGFloat)width
          cardWidth:(CGFloat)cardWidth;

/** KLAnime. */
- (void)setAnimeList:(NSArray *)list;

/** KLLibraryEntry — для рядов «Моего», где каталога под рукой нет. */
- (void)setEntries:(NSArray *)entries showsProgress:(BOOL)showsProgress;

/** Что делать при нажатии на карточку. Приходит KLAnime либо KLLibraryEntry. */
@property (nonatomic, copy) void (^onPick)(id item);

/** Показать вместо карточек строку «здесь пусто». */
- (void)showMessage:(NSString *)message;

/** Крутить индикатор вместо карточек. */
- (void)showBusy;

@end
