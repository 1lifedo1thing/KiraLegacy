#!/bin/sh
# OpenSSL для iOS, по срезу на каждую архитектуру.
#
#     sh tools/build-openssl.sh
#     OPENSSL_VERSION=1.1.1w sh tools/build-openssl.sh
#
# Скрипт перенесён из Max-iOS (tools/build-openssl.sh), где он собирает
# ту же библиотеку для протокольного сокета. Отличий два: версия и нижняя
# граница — у нас 5.1, а не 6.0.
#
# Зачем своя криптография. Secure Transport на iOS 5 и 6 предлагает только
# наборы на CBC и SHA-1: ни AES-GCM, ни ChaCha20, ни TLS 1.3 там нет вовсе.
# Сегодня зеркала такие наборы ещё принимают — проверено, — но день, когда
# перестанут, назначаем не мы, и наступит он без предупреждения: сначала
# на одном хосте, потом на всех. Со своей библиотекой разговор с сервером
# выглядит так, как задали мы, а не так, как решил телефон 2011 года.
#
# Версия по умолчанию — 1.1.1w, и это выбор не от хорошей жизни.
#
# Сначала здесь стояла 3.5.4: ветка с долгой поддержкой, тогда как 1.1.1
# закончила жизнь в сентябре 2023 года. На устройстве она падала —
# EXC_BAD_ACCESS внутри собственной машинерии провайдеров, при разборе
# сертификата сервера:
#
#     SSL_connect -> tls_process_server_certificate -> ASN1_item_d2i
#       -> x509_pubkey_ex_d2i_ex -> OSSL_DECODER_CTX_new_for_pkey
#       -> EVP_KEYMGMT_do_all_provided -> ossl_method_store_do_all
#       -> ossl_sa_doall_arg          <- обращение по адресу 0x4b0
#
# Падало на iPad 2 с iOS 6.1.3, когда три потока впервые жали руки
# одновременно. На x86_64 с теми же ключами сборки не воспроизводится
# ни разу — то есть беда не в логике, а в том, как весь этот слой ложится
# на armv7 без ассемблера и с откатом на мьютексах вместо атомарных операций.
#
# В 1.1.1 этого слоя нет вовсе: открытый ключ разбирается простой таблицей
# методов, без OSSL_DECODER, провайдеров и реестров. То есть исчезает
# не симптом, а вся подсистема, в которой он возник. Ровно эта версия
# стоит и в Max-iOS, на таком же железе и с тем же тулчейном.
#
# Цена известна и записана в README: обновлений безопасности к 1.1.1 больше
# нет. Собрать 3.x можно одной переменной, если будет чем её вылечить:
#
#     OPENSSL_VERSION=3.5.4 sh tools/build-openssl.sh
#
# Результат кладётся в $SSL_OUT/<срез>/openssl, откуда его и берёт Makefile.
set -e

THEOS="${THEOS:-$HOME/theos}"
IOS_SDK="${IOS_SDK:-$THEOS/sdks/iPhoneOS9.3.sdk}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$THEOS/toolchain/linux/iphone/bin}"

# 5.1 — нижняя граница самого приложения. Библиотека обязана совпадать:
# если она соберётся с более высокой, приложение на iOS 5 просто не пойдёт.
IOS_MIN_VERSION="${IOS_MIN_VERSION:-5.1}"
IOS_ARCHS="${IOS_ARCHS:-armv7 arm64}"

OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"

WORK="${WORK:-$HOME/kiralegacy}"
DL_DIR="$WORK/dl"
BUILD_DIR="$WORK/build"
SSL_OUT="${SSL_OUT:-$WORK/out}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ -d "$THEOS" ]               || die "нет $THEOS"
[ -x "$TOOLCHAIN_BIN/clang" ] || die "нет $TOOLCHAIN_BIN/clang"
[ -d "$IOS_SDK" ]             || die "нет $IOS_SDK"

mkdir -p "$DL_DIR" "$BUILD_DIR"
tarball="$DL_DIR/openssl-$OPENSSL_VERSION.tar.gz"

# Метка выпуска у разных веток разная: до 3.0 это OpenSSL_1_1_1w,
# начиная с 3.0 — openssl-3.5.4.
case "$OPENSSL_VERSION" in
	1.*) tag="OpenSSL_$(echo "$OPENSSL_VERSION" | tr . _)" ;;
	*)   tag="openssl-$OPENSSL_VERSION" ;;
esac

if [ ! -f "$tarball" ] || ! gzip -t "$tarball" 2>/dev/null; then
	echo "== Качаю OpenSSL $OPENSSL_VERSION =="
	rm -f "$tarball"
	curl -fL --retry 3 -o "$tarball" \
		"https://github.com/openssl/openssl/releases/download/$tag/openssl-$OPENSSL_VERSION.tar.gz" ||
	curl -fL --retry 3 -o "$tarball" \
		"https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
	gzip -t "$tarball" || die "архив OpenSSL повреждён"
fi

# Правки к порождённому Makefile — две, и обе обязательны.
#
# 1. AR и RANLIB. Системные собраны под ELF и с форматом Mach-O не работают.
#
# 2. CNF_CFLAGS. Цели ios-cross и ios64-cross рассчитаны на Xcode
#    и дописывают в флаги вот это:
#
#      -arch armv7 -mios-version-min=5.1.0 -fno-common \
#      -isysroot $(CROSS_TOP)/SDKs/$(CROSS_SDK)
#
#    Обе переменные Configure ждёт из окружения и до make не доносит, так что
#    путь превращается в «-isysroot /SDKs/» и перекрывает наш, правильный:
#    сборка встаёт на первом же #include <stdio.h>. Оставляем от строки
#    только -fno-common: срез и граница приходят из -target
#    и -miphoneos-version-min в CC.
fix_makefile() {
	sed -i \
		-e "s|^AR=.*|AR=$TOOLCHAIN_BIN/ar|" \
		-e "s|^RANLIB=.*|RANLIB=$TOOLCHAIN_BIN/ranlib|" \
		-e "s|^CNF_CFLAGS=.*|CNF_CFLAGS=-fno-common|" \
		Makefile
}

# Ключи Configure — общие для обеих попыток.
#
#   no-shared      статикой — разделяемых библиотек в приложении iOS быть
#                  не может;
#   no-dso         динамическая загрузка модулей не нужна и не работает;
#   no-async       механизм асинхронных заданий использует контексты
#                  выполнения, на iOS от него одни неприятности;
#   no-ui-console  консольный ввод пароля на телефоне бессмыслен;
#   no-legacy      старый провайдер с MD2, RC5 и прочим нам не нужен (3.x).
CONF_OPTS="no-shared no-dso no-tests no-async no-engine no-ui-console
           no-comp no-ssl3 no-weak-ssl-ciphers"

case "$OPENSSL_VERSION" in
	3.*) CONF_OPTS="$CONF_OPTS no-legacy" ;;
esac

for arch in $IOS_ARCHS; do
	triple="$arch-apple-ios$IOS_MIN_VERSION"
	src="$BUILD_DIR/openssl-$arch"
	prefix="$SSL_OUT/$arch/openssl"

	# Цели разные для 32 и 64 бит: у них отличается модель данных
	# (ILP32 против LP64), и от этого зависит выбор реализации длинной
	# арифметики — самой горячей части всей библиотеки.
	case "$arch" in
		armv7) target=ios-cross ;;
		arm64) target=ios64-cross ;;
		*)     die "неизвестный срез $arch" ;;
	esac

	echo
	echo "=============================================================="
	echo "  OpenSSL $OPENSSL_VERSION -> $arch ($triple, $target)"
	echo "=============================================================="

	rm -rf "$src"
	tar xzf "$tarball" -C "$BUILD_DIR"
	mv "$BUILD_DIR/openssl-$OPENSSL_VERSION" "$src"
	cd "$src"

	CC_LINE="$TOOLCHAIN_BIN/clang -target $triple -isysroot $IOS_SDK -miphoneos-version-min=$IOS_MIN_VERSION"

	# У armv7 нет 64-битных атомарных операций в железе, и clang для них
	# зовёт подпрограммы времени выполнения (__atomic_is_lock_free и
	# соседние). В SDK для iOS их нет, и сборка встаёт на компоновке
	# приложения — то есть много позже, когда библиотека уже «готова».
	#
	# BROKEN_CLANG_ATOMICS — выключатель самого OpenSSL ровно для таких
	# случаев: вместо встроенных операций берётся откат на мьютексах.
	# Он медленнее, но счётчики ссылок — не то место, где это заметно.
	case "$arch" in
		armv7) CC_LINE="$CC_LINE -DBROKEN_CLANG_ATOMICS" ;;
	esac

	# CC передаётся целиком, вместе с тройкой и SDK: цели ios*-cross
	# рассчитаны на Xcode, который сам знает, где что лежит.
	CC="$CC_LINE" CROSS_COMPILE="" \
	./Configure "$target" $CONF_OPTS \
		--prefix="$prefix" --openssldir="$prefix/ssl" \
		> "$WORK/openssl-$arch-configure.log" 2>&1 ||
		{ tail -20 "$WORK/openssl-$arch-configure.log"; die "Configure ($arch)"; }

	fix_makefile

	echo "-- собираю (лог: $WORK/openssl-$arch-make.log)"
	if ! make -j"$(nproc)" build_libs > "$WORK/openssl-$arch-make.log" 2>&1; then
		# Ассемблерные вставки — самая частая причина отказа при сборке
		# чужим тулчейном. Без них AES на arm64 теряет аппаратное ускорение,
		# поэтому сначала пробуем с ними и только потом отступаем.
		echo "-- не собралось с ассемблером, повторяю с no-asm"
		make clean > /dev/null 2>&1 || true
		CC="$CC_LINE" CROSS_COMPILE="" \
		./Configure "$target" no-asm $CONF_OPTS \
			--prefix="$prefix" --openssldir="$prefix/ssl" \
			>> "$WORK/openssl-$arch-configure.log" 2>&1
		fix_makefile
		make -j"$(nproc)" build_libs > "$WORK/openssl-$arch-make.log" 2>&1 ||
			{ tail -30 "$WORK/openssl-$arch-make.log"; die "make ($arch)"; }
	fi

	mkdir -p "$prefix/lib" "$prefix/include"
	cp libcrypto.a libssl.a "$prefix/lib/"
	rm -rf "$prefix/include/openssl"
	cp -r include/openssl "$prefix/include/openssl"

	echo "-- готово: $prefix"

	# Нижняя граница проверяется прямо в собранном файле, и это не
	# перестраховка: ровно здесь Configure и пытался подсунуть свою.
	minver=$("$TOOLCHAIN_BIN/otool" -l "$prefix/lib/libssl.a" 2>/dev/null |
	         grep -A2 LC_VERSION_MIN_IPHONEOS | grep -m1 version | awk '{print $2}')
	echo "-- нижняя граница в библиотеке: ${minver:-не определилась}"
	if [ -n "$minver" ] && [ "$minver" != "$IOS_MIN_VERSION" ]; then
		die "в библиотеке граница $minver, а должна быть $IOS_MIN_VERSION"
	fi
done

echo
echo "OpenSSL $OPENSSL_VERSION собран для: $IOS_ARCHS"
echo "Путь для Makefile:  SSL_OUT=$SSL_OUT"
