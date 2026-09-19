#import "KLSearchView.h"

#import "KLStrings.h"

#import "KLAnime.h"
#import "KLApi.h"
#import "KLCardView.h"
#import "KLDetailViewController.h"
#import "KLMetrics.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Сколько ждать после последней нажатой клавиши, прежде чем искать. */
static const NSTimeInterval KLSearchDelay = 0.45;

/** Колонок в сетке. Три — как в макете. */
static const NSInteger KLSearchColumns = 3;

@interface KLSearchView () <UITextFieldDelegate>
@end

@implementation KLSearchView {
    UITextField *_field;
    KLPillView *_bar;
    UIButton *_clear;
    UIScrollView *_scroll;
    KLStatusView *_status;

    /** Размер, под который всё разложено сейчас. */
    CGSize _laidOut;

    KLGeneration *_generation;
    NSArray *_results;
    BOOL _everSearched;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _generation = [[KLGeneration alloc] init];

    [self setBackgroundColor:[KLTheme pageBackground]];

    [self buildField];
    [self buildGrid];

    [_status showMessage:KLStr(@"search.prompt")];

    return self;
}

#pragma mark Поле

- (void)buildField {
    _bar = [[KLPillView alloc] initWithFrame:CGRectZero];

    // Не декорация: внутри поле ввода и кнопка очистки — см. KLPillView.
    [_bar setUserInteractionEnabled:YES];

    [_bar setFillColor:KLColor(0x1C1C24)];
    [_bar setCornerRadius:14];
    [self addSubview:_bar];

    KLIconView *icon = [KLIconView iconOf:KLIconSearch tint:[KLTheme faintInk] side:18];
    [icon setCenter:CGPointMake(24, 22)];
    [_bar addSubview:icon];

    _field = [[UITextField alloc] initWithFrame:CGRectZero];

    [_field setFont:[UIFont systemFontOfSize:16]];
    [_field setTextColor:[KLTheme ink]];
    [_field setPlaceholder:KLStr(@"search.placeholder")];
    [_field setDelegate:self];
    [_field setReturnKeyType:UIReturnKeySearch];
    [_field setAutocorrectionType:UITextAutocorrectionTypeNo];
    [_field setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [_field setClearButtonMode:UITextFieldViewModeNever];

    // Раскраска подсказки: attributedPlaceholder — это iOS 6, а на 5.1
    // подсказка рисуется системным серым, и на чёрном фоне он читается
    // не хуже задуманного. Поэтому ничего не подменяем.

    [_field addTarget:self
               action:@selector(textChanged)
     forControlEvents:UIControlEventEditingChanged];

    [_bar addSubview:_field];

    _clear = [UIButton buttonWithType:UIButtonTypeCustom];
    [_clear addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    [_clear setHidden:YES];

    KLIconView *cross = [KLIconView iconOf:KLIconClose tint:[KLTheme faintInk] side:16];
    [cross setCenter:CGPointMake(20, 22)];
    [_clear addSubview:cross];

    [_bar addSubview:_clear];
}

/**
 * Ставит рамки по нынешнему размеру и пересобирает сетку.
 *
 * Сетку приходится именно пересобирать, а не двигать: ширина карточки
 * считается от ширины вида (три колонки с зазорами), и при повороте
 * планшета карточки должны стать шире, а не разъехаться.
 */
- (void)layoutContents {
    CGSize size = self.bounds.size;

    _laidOut = size;

    CGFloat top = KLStatusBarHeight() + 12;
    CGFloat barWidth = size.width - KLSidePadding * 2;

    [_bar setFrame:CGRectMake(KLSidePadding, top, barWidth, 44)];
    [_field setFrame:CGRectMake(40, 0, barWidth - 80, 44)];
    [_clear setFrame:CGRectMake(barWidth - 40, 0, 40, 44)];

    CGFloat gridTop = [self gridTop];
    CGRect area = CGRectMake(0, gridTop, size.width, size.height - gridTop);

    [_scroll setFrame:area];
    [_status setFrame:area];

    [self showResults:_results];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (!CGSizeEqualToSize(self.bounds.size, _laidOut)) {
        [self layoutContents];
    }
}

#pragma mark Сетка

- (CGFloat)gridTop {
    return KLStatusBarHeight() + 12 + 44 + 12;
}

- (void)buildGrid {
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];

    [_scroll setBackgroundColor:[KLTheme pageBackground]];
    [_scroll setShowsVerticalScrollIndicator:NO];

    // Прокрутка уходит под плавающую панель вкладок — отступаем снизу,
    // чтобы последний ряд из-под неё выходил.
    [_scroll setContentInset:UIEdgeInsetsMake(0, 0, KLDockHeight + 16, 0)];

    [self addSubview:_scroll];

    _status = [[KLStatusView alloc] initWithFrame:CGRectZero];
    [self addSubview:_status];
}

- (CGFloat)cardWidth {
    CGFloat inner = self.bounds.size.width - KLSidePadding * 2;

    return floorf((inner - KLGap * (KLSearchColumns - 1)) / KLSearchColumns);
}

- (void)showResults:(NSArray *)results {
    _results = results;

    for (UIView *view in [NSArray arrayWithArray:[_scroll subviews]]) {
        [view removeFromSuperview];
    }

    if ([results count] == 0) {
        [_scroll setContentSize:CGSizeZero];

        // Перекладка зовёт этот метод и до первого поиска, когда показывать
        // нечего и нечего было. Тогда сообщение оставляем то, что стоит:
        // «Ничего не нашлось» до первого запроса было бы неправдой.
        if (_everSearched) {
            [_status showMessage:KLStr(@"search.empty")];
        }

        return;
    }

    [_status hide];

    CGFloat cardWidth = [self cardWidth];
    CGFloat cardHeight = [KLCardView heightForWidth:cardWidth];
    CGFloat rowGap = 14;

    for (NSUInteger i = 0; i < [results count]; i++) {
        KLAnime *anime = [results objectAtIndex:i];

        KLCardView *card = [[KLCardView alloc] initWithWidth:cardWidth];
        [card setAnime:anime];

        NSUInteger column = i % KLSearchColumns;
        NSUInteger row = i / KLSearchColumns;

        [card setFrame:CGRectMake(KLSidePadding + column * (cardWidth + KLGap),
                                  8 + row * (cardHeight + rowGap),
                                  cardWidth, cardHeight)];

        [card setAction:^{
            [KLNav push:[[KLDetailViewController alloc] initWithAnime:anime]];
        }];

        [_scroll addSubview:card];
    }

    NSUInteger rows = ([results count] + KLSearchColumns - 1) / KLSearchColumns;

    [_scroll setContentSize:CGSizeMake(self.bounds.size.width,
                                       8 + rows * (cardHeight + rowGap))];
    [_scroll setContentOffset:CGPointZero animated:NO];
}

#pragma mark Ввод

- (void)textChanged {
    [_clear setHidden:[[_field text] length] == 0];

    // Отменяем ранее назначенный поиск: пока набирают, искать рано.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(runSearch)
                                               object:nil];

    NSString *query = [[_field text]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([query length] == 0) {
        // Новое поколение обязательно: иначе ответ на «Nar», доехавший уже
        // после того, как поле очистили, дорисовал бы сетку заново.
        [_generation next];

        [self showResults:[NSArray array]];
        [_status showMessage:KLStr(@"search.prompt")];

        return;
    }

    [self performSelector:@selector(runSearch) withObject:nil afterDelay:KLSearchDelay];
}

- (void)clearTapped {
    [_field setText:@""];
    [self textChanged];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(runSearch)
                                               object:nil];
    [textField resignFirstResponder];
    [self runSearch];

    return NO;
}

- (void)runSearch {
    NSString *query = [[_field text]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([query length] == 0) {
        return;
    }

    NSInteger generation = [_generation next];
    _everSearched = YES;

    [_status showBusy];

    KLAsync(^{
        NSArray *found = [KLApi search:query];

        KLMain(^{
            if (![_generation isCurrent:generation]) {
                return;
            }

            [self showResults:found];
        });
    });
}

- (void)didBecomeVisible {
    // Курсор ставим сами: экран без клавиатуры, на который перешли ради
    // поиска, требует лишнего нажатия ни за чем. Но только если ещё
    // ничего не искали — возврат к готовым результатам клавиатурой
    // накрывать не за что.
    if (!_everSearched) {
        [self performSelector:@selector(focusField) withObject:nil afterDelay:0.05];
    }
}

- (void)focusField {
    [_field becomeFirstResponder];
}

@end
