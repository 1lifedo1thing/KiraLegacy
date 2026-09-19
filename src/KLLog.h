#import <Foundation/Foundation.h>

/**
 * Журнал приложения.
 *
 * NSLog пишет в системный журнал (ASL), а не в файл: на устройстве его видно
 * только сторонними средствами — «Системный лог» в 3uTools, `syslog -w`
 * по SSH, окно устройств в Xcode. Для отладки на живом железе этого мало:
 * чтобы прислать лог, его сначала надо откуда-то достать.
 *
 * Поэтому всё, что уходит в NSLog, попадает ещё и в файл:
 * Documents/kiralegacy.log. Папка открыта наружу (UIFileSharingEnabled),
 * так что файл забирается через «Файлы» или iTunes без всяких
 * дополнительных средств.
 *
 * Подмена сделана макросом и подключается ко всем файлам сразу (-include
 * в Makefile), поэтому обычные вызовы NSLog трогать не пришлось.
 */
void KLLogWrite(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/** Путь к файлу журнала — показывается на экране «О программе». */
NSString *KLLogPath(void);

/** Стереть журнал. */
void KLLogClear(void);

#ifndef KL_LOG_KEEP_NSLOG
#define NSLog(...) KLLogWrite(__VA_ARGS__)
#endif
