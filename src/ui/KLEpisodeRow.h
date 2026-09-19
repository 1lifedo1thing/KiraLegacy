#import <UIKit/UIKit.h>

@class KLEpisode;

/**
 * Строка списка серий: кадр слева, название и описание справа, линия снизу.
 *
 * Высота у строки не постоянная — описание занимает то одну строку, то две,
 * а у части серий его нет вовсе. Считается она один раз при заведении и
 * лежит в рамке: тот, кто раскладывает список, спрашивает её оттуда.
 */
@interface KLEpisodeRow : UIControl

- (id)initWithWidth:(CGFloat)width episode:(KLEpisode *)episode;

/** Подсветить как ту, что смотрят сейчас. */
- (void)setPlaying:(BOOL)playing;

@property (nonatomic, copy) dispatch_block_t action;

@end
