#import "KLSubtitles.h"

#import "KLHttp.h"

@implementation KLSubtitleCue
@end


/**
 * Время вида 00:01:02.500 либо 01:02.500 — в секунды.
 *
 * Часы необязательны, и это не редкость: короткие серии зеркала подписывают
 * без них. Разделителем дробной части бывает и точка, и запятая — второе
 * это уже SRT, но такие файлы среди .vtt тоже попадаются.
 */
static NSTimeInterval KLParseTime(NSString *value) {
    NSString *clean = [[value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]]
        stringByReplacingOccurrencesOfString:@"," withString:@"."];

    NSArray *parts = [clean componentsSeparatedByString:@":"];

    if ([parts count] < 2 || [parts count] > 3) {
        return -1;
    }

    NSTimeInterval seconds = 0;

    for (NSString *part in parts) {
        seconds = seconds * 60 + [part doubleValue];
    }

    return seconds;
}

/** Снимает разметку внутри реплики: <i>, <b>, <c.colorE5E5E5> и подобное. */
static NSString *KLStripCueMarkup(NSString *text) {
    NSMutableString *clean = [NSMutableString stringWithString:text];

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
        @"&", @"&amp;", @"<", @"&lt;", @">", @"&gt;",
        @"\"", @"&quot;", @"'", @"&#39;", @" ", @"&nbsp;", nil];

    for (NSString *entity in entities) {
        [clean replaceOccurrencesOfString:entity
                               withString:[entities objectForKey:entity]
                                  options:0
                                    range:NSMakeRange(0, [clean length])];
    }

    return [clean stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@implementation KLSubtitles {
    NSArray *_cues;
}

+ (KLSubtitles *)load:(NSString *)url referer:(NSString *)referer {
    if ([url length] == 0) {
        return nil;
    }

    NSMutableURLRequest *request =
        KLRequest(url, NSURLRequestUseProtocolCachePolicy, 20.0);

    if (request == nil) {
        return nil;
    }

    if (referer != nil) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }

    // Потолок на всякий случай: файл субтитров это десятки килобайт,
    // и мегабайт здесь означал бы, что пришло что-то не то.
    KLHttpResponse *response = [KLHttp send:request bodyLimit:2 * 1024 * 1024];

    if (![response isSuccessful]) {
        NSLog(@"[Кира/Субтитры] %@ → HTTP %ld", url, (long)response.statusCode);
        return nil;
    }

    KLSubtitles *subtitles = [self parse:[response text]];

    NSLog(@"[Кира/Субтитры] Реплик разобрано: %lu", (unsigned long)[subtitles count]);

    return [subtitles count] > 0 ? subtitles : nil;
}

+ (KLSubtitles *)parse:(NSString *)text {
    if ([text length] == 0) {
        return nil;
    }

    KLSubtitles *result = [[KLSubtitles alloc] init];

    NSMutableArray *cues = [NSMutableArray array];

    // Переводы строк приводим к одному виду: файлы приходят и с \r\n.
    NSString *normal = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSArray *lines = [normal componentsSeparatedByString:@"\n"];

    KLSubtitleCue *current = nil;
    NSMutableArray *body = nil;

    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];

        NSRange arrow = [line rangeOfString:@"-->"];

        if (arrow.location != NSNotFound) {
            // Началась новая реплика — предыдущую закрываем.
            if (current != nil && [body count] > 0) {
                current.text = [body componentsJoinedByString:@"\n"];
                [cues addObject:current];
            }

            NSString *from = [line substringToIndex:arrow.location];
            NSString *to = [line substringFromIndex:arrow.location + arrow.length];

            /**
             * После времени конца бывают настройки положения:
             * «00:00:13.000 align:start position:10%». Отрезаем по первому
             * пробелу — всё, что за ним, нас не касается.
             */
            NSRange space = [[to stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]] rangeOfString:@" "];

            NSString *cleanTo = [to stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];

            if (space.location != NSNotFound) {
                cleanTo = [cleanTo substringToIndex:space.location];
            }

            NSTimeInterval start = KLParseTime(from);
            NSTimeInterval end = KLParseTime(cleanTo);

            current = nil;
            body = nil;

            if (start >= 0 && end > start) {
                current = [[KLSubtitleCue alloc] init];

                current.start = start;
                current.end = end;

                body = [NSMutableArray array];
            }

            continue;
        }

        if (current == nil) {
            continue;
        }

        if ([line length] == 0) {
            // Пустая строка закрывает реплику.
            if ([body count] > 0) {
                current.text = [body componentsJoinedByString:@"\n"];
                [cues addObject:current];
            }

            current = nil;
            body = nil;

            continue;
        }

        NSString *clean = KLStripCueMarkup(line);

        if ([clean length] > 0) {
            [body addObject:clean];
        }
    }

    if (current != nil && [body count] > 0) {
        current.text = [body componentsJoinedByString:@"\n"];
        [cues addObject:current];
    }

    // Порядок в файле обычно и так по времени, но полагаться на это нельзя:
    // двоичный поиск ниже требует отсортированного списка.
    [cues sortUsingComparator:^NSComparisonResult(KLSubtitleCue *a, KLSubtitleCue *b) {
        if (a.start < b.start) return NSOrderedAscending;
        if (a.start > b.start) return NSOrderedDescending;

        return NSOrderedSame;
    }];

    result->_cues = [cues copy];

    return result;
}

- (NSUInteger)count {
    return [_cues count];
}

- (NSString *)textAt:(NSTimeInterval)time {
    NSUInteger low = 0;
    NSUInteger high = [_cues count];

    /**
     * Ищем последнюю реплику, начавшуюся не позже текущей секунды.
     *
     * Тип у элемента указан явно, и это обязательно: objectAtIndex: отдаёт
     * id, а селектор start знает не только наша реплика — у NSThread он
     * тоже есть и ничего не возвращает. Компилятор в таком случае берётся
     * гадать и выбирает не тот.
     */
    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        KLSubtitleCue *probe = [_cues objectAtIndex:mid];

        if (probe.start <= time) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (low == 0) {
        return nil;
    }

    KLSubtitleCue *cue = [_cues objectAtIndex:low - 1];

    /**
     * Найденная реплика могла уже закончиться — тогда сейчас молчат.
     *
     * Соседнюю проверять незачем: реплики в этих файлах не накладываются
     * друг на друга, и если ближайшая слева кончилась, то следующая
     * ещё не начиналась.
     */
    return time <= cue.end ? cue.text : nil;
}

@end
