#import "BrightnessControl.h"
#import "KeyboardManager.h"

@implementation BrightnessControl

// The built-in keyboard's backlight ID (usually 1). Looked up once from
// CoreBrightness instead of being hard-coded.
+ (unsigned long long)keyboardID {
    static unsigned long long cached = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = 1;
        KeyboardBrightnessClient *client = KeyboardManager.brightnessClient;
        if (![client respondsToSelector:@selector(copyKeyboardBacklightIDs)]) return;
        id ids = [client copyKeyboardBacklightIDs];
        if (![ids isKindOfClass:[NSArray class]] || [ids count] == 0) return;
        if (![[ids firstObject] isKindOfClass:[NSNumber class]]) return;
        cached = [[ids firstObject] unsignedLongLongValue];
        if ([client respondsToSelector:@selector(isKeyboardBuiltIn:)]) {
            for (id kbd in ids) {
                if (![kbd isKindOfClass:[NSNumber class]]) continue;
                if ([client isKeyboardBuiltIn:[kbd unsignedLongLongValue]]) {
                    cached = [kbd unsignedLongLongValue];
                    break;
                }
            }
        }
    });
    return cached;
}

+ (void)setBrightness:(float)brightness {
    [KeyboardManager.brightnessClient setBrightness:brightness forKeyboard:[self keyboardID]];
}

+ (float)getBrightness {
    return [KeyboardManager.brightnessClient brightnessForKeyboard:[self keyboardID]];
}

+ (bool)isAutoBrightnessEnabled {
    return [KeyboardManager.brightnessClient isAutoBrightnessEnabledForKeyboard:[self keyboardID]];
}

+ (bool)isIdleDimmingSuspended {
    return [KeyboardManager.brightnessClient isIdleDimmingSuspendedOnKeyboard:[self keyboardID]];
}

+ (void)setSuspendIdleDimming:(bool)value {
    [KeyboardManager.brightnessClient suspendIdleDimming:value forKeyboard:[self keyboardID]];
}

+ (void)setIdleDimTime:(double)value {
    [KeyboardManager.brightnessClient setIdleDimTime:value forKeyboard:[self keyboardID]];
}

+ (double)idleDimTimeForKeyboard {
    return [KeyboardManager.brightnessClient idleDimTimeForKeyboard:[self keyboardID]];
}

+ (void)enableAutoBrightness:(bool)value {
    [KeyboardManager.brightnessClient enableAutoBrightness:value forKeyboard:[self keyboardID]];
}

+ (void)flashKeyboardLights:(int)times withInterval:(double)interval andFadeSpeed:(double)fadeSpeed {
    float current = [self getBrightness];
    for (int i = 0; i < times; i++) {
        [KeyboardManager.brightnessClient setBrightness:0 fadeSpeed:fadeSpeed commit:true forKeyboard:[self keyboardID]];
        [NSThread sleepForTimeInterval:interval];
        [KeyboardManager.brightnessClient setBrightness:1 fadeSpeed:fadeSpeed commit:true forKeyboard:[self keyboardID]];
        [NSThread sleepForTimeInterval:interval];
    }
    [self setBrightness:current];
}


@end
