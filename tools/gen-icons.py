# -*- coding: utf-8 -*-
"""
Собирает значок KiraLegacy и экраны запуска из кадра исходного видео.

Откуда картинка. Значок — не рисунок этого скрипта, а кадр из видео автора
приложения: стилизованный аниме-персонаж с «лоскутным» лицом, у которого один
глаз белый, а второй алый. Взят кадр 184 (3,07 с) — середина статичного плана,
где нет глитча, и вырезан алый глаз.

Почему именно алый глаз. Имя работает сразу в две стороны. По-японски «кира»
(キラ) — это блеск, звук вспышки: «кира-кира» говорят о блестящем, и в манге
этим словом подписывают блик. А «Кира» с большой буквы — самый известный
псевдоним во всём аниме, и глаза у его носителя в решающие минуты красные.
Кадр попал в оба смысла разом, и придумывать поверх него нечего.

Исходники лежат рядом, чтобы значок пересобирался без самого видео (83 МБ):

    tools/icon-eye.png      320×320, вырез вокруг глаза, родное разрешение
    tools/launch-frame.png  2560×1440, кадр целиком — для экранов запуска

Что здесь есть и чего нет.

Рисованного не осталось ничего. Прежний значок собирался кривыми Безье, и весь
тот код убран; убрана и четырёхлучевая вспышка «кира», которая какое-то время
держалась на экране запуска. Кадр самодостаточен, и всё, что кладётся поверх
него, читается как наклейка.

Осталось три действия: раскладка по размерам, кадрирование под пропорцию
экрана и виньетка.

Значок идёт в край, без подложки. Подложка была нужна рисованному глазу,
у которого фон прозрачный; у кадра фон свой, и любая рамка поверх него
читается как кант, будто картинка не влезла. Углы всё равно обрезает сама
система, поэтому и скругления здесь нет — иначе вышел бы двойной радиус.

    python tools/gen-icons.py
"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Resources")
TOOLS = os.path.join(ROOT, "tools")

ICON_SOURCE = os.path.join(TOOLS, "icon-eye.png")
LAUNCH_SOURCE = os.path.join(TOOLS, "launch-frame.png")

# Размеры, объявленные в CFBundleIconFiles.
#
# Они не по плотностям экрана, а по устройствам: 57 и 114 — iPhone до iOS 7,
# 120 — iPhone с iOS 7, 72 и 144 — iPad, 76 и 152 — iPad с iOS 7,
# 180 — iPhone Plus.
SIZES = [57, 72, 76, 114, 120, 144, 152, 180]

# Экраны запуска.
#
# Это не украшение: по наличию картинки нужного размера iOS решает, умеет ли
# приложение работать на этом экране. Без Default-568h@2x на iPhone 5 оно
# запускается в режиме 320x480 — с чёрными полосами сверху и снизу. На
# iPhone 4 полос не было просто потому, что там экран и есть 320x480.
#
# У планшета картинок две: iOS считает объявленной ту ориентацию, для которой
# картинка есть. Без Default-Landscape~ipad планшет, лежащий набок, — это
# ровно тот же случай, что iPhone 5 без Default-568h@2x.
LAUNCH = [
    ("Default.png", 320, 480),                     # 3,5 дюйма, без ретины
    ("Default@2x.png", 640, 960),                  # iPhone 4 и 4S
    ("Default-568h@2x.png", 640, 1136),            # iPhone 5, 5s, SE
    ("Default-667h@2x.png", 750, 1334),            # iPhone 6, 7, 8, SE 2 и 3
    ("Default-736h@3x.png", 1242, 2208),           # iPhone 6 Plus и до 8 Plus
    ("Default-Portrait~ipad.png", 768, 1024),      # iPad 1, 2, mini 1
    ("Default-Portrait@2x~ipad.png", 1536, 2048),  # iPad с ретиной, mini 2+
    ("Default-Landscape~ipad.png", 1024, 768),
    ("Default-Landscape@2x~ipad.png", 2048, 1536),
    # iPad Pro. Имя здесь без слова про положение: система дописывает
    # «-Portrait» и «-Landscape» сама, по записи в UILaunchImages.
    ("Default-1112h-Portrait@2x~ipad.png", 1668, 2224),   # iPad Pro 10,5″
    ("Default-1112h-Landscape@2x~ipad.png", 2224, 1668),
    ("Default-1366h-Portrait@2x~ipad.png", 2048, 2732),   # iPad Pro 12,9″
    ("Default-1366h-Landscape@2x~ipad.png", 2732, 2048),
]

# Докуда вообще достаёт этот список.
#
# Картинки запуска — механизм своего времени, и заканчивается он на
# iPhone 8 Plus. Для iPhone X и всего, что после, Apple их не читает вовсе:
# там нужен LaunchScreen.storyboard, а storyboard — это скомпилированный
# .storyboardc, который собирается только ibtool на macOS. Из-под WSL его
# не сделать.
#
# Без него на iPhone X и новее приложение запускается в совместимом режиме:
# кадр берётся 750×1334 (от iPhone 8) и показывается с чёрными полосами
# сверху и снизу. Само приложение при этом работает как обычно — вся
# раскладка считается от bounds, а не от списка размеров.


# Где в кадре лицо, долями от стороны.
#
# По горизонтали оно ровно посередине, по вертикали — заметно выше центра:
# кадр взят по пояс, и нижняя треть занята чёрной водолазкой. При обрезке
# под узкий экран середину надо брать по лицу, иначе голова уезжает за
# верхний край.
FACE = (0.50, 0.37)


def crop_to_aspect(image, width, height, focus=FACE):
    """
    Наибольший кусок кадра нужной пропорции, поставленный по лицу.

    Обрезается всегда только одна сторона — та, которой в исходнике больше
    относительно нужной пропорции. Вторая берётся целиком: подрезать обе
    значило бы терять пиксели ни за что.
    """
    src_w, src_h = image.size

    if src_w / src_h > width / height:
        box_h = src_h
        box_w = int(round(src_h * width / height))
    else:
        box_w = src_w
        box_h = int(round(src_w * height / width))

    # Середину двигаем к лицу, но не даём выйти за край кадра.
    left = int(round(src_w * focus[0] - box_w / 2))
    top = int(round(src_h * focus[1] - box_h / 2))

    left = max(0, min(left, src_w - box_w))
    top = max(0, min(top, src_h - box_h))

    return image.crop((left, top, left + box_w, top + box_h))


def vignette(image, focus=FACE, spread=0.54, softness=0.30):
    """
    Уводит края в чёрное.

    Нужно ради перехода: первый экран приложения чёрный, и заставка,
    светлая до самого края, сменялась бы им рывком. С растворением в чёрное
    переход выходит незаметным, а лицо остаётся таким же ярким, как в кадре.
    """
    width, height = image.size

    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)

    cx = width * focus[0]
    cy = height * focus[1]
    rx = width * spread
    ry = height * spread

    draw.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=255)

    mask = mask.filter(ImageFilter.GaussianBlur(min(width, height) * softness))

    return Image.composite(image, Image.new("RGB", (width, height), (0, 0, 0)), mask)


def write_icons():
    """
    Значок — вырез в край, без подложки.

    Уменьшение всегда из родного разрешения выреза (320×320), а не ступенями:
    каждое промежуточное уменьшение — ещё одно усреднение пикселей, и после
    двух-трёх шагов ресницы превращаются в кашу. LANCZOS за один шаг
    справляется заметно лучше.
    """
    source = Image.open(ICON_SOURCE).convert("RGB")

    for size in SIZES:
        path = os.path.join(RESOURCES, "Icon-%d.png" % size)

        source.resize((size, size), Image.LANCZOS).save(path)

        print("Icon-%d.png" % size)


def write_launch():
    """
    Экран запуска — кадр целиком, с растворением краёв в чёрное.

    Сохраняется палитрой в 256 цветов, и это не жадность. Тринадцать картинок
    в полном цвете весят около тринадцати мегабайт — вся связка в четырнадцать,
    то есть почти весь пакет это заставки, из которых на устройстве
    показывается ровно одна. Палитра ужимает их втрое.

    Опасное место здесь одно — растворение в чёрное: на плавном градиенте
    палитра обычно даёт полосы. Их нет: рисунок плоский, оттенков в нём мало,
    и все 256 ячеек уходят на сам градиент, а остатки прячет размывание
    (PIL применяет его сам). Сравнение самого тёмного участка до и после
    отличий не показало.
    """
    source = Image.open(LAUNCH_SOURCE).convert("RGB")

    for name, width, height in LAUNCH:
        image = crop_to_aspect(source, width, height).resize(
            (width, height), Image.LANCZOS)

        image = vignette(image).convert("P", palette=Image.ADAPTIVE, colors=256)

        image.save(os.path.join(RESOURCES, name), optimize=True)

        print(name)


if __name__ == "__main__":
    for path in (ICON_SOURCE, LAUNCH_SOURCE):
        if not os.path.exists(path):
            raise SystemExit("Нет исходника %s — см. описание вверху файла" % path)

    if not os.path.isdir(RESOURCES):
        os.makedirs(RESOURCES)

    write_icons()
    write_launch()
