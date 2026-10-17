/*
 * A declaration-only XCTest shim.
 *
 * It exists so `Scripts/check-tests.sh` can type-check the XCTest suite on a
 * machine that has the Command Line Tools instead of a full Xcode installation:
 * XCTest is part of Xcode, and a test suite that has never been type-checked is
 * worse than no test suite. Nothing here is linked or run — the real framework is
 * used by `swift test` and by the Xcode test plan.
 */
#ifndef SIFT_XCTEST_SHIM_H
#define SIFT_XCTEST_SHIM_H

#import <Foundation/Foundation.h>

@interface XCTestCase : NSObject
- (void)setUp;
- (void)tearDown;
@end

@interface XCTestExpectation : NSObject
@end

typedef void (^XCTestErrorHandler)(NSError *error);

#endif
