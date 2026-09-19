#import "KLTheme.h"

UIColor *KLColor(uint32_t argb) {
    CGFloat alpha = ((argb >> 24) & 0xFF) / 255.0;

    // Запись без альфы (просто #RRGGBB) даёт нулевой старший байт — такой
    // цвет вышел бы прозрачным, а имелся в виду сплошной.
    if (((argb >> 24) & 0xFF) == 0 && (argb & 0x00FFFFFF) != 0) {
        alpha = 1.0;
    }

    return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:alpha];
}

@implementation KLTheme

#pragma mark Фон

+ (UIColor *)pageBackground { return [UIColor blackColor]; }
+ (UIColor *)surface { return KLColor(0x15151F); }
+ (UIColor *)sheet { return KLColor(0x13131F); }
+ (UIColor *)dock { return KLColor(0x14141C); }

+ (UIColor *)hairline {
    // В макете это rgba(255,255,255,.05) поверх чёрного. Сплошной эквивалент
    // получается почти чёрным, и на слабой матрице iPhone 4 линии не видно
    // вовсе — поэтому берём чуть светлее расчётного.
    return KLColor(0x1E1E28);
}

+ (UIColor *)badge {
    // Единственное место, где прозрачность оставлена намеренно: под плашкой
    // не фон страницы, а обложка, и сплошным цветом её не заменить.
    return KLColor(0xB8000000);
}

#pragma mark Текст

+ (UIColor *)ink { return [UIColor whiteColor]; }
+ (UIColor *)cardInk { return KLColor(0xD9D9D9); }
+ (UIColor *)mutedInk { return KLColor(0x8C8C8C); }
+ (UIColor *)faintInk { return KLColor(0x525252); }

#pragma mark Фирменные

+ (UIColor *)accent { return KLColor(0x6366F1); }
+ (UIColor *)accentInk { return KLColor(0xA5B4FC); }
+ (UIColor *)accentPlaying { return KLColor(0x818CF8); }

+ (UIColor *)accentSurface {
    // rgba(99,102,241,.25) поверх чёрного.
    return KLColor(0x191A3C);
}

+ (UIColor *)gold { return KLColor(0xFFD700); }
+ (UIColor *)danger { return KLColor(0xF87171); }

@end
