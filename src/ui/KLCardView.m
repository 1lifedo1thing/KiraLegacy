#import "KLCardView.h"

#import "KLAnime.h"
#import "KLMetrics.h"
#import "KLPosterView.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Пропорция обложки: 110×156 из макета. */
static const CGFloat KLPosterRatio = 156.0 / 110.0;

/** Сколько места отведено подписи — ровно две строки плюс зазор. */
static const CGFloat KLTitleGap = 7;

@implementation KLCardView {
    KLPosterView *_poster;
    KLBadgeLabel *_score;
    KLPillView *_tag;
    UILabel *_tagLabel;
    UIView *_play;
    UILabel *_title;
    CGFloat _width;
}

+ (CGFloat)titleHeight {
    return ceilf([KLFontCardTitle() lineHeight] * 2);
}

+ (CGFloat)heightForWidth:(CGFloat)width {
    return ceilf(width * KLPosterRatio) + KLTitleGap + [self titleHeight];
}

- (id)initWithWidth:(CGFloat)width {
    CGFloat posterHeight = ceilf(width * KLPosterRatio);

    self = [super initWithFrame:CGRectMake(0, 0, width,
                                           [[self class] heightForWidth:width])];
    if (self == nil) {
        return nil;
    }

    _width = width;

    [self setBackgroundColor:[UIColor clearColor]];

    _poster = [[KLPosterView alloc] initWithFrame:CGRectMake(0, 0, width, posterHeight)];
    [_poster setCornerRadius:11];
    [self addSubview:_poster];

    _score = [[KLBadgeLabel alloc] initWithFrame:CGRectZero];
    [_score setShowsStar:YES];
    [self addSubview:_score];

    _title = KLLabel(KLFontCardTitle(), [KLTheme cardInk], 2);
    [_title setFrame:CGRectMake(0, posterHeight + KLTitleGap, width,
                                [[self class] titleHeight])];
    [self addSubview:_title];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [self addGestureRecognizer:tap];

    return self;
}

- (void)tapped {
    // Короткое притухание вместо подсветки: своей реакции на нажатие
    // у вида нет, а без неё карточка кажется неживой.
    [UIView animateWithDuration:0.08
        animations:^{ [self setAlpha:0.65]; }
        completion:^(BOOL finished) {
            [UIView animateWithDuration:0.12 animations:^{ [self setAlpha:1]; }];
        }];

    if (_action != nil) {
        _action();
    }
}

#pragma mark Содержимое

- (void)setAnime:(KLAnime *)anime {
    [self setTitle:anime.title poster:anime.coverUrl score:anime.score];
}

- (void)setTitle:(NSString *)title
          poster:(NSString *)poster
           score:(NSInteger)score {
    [_title setText:title ?: @""];
    [_poster loadUrl:poster targetSize:[_poster bounds].size];

    if (score > 0) {
        [_score setText:[NSString stringWithFormat:@"%.1f", score / 10.0]];

        CGSize size = [_score badgeSize];
        [_score setFrame:CGRectMake(_width - size.width - 6, 6, size.width, size.height)];
    } else {
        [_score setText:nil];
    }
}

- (void)setEpisodeTag:(NSString *)episodeTag {
    _episodeTag = [episodeTag copy];

    if ([episodeTag length] == 0) {
        [_tag setHidden:YES];
        return;
    }

    if (_tag == nil) {
        _tag = [[KLPillView alloc] initWithFrame:CGRectZero];
        [_tag setFillColor:[KLTheme badge]];
        [_tag setCornerRadius:5];
        [_tag setUserInteractionEnabled:NO];

        _tagLabel = KLLabel(KLFontBadge(), [KLTheme ink], 1);
        [_tagLabel setTextAlignment:NSTextAlignmentCenter];
        [_tag addSubview:_tagLabel];

        // Под плашкой оценки, чтобы при узкой карточке они не спорили за
        // порядок отрисовки.
        [self insertSubview:_tag belowSubview:_score];
    }

    [_tag setHidden:NO];
    [_tagLabel setText:episodeTag];

    CGSize text = [episodeTag sizeWithFont:KLFontBadge()];
    CGFloat width = ceilf(text.width) + 12;
    CGFloat height = ceilf(text.height) + 5;
    CGFloat posterHeight = ceilf(_width * KLPosterRatio);

    [_tag setFrame:CGRectMake(6, posterHeight - height - 6, width, height)];
    [_tagLabel setFrame:CGRectMake(0, 0, width, height)];
}

- (void)setShowsPlayOverlay:(BOOL)shows {
    _showsPlayOverlay = shows;

    if (!shows) {
        [_play setHidden:YES];
        return;
    }

    if (_play == nil) {
        CGFloat side = 34;
        CGFloat posterHeight = ceilf(_width * KLPosterRatio);

        _play = [[UIView alloc] initWithFrame:
            CGRectMake((_width - side) / 2, (posterHeight - side) / 2, side, side)];

        [_play setBackgroundColor:[UIColor clearColor]];
        [_play setUserInteractionEnabled:NO];

        // Кружок рисуем «таблеткой» с обводкой — ровно как в макете:
        // полупрозрачная чёрная заливка и белая линия в полтолщины.
        KLPillView *circle = [[KLPillView alloc] initWithFrame:_play.bounds];
        [circle setFillColor:[KLTheme badge]];
        [circle setStrokeColor:[UIColor colorWithWhite:1 alpha:0.5]];
        [circle setCornerRadius:side / 2];
        [_play addSubview:circle];

        KLIconView *triangle = [KLIconView iconOf:KLIconPlay tint:[KLTheme ink] side:13];
        // Треугольник смещаем на точку вправо: у фигуры центр тяжести
        // левее геометрического центра, и ровно посередине он выглядит
        // сдвинутым влево.
        [triangle setCenter:CGPointMake(side / 2 + 1, side / 2)];
        [_play addSubview:triangle];

        [self insertSubview:_play belowSubview:_score];
    }

    [_play setHidden:NO];
}

@end
