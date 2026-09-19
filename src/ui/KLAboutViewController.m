#import "KLAboutViewController.h"

#import "KLCertificates.h"
#import "KLTls.h"
#import "KLMetrics.h"
#import "KLStrings.h"
#import "KLTheme.h"
#import "KLUtil.h"

/**
 * Экран нарочно короткий.
 *
 * Раньше здесь лежало пояснение на две тысячи слов — про корни, про прокси,
 * про то, почему на слабом железе рвётся картинка. Место у всего этого одно,
 * и оно не на экране в 320 точек шириной: README читают с монитора и целиком,
 * а сюда приходят за версией, ссылкой и именем автора.
 *
 * Заодно это сняло восемь десятков строк с перевода: длинные технические
 * абзацы пришлось бы переводить на шесть языков, и качество вышло бы
 * сомнительным ровно там, где важна точность.
 */

/** Строка-ссылка: открывается в Safari, поэтому и выглядит как ссылка. */
@interface KLAboutLink : UIControl
@property (nonatomic, copy) NSString *address;
@end

@implementation KLAboutLink

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setAlpha:highlighted ? 0.6 : 1.0];
}

@end


@implementation KLAboutViewController {
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

- (CGFloat)addText:(NSString *)text
              font:(UIFont *)font
             color:(UIColor *)color
                at:(CGFloat)y
               gap:(CGFloat)gap {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;
    CGFloat height = KLTextHeight(text, font, width, 0);

    UILabel *label = KLLabel(font, color, 0);
    [label setText:text];
    [label setFrame:CGRectMake(KLSidePadding, y, width, height)];
    [_body addSubview:label];

    return y + height + gap;
}

- (CGFloat)addLink:(NSString *)text url:(NSString *)address at:(CGFloat)y {
    CGFloat width = [[self view] bounds].size.width - KLSidePadding * 2;
    CGFloat height = 44;

    KLAboutLink *link = [[KLAboutLink alloc] initWithFrame:
        CGRectMake(KLSidePadding, y, width, height)];

    [link setAddress:address];
    [link addTarget:self action:@selector(linkTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = KLLabel([UIFont systemFontOfSize:15], [KLTheme accentInk], 1);
    [label setText:text];
    [label setFrame:CGRectMake(0, 0, width, height)];
    [link addSubview:label];

    [_body addSubview:link];

    return y + height;
}

- (void)linkTapped:(KLAboutLink *)link {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[link address]]];
}

- (void)rebuild {
    for (UIView *view in [NSArray arrayWithArray:[_body subviews]]) {
        [view removeFromSuperview];
    }

    [_title setText:KLStr(@"about.title")];

    NSString *version = [[[NSBundle mainBundle] infoDictionary]
        objectForKey:@"CFBundleShortVersionString"];

    CGFloat width = [[self view] bounds].size.width;
    CGFloat y = 12;

    y = [self addText:@"KiraLegacy"
                 font:[UIFont boldSystemFontOfSize:22]
                color:[KLTheme ink]
                   at:y
                  gap:2];

    y = [self addText:KLFmt(@"about.version", version ?: @"1.0")
                 font:[UIFont systemFontOfSize:15]
                color:[KLTheme mutedInk]
                   at:y
                  gap:16];

    y = [self addText:KLStr(@"about.tagline")
                 font:[UIFont systemFontOfSize:15]
                color:[KLTheme mutedInk]
                   at:y
                  gap:22];

    y = [self addText:KLStr(@"about.developer")
                 font:[UIFont systemFontOfSize:15]
                color:[KLTheme ink]
                   at:y
                  gap:8];

    y = [self addLink:KLStr(@"about.link.4pda")
                  url:@"https://4pda.to/forum/index.php?showuser=4458524"
                   at:y];

    y = [self addLink:KLStr(@"about.link.telegram")
                  url:@"https://t.me/cmplog"
                   at:y];

    y = [self addLink:KLStr(@"about.link.donate")
                  url:@"https://pay.cloudtips.ru/p/83821e32"
                   at:y];

    y += 18;

    // Какой библиотекой шифруемся — здесь же, рядом с корнями: это две
    // половины одного ответа на вопрос «кому приложение доверяет».
    y = [self addText:KLFmt(@"about.tls", [KLTls libraryVersion])
                 font:KLFontMeta()
                color:[KLTheme mutedInk]
                   at:y
                  gap:14];

    y = [self addText:KLStr(@"about.roots")
                 font:[UIFont boldSystemFontOfSize:15]
                color:[KLTheme ink]
                   at:y
                  gap:6];

    y = [self addText:KLStr(@"about.roots.note")
                 font:KLFontMeta()
                color:[KLTheme mutedInk]
                   at:y
                  gap:8];

    NSMutableString *list = [NSMutableString string];

    for (NSString *name in [KLCertificates fileNames]) {
        [list appendFormat:@"•  %@ — %@\n",
            [KLCertificates titleForName:name],
            KLStr([NSString stringWithFormat:@"cert.%@", name])];
    }

    y = [self addText:[list stringByTrimmingCharactersInSet:
                       [NSCharacterSet newlineCharacterSet]]
                 font:KLFontMeta()
                color:[KLTheme faintInk]
                   at:y
                  gap:24];

    y = [self addText:KLStr(@"about.trademarks")
                 font:KLFontMeta()
                color:[KLTheme faintInk]
                   at:y
                  gap:32];

    [_body setFrame:CGRectMake(0, 0, width, y)];
    [_scroll setContentSize:CGSizeMake(width, y)];
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
