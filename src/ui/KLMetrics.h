#import <UIKit/UIKit.h>

/**
 * Шрифты, размеры и мелкие общие виды.
 *
 * Числа перенесены из CSS веб-версии как есть: там они в пикселях при
 * масштабе 1, а в UIKit — в точках, и это одна и та же единица. Проверять
 * это заново не пришлось — макет и рисовался под телефон.
 */

/** Заголовок ряда: «В тренде», «Популярное». */
UIFont *KLFontSection(void);

/** Крупный заголовок экрана: «Моё». */
UIFont *KLFontScreenTitle(void);

/** Название на баннере главного экрана. */
UIFont *KLFontHeroTitle(void);

/** Название в карточке сериала. */
UIFont *KLFontDetailTitle(void);

/** Подпись под обложкой в ряду. */
UIFont *KLFontCardTitle(void);

/** Название серии в списке. */
UIFont *KLFontEpisodeTitle(void);

/** Описание серии, синопсис. */
UIFont *KLFontBody(void);

/** Метаданные, подписи под кнопками. */
UIFont *KLFontMeta(void);

/** Плашка оценки поверх обложки и «таблетки» жанров. */
UIFont *KLFontBadge(void);

/** Подпись вкладки в нижней панели. */
UIFont *KLFontTab(void);

#pragma mark Раскладка

/** Ширина обложки в горизонтальном ряду. */
extern const CGFloat KLCardWidth;

/** Обложка 110×156 — это 1:1,417, стандартная пропорция постера. */
extern const CGFloat KLCardHeight;

/** Зазор между карточками и отступ от края экрана. */
extern const CGFloat KLGap;
extern const CGFloat KLSidePadding;

/** Высота плавающей панели вкладок вместе с отступом снизу. */
extern const CGFloat KLDockHeight;

#pragma mark Текст

/**
 * Высота текста в заданной ширине, но не больше maxLines строк.
 *
 * Считается через sizeWithFont:constrainedToSize: — метод устаревший, но
 * единственный, доступный на iOS 5.1: boundingRectWithSize: пришёл только
 * с iOS 7 вместе с TextKit.
 */
CGFloat KLTextHeight(NSString *text, UIFont *font, CGFloat width, NSInteger maxLines);

/**
 * Обрезает слишком длинный текст, добавляя многоточие.
 *
 * Нужно там, где число строк не ограничено, — в развёрнутом синопсисе.
 * Замер и отрисовка такого текста идут через CoreText, и на A4 полотно
 * в десятки тысяч знаков считается секундами.
 */
NSString *KLClampText(NSString *text, NSUInteger limit);

/** Подпись с обрезкой по краю и заданным числом строк. */
UILabel *KLLabel(UIFont *font, UIColor *color, NSInteger lines);


/**
 * Прямоугольник со скруглением и заливкой — «таблетка» жанра, подложка
 * кнопки, плашка.
 *
 * Своим рисованием, а не layer.cornerRadius: на iPhone 3GS и iPad 1 каждый
 * скруглённый слой — отдельный проход отрисовки, и в списке это заметно.
 */
@interface KLPillView : UIView

@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) CGFloat cornerRadius;

/** Обводка; nil — без неё. */
@property (nonatomic, strong) UIColor *strokeColor;

@end


/**
 * Плашка поверх обложки: «★ 8.5» и подобное. Полупрозрачная чёрная,
 * скругление 10.
 */
@interface KLBadgeLabel : UILabel

/** Отступы вокруг текста. */
@property (nonatomic, assign) UIEdgeInsets padding;

/** Рисовать ли звёздочку перед текстом — плашка оценки. */
@property (nonatomic, assign) BOOL showsStar;

/** Размер под текущий текст; пустой текст даёт нулевой размер. */
- (CGSize)badgeSize;

@end


/** Звезда, которой помечена оценка. Рисуется, а не лежит картинкой. */
void KLDrawStar(CGContextRef context, CGRect rect, UIColor *color);


/**
 * Растяжка от прозрачного к чёрному — та самая, которой в макете гасят низ
 * баннера, чтобы название читалось поверх любого кадра.
 *
 * Через CAGradientLayer, а не рисованием в drawRect: слой считается один раз
 * при смене размера, а не на каждый кадр прокрутки, и рисует его GPU.
 * QuartzCore есть с самых первых версий, так что нижней границе это ничем
 * не грозит.
 */
@interface KLGradientView : UIView

/** YES — гаснет сверху вниз (прозрачное вверху), NO — наоборот. */
@property (nonatomic, assign) BOOL downwards;

- (id)initWithFrame:(CGRect)frame downwards:(BOOL)downwards;

@end
