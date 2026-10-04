#import "KLEditSourceViewController.h"

#import "KLCustomProvider.h"
#import "KLCustomSource.h"
#import "KLMetrics.h"
#import "KLSettings.h"
#import "KLStrings.h"
#import "KLTheme.h"
#import "KLUtil.h"

/**
 * Значения для проверки.
 *
 * Первый тайтл AniList — законный тайтл с законной первой серией, и это
 * важно: проверка обязана ходить по настоящему адресу. Ноль в качестве
 * образца означал бы, что половина чужих сервисов отвечает «не найдено»,
 * и проверить по ней нечего.
 */
static const NSInteger KLProbeAnilistId = 1;
static const NSInteger KLProbeMalId = 1;
static const NSInteger KLProbeEpisode = 1;

/** Строка списка: подпись слева, необязательная галочка справа. */
@interface KLEditRow : UIControl
@property (nonatomic, copy) dispatch_block_t action;
@end

@implementation KLEditRow

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setAlpha:highlighted ? 0.6 : 1.0];
}

@end


@interface KLEditSourceViewController () <UITextFieldDelegate>
@end


@implementation KLEditSourceViewController {
    UIScrollView *_scroll;
    UIView *_body;
    UILabel *_title;
    UILabel *_status;
    UIButton *_back;
    CGSize _laidOut;

    NSInteger _index;
    KLCustomKind _kind;
    BOOL _enabled;

    UITextField *_name;
    UITextField *_address;
    UITextField *_path;
    UITextField *_referer;
    UITextField *_offset;

    /** Итог последней проверки; живёт между перерисовками. */
    NSString *_report;
}

- (id)initWithIndex:(NSInteger)index {
    self = [super init];

    if (self != nil) {
        _index = index;
        _kind = KLCustomKindDirect;
        _enabled = YES;
    }

    return self;
}

/** Запись, которую правим; при добавлении — пустая. */
- (KLCustomSource *)entry {
    NSArray *list = [KLSettings customSources];

    if (_index >= 0 && _index < (NSInteger)[list count]) {
        return [list objectAtIndex:(NSUInteger)_index];
    }

    return nil;
}

- (void)loadView {
    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];
    [[self view] setBackgroundColor:[KLTheme pageBackground]];

    KLUseFullScreenLayout(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    KLCustomSource *entry = [self entry];

    if (entry != nil) {
        _kind = [entry kind];
        _enabled = [entry enabled];
    }

    _back = [UIButton buttonWithType:UIButtonTypeCustom];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];

    KLIconView *arrow = [KLIconView iconOf:KLIconBack tint:[KLTheme ink] side:22];
    [arrow setCenter:CGPointMake(22, 22)];
    [_back addSubview:arrow];
    [[self view] addSubview:_back];

    _title = KLLabel(KLFontScreenTitle(), [KLTheme ink], 1);
    [[self view] addSubview:_title];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [_scroll setShowsVerticalScrollIndicator:NO];
    [_scroll setAlwaysBounceVertical:YES];
    [[self view] addSubview:_scroll];

    _body = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_body];

    /**
     * Касание по пустому месту убирает клавиатуру.
     *
     * cancelsTouchesInView = NO — и это тут главное. С ним распознаватель
     * видит касание, но не отменяет его доставку тому виду, где оно
     * началось: поля ввода и строки продолжают работать. В плеере
     * приложения ровно на этом уже обожглись однажды.
     */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    [tap setCancelsTouchesInView:NO];
    [[self view] addGestureRecognizer:tap];
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

- (void)dismissKeyboard {
    [[self view] endEditing:YES];
}

#pragma mark - Сборка

- (CGFloat)addNote:(NSString *)text at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;
    CGFloat height = KLTextHeight(text, KLFontMeta(), width, 0);

    UILabel *label = KLLabel(KLFontMeta(), [KLTheme faintInk], 0);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, y + 2, width, height)];
    [_body addSubview:label];

    return y + height + 12;
}

- (CGFloat)addHeading:(NSString *)text at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:12], [KLTheme mutedInk], 1);
    [label setText:[text uppercaseString]];
    [label setFrame:CGRectMake(KLSidePadding, y + 18, width, 18)];
    [_body addSubview:label];

    return y + 18 + 18 + 6;
}

- (CGFloat)addField:(UITextField *)field at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;
    CGFloat height = 40;

    [field setFrame:CGRectMake(KLSidePadding, y, width, height)];
    [_body addSubview:field];

    return y + height + 10;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder
                                value:(NSString *)value
                          keyboard:(UIKeyboardType)keyboard {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];

    [field setPlaceholder:placeholder];
    [field setText:value];
    [field setFont:[UIFont systemFontOfSize:14]];
    [field setTextColor:[KLTheme ink]];
    [field setBackgroundColor:[KLTheme surface]];
    [field setKeyboardType:keyboard];
    [field setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [field setAutocorrectionType:UITextAutocorrectionTypeNo];
    [field setReturnKeyType:UIReturnKeyDone];
    [field setClearButtonMode:UITextFieldViewModeWhileEditing];
    [field setDelegate:self];

    // Своего отступа слева у UITextField нет, а вплотную к краю текст
    // в тёмной подложке читается как обрезанный.
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 40)];
    [field setLeftView:pad];
    [field setLeftViewMode:UITextFieldViewModeAlways];

    return field;
}

- (CGFloat)addOption:(NSString *)text
               color:(UIColor *)color
             checked:(BOOL)checked
                  at:(CGFloat)y
              action:(dispatch_block_t)action {
    CGFloat width = [[self view] bounds].size.width;
    CGFloat height = 46;

    KLEditRow *row = [[KLEditRow alloc] initWithFrame:CGRectMake(0, y, width, height)];

    [row setAction:action];
    [row addTarget:self action:@selector(rowTapped:)
        forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = KLLabel([UIFont systemFontOfSize:15], color, 1);
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

- (void)rowTapped:(KLEditRow *)row {
    dispatch_block_t action = [row action];

    if (action != nil) {
        action();
    }
}

- (void)rebuild {
    KLCustomSource *entry = [self entry];

    // Поля пересоздаются, поэтому недописанное забираем из старых, а не
    // теряем: перерисовка случается и при смене вида, и после проверки.
    NSString *name = _name != nil ? [_name text] : [entry name];
    NSString *address = _address != nil ? [_address text] : [entry address];
    NSString *path = _path != nil ? [_path text] : [entry fieldPath];
    NSString *referer = _referer != nil ? [_referer text] : [entry referer];
    NSString *offset = _offset != nil
        ? [_offset text]
        : (entry != nil ? [NSString stringWithFormat:@"%ld", (long)[entry episodeOffset]] : @""); 

    for (UIView *view in [NSArray arrayWithArray:[_body subviews]]) {
        [view removeFromSuperview];
    }

    _name = nil;
    _address = nil;
    _path = nil;
    _referer = nil;
    _offset = nil;

    [_title setText:entry != nil ? KLStr(@"custom.title") : KLStr(@"custom.new")];

    __weak KLEditSourceViewController *weakSelf = self;

    CGFloat width = [[self view] bounds].size.width;
    CGFloat y = 0;

    y = [self addHeading:KLStr(@"custom.name") at:y];
    _name = [self fieldWithPlaceholder:KLStr(@"custom.name.placeholder")
                                 value:name
                              keyboard:UIKeyboardTypeDefault];
    y = [self addField:_name at:y];

    y = [self addHeading:KLStr(@"custom.kind") at:y];

    y = [self addOption:KLStr(@"custom.kind.direct")
                  color:[KLTheme cardInk]
                checked:_kind == KLCustomKindDirect
                     at:y
                 action:^{ _kind = KLCustomKindDirect; [weakSelf rebuild]; }];

    y = [self addOption:KLStr(@"custom.kind.json")
                  color:[KLTheme cardInk]
                checked:_kind == KLCustomKindJson
                     at:y
                 action:^{ _kind = KLCustomKindJson; [weakSelf rebuild]; }];

    y = [self addHeading:KLStr(_kind == KLCustomKindJson ? @"custom.address.json"
                                                         : @"custom.address")
                      at:y];
    _address = [self fieldWithPlaceholder:KLStr(@"custom.address.placeholder")
                                    value:address
                                 keyboard:UIKeyboardTypeURL];
    y = [self addField:_address at:y];

    if (_kind == KLCustomKindJson) {
        y = [self addNote:KLStr(@"custom.address.note") at:y];

        y = [self addHeading:KLStr(@"custom.path") at:y];
        _path = [self fieldWithPlaceholder:KLStr(@"custom.path.placeholder")
                                     value:path
                                  keyboard:UIKeyboardTypeDefault];
        y = [self addField:_path at:y];
        y = [self addNote:KLStr(@"custom.path.note") at:y];
    }

    y = [self addHeading:KLStr(@"custom.referer") at:y];
    _referer = [self fieldWithPlaceholder:KLStr(@"custom.referer.placeholder")
                                    value:referer
                                 keyboard:UIKeyboardTypeURL];
    y = [self addField:_referer at:y];

    y = [self addHeading:KLStr(@"custom.offset") at:y];
    _offset = [self fieldWithPlaceholder:@"0" value:offset keyboard:UIKeyboardTypeNumbersAndPunctuation];
    y = [self addField:_offset at:y];
    y = [self addNote:KLStr(@"custom.offset.note") at:y];

    y = [self addOption:_enabled ? KLStr(@"custom.enabled") : KLStr(@"custom.off")
                  color:[KLTheme cardInk]
                checked:_enabled
                     at:y
                 action:^{ _enabled = !_enabled; [weakSelf rebuild]; }];

    // --- Проверка ---------------------------------------------------------
    y = [self addHeading:KLStr(@"custom.test") at:y];
    y = [self addNote:KLFmt(@"custom.test.note", (long)KLProbeAnilistId,
                            (long)KLProbeEpisode) at:y];

    if ([_report length] > 0) {
        CGFloat noteWidth = width - KLSidePadding * 2;
        CGFloat height = KLTextHeight(_report, KLFontMeta(), noteWidth, 0);

        _status = KLLabel(KLFontMeta(), [KLTheme ink], 0);
        [_status setText:_report];
        [_status setFrame:CGRectMake(KLSidePadding, y, noteWidth, height)];
        [_body addSubview:_status];

        y += height + 12;
    }

    y = [self addOption:KLStr(@"custom.test")
                  color:[KLTheme accentInk]
                checked:NO
                     at:y
                 action:^{ [weakSelf runCheck]; }];

    // --- Сохранение -------------------------------------------------------

    y += 18;

    if (entry != nil) {
        y = [self addOption:KLStr(@"custom.delete")
                      color:[KLTheme danger]
                    checked:NO
                         at:y
                     action:^{ [weakSelf removeEntry]; }];
    }

    y = [self addOption:KLStr(@"custom.save")
                  color:[KLTheme accentInk]
                checked:NO
                     at:y
                 action:^{ [weakSelf saveEntry]; }];

    /**
     * Запас пустого места снизу.
     *
     * Клавиатура закрывает нижнюю треть экрана, и без запаса до строк
     * «Сохранить» не доскроллить: список заканчивается ровно там, где
     * начинается клавиатура. Отслеживать её появление ради этого не нужно —
     * пустое место внизу ничему не мешает.
     */
    y += 240;

    [_body setFrame:CGRectMake(0, 0, width, y)];
    [_scroll setContentSize:CGSizeMake(width, y)];
}

#pragma mark - Значения

- (NSString *)trimmed:(NSString *)text {
    return [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/** Источник из того, что сейчас в полях. Проверяется именно он. */
- (KLCustomSource *)currentEntry {
    KLCustomSource *built = [[KLCustomSource alloc] init];

    built.name = [self trimmed:[_name text]] ?: @"";
    built.kind = _kind;
    built.address = [self trimmed:[_address text]] ?: @"";
    built.fieldPath = [self trimmed:[_path text]] ?: @"";
    built.referer = [self trimmed:[_referer text]] ?: @"";
    built.episodeOffset = [[_offset text] integerValue];
    built.enabled = _enabled;

    return built;
}

/**
 * Имя, которого ещё нет в списке.
 *
 * Пустое имя не годится, а одинаковые — ломают выбор по умолчанию: он
 * хранится именем, и «мой источник» в двух экземплярах означает, что
 * выбрать между ними нечем.
 */
- (NSString *)uniqueName:(NSString *)name {
    NSMutableArray *taken = [NSMutableArray array];

    for (NSString *label in [KLSettings knownSources]) {
        [taken addObject:label];
    }

    NSArray *list = [KLSettings customSources];

    for (NSInteger i = 0; i < (NSInteger)[list count]; i++) {
        if (i != _index) {
            [taken addObject:[[list objectAtIndex:(NSUInteger)i] name] ?: @""];
        }
    }

    if (![taken containsObject:name]) {
        return name;
    }

    for (NSInteger suffix = 2; suffix < 100; suffix++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %ld", name, (long)suffix];

        if (![taken containsObject:candidate]) {
            return candidate;
        }
    }

    return name;
}

#pragma mark - Действия

- (void)runCheck {
    [[self view] endEditing:YES];

    KLCustomSource *current = [self currentEntry];

    if ([current.address length] == 0) {
        [KLToast show:KLStr(@"custom.needaddress")];
        return;
    }

    _report = KLStr(@"custom.testing");
    [self rebuild];

    __weak KLEditSourceViewController *weakSelf = self;

    KLAsync(^{
        NSString *text = [KLCustomProvider checkEntry:current
                                            anilistId:KLProbeAnilistId
                                                malId:KLProbeMalId
                                              episode:KLProbeEpisode
                                                 kind:@"sub"];

        KLMain(^{
            KLEditSourceViewController *strong = weakSelf;

            if (strong == nil) {
                return;
            }

            strong->_report = text;
            [strong rebuild];
        });
    });
}

- (void)saveEntry {
    [[self view] endEditing:YES];

    NSString *name = [self trimmed:[_name text]];
    NSString *address = [self trimmed:[_address text]];

    if ([name length] == 0) {
        [KLToast show:KLStr(@"custom.needname")];
        return;
    }

    if ([address length] == 0) {
        [KLToast show:KLStr(@"custom.needaddress")];
        return;
    }

    KLCustomSource *built = [self currentEntry];

    built.name = [self uniqueName:name];

    NSMutableArray *list = [NSMutableArray arrayWithArray:[KLSettings customSources]];

    if (_index >= 0 && _index < (NSInteger)[list count]) {
        [list replaceObjectAtIndex:(NSUInteger)_index withObject:built];
    } else {
        [list addObject:built];
    }

    [KLSettings setCustomSources:list];

    [KLToast show:KLStr(@"custom.saved")];

    dispatch_block_t finished = self.onFinished;

    if (finished != nil) {
        finished();
    }

    [KLNav pop];
}

- (void)removeEntry {
    NSMutableArray *list = [NSMutableArray arrayWithArray:[KLSettings customSources]];

    if (_index < 0 || _index >= (NSInteger)[list count]) {
        [KLNav pop];
        return;
    }

    [list removeObjectAtIndex:(NSUInteger)_index];
    [KLSettings setCustomSources:list];

    [KLToast show:KLStr(@"custom.saved")];

    dispatch_block_t finished = self.onFinished;

    if (finished != nil) {
        finished();
    }

    [KLNav pop];
}

#pragma mark - Клавиатура

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];

    return YES;
}

#pragma mark - Поворот

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
