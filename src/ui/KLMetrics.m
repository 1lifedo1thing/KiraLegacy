#import "KLMetrics.h"

#import <QuartzCore/QuartzCore.h>

#import "KLTheme.h"

UIFont *KLFontSection(void) { return [UIFont boldSystemFontOfSize:17]; }
UIFont *KLFontScreenTitle(void) { return [UIFont boldSystemFontOfSize:26]; }
UIFont *KLFontHeroTitle(void) { return [UIFont boldSystemFontOfSize:24]; }
UIFont *KLFontDetailTitle(void) { return [UIFont boldSystemFontOfSize:22]; }
UIFont *KLFontCardTitle(void) { return [UIFont systemFontOfSize:12]; }
UIFont *KLFontEpisodeTitle(void) { return [UIFont boldSystemFontOfSize:14]; }
UIFont *KLFontBody(void) { return [UIFont systemFontOfSize:13]; }
UIFont *KLFontMeta(void) { return [UIFont systemFontOfSize:12]; }
UIFont *KLFontBadge(void) { return [UIFont boldSystemFontOfSize:10]; }
UIFont *KLFontTab(void) { return [UIFont boldSystemFontOfSize:10]; }

const CGFloat KLCardWidth = 110;
const CGFloat KLCardHeight = 156;
const CGFloat KLGap = 11;
const CGFloat KLSidePadding = 16;
const CGFloat KLDockHeight = 70;

NSString *KLClampText(NSString *text, NSUInteger limit) {
    if ([text length] <= limit) {
        return text;
    }

    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

CGFloat KLTextHeight(NSString *text, UIFont *font, CGFloat width, NSInteger maxLines) {
    if ([text length] == 0 || width <= 0) {
        return 0;
    }

    // Последний рубеж на случай, если в замер попадёт полотно в десятки тысяч
    // знаков: без ограничения по строкам такой замер занимает секунды.
    if (maxLines <= 0) {
        text = KLClampText(text, 8000);
    }

    CGFloat line = [font lineHeight];

    /**
     * Потолок с запасом в точку, и это не суеверие.
     *
     * sizeWithFont: укладывает строки по своей метрике, и высота двух строк
     * нет-нет да и окажется на доли точки больше, чем lineHeight × 2.
     * Потолок ровно в lineHeight × maxLines тогда пропускает на строку
     * меньше задуманного — замер отвечает высотой одной строки, подпись
     * получает рамку в одну строку и обрезается многоточием, хотя
     * numberOfLines у неё две.
     */
    CGFloat ceiling = maxLines > 0 ? line * maxLines + 1 : CGFLOAT_MAX;

    /**
     * Мерим переносом по словам, а не усечением: усечение нужно самой
     * подписи, чтобы поставить многоточие в последней строке, а здесь оно
     * только мешает посчитать, сколько строк выйдет.
     */
    CGSize size = [text sizeWithFont:font
                   constrainedToSize:CGSizeMake(width, ceiling)
                       lineBreakMode:NSLineBreakByWordWrapping];

    CGFloat height = ceilf(size.height);

    // Запас был нужен замеру, наружу он уходить не должен.
    if (maxLines > 0) {
        height = MIN(height, ceilf(line * maxLines));
    }

    return height;
}

UILabel *KLLabel(UIFont *font, UIColor *color, NSInteger lines) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];

    [label setFont:font];
    [label setTextColor:color];
    [label setNumberOfLines:lines];
    [label setBackgroundColor:[UIColor clearColor]];
    [label setLineBreakMode:NSLineBreakByTruncatingTail];

    return label;
}

void KLDrawStar(CGContextRef context, CGRect rect, UIColor *color) {
    CGFloat cx = CGRectGetMidX(rect);
    CGFloat cy = CGRectGetMidY(rect);
    CGFloat outer = MIN(rect.size.width, rect.size.height) / 2;
    CGFloat inner = outer * 0.42;

    CGContextBeginPath(context);

    // Десять вершин по кругу, через одну — внутренние. Начинаем с верхнего
    // луча, оттого и сдвиг на четверть оборота.
    for (NSInteger i = 0; i < 10; i++) {
        CGFloat radius = (i % 2 == 0) ? outer : inner;
        CGFloat angle = (CGFloat)(M_PI * i / 5.0 - M_PI_2);

        CGFloat x = cx + radius * cosf(angle);
        CGFloat y = cy + radius * sinf(angle);

        if (i == 0) {
            CGContextMoveToPoint(context, x, y);
        } else {
            CGContextAddLineToPoint(context, x, y);
        }
    }

    CGContextClosePath(context);
    CGContextSetFillColorWithColor(context, [color CGColor]);
    CGContextFillPath(context);
}


@implementation KLPillView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _cornerRadius = 6;
    _fillColor = [KLTheme surface];

    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];
    [self setContentMode:UIViewContentModeRedraw];

    /**
     * Касания сквозь себя пропускаем, и это не мелочь, а причина мёртвых
     * кнопок.
     *
     * Почти везде «таблетка» — заливка под кнопкой: её кладут внутрь UIButton
     * первым слоем, чтобы нарисовать скруглённый фон. Но обычный UIView
     * касания принимает, а UIControl начинает следить за нажатием только
     * тогда, когда касание пришло ему самому. Подложка накрывает кнопку
     * целиком, hitTest отдаёт её — и нажатие до кнопки не доходит вовсе.
     *
     * Снаружи это выглядит как кнопка, которая просто не работает. Поэтому
     * умолчание здесь «не трогать меня»: декоративных таблеток в приложении
     * два десятка, а тех, внутри которых и правда живут кнопки, — три,
     * и они включают приём касаний явно.
     */
    [self setUserInteractionEnabled:NO];

    return self;
}

- (void)setFillColor:(UIColor *)fillColor {
    _fillColor = fillColor;
    [self setNeedsDisplay];
}

- (void)setStrokeColor:(UIColor *)strokeColor {
    _strokeColor = strokeColor;
    [self setNeedsDisplay];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    // Обводка рисуется по центру линии, поэтому фигура ужимается на полтолщины:
    // иначе внешняя половина линии срезается краем вида.
    CGRect shape = _strokeColor != nil
        ? CGRectInset(self.bounds, 0.5, 0.5)
        : self.bounds;

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:shape
                                                   cornerRadius:_cornerRadius];

    if (_fillColor != nil) {
        [_fillColor setFill];
        [path fill];
    }

    if (_strokeColor != nil) {
        [_strokeColor setStroke];
        [path setLineWidth:1];
        [path stroke];
    }
}

@end


@implementation KLBadgeLabel

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _padding = UIEdgeInsetsMake(3, 6, 3, 6);

    [self setFont:KLFontBadge()];
    [self setTextColor:[KLTheme gold]];
    [self setTextAlignment:NSTextAlignmentCenter];
    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];

    return self;
}

/** Сколько места занимает звезда вместе с зазором до текста. */
- (CGFloat)starWidth {
    return _showsStar ? [[self font] pointSize] + 3 : 0;
}

- (CGSize)badgeSize {
    if ([[self text] length] == 0) {
        return CGSizeZero;
    }

    CGSize text = [[self text] sizeWithFont:[self font]];

    return CGSizeMake(ceilf(text.width) + [self starWidth] + _padding.left + _padding.right,
                      ceilf(text.height) + _padding.top + _padding.bottom);
}

- (void)drawRect:(CGRect)rect {
    if ([[self text] length] == 0) {
        return;
    }

    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                    cornerRadius:self.bounds.size.height / 2];
    [[KLTheme badge] setFill];
    [shape fill];

    CGFloat star = [self starWidth];

    if (star > 0) {
        CGFloat side = [[self font] pointSize];

        KLDrawStar(UIGraphicsGetCurrentContext(),
                   CGRectMake(_padding.left,
                              (self.bounds.size.height - side) / 2,
                              side, side),
                   [self textColor]);
    }

    // Текст рисуем сами, а не через super: у UILabel нет отступов, и
    // со звездой слева он встал бы поверх неё.
    CGRect text = CGRectMake(_padding.left + star,
                             _padding.top,
                             self.bounds.size.width - _padding.left - _padding.right - star,
                             self.bounds.size.height - _padding.top - _padding.bottom);

    [[self textColor] set];
    [[self text] drawInRect:text
                   withFont:[self font]
              lineBreakMode:NSLineBreakByClipping
                  alignment:NSTextAlignmentLeft];
}

- (void)setText:(NSString *)text {
    [super setText:text];

    // Плашка без текста не показывается вовсе.
    [self setHidden:[text length] == 0];
    [self setNeedsDisplay];
}

@end


@implementation KLGradientView

+ (Class)layerClass {
    return [CAGradientLayer class];
}

- (id)initWithFrame:(CGRect)frame downwards:(BOOL)downwards {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    [self setUserInteractionEnabled:NO];
    [self setBackgroundColor:[UIColor clearColor]];
    [self setDownwards:downwards];

    return self;
}

- (void)setDownwards:(BOOL)downwards {
    _downwards = downwards;

    id clear = (id)[[UIColor colorWithWhite:0 alpha:0] CGColor];
    id solid = (id)[[UIColor blackColor] CGColor];

    CAGradientLayer *layer = (CAGradientLayer *)[self layer];

    [layer setColors:[NSArray arrayWithObjects:
        downwards ? clear : solid,
        downwards ? solid : clear, nil]];
}

@end
