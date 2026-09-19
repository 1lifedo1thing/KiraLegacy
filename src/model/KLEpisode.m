#import "KLEpisode.h"

#import "KLStrings.h"

#import "KLJson.h"

@implementation KLEpisode

+ (KLEpisode *)fromJson:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    KLEpisode *episode = [[KLEpisode alloc] init];

    episode.number = [KLJson intIn:json key:@"number"];
    if (episode.number <= 0) {
        return nil;
    }

    episode.seasonNumber = [KLJson intIn:json key:@"seasonNumber"];
    episode.seasonName = [KLJson textIn:json key:@"seasonName"];

    // Английское название, если оно есть; иначе romaji, иначе японское.
    // Порядок тот же, что у самого тайтла: латиница читается всегда,
    // а кандзи на старом устройстве нет-нет да и окажется без шрифта.
    episode.title = [KLJson textIn:json key:@"title"]
                    ?: ([KLJson textIn:json key:@"titleRomaji"]
                        ?: [KLJson textIn:json key:@"titleNative"]);

    episode.overview = [KLJson textIn:json key:@"description"];
    episode.imageUrl = [KLJson textIn:json key:@"image"];

    return episode;
}

- (NSString *)displayTitle {
    if ([_title length] == 0) {
        return KLFmt(@"episode.number", (long)_number);
    }

    return KLFmt(@"episode.number.title", (long)_number, _title);
}

@end
