#import "KLEpisodeRow.h"

#import "KLEpisode.h"
#import "KLMetrics.h"
#import "KLPosterView.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Кадр серии — 108×62, как в макете: это 16:9 с округлением. */
static const CGFloat KLThumbWidth = 108;
static const CGFloat KLThumbHeight = 62;
static const CGFloat KLRowPadding = 12;

@implementation KLEpisodeRow {
    UILabel *_name;
}

- (id)initWithWidth:(CGFloat)width episode:(KLEpisode *)episode {
    CGFloat textLeft = KLSidePadding + KLThumbWidth + KLRowPadding;
    CGFloat textWidth = width - textLeft - KLSidePadding;

    NSString *name = [episode displayTitle];
    NSString *overview = episode.overview;

    CGFloat nameHeight = KLTextHeight(name, KLFontEpisodeTitle(), textWidth, 2);
    CGFloat overviewHeight = [overview length] > 0
        ? KLTextHeight(overview, KLFontMeta(), textWidth, 2) + 5
        : 0;

    // Строка не ниже кадра: иначе у серий без описания кадр вылезал бы
    // за линию раздела.
    CGFloat height = MAX(KLThumbHeight, nameHeight + overviewHeight) + KLRowPadding * 2;

    self = [super initWithFrame:CGRectMake(0, 0, width, height)];
    if (self == nil) {
        return nil;
    }

    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];

    KLPosterView *thumb = [[KLPosterView alloc] initWithFrame:
        CGRectMake(KLSidePadding, KLRowPadding, KLThumbWidth, KLThumbHeight)];

    [thumb setCornerRadius:8];
    [thumb setPlaceholderColor:[KLTheme surface]];
    [thumb loadUrl:episode.imageUrl targetSize:CGSizeMake(KLThumbWidth, KLThumbHeight)];
    [self addSubview:thumb];

    // Кружок с треугольником поверх кадра — он же подсказка, что по строке
    // можно нажать.
    UIView *play = [[UIView alloc] initWithFrame:
        CGRectMake(KLSidePadding + (KLThumbWidth - 26) / 2,
                   KLRowPadding + (KLThumbHeight - 26) / 2, 26, 26)];

    KLPillView *circle = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
    [circle setFillColor:[KLTheme badge]];
    [circle setCornerRadius:13];
    [play addSubview:circle];

    KLIconView *triangle = [KLIconView iconOf:KLIconPlay tint:[KLTheme ink] side:10];
    [triangle setCenter:CGPointMake(14, 13)];
    [play addSubview:triangle];

    [play setUserInteractionEnabled:NO];
    [self addSubview:play];

    _name = KLLabel(KLFontEpisodeTitle(), [KLTheme ink], 2);
    [_name setText:name];
    [_name setFrame:CGRectMake(textLeft, KLRowPadding, textWidth, nameHeight)];
    [self addSubview:_name];

    if (overviewHeight > 0) {
        UILabel *description = KLLabel(KLFontMeta(), [KLTheme faintInk], 2);
        [description setText:overview];
        [description setFrame:CGRectMake(textLeft, KLRowPadding + nameHeight + 5,
                                         textWidth, overviewHeight - 5)];
        [self addSubview:description];
    }

    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    return self;
}

- (void)setPlaying:(BOOL)playing {
    [_name setTextColor:playing ? [KLTheme accentPlaying] : [KLTheme ink]];
}

- (void)tapped {
    if (_action != nil) {
        _action();
    }
}

/** Линия раздела снизу — та же, что между строками в макете. */
- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();

    CGContextSetFillColorWithColor(context, [[KLTheme hairline] CGColor]);
    CGContextFillRect(context, CGRectMake(KLSidePadding, self.bounds.size.height - 1,
                                          self.bounds.size.width - KLSidePadding * 2, 1));
}

/** Короткое притухание на нажатие — своей подсветки у UIControl здесь нет. */
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setAlpha:highlighted ? 0.7 : 1.0];
}

@end
