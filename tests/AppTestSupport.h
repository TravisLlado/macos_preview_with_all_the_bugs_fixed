#pragma once

// Helpers for tests that drive real AppKit objects.

#import <AppKit/AppKit.h>

#include "TestSupport.h"

namespace test {

// Sets up NSApplication once (no Dock icon, no run loop of its own).
inline void ensureApplication() {
    static bool done = false;
    if (!done) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        done = true;
    }
}

// Runs the main run loop (so main-queue blocks, timers and delayed performs
// fire) until `condition` returns true or `timeout` seconds pass.
inline bool runUntil(BOOL (^condition)(void), double timeout = 5.0) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        if ([deadline timeIntervalSinceNow] <= 0) {
            return false;
        }
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return true;
}

// Runs the main run loop for `seconds`.
inline void runFor(double seconds) {
    runUntil(^BOOL { return NO; }, seconds);
}

inline NSImage* makeNSImage(int w, int h) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(nullptr, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGImageRef cg = CGBitmapContextCreateImage(context);
    NSImage* image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(w, h)];
    CGImageRelease(cg);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

inline std::string str(NSString* s) {
    return s ? std::string(s.UTF8String) : std::string("(nil)");
}

inline bool nearlyEqual(double a, double b, double tolerance = 0.001) {
    return std::fabs(a - b) <= tolerance;
}

}  // namespace test
