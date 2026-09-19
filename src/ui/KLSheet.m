#import "KLSheet.h"

#import "KLStrings.h"

#import <objc/runtime.h>

#import "KLAnime.h"
#import "KLLibrary.h"
#import "KLMetrics.h"
#import "KLTheme.h"
#import "KLUtil.h"

static const CGFloat KLSheetRadius = 18;
static const CGFloat KLSheetPadding = 20;

/**
 * Показанные сейчас панели.
 *
 * Панель заводят и тут же отпускают: `[[KLSheet alloc] init…]` попадает
 * в локальную переменную, которая живёт до конца метода. Виды при этом
 * уезжают в окно и остаются на экране, а сам объект — цель всех нажатий —
 * под ARC исчезает. Первое же касание строки уходило бы к освобождённой
 * памяти.
 *
 * Поэтому показанная панель держится здесь и отпускается при закрытии.
 * Владеет ею, таким образом, факт показа, а не тот, кто её собрал, — что
 * и правильно: собравший про неё уже забыл.
 */
static NSMutableArray *KLLiveSheets(void) {
    static NSMutableArray *sheets = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{ sheets = [[NSMutableArray alloc] init]; });

    return sheets;
}

/** Строка панели: сама рисует разделитель снизу и ловит нажатие. */
@interface KLSheetRow : UIControl
@property (nonatomic, copy) dispatch_block_t action;
@property (nonatomic, assign) BOOL showsSeparator;
@end

@implementation KLSheetRow

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _showsSeparator = YES;

        [self setBackgroundColor:[UIColor clearColor]];
        [self setOpaque:NO];
    }

    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!_showsSeparator) {
        return;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    CGContextSetFillColorWithColor(context, [[KLTheme hairline] CGColor]);
    CGContextFillRect(context, CGRectMake(KLSheetPadding, self.bounds.size.height - 1,
                                          self.bounds.size.width - KLSheetPadding * 2, 1));
}

@end


@implementation KLSheet {
    UIView *_overlay;
    UIView *_panel;

    NSString *_title;
    NSString *_subtitle;

    NSMutableArray *_rows;
    CGFloat _height;
    CGFloat _width;
}

- (id)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _title = [title copy];
    _subtitle = [subtitle copy];
    _rows = [NSMutableArray array];

    UIView *host = KLOverlayHost();
    _width = host != nil ? host.bounds.size.width : 320;

    [self buildHeader];

    return self;
}

#pragma mark Сборка

- (void)addRow:(UIView *)row {
    CGRect frame = [row frame];
    frame.origin = CGPointMake(0, _height);
    [row setFrame:frame];

    _height += frame.size.height;

    [_rows addObject:row];
}

- (void)buildHeader {
    // «Ручка» — короткая светлая полоска сверху: знак того, что панель
    // выехала снизу и закрывается тем же движением.
    KLPillView *handle = [[KLPillView alloc]
        initWithFrame:CGRectMake((_width - 36) / 2, 12, 36, 4)];

    [handle setFillColor:KLColor(0x4D4D57)];
    [handle setCornerRadius:2];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _width, 0)];
    [header addSubview:handle];

    CGFloat y = 28;

    if ([_title length] > 0) {
        UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme mutedInk], 1);

        // Прописные и разрядка — так заголовок панели набран в макете.
        [label setText:[_title uppercaseString]];
        [label setFrame:CGRectMake(KLSheetPadding, y, _width - KLSheetPadding * 2, 16)];

        [header addSubview:label];

        y += 24;
    }

    if ([_subtitle length] > 0) {
        CGFloat width = _width - KLSheetPadding * 2;
        CGFloat height = KLTextHeight(_subtitle, [UIFont boldSystemFontOfSize:17], width, 2);

        UILabel *label = KLLabel([UIFont boldSystemFontOfSize:17], [KLTheme ink], 2);
        [label setText:_subtitle];
        [label setFrame:CGRectMake(KLSheetPadding, y, width, height)];

        [header addSubview:label];

        y += height + 16;
    }

    CGRect frame = [header frame];
    frame.size.height = MAX(y, 28);
    [header setFrame:frame];

    [self addRow:header];
}

- (void)addOption:(NSString *)title
          checked:(BOOL)checked
        dangerous:(BOOL)dangerous
           action:(dispatch_block_t)action {
    KLSheetRow *row = [[KLSheetRow alloc] initWithFrame:CGRectMake(0, 0, _width, 50)];

    [row setAction:action];
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:15],
                             dangerous ? [KLTheme danger] : [KLTheme ink], 1);
    [label setText:title];
    [label setFrame:CGRectMake(KLSheetPadding, 0, _width - KLSheetPadding * 2 - 32, 50)];
    [row addSubview:label];

    if (checked) {
        KLIconView *check = [KLIconView iconOf:KLIconCheck tint:[KLTheme accent] side:20];
        [check setCenter:CGPointMake(_width - KLSheetPadding - 10, 25)];
        [row addSubview:check];
    }

    [self addRow:row];
}

- (void)addSource:(NSString *)name
      firstTitle:(NSString *)firstTitle
     firstAction:(dispatch_block_t)firstAction
     secondTitle:(NSString *)secondTitle
    secondAction:(dispatch_block_t)secondAction {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _width, 92)];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme mutedInk], 1);
    [label setText:[name uppercaseString]];
    [label setFrame:CGRectMake(KLSheetPadding, 12, _width - KLSheetPadding * 2, 16)];
    [row addSubview:label];

    CGFloat inner = _width - KLSheetPadding * 2;
    CGFloat gap = 8;
    CGFloat buttonWidth = secondTitle != nil ? (inner - gap) / 2 : inner;

    [row addSubview:[self actionButton:firstTitle
                                 frame:CGRectMake(KLSheetPadding, 36, buttonWidth, 42)
                               primary:YES
                                action:firstAction]];

    if (secondTitle != nil) {
        [row addSubview:[self actionButton:secondTitle
                                     frame:CGRectMake(KLSheetPadding + buttonWidth + gap,
                                                      36, buttonWidth, 42)
                                   primary:NO
                                    action:secondAction]];
    }

    [self addRow:row];
}

/** Белая главная и приглушённая индиговая второстепенная — как в макете. */
- (UIButton *)actionButton:(NSString *)title
                     frame:(CGRect)frame
                   primary:(BOOL)primary
                    action:(dispatch_block_t)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setFrame:frame];

    KLPillView *fill = [[KLPillView alloc]
        initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];

    [fill setFillColor:primary ? [KLTheme ink] : [KLTheme accentSurface]];
    [fill setStrokeColor:primary ? nil : [KLTheme accent]];
    [fill setCornerRadius:8];
    [fill setUserInteractionEnabled:NO];
    [button addSubview:fill];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:14],
                             primary ? [KLTheme pageBackground] : [KLTheme accentInk], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:title];
    [label setFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)];
    [button addSubview:label];

    // Блок держим на самой кнопке через связанный объект — заводить ради
    // этого ещё один класс строки было бы больше кода, чем пользы.
    objc_setAssociatedObject(button, @selector(actionButton:frame:primary:action:),
                             [action copy], OBJC_ASSOCIATION_COPY_NONATOMIC);

    [button addTarget:self
               action:@selector(buttonTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    return button;
}

- (void)addNote:(NSString *)text {
    CGFloat width = _width - KLSheetPadding * 2;
    CGFloat height = KLTextHeight(text, KLFontBody(), width, 3);

    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _width, height + 32)];

    UILabel *label = KLLabel(KLFontBody(), [KLTheme mutedInk], 3);
    [label setText:text];
    [label setFrame:CGRectMake(KLSheetPadding, 16, width, height)];
    [row addSubview:label];

    [self addRow:row];
}

#pragma mark Показ

- (void)present {
    UIView *window = KLOverlayHost();
    if (window == nil) {
        return;
    }

    CGFloat screenHeight = window.bounds.size.height;

    // Кнопка «Отмена» — последней строкой, отдельно от списка.
    [self addCancel];

    CGFloat panelHeight = MIN(_height + 24, screenHeight * 0.85);

    _overlay = [[UIView alloc] initWithFrame:window.bounds];
    [_overlay setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.78]];
    [_overlay setAlpha:0];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [_overlay addGestureRecognizer:tap];

    // Скруглён только верх, но UIBezierPath с разными радиусами по углам —
    // это iOS 11. Поэтому панель рисуется «таблеткой» со скруглением по всем
    // четырём, а нижние два уезжают за край экрана: их просто не видно.
    KLPillView *panel = [[KLPillView alloc] initWithFrame:
        CGRectMake(0, screenHeight, _width, panelHeight + KLSheetRadius)];

    // Не декорация: внутри лежат строки выбора — см. KLPillView.
    [panel setUserInteractionEnabled:YES];

    [panel setFillColor:[KLTheme sheet]];
    [panel setCornerRadius:KLSheetRadius];

    for (UIView *row in _rows) {
        [panel addSubview:row];
    }

    _panel = panel;

    [KLLiveSheets() addObject:self];

    [window addSubview:_overlay];
    [window addSubview:_panel];

    [UIView animateWithDuration:0.25 animations:^{
        [_overlay setAlpha:1];
        [_panel setFrame:CGRectMake(0, screenHeight - panelHeight,
                                    _width, panelHeight + KLSheetRadius)];
    }];
}

- (void)addCancel {
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    [cancel setFrame:CGRectMake(KLSheetPadding, _height + 12,
                                _width - KLSheetPadding * 2, 46)];

    KLPillView *fill = [[KLPillView alloc] initWithFrame:[cancel bounds]];
    [fill setFillColor:KLColor(0x1F1F29)];
    [fill setCornerRadius:10];
    [fill setUserInteractionEnabled:NO];
    [cancel addSubview:fill];

    UILabel *label = KLLabel([UIFont systemFontOfSize:15], [KLTheme mutedInk], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:KLStr(@"sheet.cancel")];
    [label setFrame:[cancel bounds]];
    [cancel addSubview:label];

    [cancel addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    [_rows addObject:cancel];

    _height += 12 + 46;
}

- (void)rowTapped:(KLSheetRow *)row {
    dispatch_block_t action = [row action];

    [self dismiss];

    if (action != nil) {
        action();
    }
}

- (void)buttonTapped:(UIButton *)button {
    dispatch_block_t action =
        objc_getAssociatedObject(button, @selector(actionButton:frame:primary:action:));

    [self dismiss];

    if (action != nil) {
        action();
    }
}

- (void)dismiss {
    if (_panel == nil) {
        return;
    }

    UIView *panel = _panel;
    UIView *overlay = _overlay;

    _panel = nil;
    _overlay = nil;

    CGRect away = [panel frame];
    away.origin.y = KLOverlayHost().bounds.size.height;

    [UIView animateWithDuration:0.2 animations:^{
        [overlay setAlpha:0];
        [panel setFrame:away];
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
        [panel removeFromSuperview];

        if (self.onDismiss != nil) {
            self.onDismiss();
        }

        // Отпускаем себя последним действием: до этой строки на панель
        // ссылался только этот список.
        [KLLiveSheets() removeObject:self];
    }];
}

@end


#pragma mark - Выбор статуса

@implementation KLStatusSheet

+ (void)presentFor:(KLAnime *)anime completion:(dispatch_block_t)completion {
    if (anime == nil) {
        return;
    }

    NSString *current = [KLLibrary statusFor:anime.anilistId];

    KLSheet *sheet = [[KLSheet alloc] initWithTitle:KLStr(@"sheet.list")
                                           subtitle:anime.title];

    NSArray *statuses = [NSArray arrayWithObjects:
        KLStatusWatching, KLStatusPlanning, KLStatusCompleted, KLStatusDropped, nil];

    for (NSString *status in statuses) {
        [sheet addOption:[KLLibrary titleForStatus:status]
                 checked:[current isEqualToString:status]
               dangerous:NO
                  action:^{
            [KLLibrary setStatus:status forAnime:anime];
            [KLToast show:[NSString stringWithFormat:@"%@ — %@",
                           anime.title, [KLLibrary titleForStatus:status]]];
        }];
    }

    // Отдельной строкой внизу и красным: это единственное действие панели,
    // которое что-то убирает, а не добавляет.
    if (![current isEqualToString:KLStatusNone]) {
        [sheet addOption:KLStr(@"sheet.list.remove")
                 checked:NO
               dangerous:YES
                  action:^{
            [KLLibrary setStatus:KLStatusNone forAnime:anime];
            [KLToast show:KLStr(@"toast.list.removed")];
        }];
    }

    [sheet setOnDismiss:completion];
    [sheet present];
}

@end
