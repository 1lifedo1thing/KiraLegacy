#import "KLAppDelegate.h"

#import <AVFoundation/AVFoundation.h>

#import "KLImageLoader.h"
#import "KLStrings.h"
#import "KLShellViewController.h"
#import "KLTheme.h"
#import "KLUtil.h"

@implementation KLAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {
    [self configureAudioSession];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setBackgroundColor:[KLTheme pageBackground]];

    KLShellViewController *shell = [[KLShellViewController alloc] init];

    /**
     * Навигация штатная, но с невидимой полосой: свои шапки приложение
     * рисует само — у них другая высота, другой шрифт и своя кнопка назад.
     * От UINavigationController нужны только переходы и стопка экранов.
     */
    UINavigationController *navigation =
        [[KLNavigationController alloc] initWithRootViewController:shell];

    [navigation setNavigationBarHidden:YES];

    // Стопка — контроллер верхнего уровня, и до iOS 7 отступ под строку
    // состояния система отмеряет именно от неё. Экраны отступают сами.
    KLUseFullScreenLayout(navigation);

    /**
     * Подложка стопки экранов тоже чёрная. По умолчанию она белая, и на
     * iPad её видно светлыми полосами по краям, когда вид экрана оказывается
     * чуть уже окна.
     */
    [[navigation view] setBackgroundColor:[KLTheme pageBackground]];

    [KLNav setController:navigation];

    [self.window setRootViewController:navigation];
    [self.window makeKeyAndVisible];

    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged)
                                                 name:KLLanguageChangedNotification
                                               object:nil];

    return YES;
}

/**
 * Пересобирает корневой экран, когда сменили язык.
 *
 * Подписи разложены по полусотне видов, и обойти их все, ничего не забыв,
 * не выйдет: половина создаётся на лету при наполнении лент. Проще собрать
 * вкладки заново — они и так собираются за миллисекунды, а ленты возьмутся
 * из кеша ответов.
 *
 * Заменяется при этом только корень, а остальная стопка остаётся на месте:
 * язык обычно меняют из настроек, и выкидывать человека оттуда на главный
 * экран было бы грубо. Экраны выше корня подписи обновят при следующем
 * открытии — кроме карточки, которая слушает то же уведомление сама.
 */
- (void)languageChanged {
    UINavigationController *navigation = [KLNav controller];

    NSMutableArray *stack = [[navigation viewControllers] mutableCopy];

    if ([stack count] == 0) {
        return;
    }

    [stack replaceObjectAtIndex:0 withObject:[[KLShellViewController alloc] init]];
    [navigation setViewControllers:stack animated:NO];
}

/**
 * Категория звука: играем и при выключенном звонке.
 *
 * По умолчанию приложение получает AVAudioSessionCategorySoloAmbient, а он
 * означает «замолкать, когда переключатель на боку выключен». Для видео это
 * не годится: человек нажимает «Смотреть», видит картинку и не слышит
 * ничего — при том что громкость на максимуме.
 *
 * Playback заодно разрешает звук в фоне; он же объявлен в Info.plist
 * через UIBackgroundModes.
 */
- (void)configureAudioSession {
    NSError *error = nil;

    AVAudioSession *session = [AVAudioSession sharedInstance];

    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        NSLog(@"[Кира/Звук] Категория не выставилась: %@", [error localizedDescription]);
    }

    if (![session setActive:YES error:&error]) {
        NSLog(@"[Кира/Звук] Сессия не включилась: %@", [error localizedDescription]);
    }
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    // Система просит потесниться — отдаём кеш обложек: он самый крупный
    // из того, что мы держим, и восстанавливается сам.
    [KLImageLoader trim];
}

@end
