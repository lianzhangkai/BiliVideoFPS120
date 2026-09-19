#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdlib.h>
#include <stdint.h>

/*
 * BiliVideoFPS120 0.2.1 ExactRendererCounter
 *
 * Goals:
 * - Keep the known-safe IJK controller hooks.
 * - Do NOT touch EAGL / Metal / SampleBuffer or broad renderer classes.
 * - Read the active IJK controller's actual `view`. If that exact runtime class
 *   implements `display_pixels:` with the expected IJK ABI (void return, one pointer
 *   argument), hook ONLY that exact class and count frame submissions.
 * - If the ABI does not match or the method is absent, leave VID as `--` and dump
 *   the real renderer class / interesting methods into the sandbox log.
 * - Keep max-fps <120 ->120 and CADisplayLink 60->120 / frameInterval 2->1.
 */

@interface GTVPassthroughWindow : UIWindow @end
@implementation GTVPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString *GTLogPath = nil;
static dispatch_queue_t GTLogQueue;
static __weak id gActivePlayer = nil;
static float gPlaybackRate = 1.0f;
static BOOL gPlayerHooked = NO;
static BOOL gOptionsHooked = NO;
static BOOL gRenderHooked = NO;
static int gInstallAttempt = 0;
static volatile uint64_t gRenderFrameCount = 0;
static Class gRenderClass = Nil;
static Class gLastInspectedRenderClass = Nil;

static NSInteger GTMaxScreenFPS(void) {
    UIScreen *s = [UIScreen mainScreen];
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
}
static BOOL GTIsProMotion120(void) { return GTMaxScreenFPS() >= 120; }

static void GTLog(NSString *format, ...) {
    if (!GTLogQueue || !GTLogPath) return;
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_async(GTLogQueue, ^{
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n", [NSDate date].timeIntervalSince1970, msg];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:GTLogPath]) {
                [data writeToFile:GTLogPath atomically:YES];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:GTLogPath];
                if (fh) { [fh seekToEndOfFile]; [fh writeData:data]; [fh closeFile]; }
            }
        }
    });
}

#pragma mark - Exact active-renderer probe

typedef void (*GTRenderPixelsIMP)(id, SEL, void *);
static GTRenderPixelsIMP origRenderPixels = NULL;

static void hookRenderPixels(id self, SEL _cmd, void *overlay) {
    __sync_fetch_and_add(&gRenderFrameCount, 1);
    if (origRenderPixels) origRenderPixels(self, _cmd, overlay);
}

static NSString *GTMethodEncodingString(Method m) {
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    return enc ? [NSString stringWithUTF8String:enc] : @"(null)";
}

static void GTLogInterestingRendererMethods(Class cls) {
    if (!cls || cls == gLastInspectedRenderClass) return;
    gLastInspectedRenderClass = cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *interesting = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel) ?: @"";
        NSString *low = name.lowercaseString;
        if ([low containsString:@"display"] || [low containsString:@"render"] ||
            [low containsString:@"pixel"] || [low containsString:@"present"] ||
            [low containsString:@"draw"] || [low containsString:@"frame"]) {
            [interesting addObject:[NSString stringWithFormat:@"%@{%@}", name, GTMethodEncodingString(methods[i])]];
        }
    }
    if (methods) free(methods);
    GTLog(@"RENDER methods class=%@ interesting=%@", NSStringFromClass(cls), [interesting componentsJoinedByString:@", "]);
}

static id GTPlayerView(id player) {
    if (!player) return nil;
    SEL s = NSSelectorFromString(@"view");
    if (![player respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(player, s);
}

static void GTTryInstallExactRendererHook(id player) {
    if (gRenderHooked || !player) return;
    id view = GTPlayerView(player);
    if (!view) return;
    Class cls = object_getClass(view);
    if (!cls) return;

    GTLogInterestingRendererMethods(cls);

    SEL sel = NSSelectorFromString(@"display_pixels:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        static Class lastNoMethod = Nil;
        if (lastNoMethod != cls) {
            lastNoMethod = cls;
            NSString *layerClass = @"n/a";
            if ([view isKindOfClass:[UIView class]]) {
                UIView *uv = (UIView *)view;
                CALayer *layer = uv.layer;
                layerClass = layer ? NSStringFromClass([layer class]) : @"nil";
            }
            GTLog(@"RENDER no display_pixels: class=%@ view=%p layer=%@", NSStringFromClass(cls), view, layerClass);
        }
        return;
    }

    unsigned int argc = method_getNumberOfArguments(m);
    char ret[16] = {0};
    char arg2[128] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (argc > 2) method_getArgumentType(m, 2, arg2, sizeof(arg2));
    NSString *enc = GTMethodEncodingString(m);
    BOOL safeABI = (argc == 3 && ret[0] == 'v' && arg2[0] == '^');

    GTLog(@"RENDER candidate class=%@ view=%p encoding=%@ argc=%u ret=%s arg2=%s safe=%d",
          NSStringFromClass(cls), view, enc, argc, ret, arg2, safeABI);
    if (!safeABI) return;

    MSHookMessageEx(cls, sel, (IMP)hookRenderPixels, (IMP *)&origRenderPixels);
    if (origRenderPixels) {
        gRenderClass = cls;
        gRenderHooked = YES;
        GTLog(@"HOOK OK exact renderer %@ display_pixels: orig=%p", NSStringFromClass(cls), origRenderPixels);
    }
}

#pragma mark - Known-safe IJK controller hooks

typedef void (*GTVoidIMP)(id, SEL);
typedef void (*GTRateIMP)(id, SEL, float);
typedef void (*GTOptionIMP)(id, SEL, int64_t, NSString *);

static GTVoidIMP origPrepareToPlay = NULL;
static GTVoidIMP origPlay = NULL;
static GTRateIMP origSetPlaybackRate = NULL;
static GTOptionIMP origOptionsSetInt = NULL;

static void hookPrepare(id self, SEL _cmd) {
    gActivePlayer = self;
    GTLog(@"PLAYER prepare class=%@ obj=%p", NSStringFromClass([self class]), self);
    if (origPrepareToPlay) origPrepareToPlay(self, _cmd);
    GTTryInstallExactRendererHook(self);
}

static void hookPlay(id self, SEL _cmd) {
    gActivePlayer = self;
    if (origPlay) origPlay(self, _cmd);
    GTTryInstallExactRendererHook(self);
}

static void hookRate(id self, SEL _cmd, float rate) {
    gActivePlayer = self;
    gPlaybackRate = rate;
    GTLog(@"PLAYER rate=%.3f class=%@ obj=%p", rate, NSStringFromClass([self class]), self);
    if (origSetPlaybackRate) origSetPlaybackRate(self, _cmd, rate);
}

static void hookOptionsSetInt(id self, SEL _cmd, int64_t value, NSString *key) {
    if (GTIsProMotion120() && [key isEqualToString:@"max-fps"] && value < 120) {
        GTLog(@"OPTIONS max-fps %lld -> 120", (long long)value);
        if (origOptionsSetInt) origOptionsSetInt(self, _cmd, 120, key);
        return;
    }
    if (origOptionsSetInt) origOptionsSetInt(self, _cmd, value, key);
}

static BOOL GTHookIfPresent(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    MSHookMessageEx(cls, sel, replacement, origOut);
    return YES;
}

static void GTInstallRuntimeHooks(void) {
    gInstallAttempt++;

    if (!gOptionsHooked) {
        Class c = NSClassFromString(@"IJKFFOptions");
        if (GTHookIfPresent(c, NSSelectorFromString(@"setPlayerOptionIntValue:forKey:"), (IMP)hookOptionsSetInt, (IMP *)&origOptionsSetInt)) {
            gOptionsHooked = YES;
            GTLog(@"HOOK OK IJKFFOptions");
        }
    }

    if (!gPlayerHooked) {
        Class c = NSClassFromString(@"IJKFFMoviePlayerController");
        if (c) {
            BOOL any = NO;
            any |= GTHookIfPresent(c, NSSelectorFromString(@"prepareToPlay"), (IMP)hookPrepare, (IMP *)&origPrepareToPlay);
            any |= GTHookIfPresent(c, NSSelectorFromString(@"play"), (IMP)hookPlay, (IMP *)&origPlay);
            any |= GTHookIfPresent(c, NSSelectorFromString(@"setPlaybackRate:"), (IMP)hookRate, (IMP *)&origSetPlaybackRate);
            if (any) {
                gPlayerHooked = YES;
                GTLog(@"HOOK OK IJKFFMoviePlayerController fpsInMeta=%d dropFrameRate=%d",
                      class_getInstanceMethod(c, NSSelectorFromString(@"fpsInMeta")) != NULL,
                      class_getInstanceMethod(c, NSSelectorFromString(@"dropFrameRate")) != NULL);
            }
        }
    }

    if (gInstallAttempt >= 120) {
        GTLog(@"HOOK STATUS attempts=%d player=%d options=%d renderer=%d renderClass=%@",
              gInstallAttempt, gPlayerHooked, gOptionsHooked, gRenderHooked,
              gRenderClass ? NSStringFromClass(gRenderClass) : @"nil");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GTInstallRuntimeHooks();
    });
}

#pragma mark - Safe property readers

static double GTReadCGFloatSelector(id obj, NSString *name) {
    if (!obj) return 0.0;
    SEL s = NSSelectorFromString(name);
    if (![obj respondsToSelector:s]) return 0.0;
    CGFloat v = ((CGFloat(*)(id,SEL))objc_msgSend)(obj, s);
    double d = (double)v;
    return (d > 0.05 && d < 500.0) ? d : 0.0;
}

static double GTSourceFPS(id player) {
    double v = GTReadCGFloatSelector(player, @"fpsInMeta");
    if (v > 0.05) return v;

    SEL monitorSel = NSSelectorFromString(@"monitor");
    if (player && [player respondsToSelector:monitorSel]) {
        id monitor = ((id(*)(id,SEL))objc_msgSend)(player, monitorSel);
        SEL fpsSel = NSSelectorFromString(@"fps");
        if (monitor && [monitor respondsToSelector:fpsSel]) {
            float f = ((float(*)(id,SEL))objc_msgSend)(monitor, fpsSel);
            if (f > 0.05f && f < 500.0f) return (double)f;
        }
    }
    return 0.0;
}

#pragma mark - Overlay

@interface GTVOverlayController : NSObject
@property(nonatomic, strong) GTVPassthroughWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) uint64_t lastRenderCount;
@property(nonatomic, assign) CFTimeInterval lastRenderTime;
@property(nonatomic, assign) double smoothedRenderFPS;
+ (instancetype)shared;
- (void)start;
@end

@implementation GTVOverlayController
+ (instancetype)shared {
    static GTVOverlayController *o = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ o = [[GTVOverlayController alloc] init]; });
    return o;
}
- (UIWindowScene *)foregroundWindowScene API_AVAILABLE(ios(13.0)) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive)
            return (UIWindowScene *)scene;
    }
    return nil;
}
- (CGRect)statusBarFrame {
    CGRect f = CGRectZero;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *s = self.window.windowScene ?: [self foregroundWindowScene];
        if (s.statusBarManager) f = s.statusBarManager.statusBarFrame;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CGRectIsEmpty(f)) f = UIApplication.sharedApplication.statusBarFrame;
#pragma clang diagnostic pop
    if (CGRectIsEmpty(f) || CGRectGetHeight(f) < 1.0) f = CGRectMake(0, 0, CGRectGetWidth(UIScreen.mainScreen.bounds), 20.0);
    return f;
}
- (void)layoutOverlay {
    if (!self.window || !self.label) return;
    CGRect b = UIScreen.mainScreen.bounds;
    self.window.frame = b;
    CGRect sf = [self statusBarFrame];
    CGFloat h = MIN(19.0, MAX(18.0, CGRectGetHeight(sf)));
    CGSize wanted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat w = MIN(MAX(1.0, ceil(wanted.width + 10.0)), 250.0);
    CGFloat cx = CGRectGetWidth(b) * 0.60;
    CGFloat cy = CGRectGetMinY(sf) + MAX(18.0, CGRectGetHeight(sf)) * 0.5;
    CGFloat x = MAX(2.0, MIN(round(cx - w * 0.5), CGRectGetWidth(b) - w - 2.0));
    CGFloat y = MAX(0.0, round(cy - h * 0.5));
    self.label.frame = CGRectIntegral(CGRectMake(x, y, w, h));
}
- (void)buildOverlay {
    if (self.window) return;
    GTVPassthroughWindow *w = [[GTVPassthroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 998.0;
    w.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) { UIWindowScene *s = [self foregroundWindowScene]; if (s) w.windowScene = s; }
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    w.rootViewController = root;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 5.0;
    l.layer.masksToBounds = YES;
    l.userInteractionEnabled = NO;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.72;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)])
        l.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else
        l.font = [UIFont boldSystemFontOfSize:10.5];
    l.text = @"VID --  SRC --  1.0x";
    [root.view addSubview:l];
    self.window = w;
    self.label = l;
    [self layoutOverlay];
    w.hidden = NO;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    id player = gActivePlayer;
    GTTryInstallExactRendererHook(player);

    CFTimeInterval now = CACurrentMediaTime();
    uint64_t count = __sync_fetch_and_add(&gRenderFrameCount, 0);
    double actualRender = 0.0;
    if (self.lastRenderTime > 0.0 && now > self.lastRenderTime && count >= self.lastRenderCount) {
        double dt = now - self.lastRenderTime;
        uint64_t delta = count - self.lastRenderCount;
        if (dt > 0.10 && delta > 0) {
            double raw = (double)delta / dt;
            if (self.smoothedRenderFPS <= 0.0) self.smoothedRenderFPS = raw;
            else self.smoothedRenderFPS = self.smoothedRenderFPS * 0.45 + raw * 0.55;
            actualRender = self.smoothedRenderFPS;
        } else if (dt > 0.10 && delta == 0) {
            self.smoothedRenderFPS = 0.0;
        }
    }
    self.lastRenderTime = now;
    self.lastRenderCount = count;

    double src = GTSourceFPS(player);
    double rate = (gPlaybackRate > 0.05f) ? (double)gPlaybackRate : 1.0;
    NSString *vidText = @"VID --";
    NSString *mode = @"NONE";
    if (gRenderHooked && actualRender > 0.05) {
        vidText = [NSString stringWithFormat:@"VID %.1f", actualRender];
        mode = @"PIX";
    }
    NSString *srcText = src > 0.05 ? [NSString stringWithFormat:@"%.0f", src] : @"--";
    self.label.text = [NSString stringWithFormat:@"%@  SRC %@  %.1fx", vidText, srcText, rate];
    [self layoutOverlay];

    static int div = 0;
    if ((++div % 2) == 0) {
        id view = GTPlayerView(player);
        GTLog(@"FPS mode=%@ renderHook=%d render=%.3f src=%.3f rate=%.3f count=%llu player=%@ view=%@",
              mode, gRenderHooked, actualRender, src, rate, (unsigned long long)count,
              player ? NSStringFromClass([player class]) : @"nil",
              view ? NSStringFromClass([view class]) : @"nil");
    }
}
- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.lastRenderTime = CACurrentMediaTime();
    self.lastRenderCount = __sync_fetch_and_add(&gRenderFrameCount, 0);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

#pragma mark - UI / danmaku 120Hz lift

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    NSInteger adjustedFPS = fps;
    if (GTIsProMotion120() && fps == 60) adjustedFPS = 120;
    %orig(adjustedFPS);
}
- (void)setFrameInterval:(NSInteger)interval {
    NSInteger adjustedInterval = interval;
    if (GTIsProMotion120() && interval == 2) adjustedInterval = 1;
    %orig(adjustedInterval);
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;
        GTLogQueue = dispatch_queue_create("com.chatgpt.bilivideofps120.log", DISPATCH_QUEUE_SERIAL);
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        GTLogPath = [docs stringByAppendingPathComponent:@"BiliVideoFPS120.log"];
        GTLog(@"BiliVideoFPS120 0.2.1 START maxScreen=%ld home=%@ log=%@", (long)GTMaxScreenFPS(), NSHomeDirectory(), GTLogPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTVOverlayController shared] start];
            GTInstallRuntimeHooks();
        });
    }
}
