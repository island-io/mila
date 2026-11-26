#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for an `NSException` caught by `+[ObjCException catching:error:]`.
FOUNDATION_EXPORT NSErrorDomain const ObjCExceptionErrorDomain;

/// `userInfo` key holding the caught exception's `name` (an `NSString`).
/// The exception's `reason` is the error's `localizedDescription`.
FOUNDATION_EXPORT NSString * const ObjCExceptionNameKey;

@interface ObjCException : NSObject

/// Runs `block`, converting an `NSException` it raises into an `NSError`
/// instead of letting it unwind into Swift (where it terminates the
/// process). Imported into Swift as `try ObjCException.catching { … }`.
///
/// Only for framework calls documented or observed to raise on a runtime
/// condition the caller can recover from — not a general crash suppressor.
/// State the raising call left half-done is the caller's to discard.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block
           error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(catching(_:));

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
