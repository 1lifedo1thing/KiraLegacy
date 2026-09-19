#import "KLFilesView.h"

#import "KLAboutViewController.h"
#import "KLSettingsViewController.h"
#import "KLStrings.h"
#import "KLCardView.h"
#import "KLDetailViewController.h"
#import "KLLibrary.h"
#import "KLMetrics.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Разделы в том порядке, в каком они идут по экрану. */
static NSArray *KLFilesSections(void) {
    return [NSArray arrayWithObjects:
        @"continue", @"favorite",
        KLStatusWatching, KLStatusPlanning, KLStatusCompleted, KLStatusDropped, nil];
}

static NSString *KLFilesTitle(NSString *kind) {
    if ([kind isEqualToString:@"continue"]) return KLStr(@"files.continue");
    if ([kind isEqualToString:@"favorite"]) return KLStr(@"files.favorite");

    return [KLLibrary titleForStatus:kind];
}

@implementation KLFilesView {
    UIScrollView *_scroll;
    UILabel *_title;
    UILabel *_empty;
    NSMutableArray *_sectionViews;

    /** Размер, под который всё разложено сейчас. */
    CGSize _laidOut;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _sectionViews = [NSMutableArray array];

    [self setBackgroundColor:[KLTheme pageBackground]];

    _title = KLLabel(KLFontScreenTitle(), [KLTheme ink], 1);
    [_title setText:KLStr(@"tab.files")];
    [self addSubview:_title];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_scroll setBackgroundColor:[KLTheme pageBackground]];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [self addSubview:_scroll];

    _empty = KLLabel(KLFontBody(), [KLTheme faintInk], 0);
    [_empty setTextAlignment:NSTextAlignmentCenter];
    [_empty setText:KLStr(@"files.empty")];
    [_scroll addSubview:_empty];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuild)
                                                 name:KLLibraryChangedNotification
                                               object:nil];

    [self rebuild];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/**
 * Ставит рамки по нынешнему размеру и пересобирает разделы.
 *
 * Разделы именно пересобираются: ширина карточки в них считается от ширины
 * вида (три колонки с зазорами), и при повороте планшета карточки должны
 * стать шире, а не разъехаться по прежним местам.
 */
- (void)layoutContents {
    CGSize size = self.bounds.size;

    _laidOut = size;

    CGFloat top = KLStatusBarHeight() + 16;

    [_title setFrame:CGRectMake(KLSidePadding, top, size.width - KLSidePadding * 2, 34)];

    CGFloat contentTop = top + 34 + 8;

    [_scroll setFrame:CGRectMake(0, contentTop, size.width, size.height - contentTop)];
    [_empty setFrame:CGRectMake(KLSidePadding + 8, 60,
                                size.width - (KLSidePadding + 8) * 2, 140)];

    [self rebuild];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (!CGSizeEqualToSize(self.bounds.size, _laidOut)) {
        [self layoutContents];
    }
}

/**
 * Пересобирает все разделы заново.
 *
 * Не самый бережливый ход — но записей здесь десятки, а не тысячи, и
 * поштучное обновление потребовало бы знать, что именно изменилось.
 * Уведомление же говорит только «изменилось».
 */
- (void)rebuild {
    for (UIView *view in _sectionViews) {
        [view removeFromSuperview];
    }

    [_sectionViews removeAllObjects];

    CGFloat y = 0;
    BOOL anything = NO;

    for (NSString *kind in KLFilesSections()) {
        NSArray *entries = [KLLibrary list:kind];

        if ([entries count] == 0) {
            continue;
        }

        anything = YES;

        UIView *section = [self buildSection:kind entries:entries atY:y];

        [_scroll addSubview:section];
        [_sectionViews addObject:section];

        y += [section frame].size.height;
    }

    [_empty setHidden:anything];

    // Настройки и «О программе» — внизу «Моего»: отдельной вкладки они
    // не заслуживают, а спрятать их совсем нельзя — там и выбор языка,
    // и установка корней.
    y = [self addButton:KLStr(@"files.settings")
                 action:@selector(openSettings)
                     at:anything ? y : 220];

    y = [self addButton:KLStr(@"files.about") action:@selector(openAbout) at:y - 12];

    [_scroll setContentSize:CGSizeMake(self.bounds.size.width,
                                       y + KLDockHeight + 16)];
}

- (CGFloat)addButton:(NSString *)title action:(SEL)action at:(CGFloat)y {
    CGFloat width = self.bounds.size.width - KLSidePadding * 2;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setFrame:CGRectMake(KLSidePadding, y + 24, width, 46)];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    KLPillView *fill = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, width, 46)];
    [fill setFillColor:KLColor(0x1C1C24)];
    [fill setCornerRadius:10];
    [fill setUserInteractionEnabled:NO];
    [button addSubview:fill];

    UILabel *label = KLLabel([UIFont systemFontOfSize:15], [KLTheme mutedInk], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:title];
    [label setFrame:CGRectMake(0, 0, width, 46)];
    [button addSubview:label];

    [_scroll addSubview:button];
    [_sectionViews addObject:button];

    return y + 24 + 46;
}

- (void)openAbout {
    [KLNav push:[[KLAboutViewController alloc] init]];
}

- (void)openSettings {
    [KLNav push:[[KLSettingsViewController alloc] init]];
}

/**
 * Раздел — это заголовок и сетка карточек под ним.
 *
 * Сеткой, а не рядом с горизонтальной прокруткой: на главном экране ряды
 * уместны, потому что там их много и каждый — витрина. Здесь наоборот,
 * раздел это весь список целиком, и прятать половину его за краем экрана
 * было бы неудобно ровно в том месте, ради которого экран и заведён.
 */
- (UIView *)buildSection:(NSString *)kind entries:(NSArray *)entries atY:(CGFloat)y {
    CGFloat width = self.bounds.size.width;
    CGFloat cardWidth = floorf((width - KLSidePadding * 2 - KLGap * 2) / 3);
    CGFloat cardHeight = [KLCardView heightForWidth:cardWidth];
    CGFloat rowGap = 14;

    NSUInteger rows = ([entries count] + 2) / 3;
    CGFloat height = 20 + 24 + 10 + rows * (cardHeight + rowGap);

    UIView *section = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, height)];

    UILabel *title = KLLabel(KLFontSection(), [KLTheme ink], 1);
    [title setText:[NSString stringWithFormat:@"%@ · %lu",
                    KLFilesTitle(kind), (unsigned long)[entries count]]];
    [title setFrame:CGRectMake(KLSidePadding, 20, width - KLSidePadding * 2, 24)];
    [section addSubview:title];

    BOOL showsProgress = [kind isEqualToString:@"continue"];

    for (NSUInteger i = 0; i < [entries count]; i++) {
        KLLibraryEntry *entry = [entries objectAtIndex:i];

        KLCardView *card = [[KLCardView alloc] initWithWidth:cardWidth];

        [card setTitle:entry.title poster:entry.poster score:entry.score];

        if (showsProgress && entry.progressEpisode > 0) {
            [card setShowsPlayOverlay:YES];
            [card setEpisodeTag:KLFmt(@"card.episode", (long)entry.progressEpisode)];
        }

        [card setFrame:CGRectMake(KLSidePadding + (i % 3) * (cardWidth + KLGap),
                                  20 + 24 + 10 + (i / 3) * (cardHeight + rowGap),
                                  cardWidth, cardHeight)];

        [card setAction:^{
            [KLNav push:[[KLDetailViewController alloc]
                initWithAnilistId:entry.anilistId
                            title:entry.title
                           poster:entry.poster]];
        }];

        [section addSubview:card];
    }

    return section;
}

- (void)didBecomeVisible {
    [self rebuild];
}

@end
