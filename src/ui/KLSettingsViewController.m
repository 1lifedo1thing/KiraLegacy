#import "KLSettingsViewController.h"

#import "KLHlsProxy.h"
#import "KLLog.h"
#import "KLMetrics.h"
#import "KLSettings.h"
#import "KLStrings.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Строка списка: подпись слева, галочка справа. */
@interface KLSettingsRow : UIControl
@property (nonatomic, copy) dispatch_block_t action;
@end

@implementation KLSettingsRow

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setAlpha:highlighted ? 0.6 : 1.0];
}

@end


@implementation KLSettingsViewController {
    UIScrollView *_scroll;
    UIView *_body;
    UILabel *_title;
    UIButton *_back;
    CGSize _laidOut;
}

- (void)loadView {
    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];
    [[self view] setBackgroundColor:[KLTheme pageBackground]];

    KLUseFullScreenLayout(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];

    KLIconView *arrow = [KLIconView iconOf:KLIconBack tint:[KLTheme ink] side:22];
    [arrow setCenter:CGPointMake(22, 22)];
    [_back addSubview:arrow];
    [[self view] addSubview:_back];

    _title = KLLabel([UIFont boldSystemFontOfSize:18], [KLTheme ink], 1);
    [[self view] addSubview:_title];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [[self view] addSubview:_scroll];

    _body = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_body];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    CGSize size = [[self view] bounds].size;

    if (CGSizeEqualToSize(size, _laidOut)) {
        return;
    }

    _laidOut = size;

    CGFloat top = KLStatusBarHeight();

    [_back setFrame:CGRectMake(6, top, 44, 44)];
    [_title setFrame:CGRectMake(56, top, size.width - 72, 44)];

    CGFloat contentTop = top + 44;

    [_scroll setFrame:CGRectMake(0, contentTop, size.width, size.height - contentTop)];

    [self rebuild];
}

- (void)goBack {
    [KLNav pop];
}

#pragma mark Сборка

- (CGFloat)addHeading:(NSString *)text at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme mutedInk], 1);
    [label setText:[text uppercaseString]];
    [label setFrame:CGRectMake(KLSidePadding, y + 22, width, 18)];
    [_body addSubview:label];

    return y + 22 + 18 + 8;
}

- (CGFloat)addNote:(NSString *)text at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;
    CGFloat height = KLTextHeight(text, KLFontMeta(), width, 0);

    UILabel *label = KLLabel(KLFontMeta(), [KLTheme faintInk], 0);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, y + 2, width, height)];
    [_body addSubview:label];

    return y + height + 12;
}

/** Строка выбора: подпись и галочка, если выбрано. */
- (CGFloat)addOption:(NSString *)text
             checked:(BOOL)checked
                  at:(CGFloat)y
              action:(dispatch_block_t)action {
    CGFloat width = [[self view] bounds].size.width;
    CGFloat height = 46;

    KLSettingsRow *row = [[KLSettingsRow alloc] initWithFrame:
        CGRectMake(0, y, width, height)];

    [row setAction:action];
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = KLLabel([UIFont systemFontOfSize:15],
                             checked ? [KLTheme ink] : [KLTheme cardInk], 1);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, 0, width - KLSidePadding * 2 - 34, height)];
    [row addSubview:label];

    if (checked) {
        KLIconView *check = [KLIconView iconOf:KLIconCheck tint:[KLTheme accent] side:20];
        [check setCenter:CGPointMake(width - KLSidePadding - 10, height / 2)];
        [row addSubview:check];
    }

    [_body addSubview:row];

    return y + height;
}

- (void)rowTapped:(KLSettingsRow *)row {
    dispatch_block_t action = [row action];

    if (action != nil) {
        action();
    }
}

- (void)rebuild {
    for (UIView *view in [NSArray arrayWithArray:[_body subviews]]) {
        [view removeFromSuperview];
    }

    [_title setText:KLStr(@"settings.title")];

    __weak KLSettingsViewController *weakSelf = self;

    CGFloat width = [[self view] bounds].size.width;
    CGFloat y = 0;

    // --- Язык ------------------------------------------------------------
    y = [self addHeading:KLStr(@"settings.language") at:y];

    NSString *chosen = [KLStrings language];

    y = [self addOption:KLFmt(@"settings.language.system",
                              [KLStrings nameForLanguage:[KLStrings effectiveLanguage]])
                checked:chosen == nil
                     at:y
                 action:^{ [KLStrings setLanguage:nil]; [weakSelf rebuild]; }];

    for (NSString *code in [KLStrings available]) {
        y = [self addOption:[KLStrings nameForLanguage:code]
                    checked:[chosen isEqualToString:code]
                         at:y
                     action:^{ [KLStrings setLanguage:code]; [weakSelf rebuild]; }];
    }

    // --- Источник ---------------------------------------------------------
    y = [self addHeading:KLStr(@"settings.source") at:y];
    y = [self addNote:KLStr(@"settings.source.note") at:y];

    NSString *source = [KLSettings preferredSource];

    y = [self addOption:KLStr(@"settings.source.ask")
                checked:[source length] == 0
                     at:y
                 action:^{ [KLSettings setPreferredSource:@""]; [weakSelf rebuild]; }];

    for (NSString *label in [KLSettings knownSources]) {
        y = [self addOption:label
                    checked:[source isEqualToString:label]
                         at:y
                     action:^{ [KLSettings setPreferredSource:label]; [weakSelf rebuild]; }];
    }

    // --- Качество ---------------------------------------------------------
    y = [self addHeading:KLStr(@"settings.quality") at:y];
    y = [self addNote:KLStr(@"settings.quality.note") at:y];

    NSInteger height = [KLSettings preferredHeight];

    for (NSNumber *step in [KLSettings knownHeights]) {
        NSInteger value = [step integerValue];

        NSString *text = value == 0
            ? KLStr(@"settings.quality.auto")
            : [NSString stringWithFormat:@"%ldp", (long)value];

        y = [self addOption:text
                    checked:height == value
                         at:y
                     action:^{ [KLSettings setPreferredHeight:value]; [weakSelf rebuild]; }];
    }

    // --- Воспроизведение --------------------------------------------------
    y = [self addHeading:KLStr(@"settings.playback") at:y];
    y = [self addNote:KLStr(@"settings.playback.note") at:y];

    BOOL direct = [KLHlsProxy directPlaybackEnabled];

    y = [self addOption:KLStr(@"settings.profile.install")
                checked:NO
                     at:y
                 action:^{ [weakSelf installProfile]; }];

    y = [self addOption:direct ? KLStr(@"settings.direct.on") : KLStr(@"settings.direct.off")
                checked:direct
                     at:y
                 action:^{
                     [KLHlsProxy setDirectPlaybackEnabled:![KLHlsProxy directPlaybackEnabled]];
                     [weakSelf rebuild];
                 }];

    // --- Журнал -----------------------------------------------------------
    y = [self addHeading:KLStr(@"settings.log") at:y];
    y = [self addNote:KLStr(@"settings.log.note") at:y];

    y = [self addOption:KLStr(@"settings.log.clear")
                checked:NO
                     at:y
                 action:^{
                     KLLogClear();
                     [KLToast show:KLStr(@"settings.log.cleared")];
                 }];

    y += 32;

    [_body setFrame:CGRectMake(0, 0, width, y)];
    [_scroll setContentSize:CGSizeMake(width, y)];
}

- (void)installProfile {
    NSURL *url = [[KLHlsProxy shared] certificateProfileUrl];

    if (url == nil) {
        [KLToast show:KLStr(@"settings.profile.failed")];
        return;
    }

    // Профиль отдаёт наш же сервер на петле, а ставит его система — для
    // этого его надо открыть снаружи приложения. Safari по типу
    // содержимого узнаёт профиль и передаёт его установщику.
    [[UIApplication sharedApplication] openURL:url];
}

#pragma mark Поворот

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
