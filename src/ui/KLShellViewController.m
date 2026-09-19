#import "KLShellViewController.h"

#import "KLStrings.h"

#import "KLFilesView.h"
#import "KLHomeView.h"
#import "KLMetrics.h"
#import "KLSearchView.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Одна кнопка панели: значок и подпись под ним. */
@interface KLDockButton : UIControl {
    KLIconView *_icon;
    UILabel *_label;
    KLPillView *_highlight;
}

- (id)initWithKind:(KLIconKind)kind title:(NSString *)title;
- (void)setChosen:(BOOL)chosen;

@end

@implementation KLDockButton

- (id)initWithKind:(KLIconKind)kind title:(NSString *)title {
    self = [super initWithFrame:CGRectMake(0, 0, 84, 54)];
    if (self == nil) {
        return nil;
    }

    _highlight = [[KLPillView alloc] initWithFrame:self.bounds];
    [_highlight setFillColor:KLColor(0x24242E)];
    [_highlight setCornerRadius:20];
    [_highlight setUserInteractionEnabled:NO];
    [_highlight setHidden:YES];
    [self addSubview:_highlight];

    _icon = [KLIconView iconOf:kind tint:[KLTheme faintInk] side:21];
    [_icon setCenter:CGPointMake(42, 20)];
    [self addSubview:_icon];

    _label = KLLabel(KLFontTab(), [KLTheme faintInk], 1);
    [_label setTextAlignment:NSTextAlignmentCenter];
    [_label setText:title];
    [_label setFrame:CGRectMake(0, 33, 84, 14)];
    [self addSubview:_label];

    return self;
}

- (void)setChosen:(BOOL)chosen {
    UIColor *tint = chosen ? [KLTheme ink] : [KLTheme faintInk];

    [_icon setTint:tint];
    [_label setTextColor:tint];
    [_highlight setHidden:!chosen];
}

@end


@implementation KLShellViewController {
    KLPillView *_dock;
    NSArray *_buttons;
    NSArray *_tabs;
    NSInteger _selected;
}

- (void)loadView {
    // Окно целиком: шапки вкладок сами отступают под строку состояния,
    // а иначе отступ вышел бы двойным. Подробности в KLUseFullScreenLayout.
    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];
    [[self view] setBackgroundColor:[KLTheme pageBackground]];

    KLUseFullScreenLayout(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    CGRect bounds = [[self view] bounds];

    KLHomeView *home = [[KLHomeView alloc] initWithFrame:bounds];
    KLSearchView *search = [[KLSearchView alloc] initWithFrame:bounds];
    KLFilesView *files = [[KLFilesView alloc] initWithFrame:bounds];

    _tabs = [NSArray arrayWithObjects:home, search, files, nil];

    for (UIView<KLTabContent> *tab in _tabs) {
        [tab setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight];
        [tab setHidden:YES];
        [[self view] addSubview:tab];
    }

    [self buildDock];
    [self selectTab:0];
}

#pragma mark Панель

- (void)buildDock {
    _dock = [[KLPillView alloc] initWithFrame:CGRectZero];

    // Не декорация: внутри лежат кнопки вкладок — см. KLPillView.
    [_dock setUserInteractionEnabled:YES];

    [_dock setFillColor:[KLTheme dock]];
    [_dock setStrokeColor:KLColor(0x2A2A34)];
    [_dock setCornerRadius:28];

    KLDockButton *home = [[KLDockButton alloc] initWithKind:KLIconHome title:KLStr(@"tab.home")];
    KLDockButton *search = [[KLDockButton alloc] initWithKind:KLIconSearch title:KLStr(@"tab.search")];
    KLDockButton *files = [[KLDockButton alloc] initWithKind:KLIconFolder title:KLStr(@"tab.files")];

    _buttons = [NSArray arrayWithObjects:home, search, files, nil];

    for (NSUInteger i = 0; i < [_buttons count]; i++) {
        KLDockButton *button = [_buttons objectAtIndex:i];

        [button setTag:i];
        [button addTarget:self
                   action:@selector(dockTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [_dock addSubview:button];
    }

    [[self view] addSubview:_dock];
}

- (void)dockTapped:(KLDockButton *)button {
    [self selectTab:[button tag]];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutDock];
}

/** iOS 5 не зовёт viewWillLayoutSubviews при повороте так же охотно. */
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutDock];
}

- (void)layoutDock {
    CGFloat padding = 8;
    CGFloat buttonWidth = 84;
    CGFloat buttonHeight = 54;

    CGFloat width = buttonWidth * [_buttons count] + padding * 2;
    CGFloat height = buttonHeight + padding * 2;

    CGRect bounds = [[self view] bounds];

    // Панель узкая, и на телефоне 320 точек три кнопки по 84 в неё уже
    // не помещаются вместе с отступами — тогда ужимаем кнопки, а не панель:
    // иначе она уехала бы за край.
    if (width > bounds.size.width - 24) {
        width = bounds.size.width - 24;
        buttonWidth = (width - padding * 2) / [_buttons count];
    }

    [_dock setFrame:CGRectMake((bounds.size.width - width) / 2,
                               bounds.size.height - height - 16,
                               width, height)];

    for (NSUInteger i = 0; i < [_buttons count]; i++) {
        [[_buttons objectAtIndex:i] setFrame:
            CGRectMake(padding + buttonWidth * i, padding, buttonWidth, buttonHeight)];
    }

    // Панель всегда поверх содержимого: вкладки добавляются в вид позже неё
    // только при первом заходе, но порядок надо держать и после поворота.
    [[self view] bringSubviewToFront:_dock];
}

#pragma mark Вкладки

- (void)selectTab:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)[_tabs count]) {
        return;
    }

    _selected = index;

    for (NSUInteger i = 0; i < [_tabs count]; i++) {
        BOOL chosen = (NSInteger)i == index;

        [(UIView *)[_tabs objectAtIndex:i] setHidden:!chosen];
        [[_buttons objectAtIndex:i] setChosen:chosen];
    }

    // Вкладка узнаёт, что её открыли: «Моё» на этом перечитывает списки,
    // поиск — ставит курсор в поле.
    [[_tabs objectAtIndex:index] didBecomeVisible];

    [[self view] bringSubviewToFront:_dock];
}

/**
 * Возврат на главный экран: списки «Моего» могли измениться, пока смотрели
 * карточку, а ряд «Продолжить» на главной — это те же самые записи.
 */
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [[_tabs objectAtIndex:_selected] didBecomeVisible];
}

/** Корневой экран живёт только стоя: лёжа его никто не рисовал. */
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

@end
