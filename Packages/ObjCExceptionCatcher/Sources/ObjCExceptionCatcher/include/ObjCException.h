#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

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
///
/// Called from Swift, `block` is a Swift closure, and the raise unwinds
/// THROUGH its frame to reach the `@catch`. Swift emits no cleanups for that
/// path, so whatever the closure was holding at the raise is never released —
/// a Swift closure it bridged to a block argument of the raising call, in
/// particular (#427). Use this only for closures that own nothing at that
/// moment; a call that takes an object argument gets its own wrapper here
/// that makes the call from Objective-C, as `installTap` below does.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block
           error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(catching(_:));

/// `-[AVAudioNode installTapOnBus:bufferSize:format:block:]`, with the
/// `NSException` it raises turned into an `NSError` (domain and keys as for
/// `catching:`). It raises when `format` no longer matches the hardware —
/// Bluetooth headphones switching to their call profile mid-bring-up (#385).
/// Nothing is installed when it fails.
///
/// The call is made here rather than in a Swift closure handed to
/// `catching:` so that no Swift frame sits between the raise and the
/// `@catch`: the caller bridges its tap closure to a block in a frame that
/// returns normally, so a refused tap no longer strands the caller's
/// reference to it (#427).
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(nullable AVAudioFormat *)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(installTap(on:bus:bufferSize:format:block:));

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
