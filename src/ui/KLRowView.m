#import "KLRowView.h"

#import "KLStrings.h"

#import "KLAnime.h"
#import "KLCardView.h"
#import "KLLibrary.h"
#import "KLMetrics.h"
#import "KLTheme.h"

/** Отступ заголовка от верха ряда и карточек от заголовка. */
static const CGFloat KLRowTitleHeight = 22;
static const CGFloat KLRowTitleGap = 12;
static const CGFloat KLRowTopPadding = 22;

@implementation KLRowView {
    UILabel *_title;
    UIScrollView *_scroll;
    UILabel *_message;
    UIActivityIndicatorView *_spinner;
    CGFloat _cardWidth;
    CGFloat _width;
}


+ (CGFloat)heightForCardWidth:(CGFloat)cardWidth {
    return KLRowTopPadding + KLRowTitleHeight + KLRowTitleGap +
           [KLCardView heightForWidth:cardWidth];
}

- (id)initWithTitle:(NSString *)title
              width:(CGFloat)width
          cardWidth:(CGFloat)cardWidth {
    self = [super initWithFrame:
        CGRectMake(0, 0, width, [[self class] heightForCardWidth:cardWidth])];

    if (self == nil) {
        return nil;
    }

    _width = width;
    _cardWidth = cardWidth;

    [self setBackgroundColor:[UIColor clearColor]];

    _title = KLLabel(KLFontSection(), [KLTheme ink], 1);
    [_title setText:title];
    [self addSubview:_title];

    CGFloat cardsTop = KLRowTopPadding + KLRowTitleHeight + KLRowTitleGap;
    CGFloat cardsHeight = [KLCardView heightForWidth:cardWidth];

    _scroll = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, cardsTop, width, cardsHeight)];

    [_scroll setShowsHorizontalScrollIndicator:NO];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [_scroll setBackgroundColor:[UIColor clearColor]];

    // Отступ от краёв задаём вставкой, а не сдвигом рамки: так первая
    // карточка стоит по общей линии полей, а прокрутка по-прежнему
    // ловит палец от самого края экрана.
    [_scroll setContentInset:UIEdgeInsetsMake(0, KLSidePadding, 0, KLSidePadding)];

    [self addSubview:_scroll];

    _message = KLLabel(KLFontBody(), [KLTheme faintInk], 2);
    [_message setHidden:YES];
    [self addSubview:_message];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [_spinner setCenter:CGPointMake(KLSidePadding + 12, cardsTop + 24)];
    [self addSubview:_spinner];

    [self layoutContents];

    return self;
}

/**
 * Расставляет всё по нынешней ширине.
 *
 * Ширина берётся из bounds каждый раз, а не запоминается при создании.
 * Ряд заводится однажды, а ширина у него меняется — на планшете при
 * повороте она прыгает с 768 на 1024. Пока рамки ставились в init
 * по тогдашним bounds, ряд так и оставался шириной 768, и справа
 * висела чёрная полоса в четверть экрана.
 */
- (void)layoutContents {
    _width = self.bounds.size.width;

    CGFloat inner = _width - KLSidePadding * 2;
    CGFloat cardsTop = KLRowTopPadding + KLRowTitleHeight + KLRowTitleGap;
    CGFloat cardsHeight = [KLCardView heightForWidth:_cardWidth];

    [_title setFrame:CGRectMake(KLSidePadding, KLRowTopPadding, inner, KLRowTitleHeight)];
    [_scroll setFrame:CGRectMake(0, cardsTop, _width, cardsHeight)];
    [_message setFrame:CGRectMake(KLSidePadding, cardsTop + 12, inner, 40)];
    [_spinner setCenter:CGPointMake(KLSidePadding + 12, cardsTop + 24)];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (self.bounds.size.width != _width) {
        [self layoutContents];
    }
}

#pragma mark Наполнение

- (void)clear {
    for (UIView *view in [NSArray arrayWithArray:[_scroll subviews]]) {
        [view removeFromSuperview];
    }

    [_scroll setContentOffset:CGPointZero animated:NO];
    [_message setHidden:YES];
    [_spinner stopAnimating];
}

- (void)place:(NSArray *)cards {
    CGFloat x = 0;

    for (KLCardView *card in cards) {
        CGRect frame = [card frame];
        frame.origin = CGPointMake(x, 0);
        [card setFrame:frame];

        [_scroll addSubview:card];

        x += _cardWidth + KLGap;
    }

    // Последний зазор не нужен: он добавил бы пустую полосу справа
    // при полной прокрутке.
    [_scroll setContentSize:CGSizeMake(MAX(0, x - KLGap), [_scroll bounds].size.height)];
    [_scroll setHidden:NO];
}

- (void)setAnimeList:(NSArray *)list {
    [self clear];

    if ([list count] == 0) {
        [self showMessage:KLStr(@"row.empty")];
        return;
    }

    NSMutableArray *cards = [NSMutableArray array];

    for (KLAnime *anime in list) {
        KLCardView *card = [[KLCardView alloc] initWithWidth:_cardWidth];

        [card setAnime:anime];

        __weak KLRowView *weakSelf = self;
        [card setAction:^{
            KLRowView *strong = weakSelf;

            if (strong != nil && strong.onPick != nil) {
                strong.onPick(anime);
            }
        }];

        [cards addObject:card];
    }

    [self place:cards];
}

- (void)setEntries:(NSArray *)entries showsProgress:(BOOL)showsProgress {
    [self clear];

    if ([entries count] == 0) {
        [self showMessage:KLStr(@"row.empty")];
        return;
    }

    NSMutableArray *cards = [NSMutableArray array];

    for (KLLibraryEntry *entry in entries) {
        KLCardView *card = [[KLCardView alloc] initWithWidth:_cardWidth];

        [card setTitle:entry.title poster:entry.poster score:entry.score];

        if (showsProgress && entry.progressEpisode > 0) {
            [card setShowsPlayOverlay:YES];
            [card setEpisodeTag:KLFmt(@"card.episode", (long)entry.progressEpisode)];
        }

        __weak KLRowView *weakSelf = self;
        [card setAction:^{
            KLRowView *strong = weakSelf;

            if (strong != nil && strong.onPick != nil) {
                strong.onPick(entry);
            }
        }];

        [cards addObject:card];
    }

    [self place:cards];
}

- (void)showMessage:(NSString *)message {
    [self clear];

    [_scroll setHidden:YES];
    [_message setText:message];
    [_message setHidden:NO];
}

- (void)showBusy {
    [self clear];

    [_scroll setHidden:YES];
    [_spinner startAnimating];
}

@end
