#import "KLPosterView.h"

#import "KLTheme.h"

@implementation KLPosterView {
    UIImage *_image;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }

    _cornerRadius = 0;
    _placeholderColor = [KLTheme surface];
    _dimming = 0;

    [self setBackgroundColor:[UIColor clearColor]];
    [self setOpaque:NO];
    [self setContentMode:UIViewContentModeRedraw];

    return self;
}

- (void)setImage:(UIImage *)image {
    _image = image;
    [self setNeedsDisplay];
}

- (void)setCornerRadius:(CGFloat)radius {
    _cornerRadius = radius;
    [self setNeedsDisplay];
}

- (void)setPlaceholderColor:(UIColor *)color {
    _placeholderColor = color;
    [self setNeedsDisplay];
}

- (void)setDimming:(CGFloat)dimming {
    _dimming = dimming;
    [self setNeedsDisplay];
}

- (void)loadUrl:(NSString *)url targetSize:(CGSize)targetSize {
    CGSize own = self.bounds.size;
    CGSize size = (own.width > 0 && own.height > 0) ? own : targetSize;

    [KLImageLoader loadInto:self url:url targetSize:size];
}

- (void)drawRect:(CGRect)rect {
    CGRect bounds = self.bounds;

    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        return;
    }

    UIBezierPath *shape = _cornerRadius > 0
        ? [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:_cornerRadius]
        : [UIBezierPath bezierPathWithRect:bounds];

    if (_placeholderColor != nil) {
        [_placeholderColor setFill];
        [shape fill];
    }

    if (_image == nil) {
        return;
    }

    CGContextRef context = UIGraphicsGetCurrentContext();

    CGContextSaveGState(context);

    // Обрезка по форме: всё, что выйдет за скругление, не нарисуется.
    [shape addClip];

    CGSize size = [_image size];

    if (size.width > 0 && size.height > 0) {
        // Заполнение: берём больший из двух множителей, так что по одной
        // стороне кадр совпадёт с рамкой, а по другой выйдет за неё —
        // и лишнее срежет обрезка.
        CGFloat scale = MAX(bounds.size.width / size.width,
                            bounds.size.height / size.height);

        CGFloat width = size.width * scale;
        CGFloat height = size.height * scale;

        [_image drawInRect:CGRectMake(bounds.origin.x + (bounds.size.width - width) / 2,
                                      bounds.origin.y + (bounds.size.height - height) / 2,
                                      width, height)];
    }

    if (_dimming > 0) {
        CGContextSetFillColorWithColor(context,
            [[UIColor colorWithWhite:0 alpha:_dimming] CGColor]);
        CGContextFillRect(context, bounds);
    }

    CGContextRestoreGState(context);
}

@end
