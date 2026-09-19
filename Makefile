export THEOS ?= $(HOME)/theos

# OpenSSL по срезу на архитектуру — собирается tools/build-openssl.sh.
#
# Своя криптография здесь не прихоть. Secure Transport на iOS 5 и 6
# предлагает только наборы на CBC и SHA-1: ни AES-GCM, ни ChaCha20,
# ни TLS 1.3 там нет вовсе. Сегодня зеркала такие наборы ещё принимают,
# но день, когда перестанут, назначаем не мы, и наступит он без
# предупреждения. Подробности — в src/net/KLTls.h.
#
# `?=` позволяет задать путь вручную, если библиотека собрана в другом месте.
SSL_OUT ?= $(HOME)/kiralegacy/out

# 9.3 — последний SDK, где ещё живы заголовки эпохи iOS 5 и в котором есть
# срез armv7. Нижняя граница 5.1: там уже есть TLS 1.2 в Secure Transport,
# NSJSONSerialization и ARC — всё, на чём стоит это приложение.
TARGET := iphone:9.3:5.1

# armv7 покрывает всё от iPhone 3GS до iPhone 5; arm64 — всё, что новее.
ARCHS := armv7 arm64

# dpkg-deb отказывается паковать каталог с правами 777, а именно их выдаёт
# диску Windows подсистема WSL — chmod там ничего не меняет. Поэтому дерево,
# из которого собирается пакет, складывается в файловую систему Linux.
export THEOS_STAGING_DIR ?= /tmp/theos-kiralegacy/_

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = KiraLegacy

KiraLegacy_FILES = $(shell find src -name '*.m')
KiraLegacy_CFLAGS  = -fobjc-arc -Wall -Wno-deprecated-declarations
KiraLegacy_CFLAGS += $(addprefix -I,$(shell find src -type d))

# Подменяет NSLog во всех файлах разом: всё, что уходит в системный журнал,
# попадает ещё и в Documents/kiralegacy.log — оттуда его можно просто забрать
# с устройства. Подробности в src/KLLog.h.
KiraLegacy_CFLAGS += -include src/KLLog.h
KiraLegacy_CFLAGS += -Wno-unused-variable -fvisibility=hidden
KiraLegacy_CFLAGS += -I$(SSL_OUT)/$(THEOS_CURRENT_ARCH)/openssl/include

KiraLegacy_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO AVFoundation \
                        CoreMedia MediaPlayer Security SystemConfiguration

# NSObject ищем по всем библиотекам, а не в той, где он лежит сегодня.
#
# iPad 1 с iOS 5.1.1 не запускает приложение вовсе, и dyld объясняет почему:
#
#   Symbol not found: _OBJC_CLASS_$_NSObject
#   Expected in: /usr/lib/libobjc.A.dylib
#
# Класс NSObject переехал в libobjc только в iOS 6. До неё он живёт
# в CoreFoundation, а SDK у нас от 9.3 — по нему компоновщик и записывает
# «спрашивать в libobjc». Двухуровневые имена означают, что dyld ищет символ
# ровно в названной библиотеке и, не найдя, отказывает целиком: приложение
# умирает до main, и это не «падение», а отказ загрузчика.
#
# -U снимает привязку к библиотеке ровно для названного символа: dyld ищет
# его во всём, что загружено, и находит там, где он есть на этой версии.
#
# Доллар приходится закрывать дважды, и оба раза по делу: \$$ превращается
# в \$ на разборе make, а уже \$ доживает до ld как $ — потому что между ними
# ещё оболочка, для которой $_NSObject это имя переменной.
# OpenSSL — статикой, отдельными файлами, а не через -l: так виднее, что
# именно уезжает в пакет, и не приходится гадать, чью библиотеку нашёл
# компоновщик. Порядок важен: libssl зависит от libcrypto.
KiraLegacy_LDFLAGS += $(SSL_OUT)/$(THEOS_CURRENT_ARCH)/openssl/lib/libssl.a
KiraLegacy_LDFLAGS += $(SSL_OUT)/$(THEOS_CURRENT_ARCH)/openssl/lib/libcrypto.a

# zlib — ею разворачиваются сжатые ответы серверов. В системе она есть
# с самого начала, приносить свою незачем.
KiraLegacy_LDFLAGS += -lz

KiraLegacy_LDFLAGS += -Wl,-U,_OBJC_CLASS_\$$_NSObject
KiraLegacy_LDFLAGS += -Wl,-U,_OBJC_METACLASS_\$$_NSObject

# Подпись: две сводки сразу, и это обязательно с обоих концов диапазона.
#
# ldid по умолчанию делает три вещи, и одна из них была ошибочно записана
# во вредные — та самая, без которой ничего не поставится на iOS 11.
#
# Вредны из них две: имя «KiraLegacy.<хеш>.unsigned» вместо имени пакета
# и снятый признак adhoc. Со снятым признаком система идёт искать
# удостоверяющую часть, которой в файле нет вовсе, и отказывает молча,
# до запуска процесса: ни падения, ни строки в журнале. Лечится это -I и
# -Cadhoc, и они здесь остаются.
#
# Третья — две сводки, SHA-1 и SHA-256, — не вредна ничем, и убирать её
# было ошибкой (в Трубаче стоит -Hsha1, и это его беда, не наша). Смысл
# у второй записи ровно обратный: SHA-1 в подписях Apple объявила негодной,
# и с iOS 11 подпись только по ней не принимается. Джейлбрейк тут не спасает:
# сводку разбирает amfid, а его подменяют, а не выключают.
#
# Уживаются они потому, что лежат в разных слотах, и придумано это как раз
# ради перехода:
#
#   слот 0x0000  основная запись, SHA-1     — её читают iOS 5…10
#   слот 0x1000  запасная запись, SHA-256   — её читают iOS 11 и новее
#
# Слот 0x1000 (CSSLOT_ALTERNATE_CODEDIRECTORY) старым системам неизвестен,
# и они его просто пропускают: iOS 5.1 видит ровно то же, что видела бы
# без него. Признак adhoc и имя проставлены в обеих записях — проверено
# разбором готового файла.
#
#   -Cadhoc  признак «подпись сама себе удостоверение» — то, чем она
#            и является;
#   -I…      имя, совпадающее с CFBundleIdentifier, — по нему система
#            сверяет подпись со связкой.
#
# Ключа -H здесь нет намеренно: он выбирает ровно одну сводку, а нужны обе.
# Что получилось, показывает tools/check-macho.py.
KiraLegacy_CODESIGN_FLAGS = -Cadhoc -Iru.computershik.kiralegacy -S

include $(THEOS_MAKE_PATH)/application.mk

# Права на файлы приложения.
#
# WSL выдаёт всему на диске Windows права 777, и chmod там ничего не меняет.
# Каталог сборки поэтому и уносится в файловую систему Linux — но права
# приезжают туда вместе с файлами, и в пакет уходило бы дерево, где и связка,
# и сам исполняемый файл открыты на запись всему миру.
#
# На iOS 5 и 6 это сходит с рук, дальше — нет: связку с правами 777
# LaunchServices не регистрирует, а исполняемый файл, доступный на запись
# кому угодно, система запускать отказывается. Отказ тихий — значка может
# и не появиться, а если появится, нажатие не даст ничего.
after-stage::
	@find $(THEOS_STAGING_DIR) -type d -exec chmod 755 {} +
	@find $(THEOS_STAGING_DIR) -type f -exec chmod 644 {} +
	@chmod 755 $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app/$(APPLICATION_NAME)

# То же самое для служебного каталога пакета, и отдельным шагом: layout/DEBIAN
# переносится сюда позже — уже при упаковке, — так что предыдущее правило
# его ещё не застаёт.
before-package::
	@chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN"
	@for script in preinst postinst prerm postrm; do \
		[ -f "$(THEOS_STAGING_DIR)/DEBIAN/$$script" ] && \
			chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/$$script"; \
	done; true
	@[ -f "$(THEOS_STAGING_DIR)/DEBIAN/control" ] && \
		chmod 644 "$(THEOS_STAGING_DIR)/DEBIAN/control"; true

# Payload/KiraLegacy.app в zip — то же дерево, что кладётся в .deb.
ipa:: package
	@rm -rf $(THEOS_STAGING_DIR)-ipa
	@mkdir -p $(THEOS_STAGING_DIR)-ipa/Payload
	@cp -r $(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app \
	       $(THEOS_STAGING_DIR)-ipa/Payload/
	@cd $(THEOS_STAGING_DIR)-ipa && zip -qry \
	       $(CURDIR)/packages/$(APPLICATION_NAME).ipa Payload
	@echo "packages/$(APPLICATION_NAME).ipa"
