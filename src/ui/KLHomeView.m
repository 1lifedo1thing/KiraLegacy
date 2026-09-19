#import "KLHomeView.h"

#import "KLStrings.h"

#import "KLAnime.h"
#import "KLApi.h"
#import "KLDetailViewController.h"
#import "KLHttp.h"
#import "KLLibrary.h"
#import "KLMetrics.h"
#import "KLPosterView.h"
#import "KLRowView.h"
#import "KLSheet.h"
#import "KLShellViewController.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Высота баннера: доля экрана, но не выше макетных 420 точек. */
static CGFloat KLHeroHeight(CGFloat screenHeight) {
    return MIN(420.0, floorf(screenHeight * 0.62));
}

@interface KLHomeView () <UIScrollViewDelegate>
@end

@implementation KLHomeView {
    UIScrollView *_scroll;
    KLRefreshHeader *_refresh;

    UIView *_hero;
    KLPosterView *_heroImage;
    KLGradientView *_topFade;
    KLGradientView *_bottomFade;
    UILabel *_wordmark;
    UIButton *_searchButton;
    UILabel *_heroTitle;
    UILabel *_heroMeta;
    UILabel *_heroListText;
    KLIconView *_heroListIcon;

    UIButton *_listButton;
    UIButton *_playButton;
    UIButton *_infoButton;
    KLPillView *_playFill;
    KLIconView *_playIcon;
    UILabel *_playLabel;
    UIButton *_leftArrow;
    UIButton *_rightArrow;

    /** Размер, под который всё разложено сейчас. */
    CGSize _laidOut;

    /** Спрятан ли ряд «Продолжить» — нужно помнить при перекладке. */
    BOOL _continueHidden;

    NSArray *_heroList;
    NSInteger _heroIndex;

    KLRowView *_continueRow;
    KLRowView *_trendingRow;
    KLRowView *_popularRow;
    KLRowView *_moviesRow;
    KLRowView *_seriesRow;

    KLGeneration *_generation;
    BOOL _loaded;
    BOOL _loading;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _generation = [[KLGeneration alloc] init];
    _heroIndex = 0;

    [self setBackgroundColor:[KLTheme pageBackground]];

    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    [_scroll setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight];
    [_scroll setBackgroundColor:[KLTheme pageBackground]];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [_scroll setDelegate:self];
    [self addSubview:_scroll];

    [self buildHero];
    [self buildRows];

    /**
      * Слабая ссылка на себя — и это не перестраховка.
      *
      * Блок живёт в виде обновления, тот лежит в прокрутке, а прокрутка —
      * в нас. Захвати блок себя обычным образом, вышло бы кольцо, из
      * которого ARC не выберется: вкладка не освободится никогда.
      */
    __weak KLHomeView *weakSelf = self;

    _refresh = [KLRefreshHeader attachedTo:_scroll action:^{
        [KLHttp dropMemoryCache];
        [weakSelf reload];
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(libraryChanged)
                                                 name:KLLibraryChangedNotification
                                               object:nil];

    [self reload];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_scroll setDelegate:nil];
}

#pragma mark - Баннер

/**
 * Заводит баннер. Рамок здесь нет ни одной — их ставит layoutContents.
 *
 * Разделение это не украшательство. Раньше все рамки считались тут же,
 * по bounds на момент создания, и другой ширины вид уже не знал: на планшете
 * при повороте с 768 на 1024 баннер, ряды и карточки так и оставались
 * шириной 768, а справа висела чёрная полоса в четверть экрана.
 */
- (void)buildHero {
    _hero = [[UIView alloc] initWithFrame:CGRectZero];
    [_hero setBackgroundColor:KLColor(0x0C0C14)];
    [_scroll addSubview:_hero];

    _heroImage = [[KLPosterView alloc] initWithFrame:CGRectZero];
    [_heroImage setPlaceholderColor:KLColor(0x0C0C14)];
    // В макете у картинки opacity .85 поверх чёрного — то же самое, только
    // считается один раз при отрисовке, а не смешиванием слоёв.
    [_heroImage setDimming:0.15];
    [_hero addSubview:_heroImage];

    // Тень сверху — под строку состояния и словесный знак.
    _topFade = [[KLGradientView alloc] initWithFrame:CGRectZero downwards:NO];
    [_topFade setAlpha:0.55];
    [_hero addSubview:_topFade];

    // Тень снизу: без неё белое название тонет в светлом кадре.
    _bottomFade = [[KLGradientView alloc] initWithFrame:CGRectZero downwards:YES];
    [_hero addSubview:_bottomFade];

    [self buildTopBar];
    [self buildHeroText];
    [self buildHeroButtons];
    [self buildHeroArrows];
}

- (void)buildTopBar {
    _wordmark = KLLabel([UIFont boldSystemFontOfSize:18], [KLTheme ink], 1);

    // Разрядка вручную: атрибутный текст в UILabel — это iOS 6, а знак
    // с плотно сдвинутыми буквами выглядит не словесным знаком, а словом.
    [_wordmark setText:KLStr(@"brand.wordmark")];
    [_hero addSubview:_wordmark];

    _searchButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_searchButton addTarget:self
                      action:@selector(openSearch)
            forControlEvents:UIControlEventTouchUpInside];

    KLIconView *icon = [KLIconView iconOf:KLIconSearch tint:[KLTheme ink] side:21];
    [icon setCenter:CGPointMake(18, 18)];
    [_searchButton addSubview:icon];

    [_hero addSubview:_searchButton];
}

- (void)buildHeroText {
    _heroTitle = KLLabel(KLFontHeroTitle(), [KLTheme ink], 2);
    [_heroTitle setTextAlignment:NSTextAlignmentCenter];
    [_hero addSubview:_heroTitle];

    _heroMeta = KLLabel([UIFont boldSystemFontOfSize:13], [KLTheme cardInk], 1);
    [_heroMeta setTextAlignment:NSTextAlignmentCenter];
    [_hero addSubview:_heroMeta];
}

/**
 * Кнопка «значок и подпись под ним» — их на баннере две.
 *
 * У обоих «наружу» параметров указатель помечен __strong, и это обязательно.
 * По умолчанию ARC считает такой параметр __autoreleasing и на каждый вызов
 * заводит временную переменную, которую после возврата переписывает обратно.
 * Для локальной переменной это работает, а для поля объекта — нет, и
 * компилятор отказывается прямым текстом:
 *
 *     passing address of non-local object to __autoreleasing parameter
 *     for write-back
 *
 * Нам же нужно записать ровно в поля (_heroListIcon и _heroListText — их
 * потом перекрашивает updateHeroListButton). С явным __strong никакой
 * обратной записи не требуется: значение кладётся по адресу напрямую.
 */
- (UIButton *)heroIconButton:(KLIconKind)kind
                       title:(NSString *)title
                      action:(SEL)action
                     iconOut:(KLIconView * __strong *)iconOut
                    labelOut:(UILabel * __strong *)labelOut {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];

    // Внутренняя раскладка кнопки от ширины экрана не зависит: значок
    // и подпись стоят в своих 66×52. Наружу её двигает layoutContents.
    [button setFrame:CGRectMake(0, 0, 66, 52)];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    KLIconView *icon = [KLIconView iconOf:kind tint:[KLTheme ink] side:24];
    [icon setCenter:CGPointMake(33, 13)];
    [button addSubview:icon];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme ink], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:title];
    [label setFrame:CGRectMake(0, 32, 66, 16)];
    [button addSubview:label];

    if (iconOut != NULL) *iconOut = icon;
    if (labelOut != NULL) *labelOut = label;

    return button;
}

/** Ширина белой кнопки — по её подписи, а не числом. */
- (CGFloat)playButtonWidth {
    CGFloat text = ceilf([[_playLabel text] sizeWithFont:[_playLabel font]].width);

    // 16 отступ, 14 треугольник, 8 зазор, текст, 16 отступ.
    return 16 + 14 + 8 + text + 16;
}

- (void)buildHeroButtons {
    _listButton = [self heroIconButton:KLIconPlus
                                 title:KLStr(@"status.none")
                                action:@selector(heroList)
                               iconOut:&_heroListIcon
                              labelOut:&_heroListText];

    _infoButton = [self heroIconButton:KLIconInfo
                                 title:KLStr(@"home.info")
                                action:@selector(heroInfo)
                               iconOut:NULL
                              labelOut:NULL];

    // Белая «таблетка» с чёрной подписью — главная кнопка макета.
    //
    // Ширина у неё была задана числом (116), и подпись в неё не влезала:
    // на устройстве вместо «Смотреть» стояло «Смот…». Теперь ширина
    // считается от самой подписи — см. playButtonWidth.
    _playButton = [UIButton buttonWithType:UIButtonTypeCustom];

    _playFill = [[KLPillView alloc] initWithFrame:CGRectZero];
    [_playFill setFillColor:[KLTheme ink]];
    [_playFill setCornerRadius:9];
    [_playFill setUserInteractionEnabled:NO];
    [_playButton addSubview:_playFill];

    _playIcon = [KLIconView iconOf:KLIconPlay tint:[KLTheme pageBackground] side:14];
    [_playButton addSubview:_playIcon];

    _playLabel = KLLabel([UIFont boldSystemFontOfSize:15], [KLTheme pageBackground], 1);
    [_playLabel setText:KLStr(@"home.play")];
    [_playButton addSubview:_playLabel];

    [_playButton addTarget:self
                    action:@selector(heroPlay)
          forControlEvents:UIControlEventTouchUpInside];

    [_hero addSubview:_listButton];
    [_hero addSubview:_playButton];
    [_hero addSubview:_infoButton];
}

- (void)buildHeroArrows {
    NSArray *kinds = [NSArray arrayWithObjects:
        [NSNumber numberWithInt:KLIconChevronLeft],
        [NSNumber numberWithInt:KLIconChevronRight], nil];

    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *arrow = [UIButton buttonWithType:UIButtonTypeCustom];

        [arrow setFrame:CGRectMake(0, 0, 38, 38)];
        [arrow setTag:i];
        [arrow addTarget:self
                  action:@selector(heroArrow:)
        forControlEvents:UIControlEventTouchUpInside];

        KLPillView *circle = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
        [circle setFillColor:KLColor(0x66000000)];
        [circle setCornerRadius:19];
        [circle setUserInteractionEnabled:NO];
        [arrow addSubview:circle];

        KLIconView *icon = [KLIconView iconOf:[[kinds objectAtIndex:i] intValue]
                                         tint:[KLTheme ink]
                                         side:18];
        [icon setCenter:CGPointMake(19, 19)];
        [arrow addSubview:icon];

        [_hero addSubview:arrow];

        if (i == 0) {
            _leftArrow = arrow;
        } else {
            _rightArrow = arrow;
        }
    }
}

#pragma mark - Раскладка

/**
 * Ставит все рамки по нынешнему размеру вида.
 *
 * Зовётся из layoutSubviews при каждой смене размера — то есть при повороте
 * планшета и при первом появлении. Всё, что здесь считается, раньше
 * считалось однажды в init, и оттого приложение на iPad лёжа занимало
 * 768 точек из 1024.
 */
- (void)layoutContents {
    CGSize size = self.bounds.size;

    _laidOut = size;

    CGFloat width = size.width;
    CGFloat inner = width - KLSidePadding * 2;
    CGFloat heroHeight = KLHeroHeight(size.height);

    [_scroll setFrame:self.bounds];

    [_hero setFrame:CGRectMake(0, 0, width, heroHeight)];
    [_heroImage setFrame:CGRectMake(0, 0, width, heroHeight)];
    [_topFade setFrame:CGRectMake(0, 0, width, 120)];
    [_bottomFade setFrame:CGRectMake(0, heroHeight - 260, width, 260)];

    CGFloat top = KLStatusBarHeight() + 10;

    [_wordmark setFrame:CGRectMake(KLSidePadding, top, 160, 26)];
    [_searchButton setFrame:CGRectMake(width - KLSidePadding - 36, top - 5, 36, 36)];

    // Снизу вверх: кнопки прижаты к низу баннера, над ними подпись,
    // над ней название. Так блок остаётся внизу при любой высоте баннера.
    CGFloat bottom = heroHeight - 20;
    CGFloat rowTop = bottom - 52;

    [_heroTitle setFrame:CGRectMake(KLSidePadding, bottom - 58 - 22 - 6 - 62, inner, 62)];
    [_heroMeta setFrame:CGRectMake(KLSidePadding, bottom - 58 - 22, inner, 18)];

    CGFloat playWidth = [self playButtonWidth];
    CGFloat playHeight = 42;

    [_playFill setFrame:CGRectMake(0, 0, playWidth, playHeight)];
    [_playIcon setCenter:CGPointMake(16 + 7, playHeight / 2)];
    [_playLabel setFrame:CGRectMake(16 + 14 + 8, 0, playWidth - (16 + 14 + 8) - 16, playHeight)];

    // От центра: белая кнопка посередине, две значковые по бокам.
    CGFloat gap = 18;
    CGFloat total = 66 + gap + playWidth + gap + 66;
    CGFloat x = floorf((width - total) / 2);

    [_listButton setFrame:CGRectMake(x, rowTop, 66, 52)];
    [_playButton setFrame:CGRectMake(x + 66 + gap, rowTop + (52 - playHeight) / 2,
                                     playWidth, playHeight)];
    [_infoButton setFrame:CGRectMake(x + 66 + gap + playWidth + gap, rowTop, 66, 52)];

    CGFloat middle = heroHeight / 2 - 19;

    [_leftArrow setFrame:CGRectMake(10, middle, 38, 38)];
    [_rightArrow setFrame:CGRectMake(width - 48, middle, 38, 38)];

    [self layoutRowsHidingContinue:_continueHidden];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (!CGSizeEqualToSize(self.bounds.size, _laidOut)) {
        [self layoutContents];
    }
}

#pragma mark - Ряды

- (void)buildRows {
    CGFloat width = self.bounds.size.width;
    CGFloat y = KLHeroHeight(self.bounds.size.height);

    NSArray *titles = [NSArray arrayWithObjects:
        KLStr(@"files.continue"), KLStr(@"home.trending"), KLStr(@"home.popular"),
        KLStr(@"home.movies"), KLStr(@"home.series"), nil];

    NSMutableArray *rows = [NSMutableArray array];

    for (NSString *title in titles) {
        KLRowView *row = [[KLRowView alloc] initWithTitle:title
                                                    width:width
                                                cardWidth:KLCardWidth];

        CGRect frame = [row frame];
        frame.origin.y = y;
        [row setFrame:frame];

        y += frame.size.height;

        [_scroll addSubview:row];
        [rows addObject:row];
    }

    _continueRow = [rows objectAtIndex:0];
    _trendingRow = [rows objectAtIndex:1];
    _popularRow = [rows objectAtIndex:2];
    _moviesRow = [rows objectAtIndex:3];
    _seriesRow = [rows objectAtIndex:4];

    // Та же слабая ссылка, что и у обновления: блок лежит в ряду, ряд —
    // в прокрутке, прокрутка — в нас.
    __weak KLHomeView *weakSelf = self;

    for (KLRowView *row in rows) {
        // Ряд каталога отдаёт KLAnime, ряд «Продолжить» — KLLibraryEntry.
        // Открывает их одно и то же место, поэтому различаем по типу.
        [row setOnPick:^(id item) { [weakSelf openItem:item]; }];
    }

    // Ряды ниже баннера растут вниз; сколько всего — знаем только здесь.
    [_scroll setContentSize:CGSizeMake(width, y + KLDockHeight + 16)];
}

/** Убирает ряд «Продолжить», когда смотреть ещё нечего, и сдвигает остальные. */
- (void)layoutRowsHidingContinue:(BOOL)hideContinue {
    _continueHidden = hideContinue;

    CGFloat width = self.bounds.size.width;
    CGFloat y = KLHeroHeight(self.bounds.size.height);

    NSArray *rows = [NSArray arrayWithObjects:
        _continueRow, _trendingRow, _popularRow, _moviesRow, _seriesRow, nil];

    for (KLRowView *row in rows) {
        BOOL hidden = (row == _continueRow) && hideContinue;

        [row setHidden:hidden];

        if (hidden) {
            continue;
        }

        // Ширину задаём тоже здесь: сам ряд переставит по ней своё
        // содержимое, увидев в layoutSubviews, что она изменилась.
        CGRect frame = [row frame];
        frame.origin.y = y;
        frame.size.width = width;
        [row setFrame:frame];

        y += frame.size.height;
    }

    [_scroll setContentSize:CGSizeMake(width, y + KLDockHeight + 16)];
}

#pragma mark - Загрузка

- (void)reload {
    NSInteger generation = [_generation next];

    _loading = YES;

    [_trendingRow showBusy];
    [_popularRow showBusy];
    [_moviesRow showBusy];
    [_seriesRow showBusy];

    [self reloadContinue];

    /**
     * Ленты идут по очереди, а не разом.
     *
     * Четыре запроса подряд с одного адреса AniList встречает отказом 429
     * на всё, что после первого-второго, — и экран остаётся наполовину
     * пустым. Пауза между ними дешевле повторов: ждать приходится раз,
     * а не по разу на каждую отвергнутую ленту.
     *
     * Первая при этом уходит без задержки: до появления баннера экран
     * всё равно пустой, и тянуть с ним нечего.
     */
    [self load:@"trending" into:_trendingRow generation:generation delay:0 hero:YES];
    [self load:@"popular" into:_popularRow generation:generation delay:0.8 hero:NO];
    [self load:@"movies" into:_moviesRow generation:generation delay:1.7 hero:NO];
    [self load:@"series" into:_seriesRow generation:generation delay:2.6 hero:NO];
}

- (void)load:(NSString *)kind
        into:(KLRowView *)row
  generation:(NSInteger)generation
       delay:(NSTimeInterval)delay
        hero:(BOOL)feedsHero {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![_generation isCurrent:generation]) {
            return;
        }

        KLAsync(^{
            NSArray *list = [KLApi catalog:kind];

            KLMain(^{
                if (![_generation isCurrent:generation]) {
                    return;
                }

                if ([list count] == 0) {
                    [row showMessage:KLStr(@"row.failed")];
                } else {
                    [row setAnimeList:list];
                }

                if (feedsHero && [list count] > 0) {
                    _heroList = list;
                    _heroIndex = 0;
                    [self showHero:[list objectAtIndex:0]];
                }

                // Обновление считаем законченным по первой доехавшей ленте:
                // держать индикатор ещё две секунды ради остальных незачем —
                // они и так наполняются на глазах.
                if (feedsHero) {
                    [_refresh finish];

                    _loading = NO;
                    _loaded = [list count] > 0;
                }
            });
        });
    });
}

- (void)reloadContinue {
    NSArray *entries = [KLLibrary list:@"continue"];

    if ([entries count] == 0) {
        [self layoutRowsHidingContinue:YES];
        return;
    }

    if ([entries count] > 12) {
        entries = [entries subarrayWithRange:NSMakeRange(0, 12)];
    }

    [_continueRow setEntries:entries showsProgress:YES];
    [self layoutRowsHidingContinue:NO];
}

- (void)libraryChanged {
    KLMain(^{ [self reloadContinue]; });
}

- (void)didBecomeVisible {
    [self reloadContinue];
    [self updateHeroListButton];

    /**
     * Пустой экран после отказа сети: вернувшись на вкладку, пробуем снова.
     *
     * Проверка на «уже грузим» здесь обязательна, и вот почему. Вкладка
     * заводится и сразу зовёт reload, а корневой экран тут же выбирает её
     * первой и говорит didBecomeVisible — то есть в первые же миллисекунды
     * жизни экран успевал заказать четыре ленты, отменить их сменой
     * поколения и заказать те же четыре заново. Ответов это не портило,
     * а вот счётчик запросов AniList — вполне: восемь обращений подряд
     * с одного адреса это ровно тот случай, на который он отвечает 429.
     */
    if (!_loaded && !_loading) {
        [self reload];
    }
}

#pragma mark - Баннер: состояние

- (void)showHero:(KLAnime *)anime {
    if (anime == nil) {
        return;
    }

    [_heroTitle setText:anime.title];

    NSString *genres = [anime genresText];
    NSString *year = anime.year > 0
        ? [NSString stringWithFormat:@"%ld", (long)anime.year] : nil;

    NSMutableArray *parts = [NSMutableArray array];
    if ([genres length] > 0) [parts addObject:genres];
    if (year != nil) [parts addObject:year];

    [_heroMeta setText:[parts count] > 0
        ? [parts componentsJoinedByString:@"  ·  "]
        : KLStr(@"home.hero.fallback")];

    // Баннера у части тайтлов нет вовсе — тогда ставим обложку: растянутая
    // обложка выглядит лучше, чем пустая тёмная плита.
    [_heroImage loadUrl:(anime.bannerUrl ?: anime.coverUrl)
             targetSize:CGSizeMake(self.bounds.size.width,
                                   KLHeroHeight(self.bounds.size.height))];

    [self updateHeroListButton];
}

- (KLAnime *)currentHero {
    if (_heroIndex < 0 || _heroIndex >= (NSInteger)[_heroList count]) {
        return nil;
    }

    return [_heroList objectAtIndex:_heroIndex];
}

- (void)updateHeroListButton {
    KLAnime *anime = [self currentHero];
    if (anime == nil) {
        return;
    }

    NSString *status = [KLLibrary statusFor:anime.anilistId];
    BOOL none = [status isEqualToString:KLStatusNone];

    [_heroListText setText:none ? KLStr(@"status.none") : [KLLibrary titleForStatus:status]];
    [_heroListIcon setKind:none ? KLIconPlus : KLIconCheck];
}

- (void)heroArrow:(UIButton *)button {
    if ([_heroList count] == 0) {
        return;
    }

    _heroIndex = ([button tag] == 0)
        ? (_heroIndex - 1 + (NSInteger)[_heroList count]) % (NSInteger)[_heroList count]
        : (_heroIndex + 1) % (NSInteger)[_heroList count];

    // Короткое проявление вместо подмены рывком: картинка всё равно
    // приедет не сразу, и без него смена выглядит как сбой отрисовки.
    [UIView animateWithDuration:0.15 animations:^{
        [_hero setAlpha:0.4];
    } completion:^(BOOL finished) {
        [self showHero:[self currentHero]];

        [UIView animateWithDuration:0.2 animations:^{
            [_hero setAlpha:1];
        }];
    }];
}

- (void)heroPlay {
    [self openDetail:[self currentHero] autoplay:YES];
}

- (void)heroInfo {
    [self openDetail:[self currentHero] autoplay:NO];
}

- (void)heroList {
    KLAnime *anime = [self currentHero];
    if (anime == nil) {
        return;
    }

    [KLStatusSheet presentFor:anime completion:^{
        [self updateHeroListButton];
    }];
}

#pragma mark - Переходы

- (void)openSearch {
    // Поиск — соседняя вкладка, а не отдельный экран: значок на баннере
    // просто переключает её.
    UIResponder *responder = self;

    while (responder != nil) {
        if ([responder isKindOfClass:[KLShellViewController class]]) {
            [(KLShellViewController *)responder selectTab:1];
            return;
        }

        responder = [responder nextResponder];
    }
}

- (void)openItem:(id)item {
    if ([item isKindOfClass:[KLAnime class]]) {
        [self openDetail:item autoplay:NO];
        return;
    }

    if ([item isKindOfClass:[KLLibraryEntry class]]) {
        KLLibraryEntry *entry = item;

        // У записи «Моего» нет ничего, кроме названия и обложки: карточка
        // дотянет остальное сама, зная идентификатор.
        [KLNav push:[[KLDetailViewController alloc] initWithAnilistId:entry.anilistId
                                                               title:entry.title
                                                              poster:entry.poster]];
    }
}

- (void)openDetail:(KLAnime *)anime autoplay:(BOOL)autoplay {
    if (anime == nil) {
        return;
    }

    KLDetailViewController *detail =
        [[KLDetailViewController alloc] initWithAnime:anime];

    [detail setAutoplay:autoplay];

    [KLNav push:detail];
}

#pragma mark - Прокрутка

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [_refresh followScroll];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    [_refresh releaseScroll];
}

@end
