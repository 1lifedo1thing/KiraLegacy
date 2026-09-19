#import "KLSource.h"

#import "KLStrings.h"

@implementation KLSubtitleTrack
@end


@implementation KLSource

- (NSString *)kindText {
    return KLStr([[_kind lowercaseString] isEqualToString:@"dub"]
        ? @"source.dub" : @"source.sub");
}

- (NSString *)displayName {
    if ([_label length] == 0) {
        return [self kindText];
    }

    return [NSString stringWithFormat:@"%@ · %@", _label, [self kindText]];
}

@end
