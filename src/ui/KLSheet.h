#import <UIKit/UIKit.h>

@class KLAnime;

/**
 * Панель, выезжающая снизу.
 *
 * Не UIActionSheet, и это не каприз: штатная панель до iOS 8 рисуется
 * системной внешностью — светлой полосатой на iOS 5 и 6, — а перекрасить
 * её нечем. В макете же панель чёрная, со скруглённым верхом, «ручкой»
 * и собственной раскладкой строк (у выбора источника в строке две кнопки,
 * чего UIActionSheet не умеет вовсе).
 *
 * Панель кладётся в окно, а не в вид экрана: иначе её накрыла бы плавающая
 * панель вкладок, которая живёт выше по стопке видов.
 */
@interface KLSheet : NSObject

/** Заголовок — мелкими прописными, как в макете. */
- (id)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle;

/** Обычная строка с галочкой справа. */
- (void)addOption:(NSString *)title
          checked:(BOOL)checked
        dangerous:(BOOL)dangerous
           action:(dispatch_block_t)action;

/**
 * Строка выбора источника: название зеркала и под ним две кнопки.
 * second может быть nil — тогда первая занимает всю ширину.
 */
- (void)addSource:(NSString *)name
      firstTitle:(NSString *)firstTitle
     firstAction:(dispatch_block_t)firstAction
     secondTitle:(NSString *)secondTitle
    secondAction:(dispatch_block_t)secondAction;

/** Строка без действия — «источников нет», «ищем…». */
- (void)addNote:(NSString *)text;

/** Показывает панель. После показа добавлять строки уже нельзя. */
- (void)present;

/** Убирает панель. Обычно этого не нужно: строки закрывают её сами. */
- (void)dismiss;

/** Зовётся после закрытия — чтобы перерисовать то, что могло измениться. */
@property (nonatomic, copy) dispatch_block_t onDismiss;

@end


/**
 * Готовая панель выбора статуса: «Смотрю», «Буду смотреть», «Просмотрено»,
 * «Брошено» и «Убрать из списка».
 *
 * Отдельным классом, потому что зовут её из трёх мест — с баннера, из
 * карточки и из «Моего», — и повторять пять одинаковых строк в каждом
 * значило бы трижды помнить про порядок и подписи.
 */
@interface KLStatusSheet : NSObject

+ (void)presentFor:(KLAnime *)anime completion:(dispatch_block_t)completion;

@end
