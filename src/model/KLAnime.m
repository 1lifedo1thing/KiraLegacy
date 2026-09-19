#import "KLAnime.h"

#import "KLStrings.h"

#import "KLJson.h"

@implementation KLCastMember
@end


/**
 * Убирает разметку из описания.
 *
 * AniList отдаёт description(asHtml:false), но «без HTML» у него означает
 * только то, что абзацы разделены переносами: <br>, <i> и <b> внутри текста
 * остаются, а вместе с ними попадаются &quot; и &mdash;. UIWebView ради
 * трёх тегов заводить незачем, поэтому чистим руками.
 */
static NSString *KLStripMarkup(NSString *text) {
    if ([text length] == 0) {
        return nil;
    }

    NSMutableString *clean = [NSMutableString stringWithString:text];

    // Перевод строки у <br> сохраняем: без него абзацы слипаются в полотно.
    NSArray *breaks = [NSArray arrayWithObjects:@"<br>", @"<br/>", @"<br />", nil];
    for (NSString *tag in breaks) {
        [clean replaceOccurrencesOfString:tag
                               withString:@"\n"
                                  options:NSCaseInsensitiveSearch
                                    range:NSMakeRange(0, [clean length])];
    }

    // Остальные теги — вырезаем целиком вместе с содержимым угловых скобок.
    while (YES) {
        NSRange open = [clean rangeOfString:@"<"];
        if (open.location == NSNotFound) {
            break;
        }

        NSRange tail = NSMakeRange(open.location, [clean length] - open.location);
        NSRange close = [clean rangeOfString:@">" options:0 range:tail];

        if (close.location == NSNotFound) {
            break;
        }

        [clean deleteCharactersInRange:
            NSMakeRange(open.location, close.location - open.location + 1)];
    }

    NSDictionary *entities = [NSDictionary dictionaryWithObjectsAndKeys:
        @"&", @"&amp;", @"\"", @"&quot;", @"'", @"&#39;", @"'", @"&apos;",
        @"<", @"&lt;", @">", @"&gt;", @"—", @"&mdash;", @"–", @"&ndash;",
        @" ", @"&nbsp;", nil];

    for (NSString *entity in entities) {
        [clean replaceOccurrencesOfString:entity
                               withString:[entities objectForKey:entity]
                                  options:0
                                    range:NSMakeRange(0, [clean length])];
    }

    NSString *result = [clean stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return [result length] > 0 ? result : nil;
}

@implementation KLAnime

+ (KLAnime *)fromJson:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    KLAnime *anime = [[KLAnime alloc] init];

    anime.anilistId = [KLJson intIn:json key:@"id"];
    if (anime.anilistId <= 0) {
        return nil;
    }

    anime.malId = [KLJson intIn:json key:@"idMal"];

    NSDictionary *title = [KLJson objectIn:json key:@"title"];

    anime.romajiTitle = [KLJson textIn:title key:@"romaji"];
    anime.title = [KLJson textIn:title key:@"english"]
                  ?: (anime.romajiTitle ?: KLStr(@"anime.untitled"));

    NSDictionary *cover = [KLJson objectIn:json key:@"coverImage"];

    // extraLarge просим не всегда, поэтому спуск по ступеням: сначала самое
    // крупное из присланного, потом что есть.
    anime.coverUrl = [KLJson textIn:cover key:@"extraLarge"]
                     ?: ([KLJson textIn:cover key:@"large"]
                         ?: [KLJson textIn:cover key:@"medium"]);

    anime.bannerUrl = [KLJson textIn:json key:@"bannerImage"];

    anime.score = [KLJson intIn:json key:@"averageScore"];
    anime.episodeCount = [KLJson intIn:json key:@"episodes"];
    anime.format = [KLJson textIn:json key:@"format"];
    anime.duration = [KLJson intIn:json key:@"duration"];
    anime.status = [KLJson textIn:json key:@"status"];

    NSDictionary *start = [KLJson objectIn:json key:@"startDate"];
    anime.year = [KLJson intIn:start key:@"year"];

    // Жанры у AniList всегда английские — мы их и показываем как есть:
    // переводить два десятка слов вручную значило бы завести словарь,
    // который разойдётся с источником при первом же новом жанре.
    anime.genres = [KLJson arrayIn:json key:@"genres"] ?: [NSArray array];

    anime.synopsis = KLStripMarkup([KLJson textIn:json key:@"description"]);

    NSDictionary *next = [KLJson objectIn:json key:@"nextAiringEpisode"];
    anime.nextEpisode = [KLJson intIn:next key:@"episode"];
    anime.nextEpisodeIn = [KLJson intIn:next key:@"timeUntilAiring"];

    anime.cast = [self castFrom:[KLJson objectIn:json key:@"characters"]];

    return anime;
}

+ (NSArray *)castFrom:(NSDictionary *)characters {
    NSArray *edges = [KLJson arrayIn:characters key:@"edges"];
    if ([edges count] == 0) {
        return [NSArray array];
    }

    NSMutableArray *cast = [NSMutableArray array];

    for (NSUInteger i = 0; i < [edges count]; i++) {
        NSDictionary *edge = [KLJson objectAt:edges index:i];
        NSDictionary *node = [KLJson objectIn:edge key:@"node"];

        NSString *name = [KLJson textIn:[KLJson objectIn:node key:@"name"] key:@"full"];
        if (name == nil) {
            continue;
        }

        KLCastMember *member = [[KLCastMember alloc] init];

        member.name = name;
        member.imageUrl = [KLJson textIn:[KLJson objectIn:node key:@"image"] key:@"large"];
        member.role = [KLJson textIn:edge key:@"role"];

        // Актёров может не быть вовсе — у второстепенных персонажей это
        // обычное дело, и ряд от этого просто становится в одну строку.
        NSArray *actors = [KLJson arrayIn:edge key:@"voiceActors"];
        NSDictionary *first = [KLJson objectAt:actors index:0];

        member.actor = [KLJson textIn:[KLJson objectIn:first key:@"name"] key:@"full"];

        [cast addObject:member];
    }

    return cast;
}

- (NSString *)scoreText {
    if (_score <= 0) {
        return nil;
    }

    return [NSString stringWithFormat:@"%.1f", _score / 10.0];
}

- (NSString *)metaText {
    NSMutableArray *parts = [NSMutableArray array];

    if ([_format length] > 0) {
        // Полнометражку зовём по-русски, остальные обозначения оставляем
        // как есть: TV, OVA и ONA узнаются и без перевода.
        [parts addObject:[_format isEqualToString:@"MOVIE"] ? KLStr(@"anime.movie") : _format];
    }

    if (_year > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld", (long)_year]];
    }

    /**
     * Число серий пишется через двоеточие, а не согласованием.
     *
     * «12 серий», «2 серии», «1 серия» — правило это русское, и в каждом
     * языке оно своё: в польском три формы, в арабском шесть, в японском
     * ни одной. Держать в переводах по три ключа на каждую такую строку
     * значило бы половину работы отдать грамматике. «Серий: 12» одинаково
     * верно при любом числе и переводится одной строкой.
     */
    if (_episodeCount > 0) {
        [parts addObject:KLFmt(@"anime.episodes", (long)_episodeCount)];
    }

    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)genresText {
    if ([_genres count] == 0) {
        return @"";
    }

    NSArray *shown = [_genres count] > 3
        ? [_genres subarrayWithRange:NSMakeRange(0, 3)]
        : _genres;

    return [shown componentsJoinedByString:@" · "];
}

@end
