#import "ObjCException.h"

NSErrorDomain const ObjCExceptionErrorDomain = @"io.island.mila.ObjCException";
NSString * const ObjCExceptionNameKey = @"ObjCExceptionName";

@implementation ObjCException

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:ObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                ObjCExceptionNameKey: exception.name,
            }];
        }
        return NO;
    }
}

@end
