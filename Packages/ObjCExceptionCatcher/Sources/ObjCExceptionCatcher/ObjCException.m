#import "ObjCException.h"

NSErrorDomain const ObjCExceptionErrorDomain = @"io.island.mila.ObjCException";
NSString * const ObjCExceptionNameKey = @"ObjCExceptionName";

static NSError *ObjCExceptionError(NSException *exception) {
    return [NSError errorWithDomain:ObjCExceptionErrorDomain
                               code:0
                           userInfo:@{
        NSLocalizedDescriptionKey: exception.reason ?: exception.name,
        ObjCExceptionNameKey: exception.name,
    }];
}

@implementation ObjCException

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = ObjCExceptionError(exception);
        }
        return NO;
    }
}

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError **)error {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = ObjCExceptionError(exception);
        }
        return NO;
    }
}

@end
