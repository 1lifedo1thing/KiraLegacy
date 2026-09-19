#import "KLUtil.h"

#import "KLStrings.h"

#import <objc/message.h>

#import "KLMetrics.h"
#import "KLTheme.h"

/**
 * Своя очередь, а не глобальная: запросов немного, но каждый ждёт ответа
 * сети, и на глобальной очереди GCD в ответ на это заводит всё новые потоки.
 * На iPhone 3GS это заметно.
 */
static dispatch_queue_t KLWorkQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ru.computershik.kiralegacy.work",
                                      DISPATCH_QUEUE_CONCURRENT);
    });

    return queue;
}

void KLAsync(dispatch_block_t work) {
    dispatch_async(KLWorkQueue(), ^{
        @autoreleasepool {
            work();
        }
    });
}

void KLMain(dispatch_block_t work) {
    if ([NSThread isMainThread]) {
        work();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), work);
}

/**
 * Оба свойства зовём через objc_msgSend, а не по имени: wantsFullScreenLayout
 * из новых SDK убрали, automaticallyAdjustsScrollViewInsets в старых ещё нет,
 * и написать оба вызова прямо значит не собраться ни там, ни там. Приведение
 * обязательное: на arm64 objc_msgSend объявлен без списка аргументов, и без
 * приведения логическое значение уйдёт не тем путём, каким его прочтут.
 */
static void KLSetFlag(id target, SEL selector, BOOL value) {
    if (![target respondsToSelector:selector]) {
        return;
    }

    void (*set)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    set(target, selector, value);
}

void KLUseFullScreenLayout(UIViewController *controller) {
    KLSetFlag(controller, @selector(setWantsFullScreenLayout:), YES);
    KLSetFlag(controller, @selector(setAutomaticallyAdjustsScrollViewInsets:), NO);
}

CGFloat KLStatusBarHeight(void) {
    CGRect frame = [[UIApplication sharedApplication] statusBarFrame];

    // Лёжа строка состояния поворачивается вместе с экраном, и её «высотой»
    // становится меньшая сторона прямоугольника, а не та, что записана
    // в height.
    CGFloat height = MIN(frame.size.width, frame.size.height);

    // Скрытая строка (полноэкранный плеер) даёт нулевой прямоугольник —
    // отступать тогда не от чего.
    return height > 0 ? height : 0;
}


@implementation KLGeneration

- (NSInteger)next {
    @synchronized (self) {
        _current++;
        return _current;
    }
}

- (BOOL)isCurrent:(NSInteger)generation {
    @synchronized (self) {
        return generation == _current;
    }
}

@end


UIView *KLOverlayHost(void) {
    UIView *host = [[KLNav controller] view];

    // До того как навигация заведена, деваться некуда, кроме окна.
    return host ?: [[UIApplication sharedApplication] keyWindow];
}


#pragma mark - Переходы

static UINavigationController *KLNavController = nil;

@implementation KLNav

+ (UINavigationController *)controller {
    return KLNavController;
}

+ (void)setController:(UINavigationController *)controller {
    KLNavController = controller;
}

+ (void)push:(UIViewController *)screen {
    if (screen == nil) {
        return;
    }

    [KLNavController pushViewController:screen animated:YES];
}

+ (void)pop {
    [KLNavController popViewControllerAnimated:YES];
}

@end


@implementation KLNavigationController

/**
 * Все три вопроса переадресуются верхнему экрану.
 *
 * shouldAutorotateToInterfaceOrientation: — путь iOS 5, остальные два — iOS 6
 * и новее. Если верхний экран о себе ничего не говорит, отвечаем как обычная
 * стопка.
 */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    UIViewController *top = [self topViewController];

    if (top != nil) {
        return [top shouldAutorotateToInterfaceOrientation:orientation];
    }

    return [super shouldAutorotateToInterfaceOrientation:orientation];
}

- (BOOL)shouldAutorotate {
    UIViewController *top = [self topViewController];

    if ([top respondsToSelector:@selector(shouldAutorotate)]) {
        return [top shouldAutorotate];
    }

    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *top = [self topViewController];

    if ([top respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [top supportedInterfaceOrientations];
    }

    return [super supportedInterfaceOrientations];
}

@end


#pragma mark - Состояние экрана

@implementation KLStatusView {
    UIActivityIndicatorView *_spinner;
    UILabel *_label;
    UIButton *_action;
    dispatch_block_t _actionBlock;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];
    [self setUserInteractionEnabled:NO];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self addSubview:_spinner];

    _label = KLLabel(KLFontMeta(), [KLTheme mutedInk], 0);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [self addSubview:_label];

    [self setHidden:YES];

    return self;
}

- (void)layoutSubviews {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    [_spinner setCenter:CGPointMake(width / 2, height / 2)];
    [_label setFrame:CGRectMake(24, height / 2 - 40, width - 48, 80)];
    [_action setFrame:CGRectMake(24, height / 2 + 44, width - 48, 40)];
}

- (void)showBusy {
    [self setHidden:NO];
    [_label setText:nil];
    [_action setHidden:YES];
    [_spinner startAnimating];
}

- (void)showMessage:(NSString *)message {
    [self setHidden:NO];
    [_spinner stopAnimating];

    [_label setTextColor:[KLTheme mutedInk]];
    [_label setText:message];

    [_action setHidden:YES];
    _actionBlock = nil;

    // Без действия вид ничего не ловит и не мешает прокручивать то,
    // что под ним.
    [self setUserInteractionEnabled:NO];
}

- (void)showMessage:(NSString *)message
        actionTitle:(NSString *)title
             action:(dispatch_block_t)action {
    [self showMessage:message];

    if ([title length] == 0 || action == NULL) {
        return;
    }

    if (_action == nil) {
        _action = [UIButton buttonWithType:UIButtonTypeCustom];
        [[_action titleLabel] setFont:[UIFont boldSystemFontOfSize:15]];
        [_action addTarget:self
                    action:@selector(actionTapped)
          forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_action];
    }

    [_action setTitle:title forState:UIControlStateNormal];
    [_action setTitleColor:[KLTheme accentInk] forState:UIControlStateNormal];
    [_action setHidden:NO];

    _actionBlock = [action copy];

    [self setUserInteractionEnabled:YES];
    [self setNeedsLayout];
}

- (void)actionTapped {
    if (_actionBlock != nil) {
        _actionBlock();
    }
}

- (void)hide {
    [self setHidden:YES];
    [_spinner stopAnimating];

    [_action setHidden:YES];
    _actionBlock = nil;

    [self setUserInteractionEnabled:NO];
}

@end


#pragma mark - Короткое сообщение

@implementation KLToast

+ (void)show:(NSString *)message {
    if ([message length] == 0) {
        return;
    }

    KLMain(^{
        UIView *window = KLOverlayHost();
        if (window == nil) {
            return;
        }

        // Предыдущее сообщение убираем: два подряд иначе легли бы друг
        // на друга и оба стали бы нечитаемыми.
        for (UIView *view in [window subviews]) {
            if ([view tag] == 0x7047) {
                [view removeFromSuperview];
            }
        }

        CGFloat maxWidth = window.bounds.size.width - 60;
        CGFloat textWidth = MIN(maxWidth,
                                ceilf([message sizeWithFont:KLFontBody()].width) + 1);
        CGFloat textHeight = KLTextHeight(message, KLFontBody(), textWidth, 3);

        CGFloat width = textWidth + 32;
        CGFloat height = textHeight + 22;

        KLPillView *pill = [[KLPillView alloc] initWithFrame:
            CGRectMake((window.bounds.size.width - width) / 2,
                       window.bounds.size.height - height - KLDockHeight - 24,
                       width, height)];

        [pill setTag:0x7047];
        [pill setFillColor:KLColor(0xE61C1C28)];
        [pill setCornerRadius:height / 2];
        [pill setUserInteractionEnabled:NO];
        [pill setAlpha:0];

        UILabel *label = KLLabel(KLFontBody(), [KLTheme ink], 3);
        [label setTextAlignment:NSTextAlignmentCenter];
        [label setText:message];
        [label setFrame:CGRectMake(16, 11, textWidth, textHeight)];

        [pill addSubview:label];
        [window addSubview:pill];

        [UIView animateWithDuration:0.2 animations:^{
            [pill setAlpha:1];
        }];

        // Снимаем через две с половиной секунды — столько же, сколько держит
        // сообщение веб-версия.
        double delay = 2.5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25
                             animations:^{ [pill setAlpha:0]; }
                             completion:^(BOOL finished) { [pill removeFromSuperview]; }];
        });
    });
}

@end


#pragma mark - Потяните, чтобы обновить

/** Дальше какого оттягивания считаем, что список просят обновить. */
static const CGFloat KLRefreshThreshold = 64;

@implementation KLRefreshHeader {
    __weak UIScrollView *_scrollView;
    dispatch_block_t _action;
    UIActivityIndicatorView *_spinner;
    UILabel *_label;
    BOOL _refreshing;
}

+ (KLRefreshHeader *)attachedTo:(UIScrollView *)scrollView action:(dispatch_block_t)action {
    KLRefreshHeader *header =
        [[KLRefreshHeader alloc] initWithFrame:CGRectMake(0, -KLRefreshThreshold,
                                                          scrollView.bounds.size.width,
                                                          KLRefreshThreshold)];

    header->_scrollView = scrollView;
    header->_action = [action copy];

    [header setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [scrollView addSubview:header];

    return header;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self addSubview:_spinner];

    _label = KLLabel(KLFontMeta(), [KLTheme mutedInk], 1);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [_label setText:KLStr(@"refresh.pull")];
    [self addSubview:_label];

    return self;
}

- (BOOL)isRefreshing {
    return _refreshing;
}

- (void)layoutSubviews {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    [_spinner setCenter:CGPointMake(width / 2, height / 2 - 8)];
    [_label setFrame:CGRectMake(0, height / 2 + 4, width, 18)];
}

- (void)followScroll {
    if (_refreshing) {
        return;
    }

    CGFloat pulled = -[_scrollView contentOffset].y - [_scrollView contentInset].top;

    [_label setText:KLStr(pulled >= KLRefreshThreshold
        ? @"refresh.release"
        : @"refresh.pull")];
}

- (void)releaseScroll {
    if (_refreshing) {
        return;
    }

    CGFloat pulled = -[_scrollView contentOffset].y - [_scrollView contentInset].top;
    if (pulled < KLRefreshThreshold) {
        return;
    }

    _refreshing = YES;

    [_label setText:KLStr(@"refresh.loading")];
    [_spinner startAnimating];

    // Держим список оттянутым, пока идёт обновление, — иначе индикатор
    // уехал бы за край сразу после отпускания.
    UIEdgeInsets insets = [_scrollView contentInset];
    insets.top += KLRefreshThreshold;

    [UIView animateWithDuration:0.2 animations:^{
        [_scrollView setContentInset:insets];
    }];

    if (_action != nil) {
        _action();
    }
}

- (void)finish {
    if (!_refreshing) {
        return;
    }

    _refreshing = NO;
    [_spinner stopAnimating];

    UIEdgeInsets insets = [_scrollView contentInset];
    insets.top -= KLRefreshThreshold;

    [UIView animateWithDuration:0.2 animations:^{
        [_scrollView setContentInset:insets];
    }];
}

@end


#pragma mark - Значки

@implementation KLIconView

+ (KLIconView *)iconOf:(KLIconKind)kind tint:(UIColor *)tint side:(CGFloat)side {
    KLIconView *icon = [[KLIconView alloc] initWithFrame:CGRectMake(0, 0, side, side)];

    [icon setKind:kind];
    [icon setTint:tint];

    return icon;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _lineWidth = 2;
    _tint = [KLTheme ink];

    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];
    [self setContentMode:UIViewContentModeRedraw];
    [self setUserInteractionEnabled:NO];

    return self;
}

- (void)setKind:(KLIconKind)kind { _kind = kind; [self setNeedsDisplay]; }
- (void)setTint:(UIColor *)tint { _tint = tint; [self setNeedsDisplay]; }
- (void)setFilled:(BOOL)filled { _filled = filled; [self setNeedsDisplay]; }
- (void)setLineWidth:(CGFloat)width { _lineWidth = width; [self setNeedsDisplay]; }

/**
 * Все значки нарисованы в квадрате 24×24 — том же, в каком они заданы
 * в макете (`viewBox="0 0 24 24"`). Масштаб до настоящего размера вида
 * ставится один раз здесь, поэтому дальше можно писать те же числа,
 * что в SVG, и не пересчитывать их для каждого размера значка.
 */
- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat scale = side / 24.0;

    CGContextSaveGState(context);
    CGContextTranslateCTM(context,
                          (self.bounds.size.width - side) / 2,
                          (self.bounds.size.height - side) / 2);
    CGContextScaleCTM(context, scale, scale);

    CGContextSetStrokeColorWithColor(context, [_tint CGColor]);
    CGContextSetFillColorWithColor(context, [_tint CGColor]);

    // Толщину задаём в единицах вида, а рисуем в масштабе — делим, чтобы
    // линия осталась той же на экране, а не потолстела вместе с фигурой.
    CGContextSetLineWidth(context, _lineWidth / scale);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);

    switch (_kind) {
        case KLIconSearch:
            CGContextAddArc(context, 11, 11, 7, 0, 2 * M_PI, 0);
            CGContextStrokePath(context);
            CGContextMoveToPoint(context, 16, 16);
            CGContextAddLineToPoint(context, 21, 21);
            CGContextStrokePath(context);
            break;

        case KLIconHome:
            CGContextMoveToPoint(context, 3, 11);
            CGContextAddLineToPoint(context, 12, 3);
            CGContextAddLineToPoint(context, 21, 11);
            CGContextAddLineToPoint(context, 21, 21);
            CGContextAddLineToPoint(context, 3, 21);
            CGContextClosePath(context);
            CGContextStrokePath(context);
            break;

        case KLIconFolder:
            CGContextMoveToPoint(context, 3, 7);
            CGContextAddLineToPoint(context, 10, 7);
            CGContextAddLineToPoint(context, 12, 10);
            CGContextAddLineToPoint(context, 21, 10);
            CGContextAddLineToPoint(context, 21, 20);
            CGContextAddLineToPoint(context, 3, 20);
            CGContextClosePath(context);
            CGContextStrokePath(context);
            break;

        case KLIconBack:
        case KLIconChevronLeft:
            CGContextMoveToPoint(context, 15, 4);
            CGContextAddLineToPoint(context, 7, 12);
            CGContextAddLineToPoint(context, 15, 20);
            CGContextStrokePath(context);
            break;

        case KLIconChevronRight:
            CGContextMoveToPoint(context, 9, 4);
            CGContextAddLineToPoint(context, 17, 12);
            CGContextAddLineToPoint(context, 9, 20);
            CGContextStrokePath(context);
            break;

        case KLIconPlay:
            CGContextMoveToPoint(context, 6, 3);
            CGContextAddLineToPoint(context, 20, 12);
            CGContextAddLineToPoint(context, 6, 21);
            CGContextClosePath(context);
            // Треугольник всегда залит: контурный «Play» в макете
            // не встречается ни разу.
            CGContextFillPath(context);
            break;

        case KLIconPlus:
            CGContextMoveToPoint(context, 12, 5);
            CGContextAddLineToPoint(context, 12, 19);
            CGContextMoveToPoint(context, 5, 12);
            CGContextAddLineToPoint(context, 19, 12);
            CGContextStrokePath(context);
            break;

        case KLIconCheck:
            CGContextMoveToPoint(context, 4, 12);
            CGContextAddLineToPoint(context, 9, 17);
            CGContextAddLineToPoint(context, 20, 6);
            CGContextStrokePath(context);
            break;

        case KLIconInfo:
            CGContextAddArc(context, 12, 12, 9, 0, 2 * M_PI, 0);
            CGContextStrokePath(context);
            CGContextMoveToPoint(context, 12, 11);
            CGContextAddLineToPoint(context, 12, 16);
            CGContextStrokePath(context);
            CGContextFillEllipseInRect(context, CGRectMake(11, 7, 2, 2));
            break;

        case KLIconClose:
            CGContextMoveToPoint(context, 6, 6);
            CGContextAddLineToPoint(context, 18, 18);
            CGContextMoveToPoint(context, 18, 6);
            CGContextAddLineToPoint(context, 6, 18);
            CGContextStrokePath(context);
            break;

        case KLIconSort:
            // Стрелка вверх и стрелка вниз рядом — «порядок серий».
            CGContextMoveToPoint(context, 7, 20);
            CGContextAddLineToPoint(context, 7, 5);
            CGContextMoveToPoint(context, 3, 9);
            CGContextAddLineToPoint(context, 7, 5);
            CGContextAddLineToPoint(context, 11, 9);
            CGContextStrokePath(context);

            CGContextMoveToPoint(context, 17, 4);
            CGContextAddLineToPoint(context, 17, 19);
            CGContextMoveToPoint(context, 13, 15);
            CGContextAddLineToPoint(context, 17, 19);
            CGContextAddLineToPoint(context, 21, 15);
            CGContextStrokePath(context);
            break;
    }

    CGContextRestoreGState(context);
}

@end
