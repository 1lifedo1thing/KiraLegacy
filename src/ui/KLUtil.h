#import <UIKit/UIKit.h>

/**
 * Вкладка корневого экрана.
 *
 * Метод один, и объявлен он протоколом, а не зовётся через performSelector:
 * под ARC компилятор на такой вызов предупреждает — он не знает, что вернёт
 * неизвестный селектор, и не берётся решать за нас, надо ли освобождать
 * результат. Протокол снимает вопрос вместе с предупреждением.
 */
@protocol KLTabContent <NSObject>

/** Вкладку открыли: самое время перечитать то, что могло измениться. */
- (void)didBecomeVisible;

@end


/** Работа в фоне: все методы KLApi синхронные и ждут ответа. */
void KLAsync(dispatch_block_t work);

/** Вернуться на главный поток. */
void KLMain(dispatch_block_t work);

/**
 * Отменяемая фоновая задача. У экрана есть номер поколения, и ответ,
 * пришедший от прежнего запроса, свой список уже не дописывает: без этого
 * поиск, набранный по буквам, дорисовывал бы результаты «N», «Na», «Nar»
 * поверх друг друга в том порядке, в каком они доехали.
 */
@interface KLGeneration : NSObject

@property (nonatomic, readonly) NSInteger current;

/** Начинает новое поколение и возвращает его номер. */
- (NSInteger)next;

/** Актуален ли ещё ответ этого поколения. */
- (BOOL)isCurrent:(NSInteger)generation;

@end


/**
 * Отдать контроллеру всё окно целиком, включая полосу под строкой состояния.
 *
 * До iOS 7 вид контроллера по умолчанию занимал не окно, а «область
 * содержимого» — окно без строки состояния. Наши экраны при этом сами
 * отступают на её высоту, и отступ выходил бы двойной: содержимое съезжало
 * бы на 20 точек вниз, а снизу ровно столько же окна оставалось бы
 * незакрытым.
 *
 * С iOS 7 вид и так во весь экран, и звать это не нужно; поэтому свойство
 * спрашивается через runtime — в новых SDK его уже нет.
 *
 * Заодно снимается автоматическая правка отступов списков (iOS 7 и новее):
 * система добавляет первому найденному UIScrollView отступ сверху под свои
 * панели, которых у нас нет.
 *
 * Зовётся из loadView, до того как вид попадёт в окно.
 */
void KLUseFullScreenLayout(UIViewController *controller);

/** Высота строки состояния — под неё отступают шапки экранов. */
CGFloat KLStatusBarHeight(void);

/**
 * Куда класть то, что показывается поверх всего: выезжающие панели
 * и короткие сообщения.
 *
 * Это вид контроллера верхнего уровня, а не окно, и разница здесь
 * решающая. Окно на iOS не поворачивается вовсе — поворачивается вид
 * контроллера внутри него, а окну лишь меняют преобразование. Всё,
 * что положено прямо в окно, остаётся в портретных координатах:
 * лёжа панель выезжала боком, повёрнутая на девяносто градусов,
 * а на планшете могла и вовсе оказаться за краем.
 */
UIView *KLOverlayHost(void);


/**
 * Переходы между экранами.
 *
 * Виды разделов не держат ссылку на навигацию, а просят её у этого класса:
 * иначе каждому пришлось бы тащить контроллер сквозь всю цепочку создания.
 */
@interface KLNav : NSObject

+ (UINavigationController *)controller;
+ (void)setController:(UINavigationController *)controller;

+ (void)push:(UIViewController *)screen;
+ (void)pop;

@end


/**
 * Стопка экранов, которая спрашивает об ориентации верхний экран.
 *
 * С iOS 6 систему интересует только контроллер верхнего уровня — здесь это
 * сама стопка, — а штатный UINavigationController отвечает за себя и вниз
 * вопрос не передаёт. Из-за этого плеер не смог бы ни запретить поворот на
 * странице, ни разрешить его в полноэкранном режиме: его ответ никто
 * не спрашивал бы.
 */
@interface KLNavigationController : UINavigationController
@end


/** Индикатор загрузки по центру и подпись вместо содержимого. */
@interface KLStatusView : UIView

- (void)showBusy;
- (void)showMessage:(NSString *)message;

/** То же сообщение, но с нажимаемой строкой под ним — «Попробовать снова». */
- (void)showMessage:(NSString *)message
        actionTitle:(NSString *)title
             action:(dispatch_block_t)action;

- (void)hide;

@end


/**
 * Короткое сообщение поверх всего — то, что в вебе называется toast.
 *
 * UIAlertView для этого не годится: он требует нажатия и обрывает то, чем
 * человек занят, а сказать нужно ровно «ищем источник» или «зеркало
 * не отвечает» — и тут же убрать.
 */
@interface KLToast : NSObject

+ (void)show:(NSString *)message;

@end


/**
 * «Потяните, чтобы обновить».
 *
 * UIRefreshControl появился в iOS 6, поэтому здесь свой: вид над содержимым
 * списка, который следит за прокруткой и срабатывает, когда список оттянули
 * дальше порога и отпустили.
 */
@interface KLRefreshHeader : UIView

/** Заводится один раз и сам встаёт над содержимым своего списка. */
+ (KLRefreshHeader *)attachedTo:(UIScrollView *)scrollView action:(dispatch_block_t)action;

/** Зовётся из scrollViewDidScroll: владельца. */
- (void)followScroll;

/** Зовётся из scrollViewDidEndDragging: владельца. */
- (void)releaseScroll;

/** Обновление закончилось — прячем индикатор. */
- (void)finish;

@property (nonatomic, readonly) BOOL isRefreshing;

@end


/**
 * Кнопка со значком, нарисованным вектором.
 *
 * Картинок в связке нет вовсе, и это сознательно: в макете все значки —
 * контурные SVG в одну линию, и нарисовать их кодом выходит и точнее, и
 * дешевле, чем раскладывать по трём плотностям экрана. Заодно значок
 * бесплатно перекрашивается под состояние.
 */
typedef enum {
    KLIconSearch,
    KLIconHome,
    KLIconFolder,
    KLIconBack,
    KLIconPlay,
    KLIconPlus,
    KLIconCheck,
    KLIconInfo,
    KLIconClose,
    KLIconChevronLeft,
    KLIconChevronRight,
    KLIconSort
} KLIconKind;

@interface KLIconView : UIView

@property (nonatomic, assign) KLIconKind kind;
@property (nonatomic, strong) UIColor *tint;

/** Толщина линии; по умолчанию 2. */
@property (nonatomic, assign) CGFloat lineWidth;

/** Залитый значок вместо контурного — нужен «Play». */
@property (nonatomic, assign) BOOL filled;

+ (KLIconView *)iconOf:(KLIconKind)kind tint:(UIColor *)tint side:(CGFloat)side;

@end
