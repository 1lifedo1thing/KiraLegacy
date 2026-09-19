#import "KLPlayerViewController.h"

#import "KLStrings.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#import "KLHlsProxy.h"
#import "KLMetrics.h"
#import "KLSheet.h"
#import "KLSource.h"
#import "KLStreams.h"
#import "KLSubtitles.h"
#import "KLTheme.h"
#import "KLUtil.h"

/** Через сколько панель прячется сама. */
static const NSTimeInterval KLControlsTimeout = 4.0;

/**
 * Сколько ждать первого кадра, прежде чем признать, что не откроется.
 *
 * Сторож нужен потому, что AVPlayer на битом потоке не жалуется вовсе:
 * он не падает, не переводит item в Failed и не зовёт ни одного обработчика
 * — просто ждёт данных, которые считает негодными. Снаружи это ровно
 * «бесконечная загрузка», и без своего срока из неё нет выхода.
 *
 * Сорок секунд — с запасом на медленную сеть: разбор мастера, дорожки
 * и первого сегмента через посредника на слабом устройстве занимает
 * до десятка секунд.
 */
static const NSTimeInterval KLOpenTimeout = 40.0;

/** Шаг перемотки кнопками. */
static const NSTimeInterval KLSeekStep = 10.0;

/** Ключ наблюдения за готовностью потока — нужен один и уникальный. */
static void *KLPlayerStatusContext = &KLPlayerStatusContext;

@interface KLPlayerViewController () <UIGestureRecognizerDelegate>
@end

@implementation KLPlayerViewController {
    NSString *_playlistUrl;
    NSString *_title;
    NSString *_subtitle;
    KLSource *_source;

    AVPlayer *_player;
    AVPlayerLayer *_playerLayer;
    id _timeObserver;

    UIView *_controls;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_sourceLabel;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UISlider *_seek;
    UIButton *_playButton;
    KLIconView *_playIcon;
    UIActivityIndicatorView *_spinner;
    UILabel *_errorLabel;
    UILabel *_captionLabel;

    UIButton *_qualityButton;
    UILabel *_qualityLabel;
    UIButton *_captionButton;
    UILabel *_captionButtonLabel;

    KLSubtitles *_captions;
    BOOL _captionsOn;

    /** Куда вернуться после смены качества. */
    NSTimeInterval _resumeAt;

    /** Дождались ли хоть раз готовности потока. */
    BOOL _everReady;

    /** Записан ли уже размер кадра, о котором сообщил плеер. */
    BOOL _reportedFrame;

    /** Снимали ли уже закрепление качества после отказа. */
    BOOL _droppedPin;

    BOOL _controlsVisible;
    BOOL _scrubbing;
    BOOL _finished;
    BOOL _observingStatus;

    // Для распознавания заминки: прошлое показание часов и сколько раз
    // подряд оно не менялось.
    NSTimeInterval _lastElapsed;
    NSInteger _sameElapsedCount;
}

- (id)initWithPlaylist:(NSString *)playlist
                 title:(NSString *)title
              subtitle:(NSString *)subtitle
                source:(KLSource *)source {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _playlistUrl = [playlist copy];
    _title = [title copy];
    _subtitle = [subtitle copy];
    _source = source;
    _lastElapsed = -1;

    return self;
}

- (void)dealloc {
    [self teardownPlayer];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Вид

- (void)loadView {
    [self setView:[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]];
    [[self view] setBackgroundColor:[UIColor blackColor]];

    KLUseFullScreenLayout(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _playerLayer = [AVPlayerLayer layer];
    [_playerLayer setFrame:[[self view] bounds]];

    // Вписываем целиком, не обрезая: кадр 16:9 на экране 4:3 и наоборот —
    // обычное дело, и срезать людям края кадра ради заполнения не стоит.
    [_playerLayer setVideoGravity:AVLayerVideoGravityResizeAspect];

    [[[self view] layer] addSublayer:_playerLayer];

    [self buildControls];

    _spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [_spinner setCenter:[[self view] center]];
    [_spinner setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin |
                                  UIViewAutoresizingFlexibleRightMargin |
                                  UIViewAutoresizingFlexibleTopMargin |
                                  UIViewAutoresizingFlexibleBottomMargin];
    [[self view] addSubview:_spinner];
    [_spinner startAnimating];

    [self loadCaptions];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];

    /**
     * Жест не должен перехватывать нажатия по кнопкам — см.
     * gestureRecognizer:shouldReceiveTouch:.
     *
     * Без этого кнопка «назад» в плеере не работала вовсе: жест по кадру
     * распознавался первым и отменял доставку касания кнопке.
     */
    [tap setDelegate:self];

    [[self view] addGestureRecognizer:tap];

    [self startPlayback];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Строка состояния поверх видео ни к чему; на iOS 5 и 6 прячется вот так,
    // и на новых версиях этот же вызов по-прежнему работает.
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];

    // Уходим с экрана — останавливаем: без этого звук продолжал бы играть
    // из карточки, а прокси дотягивал бы сегменты в никуда.
    [self teardownPlayer];

    // Закрепление качества относится к этому просмотру, а не ко всем
    // последующим: у другой серии и лестница может быть другой.
    [[KLHlsProxy shared] setPinnedHeight:0];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Слой не участвует в авторазметке видов — размер ему ставим руками,
    // иначе после поворота кадр остался бы прежнего размера.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_playerLayer setFrame:[[self view] bounds]];
    [CATransaction commit];

    [self layoutControls];
}

#pragma mark - Панель

- (void)buildControls {
    CGRect bounds = [[self view] bounds];

    _controls = [[UIView alloc] initWithFrame:bounds];
    [_controls setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight];
    [_controls setBackgroundColor:[UIColor clearColor]];

    // Затемнение сверху и снизу: белые кнопки поверх светлого кадра иначе
    // не читаются. В макете это ровно такая же пара растяжек.
    KLGradientView *top = [[KLGradientView alloc]
        initWithFrame:CGRectMake(0, 0, bounds.size.width, 110) downwards:NO];
    [top setAlpha:0.6];
    [top setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [_controls addSubview:top];

    KLGradientView *bottom = [[KLGradientView alloc]
        initWithFrame:CGRectMake(0, bounds.size.height - 140, bounds.size.width, 140)
            downwards:YES];
    [bottom setAlpha:0.75];
    [bottom setAutoresizingMask:UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleTopMargin];
    [_controls addSubview:bottom];

    [self buildTopRow];
    [self buildCenterRow];
    [self buildBottomRow];

    [[self view] addSubview:_controls];

    _controlsVisible = YES;
    [self scheduleHide];
}

- (void)buildTopRow {
    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    [back setFrame:CGRectMake(12, 22, 40, 40)];
    [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];

    KLPillView *circle = [[KLPillView alloc] initWithFrame:CGRectMake(3, 3, 34, 34)];
    [circle setFillColor:KLColor(0x80000000)];
    [circle setCornerRadius:17];
    [back addSubview:circle];

    KLIconView *arrow = [KLIconView iconOf:KLIconBack tint:[KLTheme ink] side:18];
    [arrow setCenter:CGPointMake(20, 20)];
    [back addSubview:arrow];

    [_controls addSubview:back];

    _titleLabel = KLLabel([UIFont boldSystemFontOfSize:13], [KLTheme ink], 1);
    [_controls addSubview:_titleLabel];
    [_titleLabel setText:_title];

    _subtitleLabel = KLLabel([UIFont systemFontOfSize:11], [KLTheme cardInk], 1);
    [_controls addSubview:_subtitleLabel];
    [_subtitleLabel setText:_subtitle];

    _sourceLabel = KLLabel([UIFont systemFontOfSize:10], [KLTheme mutedInk], 1);
    [_controls addSubview:_sourceLabel];
    [_sourceLabel setText:[_source displayName]];
}

/**
 * Дописывает к имени источника настоящее разрешение потока.
 *
 * Спрашивается оно у плеера, а не берётся из ответа разрешателя: тот
 * про разрешение не сообщает ничего (поле resolution всегда пустое),
 * а presentationSize плеер заполняет, как только разберёт первый кадр.
 *
 * Строка эта — единственное место, где видно, что именно играет. Выбирать
 * не из чего: мастер-плейлиста источник не отдаёт, дорожка всегда одна.
 * Зато когда картинка рвётся, сразу понятно почему — см. «О программе».
 */
- (void)updateSourceLabel {
    NSString *name = [_source displayName];
    CGSize frame = [[_player currentItem] presentationSize];

    if (frame.width <= 0 || frame.height <= 0) {
        [_sourceLabel setText:name];
        return;
    }

    /**
     * Размер кадра записывается один раз за поток, и не для красоты:
     * на iPad 2 плеер сообщает одно и то же при заведомо разных дорожках,
     * и понять, врёт он или мы отдаём не то, можно только сравнив эту
     * строку со строкой «Качество выбрано руками» от прокси.
     */
    if (!_reportedFrame) {
        _reportedFrame = YES;

        NSLog(@"[Кира/Плеер] Плеер сообщает кадр %d×%d", (int)frame.width, (int)frame.height);
    }

    [_sourceLabel setText:[NSString stringWithFormat:@"%@ · %d×%d",
                           name, (int)frame.width, (int)frame.height]];
}

/** Кнопка перемотки на десять секунд — их две, влево и вправо. */
- (UIButton *)seekButton:(BOOL)forward {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setFrame:CGRectMake(0, 0, 56, 52)];
    [button addTarget:self
               action:forward ? @selector(seekForward) : @selector(seekBackward)
     forControlEvents:UIControlEventTouchUpInside];

    KLIconView *icon = [KLIconView iconOf:forward ? KLIconChevronRight : KLIconChevronLeft
                                     tint:[KLTheme ink]
                                     side:22];
    [icon setCenter:CGPointMake(28, 18)];
    [button addSubview:icon];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:10], [KLTheme ink], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:KLStr(@"player.seek10")];
    [label setFrame:CGRectMake(0, 32, 56, 14)];
    [button addSubview:label];

    return button;
}

- (void)buildCenterRow {
    UIButton *backward = [self seekButton:NO];
    [backward setTag:101];
    [_controls addSubview:backward];

    _playButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_playButton setFrame:CGRectMake(0, 0, 62, 62)];
    [_playButton addTarget:self action:@selector(togglePlay) forControlEvents:UIControlEventTouchUpInside];

    KLPillView *circle = [[KLPillView alloc] initWithFrame:CGRectMake(0, 0, 62, 62)];
    [circle setFillColor:KLColor(0x66000000)];
    [circle setCornerRadius:31];
    [_playButton addSubview:circle];

    _playIcon = [KLIconView iconOf:KLIconPlay tint:[KLTheme ink] side:26];
    [_playIcon setCenter:CGPointMake(32, 31)];
    [_playButton addSubview:_playIcon];

    [_controls addSubview:_playButton];

    UIButton *forward = [self seekButton:YES];
    [forward setTag:102];
    [_controls addSubview:forward];

    _errorLabel = KLLabel(KLFontBody(), [KLTheme ink], 0);
    [_errorLabel setTextAlignment:NSTextAlignmentCenter];
    [_errorLabel setHidden:YES];
    [_controls addSubview:_errorLabel];
}

- (void)buildBottomRow {
    _elapsedLabel = KLLabel([UIFont systemFontOfSize:11], [KLTheme ink], 1);
    [_elapsedLabel setText:@"0:00"];
    [_controls addSubview:_elapsedLabel];

    _durationLabel = KLLabel([UIFont systemFontOfSize:11], [KLTheme ink], 1);
    [_durationLabel setTextAlignment:NSTextAlignmentRight];
    [_durationLabel setText:@"0:00"];
    [_controls addSubview:_durationLabel];

    _seek = [[UISlider alloc] initWithFrame:CGRectZero];

    [_seek setMinimumTrackTintColor:[KLTheme accent]];
    [_seek setMaximumTrackTintColor:KLColor(0x4D4D57)];
    [_seek setValue:0];

    // Три события, и все три нужны: по первому останавливаем слежение
    // за временем (иначе бегунок дёргался бы под пальцем), по второму
    // показываем время под ним, по третьему перематываем.
    [_seek addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [_seek addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
    [_seek addTarget:self
              action:@selector(scrubEnded)
    forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                     UIControlEventTouchCancel];

    [_controls addSubview:_seek];

    _qualityButton = [self smallButton:KLStr(@"player.quality")
                                action:@selector(openQualitySheet)
                              labelOut:&_qualityLabel];

    _captionButton = [self smallButton:KLStr(@"player.subs.off")
                                action:@selector(toggleCaptions)
                              labelOut:&_captionButtonLabel];

    // Пока не выяснилось, что предложить, кнопок не видно: пустое меню
    // и выключатель того, чего нет, только сбивают с толку.
    [_qualityButton setHidden:YES];
    [_captionButton setHidden:YES];

    /**
     * Подпись субтитров лежит поверх кадра, но вне панели управления.
     *
     * Будь она внутри, она пропадала бы вместе с кнопками через четыре
     * секунды — то есть ровно тогда, когда начинают смотреть.
     */
    _captionLabel = KLLabel([UIFont boldSystemFontOfSize:15], [KLTheme ink], 3);
    [_captionLabel setTextAlignment:NSTextAlignmentCenter];
    [_captionLabel setBackgroundColor:KLColor(0x8C000000)];
    [_captionLabel setHidden:YES];
    [[self view] addSubview:_captionLabel];
}

/** Мелкая кнопка нижнего ряда: подпись на приглушённой подложке. */
- (UIButton *)smallButton:(NSString *)title
                   action:(SEL)action
                 labelOut:(UILabel * __strong *)labelOut {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = KLLabel([UIFont boldSystemFontOfSize:11], [KLTheme ink], 1);
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setText:title];
    [button addSubview:label];

    [_controls addSubview:button];

    if (labelOut != NULL) {
        *labelOut = label;
    }

    return button;
}

- (void)layoutControls {
    CGRect bounds = [[self view] bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    [_titleLabel setFrame:CGRectMake(64, 22, width - 76, 16)];
    [_subtitleLabel setFrame:CGRectMake(64, 39, width - 76, 14)];
    [_sourceLabel setFrame:CGRectMake(64, 54, width - 76, 13)];

    // Середина: три кнопки в ряд, симметрично относительно центра.
    CGFloat centerY = height / 2;
    CGFloat gap = 46;

    [[_controls viewWithTag:101] setCenter:CGPointMake(width / 2 - 31 - gap - 28, centerY)];
    [_playButton setCenter:CGPointMake(width / 2, centerY)];
    [[_controls viewWithTag:102] setCenter:CGPointMake(width / 2 + 31 + gap + 28, centerY)];

    [_errorLabel setFrame:CGRectMake(24, centerY + 52, width - 48, 60)];

    CGFloat bottom = height - 34;

    // Ряд кнопок над полосой перемотки; сама полоса из-за них поднимается.
    CGFloat buttons = bottom - 34;

    [_qualityButton setFrame:CGRectMake(width - 200, buttons, 92, 26)];
    [_qualityLabel setFrame:CGRectMake(0, 0, 92, 26)];
    [_captionButton setFrame:CGRectMake(width - 104, buttons, 92, 26)];
    [_captionButtonLabel setFrame:CGRectMake(0, 0, 92, 26)];

    [_elapsedLabel setFrame:CGRectMake(16, bottom, 46, 16)];
    [_durationLabel setFrame:CGRectMake(width - 62, bottom, 46, 16)];
    [_seek setFrame:CGRectMake(70, bottom - 6, width - 140, 28)];

    // Подпись субтитров — над рядом кнопок, чтобы панель её не закрывала.
    CGFloat captionHeight = 62;

    [_captionLabel setFrame:CGRectMake(24, buttons - captionHeight - 10,
                                       width - 48, captionHeight)];

    [_spinner setCenter:CGPointMake(width / 2, centerY)];
}

/**
 * Пропускает касания по кнопкам мимо жеста.
 *
 * Жест «нажать по кадру, чтобы показать или спрятать панель» висит на самом
 * виде контроллера, а кнопки лежат внутри него. У UITapGestureRecognizer
 * cancelsTouchesInView по умолчанию YES: распознав нажатие, он отменяет
 * доставку касания тому виду, на котором оно началось. Кнопка при этом
 * получает touchesCancelled вместо touchesEnded, и её действие не
 * срабатывает никогда.
 *
 * Снаружи это выглядело так: панель показывается и прячется по нажатию,
 * а «назад», пауза и перемотка не работают вовсе — из плеера нельзя выйти.
 *
 * Ставить cancelsTouchesInView = NO мало: тогда одно нажатие по кнопке
 * и сработает, и заодно переключит панель — кнопку нажали, а панель
 * спряталась. Поэтому жест просто не берёт касания, начавшиеся на кнопке.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
       shouldReceiveTouch:(UITouch *)touch {
    UIView *hit = [touch view];

    while (hit != nil && hit != [self view]) {
        if ([hit isKindOfClass:[UIControl class]]) {
            return NO;
        }

        hit = [hit superview];
    }

    return YES;
}

#pragma mark - Показ и скрытие панели

- (void)toggleControls {
    [self setControlsVisible:!_controlsVisible];
}

- (void)setControlsVisible:(BOOL)visible {
    _controlsVisible = visible;

    [UIView animateWithDuration:0.2 animations:^{
        [_controls setAlpha:visible ? 1 : 0];
    }];

    // Невидимая панель не должна ловить нажатия: иначе касание по кадру
    // попадало бы в спрятанную кнопку.
    [_controls setUserInteractionEnabled:visible];

    if (visible) {
        [self scheduleHide];
    }
}

- (void)scheduleHide {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(hideControls)
                                               object:nil];

    // Пока стоим на паузе, панель не прячем: убирать единственную кнопку,
    // которой можно продолжить, — плохая мысль.
    if ([_player rate] == 0) {
        return;
    }

    [self performSelector:@selector(hideControls) withObject:nil afterDelay:KLControlsTimeout];
}

- (void)hideControls {
    [self setControlsVisible:NO];
}

#pragma mark - Воспроизведение

#pragma mark - Субтитры

/**
 * Тянет дорожку субтитров, если зеркало её дало.
 *
 * В фоне и молча: субтитров может не быть вовсе, и это не повод ни ругаться,
 * ни задерживать воспроизведение. Кнопка появится, когда файл доедет.
 */
- (void)loadCaptions {
    NSArray *tracks = _source.subtitles;

    if ([tracks count] == 0) {
        return;
    }

    // Берём помеченную по умолчанию, иначе первую: выбирать язык пока
    // не из чего — зеркала присылают одну дорожку.
    KLSubtitleTrack *chosen = [tracks objectAtIndex:0];

    for (KLSubtitleTrack *track in tracks) {
        if (track.isDefault) {
            chosen = track;
            break;
        }
    }

    NSString *referer = _source.referer;

    KLAsync(^{
        KLSubtitles *loaded = [KLSubtitles load:chosen.url referer:referer];

        KLMain(^{
            if (loaded == nil) {
                return;
            }

            _captions = loaded;
            _captionsOn = YES;

            [_captionButton setHidden:NO];
            [self updateCaptionButton];
        });
    });
}

- (void)toggleCaptions {
    if (_captions == nil) {
        return;
    }

    _captionsOn = !_captionsOn;

    [self updateCaptionButton];
    [self updateCaptionText];
    [self scheduleHide];
}

- (void)updateCaptionButton {
    [_captionButtonLabel setText:KLStr(_captionsOn ? @"player.subs.on" : @"player.subs.off")];
    [_captionButtonLabel setTextColor:_captionsOn ? [KLTheme ink] : [KLTheme mutedInk]];
}

- (void)updateCaptionText {
    if (!_captionsOn || _captions == nil) {
        [_captionLabel setHidden:YES];
        return;
    }

    NSTimeInterval now = CMTimeGetSeconds([_player currentTime]);
    NSString *text = [_captions textAt:now];

    if ([text length] == 0) {
        [_captionLabel setHidden:YES];
        return;
    }

    if (![text isEqualToString:[_captionLabel text]]) {
        [_captionLabel setText:text];
    }

    [_captionLabel setHidden:NO];
}

#pragma mark - Качество

/**
 * Надпись на кнопке — это выбор человека, а не показания плеера.
 *
 * Сначала здесь стояла высота кадра из presentationSize: казалось,
 * что честнее показывать то, что и правда декодируется. На деле выходило
 * наоборот. На iPad 2 с iOS 6 плеер сообщал 480 при любом выборе — и когда
 * отдавали 1080p, и когда 720p, — хотя дорожки заведомо разные: проверено
 * по содержимому сегментов, там честные 1920×1080 High@5.0 и 1280×720
 * High@3.1. То есть кнопка спорила с галочкой в списке и с тем, что
 * происходит на самом деле.
 *
 * Выбор человека известен точно и не зависит ни от чьих сообщений. Он же
 * стоит галочкой в списке — теперь эти две надписи не могут разойтись.
 *
 * А что именно декодируется, по-прежнему видно в строке под названием:
 * это её работа, и там разница с выбранным — полезный признак, а не ошибка.
 */
- (void)updateQualityButton {
    NSArray *variants = [[KLHlsProxy shared] variants];

    // Меньше двух дорожек — выбирать не из чего, и кнопки не будет.
    [_qualityButton setHidden:[variants count] < 2];

    NSInteger pinned = [[KLHlsProxy shared] pinnedHeight];

    [_qualityLabel setText:pinned > 0
        ? [NSString stringWithFormat:@"%ldp ▾", (long)pinned]
        : KLFmt(@"player.quality.short", KLStr(@"player.auto"))];
}

/**
 * Меню качества.
 *
 * Смена дорожки — это пересоздание потока: мастер-плейлист плеер уже разобрал
 * и держит выбранное, а переписать его на лету нечем. Поэтому запоминаем
 * секунду, поднимаем поток заново с закреплённой высотой и возвращаемся
 * на то же место.
 */
- (void)openQualitySheet {
    NSArray *variants = [[KLHlsProxy shared] variants];

    if ([variants count] < 2) {
        return;
    }

    KLHlsProxy *proxy = [KLHlsProxy shared];
    NSInteger pinned = [proxy pinnedHeight];

    KLSheet *sheet = [[KLSheet alloc] initWithTitle:KLStr(@"player.quality")
                                           subtitle:[_source displayName]];

    __weak KLPlayerViewController *weakSelf = self;

    [sheet addOption:KLStr(@"player.quality.auto")
             checked:pinned == 0
           dangerous:NO
              action:^{ [weakSelf switchToHeight:0]; }];

    for (KLHlsVariant *variant in variants) {
        NSInteger height = variant.height;

        NSString *title = [variant playable]
            ? [variant label]
            : KLFmt(@"player.quality.cant", [variant label]);

        [sheet addOption:title
                 checked:pinned == height
               dangerous:NO
                  action:^{ [weakSelf switchToHeight:height]; }];
    }

    [sheet present];
}

- (void)switchToHeight:(NSInteger)height {
    KLHlsProxy *proxy = [KLHlsProxy shared];

    if ([proxy pinnedHeight] == height) {
        return;
    }

    _resumeAt = CMTimeGetSeconds([_player currentTime]);

    [proxy setPinnedHeight:height];

    [self teardownPlayer];

    _everReady = NO;
    _reportedFrame = NO;

    [_spinner startAnimating];
    [self startPlayback];

    [KLToast show:height > 0
        ? KLFmt(@"player.quality.set", (long)height)
        : KLStr(@"player.quality.setauto")];
}

- (void)startPlayback {
    // Адрес готовится в фоне не зря: в обычном режиме prepareStream поднимает
    // сервер на петле, а это заведение сокета и потока.
    KLAsync(^{
        NSURL *local = [[KLHlsProxy shared] prepareStream:_playlistUrl
                                                  referer:_source.referer];

        KLMain(^{
            if (local == nil) {
                [self showError:KLStr(@"player.failed")];
                return;
            }

            [self attachPlayerWithUrl:local];
        });
    });
}

- (void)attachPlayerWithUrl:(NSURL *)url {
    _player = [AVPlayer playerWithURL:url];

    [_playerLayer setPlayer:_player];

    // Готовность спрашиваем наблюдением, а не опросом: у HLS между созданием
    // и первым кадром проходит от доли секунды до нескольких секунд, и всё
    // это время status остаётся Unknown.
    [[_player currentItem] addObserver:self
                            forKeyPath:@"status"
                               options:NSKeyValueObservingOptionNew
                               context:KLPlayerStatusContext];
    _observingStatus = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackEnded)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:[_player currentItem]];

    __weak KLPlayerViewController *weakSelf = self;

    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf tick];
    }];

    [_player play];

    [self updatePlayIcon];

    // Сторож: см. KLOpenTimeout.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(openTimedOut)
                                               object:nil];

    [self performSelector:@selector(openTimedOut)
               withObject:nil
               afterDelay:KLOpenTimeout];
}

/**
 * Поток не открылся за отведённое время.
 *
 * Сообщение нарочно называет виноватого предположительно: снизу может быть
 * что угодно — легло зеркало, не пустил CDN, не хватило канала. Что бы это
 * ни было, полезное действие одно и то же — вернуться и взять другое
 * зеркало, поэтому его и предлагаем.
 */
- (void)openTimedOut {
    if (_everReady || _player == nil) {
        return;
    }

    AVPlayerItem *item = [_player currentItem];
    NSError *error = [item error];

    NSLog(@"[Кира/Плеер] Поток не открылся за %ld с. Статус %ld, ошибка: %@",
          (long)KLOpenTimeout, (long)[item status],
          [error localizedDescription] ?: @"нет");

    [self showError:KLStr(@"player.notopened")];
}

- (void)teardownPlayer {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(openTimedOut)
                                               object:nil];

    if (_timeObserver != nil) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }

    if (_observingStatus) {
        // Снимать наблюдение обязательно и ровно один раз: снятое дважды
        // роняет приложение так же верно, как не снятое вовсе.
        [[_player currentItem] removeObserver:self forKeyPath:@"status"];
        _observingStatus = NO;
    }

    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:AVPlayerItemDidPlayToEndTimeNotification
                object:nil];

    [_player pause];
    [_playerLayer setPlayer:nil];

    _player = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != KLPlayerStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    KLMain(^{
        AVPlayerItem *item = [_player currentItem];

        if ([item status] == AVPlayerItemStatusReadyToPlay) {
            _everReady = YES;

            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(openTimedOut)
                                                       object:nil];

            [_spinner stopAnimating];
            [self updateDuration];
            [self updateSourceLabel];
            [self updateQualityButton];

            // Место, с которого продолжаем после смены качества.
            if (_resumeAt > 1) {
                [_player seekToTime:CMTimeMakeWithSeconds(_resumeAt, NSEC_PER_SEC)
                    toleranceBefore:kCMTimeZero
                     toleranceAfter:kCMTimeZero];

                _resumeAt = 0;
            }

            return;
        }

        if ([item status] == AVPlayerItemStatusFailed) {
            NSString *reason = [[item error] localizedDescription];

            NSLog(@"[Кира/Плеер] Поток не открылся: %@", reason);

            /**
             * Не открылось при закреплённом качестве — снимаем закрепление
             * и пробуем ещё раз, один раз.
             *
             * Закрепление приходит из настроек и действует на все зеркала
             * подряд, а дорожка в нём у каждого своя: та же «1080p» у одного
             * объявлена уровнем 4.1 и играет, у другого — 5.0, и декодер
             * отказывается ещё до первого запроса. Человек при этом ничего
             * не делал и знать про уровни не обязан; он видит, что зеркало
             * «сломалось», хотя сломался выбор, а не зеркало.
             *
             * Поэтому вместо сообщения об ошибке — тихая попытка на том же
             * зеркале без закрепления. Один раз: если и без него не вышло,
             * дело не в качестве, и настаивать незачем.
             */
            if (!_droppedPin && [[KLHlsProxy shared] pinnedHeight] > 0) {
                _droppedPin = YES;

                NSLog(@"[Кира/Плеер] Пробуем без закреплённого качества");

                [KLToast show:KLStr(@"player.quality.fellback")];

                [self switchToHeight:0];
                return;
            }

            [self showError:KLStr(@"player.notopened")];
        }
    });
}

- (void)showError:(NSString *)text {
    [_spinner stopAnimating];

    [_errorLabel setText:text];
    [_errorLabel setHidden:NO];

    [_playButton setHidden:YES];
    [[_controls viewWithTag:101] setHidden:YES];
    [[_controls viewWithTag:102] setHidden:YES];

    [self setControlsVisible:YES];
}

#pragma mark - Время

- (void)tick {
    if (_scrubbing) {
        return;
    }

    CMTime current = [_player currentTime];
    if (!CMTIME_IS_NUMERIC(current)) {
        return;
    }

    NSTimeInterval elapsed = CMTimeGetSeconds(current);
    NSTimeInterval duration = [self duration];

    [_elapsedLabel setText:[self formatTime:elapsed]];

    if (duration > 0) {
        [_seek setValue:(float)(elapsed / duration)];
    }

    // Индикатор во время заминки: у AVPlayer нет уведомления «буферизуюсь»,
    // но есть косвенный признак — идём, а время не движется.
    BOOL stalled = [_player rate] > 0 && elapsed > 0 && [self likelyStalled:elapsed];

    if (stalled) {
        [_spinner startAnimating];
    } else {
        [_spinner stopAnimating];
    }

    [self updatePlayIcon];
    [self updateCaptionText];
}

/** Время не сдвинулось с прошлого замера, хотя воспроизведение идёт. */
- (BOOL)likelyStalled:(NSTimeInterval)elapsed {
    if (fabs(elapsed - _lastElapsed) < 0.01) {
        _sameElapsedCount++;
    } else {
        _sameElapsedCount = 0;
    }

    _lastElapsed = elapsed;

    // Два замера подряд по полсекунды — секунда без движения. Одного мало:
    // замеры и настоящее время кадров не совпадают, и единичное совпадение
    // случается и при исправном воспроизведении.
    return _sameElapsedCount >= 2;
}

- (NSTimeInterval)duration {
    CMTime duration = [[_player currentItem] duration];

    if (!CMTIME_IS_NUMERIC(duration) || CMTIME_IS_INDEFINITE(duration)) {
        return 0;
    }

    return CMTimeGetSeconds(duration);
}

- (void)updateDuration {
    NSTimeInterval duration = [self duration];

    // Прямой эфир (и плейлист без длительности) — перематывать нечего,
    // и полосу тогда лучше не показывать вовсе, чем показывать пустой.
    BOOL known = duration > 0;

    [_seek setEnabled:known];
    [_durationLabel setText:known ? [self formatTime:duration] : KLStr(@"player.live")];
}

- (NSString *)formatTime:(NSTimeInterval)seconds {
    if (seconds < 0 || !isfinite(seconds)) {
        seconds = 0;
    }

    NSInteger whole = (NSInteger)seconds;
    NSInteger hours = whole / 3600;
    NSInteger minutes = (whole % 3600) / 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)hours, (long)minutes, (long)(whole % 60)];
    }

    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)(whole % 60)];
}

#pragma mark - Действия

- (void)togglePlay {
    if (_player == nil) {
        return;
    }

    if (_finished) {
        // Досмотрели до конца: кнопка «играть» начинает заново, а не
        // продолжает с последнего кадра.
        _finished = NO;
        [_player seekToTime:kCMTimeZero];
    }

    if ([_player rate] > 0) {
        [_player pause];
    } else {
        [_player play];
    }

    [self updatePlayIcon];
    [self scheduleHide];
}

- (void)updatePlayIcon {
    BOOL playing = [_player rate] > 0;

    // Паузы в наборе значков нет — две полосы рисуются проще, чем заводить
    // ради них отдельный вид: прячем треугольник и показываем пару
    // прямоугольников.
    [_playIcon setHidden:playing];

    UIView *pause = [_playButton viewWithTag:55];

    if (pause == nil) {
        pause = [[UIView alloc] initWithFrame:CGRectMake(23, 20, 16, 22)];
        [pause setTag:55];
        [pause setUserInteractionEnabled:NO];

        for (NSUInteger i = 0; i < 2; i++) {
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(i * 10, 0, 5, 22)];
            [bar setBackgroundColor:[KLTheme ink]];
            [pause addSubview:bar];
        }

        [_playButton addSubview:pause];
    }

    [pause setHidden:!playing];
}

- (void)seekBy:(NSTimeInterval)delta {
    if (_player == nil) {
        return;
    }

    NSTimeInterval target = CMTimeGetSeconds([_player currentTime]) + delta;
    NSTimeInterval duration = [self duration];

    if (target < 0) {
        target = 0;
    }

    if (duration > 0 && target > duration - 1) {
        target = duration - 1;
    }

    /**
     * Перематываем точно, а не «куда получится».
     *
     * По умолчанию AVPlayer перематывает к ближайшему ключевому кадру,
     * а в HLS сегменты бывают по десять секунд — и перемотка на десять
     * секунд вперёд нет-нет да и не сдвигала бы ничего вовсе. Нулевые
     * допуски обходятся дороже по времени, но делают именно то, о чём
     * просили.
     */
    [_player seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];

    [self scheduleHide];
}

- (void)seekForward { [self seekBy:KLSeekStep]; }
- (void)seekBackward { [self seekBy:-KLSeekStep]; }

- (void)scrubStarted {
    _scrubbing = YES;

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(hideControls)
                                               object:nil];
}

- (void)scrubMoved {
    NSTimeInterval duration = [self duration];

    if (duration > 0) {
        [_elapsedLabel setText:[self formatTime:[_seek value] * duration]];
    }
}

- (void)scrubEnded {
    NSTimeInterval duration = [self duration];

    if (duration > 0) {
        [_player seekToTime:CMTimeMakeWithSeconds([_seek value] * duration, NSEC_PER_SEC)
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero];
    }

    _scrubbing = NO;
    [self scheduleHide];
}

- (void)playbackEnded {
    _finished = YES;

    [self updatePlayIcon];
    [self setControlsVisible:YES];
}

- (void)goBack {
    [KLNav pop];
}

#pragma mark - Поворот

/** Единственный экран, который поворачивается во все стороны. */
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown ||
           UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad
        ? UIInterfaceOrientationMaskAll
        : UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
