#!/bin/sh
# Готовит машину к сборке KiraLegacy — с нуля и за один заход.
#
#     sh tools/setup.sh
#
# Запускать из корня проекта, внутри Ubuntu под WSL2. Скрипт идемпотентный:
# всё, что уже стоит, он пропускает, так что повторный запуск безопасен
# и годится, чтобы проверить окружение.
#
# Что делает по порядку:
#
#   1. доставляет пакеты Ubuntu, которых не хватает (нужен sudo);
#   2. ставит Theos в ~/theos, если его там нет;
#   3. качает тулчейн — clang, умеющий целиться в iOS;
#   4. кладёт iPhoneOS9.3.sdk рядом с остальными;
#   5. чинит в нём четыре места — без этого сборка либо не линкуется,
#      либо падает на устройстве до main (см. tools/patch-sdk.sh);
#   6. собирает OpenSSL двумя срезами (см. tools/build-openssl.sh).
#
# Последний шаг самый долгий — минут пять-десять. Пропустить его нельзя:
# Makefile линкует libssl.a и libcrypto.a напрямую, и без них сборка
# останавливается на компоновке.
set -e

THEOS="${THEOS:-$HOME/theos}"
SDK_NAME="iPhoneOS9.3.sdk"
SDK_PATH="$THEOS/sdks/$SDK_NAME"
SSL_OUT="${SSL_OUT:-$HOME/kiralegacy/out}"

say() { echo; echo "== $* =="; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# Корень проекта — от расположения самого скрипта, а не от текущего каталога:
# так `sh tools/setup.sh` и `sh /путь/к/tools/setup.sh` работают одинаково.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ -f "$ROOT/Makefile" ] || die "не похоже на корень KiraLegacy: нет Makefile"

case "$(uname -s)" in
	Linux) ;;
	*) die "нужен Linux (Ubuntu под WSL2), а здесь $(uname -s)" ;;
esac


# --- 1. Пакеты Ubuntu --------------------------------------------------------
#
# perl нужен не нам, а Configure у OpenSSL; zip — сборке .ipa; dpkg-deb —
# сборке .deb; python3 — проверкам и генератору значков.

say "Пакеты Ubuntu"

missing=""

for tool in git curl perl make python3 zip dpkg-deb xz; do
	command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done

if [ -n "$missing" ]; then
	echo "не хватает:$missing"

	command -v apt-get > /dev/null 2>&1 || die "поставьте вручную:$missing"

	echo "Ставлю через apt — понадобится пароль sudo…"
	sudo apt-get update
	sudo apt-get install -y build-essential fakeroot rsync curl perl git \
		libxml2 python3 python3-pil zip xz-utils dpkg-dev

	# libtinfo5 нужна тулчейну, но из свежих Ubuntu её выкинули. Ставим
	# по возможности и молча идём дальше: на новых выпусках clang обходится
	# библиотекой шестой версии.
	sudo apt-get install -y libtinfo5 2>/dev/null || true
else
	echo "всё на месте"
fi


# --- 2. Theos ----------------------------------------------------------------

say "Theos"

if [ -d "$THEOS/makefiles" ]; then
	echo "уже стоит: $THEOS"
else
	echo "Ставлю в $THEOS…"
	git clone --recursive https://github.com/theos/theos.git "$THEOS"
	echo "поставлен"
fi


# --- 3. Тулчейн --------------------------------------------------------------
#
# Он ставится отдельно и с клоном Theos не приезжает. Берём сборку без Swift:
# она вдвое меньше, а Swift в проекте нет ни строки.
#
# Официальный путь — `bash -c "$(curl -fsSL https://raw.githubusercontent.com/
# theos/theos/master/bin/install-theos)"`, но он задаёт вопросы, а нам нужно
# без участия человека.

say "Тулчейн (clang для iOS)"

if [ -x "$THEOS/toolchain/linux/iphone/bin/clang" ]; then
	echo "на месте: $($THEOS/toolchain/linux/iphone/bin/clang --version | head -1)"
else
	arch=$(uname -m)

	[ "$arch" = "x86_64" ] || [ "$arch" = "aarch64" ] ||
		die "готового тулчейна для $arch нет — см. https://theos.dev/docs/installation-linux"

	mkdir -p "$THEOS/toolchain"

	echo "Качаю (около 300 МБ)…"
	curl -fL --retry 3 \
		"https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-$arch.tar.xz" |
		tar -xJf - -C "$THEOS/toolchain" ||
		die "не скачался тулчейн — см. https://theos.dev/docs/installation-linux"

	# В разных выпусках каталог называется по-разному, а Theos ищет строго
	# toolchain/linux/iphone.
	if [ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]; then
		found=$(find "$THEOS/toolchain" -name clang -type f -perm -u+x | head -1)

		[ -n "$found" ] || die "clang не нашёлся в $THEOS/toolchain"

		mkdir -p "$THEOS/toolchain/linux"
		ln -sfn "$(dirname "$(dirname "$found")")" "$THEOS/toolchain/linux/iphone"
	fi

	"$THEOS/toolchain/linux/iphone/bin/clang" --version > /dev/null 2>&1 ||
		die "clang не запускается. Чаще всего не хватает libtinfo5"

	echo "поставлен"
fi


# --- 4. SDK ------------------------------------------------------------------
#
# Нужен именно 9.3, и это не прихоть: в новых SDK вырезаны заголовки эпохи
# iOS 5 (MPMoviePlayerController и прочее), а 9.3 — последний, где они живы
# и где при этом есть срез armv7.

say "SDK $SDK_NAME"

if [ -d "$SDK_PATH" ]; then
	echo "уже стоит: $SDK_PATH"
else
	mkdir -p "$THEOS/sdks"

	tmp=$(mktemp -d)

	# Разреженный клон: в наборе десятки SDK, а нужен один. Так вместо
	# нескольких гигабайт качается около двухсот мегабайт.
	echo "Качаю набор SDK (около 200 МБ)…"
	git clone --filter=blob:none --sparse --depth 1 \
		https://github.com/theos/sdks.git "$tmp/sdks"

	( cd "$tmp/sdks" && git sparse-checkout set "$SDK_NAME" )

	[ -d "$tmp/sdks/$SDK_NAME" ] || die "в наборе нет $SDK_NAME"

	cp -r "$tmp/sdks/$SDK_NAME" "$THEOS/sdks/"
	rm -rf "$tmp"

	echo "поставлен: $SDK_PATH"
fi


# --- 5. Заплатки к SDK -------------------------------------------------------

say "Заплатки к SDK"

THEOS="$THEOS" sh "$ROOT/tools/patch-sdk.sh"


# --- 6. OpenSSL --------------------------------------------------------------

say "OpenSSL"

if [ -f "$SSL_OUT/armv7/openssl/lib/libssl.a" ] &&
   [ -f "$SSL_OUT/arm64/openssl/lib/libssl.a" ]; then
	echo "уже собран: $SSL_OUT"
else
	echo "Собираю оба среза — это надолго, минут пять-десять…"
	THEOS="$THEOS" SSL_OUT="$SSL_OUT" sh "$ROOT/tools/build-openssl.sh"
fi


# --- Итог --------------------------------------------------------------------

say "Готово"

cat <<TEXT
Theos      $THEOS
тулчейн    $($THEOS/toolchain/linux/iphone/bin/clang --version | head -1)
SDK        $SDK_PATH
OpenSSL    $SSL_OUT

Дальше:

    make                          отладочная сборка
    make package ipa              .deb и .ipa в packages/
    python3 tools/check-macho.py packages/KiraLegacy.ipa

Если OpenSSL лежит не там, где ждёт Makefile, задайте путь явно:

    make SSL_OUT=$SSL_OUT
TEXT
