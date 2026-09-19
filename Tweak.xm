#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <dlfcn.h>
#include <stdint.h>

/*
 * BiliVideoFPS120 0.2.0 VoutCounterSafe
 *
 * Goals:
 * - Keep the known-safe IJK controller hooks used by 0.1.7/0.1.9.
 * - Avoid the crash-prone render-view / EAGL / Metal Objective-C hooks.
 * - Try to hook IJK's C function SDL_VoutDisplayYUVOverlay. In upstream IJK,
 *   ff_ffplay calls this once for each frame sent to the video output, immediately
 *   before updating stat.vfps. If the symbol is visible in Bilibili's binary,
 *   counting these calls gives us a much more direct output-rate probe.
 * - If the symbol is stripped/hidden, fall back to VID~ (estimate), calculated
 *   from source FPS * playback rate * (1 - IJK dropFrameRate), capped at screen Hz.
 *   The tilde is intentional: the fallback is NOT claimed to be actual presented FPS.
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
static BOOL gVoutHooked = NO;
static int gInstallAttempt = 0;
static volatile uint64_t gVoutFrameCount = 0;

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

#pragma mark - IJK output C-function probe

typedef int (*GTVoutDisplayIMP)(void *vout, void *overlay);
static GTVoutDisplayIMP origVoutDisplay = NULL;

static int hookVoutDisplay(void *vout, void *overlay) {
    __sync_fetch_and_add(&gVoutFrameCount, 1);
    return origVoutDisplay ? origVoutDisplay(vout, overlay) : 0;
}

static void GTTryInstallVoutHook(void) {
    if (gVoutHooked) return;
    void *sym = dlsym(RTLD_DEFAULT, "SDL_VoutDisplayYUVOverlay");
    if (!sym) return;
    MSHookFunction(sym, (void *)&hookVoutDisplay, (void **)&origVoutDisplay);
    if (origVoutDisplay) {
        gVoutHooked = YES;
        GTLog(@"HOOK OK SDL_VoutDisplayYUVOverlay sym=%p", sym);
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
}

static void hookPlay(id self, SEL _cmd) {
    gActivePlayer = self;
    if (origPlay) origPlay(self, _cmd);
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
    GTTryInstallVoutHook();

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
        GTLog(@"HOOK STATUS attempts=%d player=%d options=%d vout=%d", gInstallAttempt, gPlayerHooked, gOptionsHooked, gVoutHooked);
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

static BOOL GTDropFrameRate(id player, double *outRate) {
    if (!player || !outRate) return NO;
    SEL s = NSSelectorFromString(@"dropFrameRate");
    if (![player respondsToSelector:s]) return NO;
    float f = ((float(*)(id,SEL))objc_msgSend)(player, s);
    if (!(f >= 0.0f) || f > 1.0f) return NO;
    *outRate = (double)f;
    return YES;
}

#pragma mark - Overlay

@interface GTVOverlayController : NSObject
@property(nonatomic, strong) GTVPassthroughWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) uint64_t lastVoutCount;
@property(nonatomic, assign) CFTimeInterval lastVoutTime;
@property(nonatomic, assign) double smoothedVoutFPS;
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
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) l.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else l.font = [UIFont boldSystemFontOfSize:10.5];
    l.text = @"VID --  SRC --  1.0x";
    [root.view addSubview:l];
    self.window = w;
    self.label = l;
    [self layoutOverlay];
    w.hidden = NO;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    GTTryInstallVoutHook();

    CFTimeInterval now = CACurrentMediaTime();
    uint64_t count = __sync_fetch_and_add(&gVoutFrameCount, 0);
    double actualVout = 0.0;
    if (self.lastVoutTime > 0.0 && now > self.lastVoutTime && count >= self.lastVoutCount) {
        double dt = now - self.lastVoutTime;
        uint64_t delta = count - self.lastVoutCount;
        if (dt > 0.10 && delta > 0) {
            double raw = (double)delta / dt;
            if (self.smoothedVoutFPS <= 0.0) self.smoothedVoutFPS = raw;
            else self.smoothedVoutFPS = self.smoothedVoutFPS * 0.45 + raw * 0.55;
            actualVout = self.smoothedVoutFPS;
        } else if (dt > 0.10 && delta == 0) {
            self.smoothedVoutFPS = 0.0;
        }
    }
    self.lastVoutTime = now;
    self.lastVoutCount = count;

    id player = gActivePlayer;
    double src = GTSourceFPS(player);
    double drop = 0.0;
    BOOL haveDrop = GTDropFrameRate(player, &drop);
    double rate = (gPlaybackRate > 0.05f) ? (double)gPlaybackRate : 1.0;

    NSString *vidText = @"VID --";
    NSString *mode = @"NONE";
    if (gVoutHooked && actualVout > 0.05) {
        vidText = [NSString stringWithFormat:@"VID %.1f", actualVout];
        mode = @"VOUT";
    } else if (src > 0.05 && haveDrop) {
        double est = src * rate * (1.0 - MAX(0.0, MIN(drop, 0.999)));
        est = MIN(est, (double)GTMaxScreenFPS());
        vidText = [NSString stringWithFormat:@"VID~%.0f", est];
        mode = @"EST";
    }

    NSString *srcText = src > 0.05 ? [NSString stringWithFormat:@"%.0f", src] : @"--";
    self.label.text = [NSString stringWithFormat:@"%@  SRC %@  %.1fx", vidText, srcText, rate];
    [self layoutOverlay];

    static int div = 0;
    if ((++div % 2) == 0) {
        GTLog(@"FPS mode=%@ voutHook=%d vout=%.3f src=%.3f rate=%.3f dropKnown=%d drop=%.5f count=%llu player=%@",
              mode, gVoutHooked, actualVout, src, rate, haveDrop, drop, (unsigned long long)count,
              player ? NSStringFromClass([player class]) : @"nil");
    }
}
- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.lastVoutTime = CACurrentMediaTime();
    self.lastVoutCount = __sync_fetch_and_add(&gVoutFrameCount, 0);
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
        GTLog(@"BiliVideoFPS120 0.2.0 START maxScreen=%ld home=%@ log=%@", (long)GTMaxScreenFPS(), NSHomeDirectory(), GTLogPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTVOverlayController shared] start];
            GTInstallRuntimeHooks();
        });
    }
}
