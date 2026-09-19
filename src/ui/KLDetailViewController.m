#import "KLDetailViewController.h"

#import "KLStrings.h"

#import "KLAnime.h"
#import "KLApi.h"
#import "KLEpisode.h"
#import "KLEpisodeRow.h"
#import "KLHlsProxy.h"
#import "KLLibrary.h"
#import "KLMetrics.h"
#import "KLPlayerViewController.h"
#import "KLPosterView.h"
#import "KLSettings.h"
#import "KLSheet.h"
#import "KLSource.h"
#import "KLTheme.h"
#import "KLUtil.h"

static const CGFloat KLHeroHeight = 230;
static const CGFloat KLTopBarHeight = 44;

/**
 * Сколько серий показываем одной страницей.
 *
 * Ограничение не из осторожности, а по факту: «One Piece» отдаёт 1178 серий,
 * и строка у нас — это кадр, два-три текста и кружок, то есть около пяти
 * видов. Разом это шесть тысяч видов в одной прокрутке; iPhone 3GS на такой
 * карточке не «подтормаживает», а перестаёт отвечать и закрывается по памяти.
 *
 * Шестьдесят — столько, сколько помещается в разумную высоту прокрутки
 * и разбивает даже самый длинный сериал на два десятка понятных отрезков.
 */
static const NSInteger KLEpisodePage = 60;

@interface KLDetailViewController () <UIScrollViewDelegate>
@end

@implementation KLDetailViewController {
    KLAnime *_anime;
    NSInteger _anilistId;
    NSString *_fallbackTitle;
    NSString *_fallbackPoster;

    NSString *_slug;
    NSArray *_episodes;
    NSString *_kind;          // sub или dub
    BOOL _ascending;
    BOOL _synopsisOpen;
    NSInteger _playingEpisode;

    /** Какой отрезок серий показан сейчас; 0 — первый. */
    NSInteger _episodeChunk;

    UIScrollView *_scroll;
    UIView *_topBar;
    KLPosterView *_heroImage;
    KLGradientView *_heroFade;
    KLIconView *_favoriteIcon;

    /** Размер, под который экран разложен сейчас. */
    CGSize _laidOut;

    UIView *_body;
    KLStatusView *_episodeStatus;

    KLGeneration *_generation;
    BOOL _detailsLoaded;
}

#pragma mark - Заведение

- (id)initWithAnime:(KLAnime *)anime {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _anime = anime;
    _anilistId = anime.anilistId;
    _fallbackTitle = [anime.title copy];
    _fallbackPoster = [anime.coverUrl copy];

    [self setUpDefaults];

    return self;
}

- (id)initWithAnilistId:(NSInteger)anilistId
                  title:(NSString *)title
                 poster:(NSString *)poster {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _anilistId = anilistId;
    _fallbackTitle = [title copy];
    _fallbackPoster = [poster copy];

    [self setUpDefaults];

    return self;
}

- (void)setUpDefaults {
    _generation = [[KLGeneration alloc] init];
    _kind = @"sub";
    _ascending = YES;
    _playingEpisode = 0;
    _episodeChunk = 0;

    // Продолжаем с той серии, на которой остановились: список сам
    // подсветит её, а кнопка «Смотреть» с баннера начнёт именно с неё.
    KLLibraryEntry *entry = [KLLibrary entryFor:_anilistId];

    if (entry.progressEpisode > 0) {
        _playingEpisode = entry.progressEpisode;
    }
}

#pragma mark - Вид

- (void)loadView {
    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];
    [[self view] setBackgroundColor:[KLTheme pageBackground]];

    KLUseFullScreenLayout(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    CGRect bounds = [[self view] bounds];

    _scroll = [[UIScrollView alloc] initWithFrame:bounds];
    [_scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight];
    [_scroll setBackgroundColor:[KLTheme pageBackground]];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [_scroll setDelegate:self];
    [[self view] addSubview:_scroll];

    [self buildHero];
    [self buildTopBar];

    _body = [[UIView alloc] initWithFrame:
        CGRectMake(0, KLHeroHeight, bounds.size.width, 0)];
    [_scroll addSubview:_body];

    _episodeStatus = [[KLStatusView alloc] initWithFrame:
        CGRectMake(0, KLHeroHeight + 160, bounds.size.width, 120)];
    [_scroll addSubview:_episodeStatus];

    [self rebuildBody];
    [self loadDetails];
    [self loadEpisodes];

    // Карточка собрана из подписей целиком, а живёт долго: язык вполне
    // могут сменить, не закрывая её.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildBody)
                                                 name:KLLanguageChangedNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_scroll setDelegate:nil];
}

- (void)buildHero {
    CGFloat width = [[self view] bounds].size.width;

    _heroImage = [[KLPosterView alloc] initWithFrame:
        CGRectMake(0, 0, width, KLHeroHeight)];

    [_heroImage setPlaceholderColor:KLColor(0x0C0C14)];
    [_heroImage setDimming:0.3];
    [_scroll addSubview:_heroImage];

    _heroFade = [[KLGradientView alloc]
        initWithFrame:CGRectMake(0, KLHeroHeight - 150, width, 150)
            downwards:YES];
    [_scroll addSubview:_heroFade];

    [self showHeroImage];
}

- (void)showHeroImage {
    CGFloat width = [[self view] bounds].size.width;

    NSString *url = _anime.bannerUrl ?: (_anime.coverUrl ?: _fallbackPoster);

    [_heroImage loadUrl:url targetSize:CGSizeMake(width, KLHeroHeight)];
}

/**
 * Верхняя полоса — назад слева, «любимое» и «в список» справа.
 *
 * Она не прокручивается вместе с содержимым, а висит поверх: в макете
 * это `position:sticky`. Поэтому она лежит в виде контроллера, а не
 * в прокрутке, и рисуется подложкой только тогда, когда содержимое
 * под неё заехало, — см. scrollViewDidScroll:.
 */
- (void)buildTopBar {
    CGFloat width = [[self view] bounds].size.width;
    CGFloat top = KLStatusBarHeight();

    _topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, top + KLTopBarHeight)];
    [_topBar setBackgroundColor:[UIColor clearColor]];
    [_topBar setAutoresizingMask:UIViewAutoresizingFlexibleWidth];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    [back setFrame:CGRectMake(6, top, 44, KLTopBarHeight)];
    [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];

    KLIconView *arrow = [KLIconView iconOf:KLIconBack tint:[KLTheme ink] side:22];
    [arrow setCenter:CGPointMake(22, KLTopBarHeight / 2)];
    [back addSubview:arrow];
    [_topBar addSubview:back];

    UIButton *favorite = [UIButton buttonWithType:UIButtonTypeCustom];
    [favorite setFrame:CGRectMake(width - 96, top, 44, KLTopBarHeight)];
    [favorite setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [favorite addTarget:self
                 action:@selector(toggleFavorite)
       forControlEvents:UIControlEventTouchUpInside];

    _favoriteIcon = [KLIconView iconOf:KLIconCheck tint:[KLTheme ink] side:22];
    [_favoriteIcon setCenter:CGPointMake(22, KLTopBarHeight / 2)];
    [favorite addSubview:_favoriteIcon];
    [_topBar addSubview:favorite];

    UIButton *list = [UIButton buttonWithType:UIButtonTypeCustom];
    [list setFrame:CGRectMake(width - 50, top, 44, KLTopBarHeight)];
    [list setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [list addTarget:self action:@selector(openStatusSheet) forControlEvents:UIControlEventTouchUpInside];

    KLIconView *plus = [KLIconView iconOf:KLIconPlus tint:[KLTheme ink] side:22];
    [plus setCenter:CGPointMake(22, KLTopBarHeight / 2)];
    [list addSubview:plus];
    [_topBar addSubview:list];

    [[self view] addSubview:_topBar];

    [self updateFavoriteIcon];
}

- (void)updateFavoriteIcon {
    BOOL favorite = [KLLibrary isFavorite:_anilistId];

    // Значка «сердце» в наборе нет, и заводить его ради одного места
    // не стали: галочка в фирменном цвете читается так же однозначно —
    // «отмечено».
    [_favoriteIcon setTint:favorite ? [KLTheme accent] : [KLTheme ink]];
}

#pragma mark - Раскладка

/**
 * Переставляет всё под нынешний размер экрана.
 *
 * Тело пересобирается целиком, а не двигается: ширина там участвует
 * в каждом замере — от переноса названия до раскладки «таблеток» жанров
 * и высоты строк серий. Двигать это по отдельности вышло бы дороже,
 * чем собрать заново.
 */
- (void)layoutContents {
    CGSize size = [[self view] bounds].size;

    _laidOut = size;

    [_scroll setFrame:[[self view] bounds]];
    [_heroImage setFrame:CGRectMake(0, 0, size.width, KLHeroHeight)];
    [_heroFade setFrame:CGRectMake(0, KLHeroHeight - 150, size.width, 150)];

    CGRect bar = [_topBar frame];
    bar.size.width = size.width;
    [_topBar setFrame:bar];

    [self rebuildBody];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    if (!CGSizeEqualToSize([[self view] bounds].size, _laidOut)) {
        [self layoutContents];
    }
}

#pragma mark - Тело

/**
 * Собирает всё, что ниже шапки, и пересобирает при каждом изменении:
 * пришли подробности, развернули описание, переключили порядок серий.
 *
 * Перекладка целиком, а не правка на месте: блоков тут восемь, высота
 * у каждого своя и зависит от содержимого, и «подвинуть всё, что ниже»
 * пришлось бы после любой правки. Пересборка стоит нескольких миллисекунд
 * и случается единицы раз за жизнь экрана.
 */
- (void)rebuildBody {
    for (UIView *view in [NSArray arrayWithArray:[_body subviews]]) {
        [view removeFromSuperview];
    }

    CGFloat width = [[self view] bounds].size.width;
    CGFloat inner = width - KLSidePadding * 2;
    CGFloat y = 16;

    y = [self addTitleAt:y width:inner];
    y = [self addTagsAt:y width:inner];
    y = [self addSynopsisAt:y width:inner];
    y = [self addCastAt:y width:width];
    y = [self addEpisodeHeaderAt:y width:inner];
    y = [self addCountdownAt:y width:inner];
    y = [self addChunkPillsAt:y width:width];
    y = [self addEpisodesAt:y width:width];

    [_body setFrame:CGRectMake(0, KLHeroHeight, width, y + 24)];

    [_scroll setContentSize:CGSizeMake(width, KLHeroHeight + y + 24)];

    [_episodeStatus setFrame:CGRectMake(0, KLHeroHeight + y - 100, width, 120)];
    [[_episodeStatus superview] bringSubviewToFront:_episodeStatus];
}

- (NSString *)displayTitle {
    return _anime.title ?: (_fallbackTitle ?: @"Без названия");
}

- (CGFloat)addTitleAt:(CGFloat)y width:(CGFloat)width {
    NSString *text = [self displayTitle];
    CGFloat height = KLTextHeight(text, KLFontDetailTitle(), width, 3);

    UILabel *label = KLLabel(KLFontDetailTitle(), [KLTheme ink], 3);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, y, width, height)];
    [_body addSubview:label];

    return y + height + 10;
}

/** «Таблетка» с текстом: оценка, год, формат, жанр. */
- (UIView *)tagWithText:(NSString *)text
                  color:(UIColor *)color
                   fill:(UIColor *)fill {
    CGSize size = [text sizeWithFont:KLFontBadge()];

    CGFloat width = ceilf(size.width) + 18;
    CGFloat height = 22;

    KLPillView *pill = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    [pill setFillColor:fill];
    [pill setCornerRadius:6];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:11], color, 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:text];
    [label setFrame:CGRectMake(0, 0, width, height)];
    [pill addSubview:label];

    return pill;
}

- (CGFloat)addTagsAt:(CGFloat)y width:(CGFloat)width {
    NSMutableArray *tags = [NSMutableArray array];

    NSString *score = [_anime scoreText];

    if (score != nil) {
        [tags addObject:[self tagWithText:[NSString stringWithFormat:@"★ %@", score]
                                    color:[KLTheme gold]
                                     fill:KLColor(0x1C1C24)]];
    }

    if (_anime.year > 0) {
        [tags addObject:[self tagWithText:[NSString stringWithFormat:@"%ld", (long)_anime.year]
                                    color:[KLTheme mutedInk]
                                     fill:KLColor(0x1C1C24)]];
    }

    if ([_anime.format length] > 0) {
        [tags addObject:[self tagWithText:_anime.format
                                    color:[KLTheme mutedInk]
                                     fill:KLColor(0x1C1C24)]];
    }

    if (_anime.duration > 0) {
        [tags addObject:[self tagWithText:KLFmt(@"anime.minutes", (long)_anime.duration)
                                    color:[KLTheme mutedInk]
                                     fill:KLColor(0x1C1C24)]];
    }

    for (NSString *genre in _anime.genres) {
        [tags addObject:[self tagWithText:genre
                                    color:[KLTheme mutedInk]
                                     fill:KLColor(0x1C1C24)]];
    }

    if ([tags count] == 0) {
        return y;
    }

    // Раскладка в несколько строк с переносом: жанров бывает и восемь,
    // в одну строку они не встают ни на каком экране.
    CGFloat x = KLSidePadding;
    CGFloat rowY = y;
    CGFloat gap = 6;

    for (UIView *tag in tags) {
        CGRect frame = [tag frame];

        if (x + frame.size.width > KLSidePadding + width && x > KLSidePadding) {
            x = KLSidePadding;
            rowY += frame.size.height + gap;
        }

        frame.origin = CGPointMake(x, rowY);
        [tag setFrame:frame];

        [_body addSubview:tag];

        x += frame.size.width + gap;
    }

    return rowY + 22 + 14;
}

- (CGFloat)addSynopsisAt:(CGFloat)y width:(CGFloat)width {
    NSString *text = _anime.synopsis;

    if ([text length] == 0) {
        return y;
    }

    NSInteger lines = _synopsisOpen ? 0 : 3;
    CGFloat height = KLTextHeight(text, KLFontBody(), width, lines);

    UILabel *label = KLLabel(KLFontBody(), [KLTheme mutedInk], lines);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, y, width, height)];
    [_body addSubview:label];

    y += height + 6;

    // Кнопку показываем только тогда, когда текст и правда не поместился:
    // «Показать полностью» под тремя строками из трёх ничего не раскрывает.
    CGFloat full = KLTextHeight(text, KLFontBody(), width, 0);

    if (!_synopsisOpen && full <= height) {
        return y + 12;
    }

    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeCustom];
    [toggle setFrame:CGRectMake(KLSidePadding, y, 200, 26)];
    [toggle addTarget:self action:@selector(toggleSynopsis) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label2 = KLLabel(KLFontMeta(), [KLTheme faintInk], 1);
    [label2 setText:KLStr(_synopsisOpen ? @"detail.showless" : @"detail.showmore")];
    [label2 setFrame:CGRectMake(0, 0, 200, 26)];
    [toggle addSubview:label2];

    [_body addSubview:toggle];

    return y + 26 + 12;
}

- (CGFloat)addCastAt:(CGFloat)y width:(CGFloat)width {
    if ([_anime.cast count] == 0) {
        return y;
    }

    UILabel *title = KLLabel(KLFontSection(), [KLTheme ink], 1);
    [title setText:KLStr(@"detail.characters")];
    [title setFrame:CGRectMake(KLSidePadding, y, width - KLSidePadding * 2, 22)];
    [_body addSubview:title];

    y += 22 + 12;

    CGFloat itemWidth = 76;
    CGFloat photo = 64;
    CGFloat height = photo + 8 + 34;

    UIScrollView *row = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, y, width, height)];

    [row setShowsHorizontalScrollIndicator:NO];
    [row setContentInset:UIEdgeInsetsMake(0, KLSidePadding, 0, KLSidePadding)];

    CGFloat x = 0;

    for (KLCastMember *member in _anime.cast) {
        UIView *item = [[UIView alloc] initWithFrame:
            CGRectMake(x, 0, itemWidth, height)];

        KLPosterView *avatar = [[KLPosterView alloc] initWithFrame:
            CGRectMake((itemWidth - photo) / 2, 0, photo, photo)];

        // Круг — это то же скругление, только радиусом в половину стороны.
        [avatar setCornerRadius:photo / 2];
        [avatar setPlaceholderColor:KLColor(0x1A1A28)];
        [avatar loadUrl:member.imageUrl targetSize:CGSizeMake(photo, photo)];
        [item addSubview:avatar];

        UILabel *name = KLLabel([UIFont boldSystemFontOfSize:11], [KLTheme ink], 2);
        [name setTextAlignment:NSTextAlignmentCenter];
        [name setText:member.name];
        [name setFrame:CGRectMake(0, photo + 7, itemWidth, 28)];
        [item addSubview:name];

        [row addSubview:item];

        x += itemWidth + 10;
    }

    [row setContentSize:CGSizeMake(MAX(0, x - 10), height)];
    [_body addSubview:row];

    return y + height + 20;
}

#pragma mark Серии

- (CGFloat)addEpisodeHeaderAt:(CGFloat)y width:(CGFloat)width {
    // Порядок серий.
    UIButton *sort = [UIButton buttonWithType:UIButtonTypeCustom];
    [sort setFrame:CGRectMake(KLSidePadding, y, 92, 32)];
    [sort addTarget:self action:@selector(toggleSort) forControlEvents:UIControlEventTouchUpInside];

    KLPillView *sortFill = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, 92, 32)];
    [sortFill setFillColor:KLColor(0x1C1C24)];
    [sortFill setCornerRadius:8];
    [sortFill setUserInteractionEnabled:NO];
    [sort addSubview:sortFill];

    UILabel *sortLabel = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme ink], 1);
    [sortLabel setText:KLStr(_ascending ? @"detail.sort.asc" : @"detail.sort.desc")];
    [sortLabel setFrame:CGRectMake(12, 0, 70, 32)];
    [sort addSubview:sortLabel];

    [_body addSubview:sort];

    // Субтитры или озвучка. Переключатель здесь, а не во всплывающей панели
    // источников, потому что выбор относится ко всему тайтлу: у зеркал это
    // разные раздачи, и список источников у них свой.
    CGFloat switchX = KLSidePadding + 92 + 10;

    NSArray *kinds = [NSArray arrayWithObjects:@"sub", @"dub", nil];
    NSArray *titles = [NSArray arrayWithObjects:
        KLStr(@"detail.subs"), KLStr(@"detail.dub"), nil];

    for (NSUInteger i = 0; i < 2; i++) {
        BOOL chosen = [_kind isEqualToString:[kinds objectAtIndex:i]];
        NSString *text = [titles objectAtIndex:i];

        CGFloat buttonWidth = ceilf([text sizeWithFont:[UIFont boldSystemFontOfSize:12]].width) + 22;

        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setFrame:CGRectMake(switchX, y, buttonWidth, 32)];
        [button setTag:i];
        [button addTarget:self action:@selector(kindTapped:) forControlEvents:UIControlEventTouchUpInside];

        KLPillView *fill = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, buttonWidth, 32)];
        [fill setFillColor:chosen ? [KLTheme accentSurface] : KLColor(0x1C1C24)];
        [fill setStrokeColor:chosen ? [KLTheme accent] : nil];
        [fill setCornerRadius:8];
        [fill setUserInteractionEnabled:NO];
        [button addSubview:fill];

        UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12],
                                 chosen ? [KLTheme ink] : [KLTheme mutedInk], 1);
        [label setTextAlignment:NSTextAlignmentCenter];
        [label setText:text];
        [label setFrame:CGRectMake(0, 0, buttonWidth, 32)];
        [button addSubview:label];

        [_body addSubview:button];

        switchX += buttonWidth + 8;
    }

    // Число серий — справа, приглушённым.
    UILabel *count = KLLabel([UIFont boldSystemFontOfSize:13], [KLTheme faintInk], 1);
    [count setTextAlignment:NSTextAlignmentRight];
    [count setText:[_episodes count] > 0
        ? KLFmt(@"detail.count", (unsigned long)[_episodes count])
        : @""];
    [count setFrame:CGRectMake(KLSidePadding + width - 90, y, 90, 32)];
    [_body addSubview:count];

    return y + 32 + 10;
}

- (CGFloat)addCountdownAt:(CGFloat)y width:(CGFloat)width {
    if (_anime.nextEpisode <= 0 || _anime.nextEpisodeIn <= 0) {
        return y;
    }

    NSInteger days = _anime.nextEpisodeIn / 86400;
    NSInteger hours = (_anime.nextEpisodeIn % 86400) / 3600;

    NSString *when = days > 0
        ? KLFmt(@"detail.next.days", (long)days, (long)hours)
        : KLFmt(@"detail.next.hours", (long)hours);

    UILabel *label = KLLabel(KLFontMeta(), [KLTheme mutedInk], 1);
    [label setText:KLFmt(@"episode.number.title", (long)_anime.nextEpisode, when)];
    [label setFrame:CGRectMake(KLSidePadding, y, width, 18)];
    [_body addSubview:label];

    return y + 18 + 12;
}

- (NSArray *)orderedEpisodes {
    if (_ascending || [_episodes count] == 0) {
        return _episodes;
    }

    return [[_episodes reverseObjectEnumerator] allObjects];
}

/** На сколько отрезков разбит список. Один — значит, разбивать нечего. */
- (NSInteger)chunkCount {
    NSInteger total = (NSInteger)[_episodes count];

    return total > 0 ? (total + KLEpisodePage - 1) / KLEpisodePage : 0;
}

/** Серии текущего отрезка — уже в выбранном порядке. */
- (NSArray *)visibleEpisodes {
    NSArray *ordered = [self orderedEpisodes];

    NSInteger total = (NSInteger)[ordered count];
    if (total == 0) {
        return ordered;
    }

    NSInteger start = _episodeChunk * KLEpisodePage;

    // Отрезок мог оказаться за краем: так бывает после смены порядка
    // на списке, где отрезков не поровну. Тогда возвращаемся к первому.
    if (start >= total) {
        start = 0;
        _episodeChunk = 0;
    }

    NSInteger length = MIN(KLEpisodePage, total - start);

    return [ordered subarrayWithRange:NSMakeRange(start, length)];
}

/**
 * Полоса отрезков: «1–60», «61–120» и так далее.
 *
 * Подписи берутся из настоящих номеров серий, а не считаются от единицы:
 * у сериалов с сезонами и спецвыпусками нумерация сквозная, но начинается
 * не всегда с единицы, и «61–120» было бы просто неправдой.
 */
- (CGFloat)addChunkPillsAt:(CGFloat)y width:(CGFloat)width {
    NSInteger chunks = [self chunkCount];

    if (chunks < 2) {
        return y;
    }

    NSArray *ordered = [self orderedEpisodes];

    UIScrollView *row = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, y, width, 40)];

    [row setShowsHorizontalScrollIndicator:NO];
    [row setContentInset:UIEdgeInsetsMake(0, KLSidePadding, 0, KLSidePadding)];

    CGFloat x = 0;

    for (NSInteger i = 0; i < chunks; i++) {
        NSInteger start = i * KLEpisodePage;
        NSInteger last = MIN(start + KLEpisodePage, (NSInteger)[ordered count]) - 1;

        KLEpisode *first = [ordered objectAtIndex:start];
        KLEpisode *final = [ordered objectAtIndex:last];

        NSString *text = [NSString stringWithFormat:@"%ld–%ld",
                          (long)first.number, (long)final.number];

        BOOL chosen = (i == _episodeChunk);

        CGFloat pillWidth = ceilf([text sizeWithFont:[UIFont boldSystemFontOfSize:12]].width) + 26;

        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setFrame:CGRectMake(x, 2, pillWidth, 32)];
        [button setTag:i];
        [button addTarget:self
                   action:@selector(chunkTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        KLPillView *fill = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, pillWidth, 32)];
        [fill setFillColor:chosen ? [KLTheme accentSurface] : KLColor(0x1C1C24)];
        [fill setStrokeColor:chosen ? [KLTheme accent] : nil];
        [fill setCornerRadius:8];
        [fill setUserInteractionEnabled:NO];
        [button addSubview:fill];

        UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12],
                                 chosen ? [KLTheme ink] : [KLTheme mutedInk], 1);
        [label setTextAlignment:NSTextAlignmentCenter];
        [label setText:text];
        [label setFrame:CGRectMake(0, 0, pillWidth, 32)];
        [button addSubview:label];

        [row addSubview:button];

        x += pillWidth + 8;
    }

    [row setContentSize:CGSizeMake(MAX(0, x - 8), 40)];
    [_body addSubview:row];

    return y + 40 + 8;
}

- (void)chunkTapped:(UIButton *)button {
    if ([button tag] == _episodeChunk) {
        return;
    }

    _episodeChunk = [button tag];
    [self rebuildBody];
}

- (CGFloat)addEpisodesAt:(CGFloat)y width:(CGFloat)width {
    NSArray *episodes = [self visibleEpisodes];

    if ([episodes count] == 0) {
        // Место под сообщение о загрузке или отказе: сам текст ставит
        // loadEpisodes через _episodeStatus.
        return y + 120;
    }

    /**
     * Слабая ссылка на себя обязательна: блок лежит в строке, строка —
     * в теле, тело — в прокрутке, прокрутка — в нас. Обычный захват
     * замкнул бы кольцо, и карточка не освобождалась бы никогда — а строк
     * у длинного сериала под тысячу, и каждая держала бы свои картинки.
     */
    __weak KLDetailViewController *weakSelf = self;

    for (KLEpisode *episode in episodes) {
        KLEpisodeRow *row = [[KLEpisodeRow alloc] initWithWidth:width episode:episode];

        [row setFrame:CGRectMake(0, y, width, [row frame].size.height)];
        [row setPlaying:episode.number == _playingEpisode];

        [row setAction:^{ [weakSelf pickEpisode:episode]; }];

        [_body addSubview:row];

        y += [row frame].size.height;
    }

    return y;
}

#pragma mark - Загрузка

- (void)loadDetails {
    NSInteger generation = [_generation next];

    KLAsync(^{
        KLAnime *full = [KLApi details:_anilistId];

        KLMain(^{
            if (![_generation isCurrent:generation] || full == nil) {
                return;
            }

            _anime = full;
            _detailsLoaded = YES;

            [self showHeroImage];
            [self rebuildBody];
        });
    });
}

- (void)loadEpisodes {
    [_episodeStatus showBusy];

    // Название для поиска у зеркал: romaji предпочтительнее — зеркала
    // подписаны именно им, и «Shingeki no Kyojin» находится там, где
    // «Attack on Titan» может и не найтись.
    NSString *lookup = _anime.romajiTitle ?: [self displayTitle];

    KLAsync(^{
        NSString *slug = [KLApi slugForTitle:lookup anilistId:_anilistId];

        if (slug == nil && ![lookup isEqualToString:[self displayTitle]]) {
            // Не нашлось по romaji — пробуем английским: у части тайтлов
            // зеркала подписаны именно им.
            slug = [KLApi slugForTitle:[self displayTitle] anilistId:_anilistId];
        }

        NSArray *episodes = slug != nil ? [KLApi episodesForSlug:slug] : nil;

        KLMain(^{
            _slug = slug;
            _episodes = episodes ?: [NSArray array];

            /**
             * Список серий строим сами, если разрешатель тайтла не знает.
             *
             * Раньше на «зеркала не знают тайтла» экран сдавался целиком —
             * и это было неправильно вдвойне: списком серий занимается один
             * разрешатель, а видео отдают ещё шесть зеркал, и им никакой slug
             * не нужен, они ищут по идентификатору. Получалось, что тайтл
             * прекрасно смотрится, а открыть его нечем.
             *
             * Сколько серий, знает AniList. Названий и кадров у такого
             * списка не будет — только номера, — но играть по нему можно.
             */
            if ([_episodes count] == 0 && _anime.episodeCount > 0) {
                NSMutableArray *plain = [NSMutableArray array];

                for (NSInteger n = 1; n <= _anime.episodeCount; n++) {
                    KLEpisode *episode = [[KLEpisode alloc] init];

                    episode.number = n;
                    [plain addObject:episode];
                }

                _episodes = plain;

                NSLog(@"[Кира/API] Список серий собран по счётчику AniList: %ld",
                      (long)_anime.episodeCount);
            }

            if ([_episodes count] > 0) {
                [_episodeStatus hide];
            } else {
                __weak KLDetailViewController *weakSelf = self;

                [_episodeStatus showMessage:KLStr(@"detail.noepisodes")
                                actionTitle:KLStr(@"detail.retry")
                                     action:^{ [weakSelf loadEpisodes]; }];
            }

            [self selectChunkWithPlayingEpisode];
            [self rebuildBody];

            if (_autoplay && [_episodes count] > 0) {
                _autoplay = NO;

                // С той серии, на которой остановились, а если не начинали —
                // с первой.
                [self pickEpisode:[self episodeNumbered:_playingEpisode > 0
                                                        ? _playingEpisode : 1]];
            }
        });
    });
}

/**
 * Открывает тот отрезок, в котором лежит серия, на которой остановились.
 *
 * Без этого возврат к сериалу, где просмотрено пятьсот серий, показывал бы
 * первый отрезок — и до места пришлось бы добираться нажатиями по полосе.
 */
- (void)selectChunkWithPlayingEpisode {
    _episodeChunk = 0;

    if (_playingEpisode <= 0 || [_episodes count] <= KLEpisodePage) {
        return;
    }

    NSArray *ordered = [self orderedEpisodes];

    for (NSUInteger i = 0; i < [ordered count]; i++) {
        KLEpisode *episode = [ordered objectAtIndex:i];

        if (episode.number == _playingEpisode) {
            _episodeChunk = (NSInteger)i / KLEpisodePage;
            return;
        }
    }
}

- (KLEpisode *)episodeNumbered:(NSInteger)number {
    for (KLEpisode *episode in _episodes) {
        if (episode.number == number) {
            return episode;
        }
    }

    return [_episodes count] > 0 ? [_episodes objectAtIndex:0] : nil;
}

#pragma mark - Действия

- (void)goBack {
    [KLNav pop];
}

- (void)toggleFavorite {
    KLAnime *anime = [self animeForLibrary];

    BOOL now = [KLLibrary toggleFavorite:anime];

    [self updateFavoriteIcon];
    [KLToast show:KLStr(now ? @"toast.fav.on" : @"toast.fav.off")];
}

- (void)openStatusSheet {
    [KLStatusSheet presentFor:[self animeForLibrary] completion:nil];
}

/**
 * Что запомнить в «Моём».
 *
 * Подробности могли ещё не доехать — тогда у нас на руках только то, с чем
 * экран открыли. Собираем из этого временный KLAnime: списку нужны ровно
 * идентификатор, название и обложка, и они есть всегда.
 */
- (KLAnime *)animeForLibrary {
    if (_anime != nil) {
        return _anime;
    }

    KLAnime *stub = [[KLAnime alloc] init];

    stub.anilistId = _anilistId;
    stub.title = _fallbackTitle;
    stub.coverUrl = _fallbackPoster;

    return stub;
}

- (void)toggleSynopsis {
    _synopsisOpen = !_synopsisOpen;
    [self rebuildBody];
}

- (void)toggleSort {
    _ascending = !_ascending;

    // Порядок перевернулся — «первый отрезок» теперь означает другие серии,
    // и оставаться на прежнем номере отрезка было бы бессмысленно.
    _episodeChunk = 0;

    [self rebuildBody];
}

- (void)kindTapped:(UIButton *)button {
    NSString *kind = [button tag] == 0 ? @"sub" : @"dub";

    if ([kind isEqualToString:_kind]) {
        return;
    }

    _kind = kind;

    // Список серий от выбора не зависит — зависит только список источников,
    // а его спрашивают в момент нажатия. Поэтому перерисовываем, но
    // не перезагружаем.
    [self rebuildBody];
}

#pragma mark - Выбор источника

- (void)pickEpisode:(KLEpisode *)episode {
    if (episode == nil || _slug == nil) {
        [KLToast show:KLStr(@"detail.nosource")];
        return;
    }

    _playingEpisode = episode.number;
    [self rebuildBody];

    [KLToast show:KLFmt(@"detail.searching", (long)episode.number)];

    KLAsync(^{
        NSArray *sources = [KLApi sourcesForAnilistId:_anilistId
                                                malId:_anime.malId
                                                 slug:_slug
                                              episode:episode.number
                                                 kind:_kind];

        KLMain(^{
            if ([sources count] == 0) {
                [KLToast show:KLFmt(@"detail.nosources.kind", (long)episode.number,
                                    KLStr([_kind isEqualToString:@"dub"]
                                          ? @"source.dub" : @"source.sub"))];
                return;
            }

            // Один источник — спрашивать не о чем, играем сразу.
            if ([sources count] == 1) {
                [self play:[sources objectAtIndex:0] episode:episode];
                return;
            }

            /**
             * Зеркало по умолчанию берётся без вопроса.
             *
             * Спрашивать каждый раз, когда ответ почти всегда один и тот же,
             * — это лишнее нажатие на каждую серию. Кому нужен выбор, тот
             * ставит в настройках «спрашивать каждый раз»; там же меняется
             * и само умолчание.
             *
             * Если любимого зеркала среди найденных нет, играем первое:
             * список уже отсортирован по пригодности, и первое — лучшее
             * из того, что нашлось.
             */
            NSString *preferred = [KLSettings preferredSource];

            if ([preferred length] > 0) {
                for (KLSource *candidate in sources) {
                    if ([candidate.label isEqualToString:preferred]) {
                        [self play:candidate episode:episode];
                        return;
                    }
                }

                [self play:[sources objectAtIndex:0] episode:episode];
                return;
            }

            [self showSourceSheet:sources episode:episode];
        });
    });
}

- (void)showSourceSheet:(NSArray *)sources episode:(KLEpisode *)episode {
    KLSheet *sheet = [[KLSheet alloc] initWithTitle:KLStr(@"detail.source")
                                           subtitle:[episode displayTitle]];

    __weak KLDetailViewController *weakSelf = self;

    for (KLSource *source in sources) {
        // К имени зеркала дописываем, что оно умеет: субтитры есть далеко
        // не у всех, и это единственное, чем выбор здесь осмыслен.
        NSMutableString *name = [NSMutableString stringWithString:[source displayName]];

        if ([source.subtitles count] > 0) {
            [name appendString:KLStr(@"detail.withsubs")];
        }

        [sheet addSource:name
              firstTitle:KLStr(@"detail.watch")
             firstAction:^{ [weakSelf play:source episode:episode]; }
             secondTitle:nil
            secondAction:nil];
    }

    [sheet present];
}

- (void)play:(KLSource *)source episode:(KLEpisode *)episode {
    NSString *playlist = [KLApi playlistUrlForSource:source];

    if (playlist == nil) {
        [KLToast show:KLStr(@"detail.nolink")];
        return;
    }

    [KLLibrary markProgress:[self animeForLibrary] episode:episode.number];

    // Качество по умолчанию — до подготовки потока: мастер разбирается
    // один раз, и позже закрепление уже ни на что не повлияет.
    [[KLHlsProxy shared] setPinnedHeight:[KLSettings preferredHeight]];

    KLPlayerViewController *player =
        [[KLPlayerViewController alloc] initWithPlaylist:playlist
                                                   title:[self displayTitle]
                                                subtitle:[episode displayTitle]
                                                  source:source];

    [KLNav push:player];
}

#pragma mark - Прокрутка

/**
 * Верхняя полоса прозрачна над кадром и закрашивается, когда под неё
 * заезжает текст: иначе кнопки терялись бы на светлом кадре в одном месте
 * и на чёрном фоне в другом.
 */
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat offset = [scrollView contentOffset].y;
    CGFloat threshold = KLHeroHeight - [_topBar frame].size.height;

    BOOL solid = offset > threshold;

    [_topBar setBackgroundColor:solid
        ? [KLTheme pageBackground]
        : [UIColor clearColor]];
}

#pragma mark - Поворот

/** Карточка живёт стоя; лёжа разворачивается только плеер. */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        return YES;
    }

    return orientation == UIInterfaceOrientationPortrait;
}

- (BOOL)shouldAutorotate {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
        ? UIInterfaceOrientationMaskAll
        : UIInterfaceOrientationMaskPortrait;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Вернулись из плеера: отметка о просмотренной серии могла измениться.
    KLLibraryEntry *entry = [KLLibrary entryFor:_anilistId];

    if (entry.progressEpisode > 0 && entry.progressEpisode != _playingEpisode) {
        _playingEpisode = entry.progressEpisode;
        [self rebuildBody];
    }

    [self updateFavoriteIcon];
}

@end
