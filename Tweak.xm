#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <string.h>

/*
 * BiliVideoFPS120 0.1.1
 *
 * Why 0.1.0 could show VID -- / SRC -- forever:
 * Bilibili can load its ijkplayer classes after tweak construction. A Logos
 * %hook resolved too early then never attached to IJKFFMoviePlayerController.
 *
 * 0.1.1 therefore:
 *  - retries runtime installation until the IJK classes actually exist;
 *  - hooks IJKSDLGLView -display: directly and counts real non-NULL video
 *    overlays submitted by IJK, independent of fpsAtOutput/controller tracking;
 *  - still reads fpsInMeta when a player controller can be tracked;
 *  - logs candidate runtime class names for diagnosis;
 *  - keeps the safe max-fps=120 lift and Bilibili 60->120 CADisplayLink lift.
 */

@interface GTVPassthroughWindow : UIWindow @end
@implementation GTVPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString * const GTLogPath = @"/var/mobile/Media/BiliVideoFPS120.log";
static dispatch_queue_t GTLogQueue;
static __weak id gActivePlayer = nil;
static float gPlaybackRate = 1.0f;

static volatile uint64_t gVideoSubmitCount = 0;
static volatile uint64_t gVideoEverSubmitted = 0;

static BOOL gPlayerHooked = NO;
static BOOL gOptionsHooked = NO;
static BOOL gGLHooked = NO;
static int gInstallAttempt = 0;

static NSInteger GTMaxScreenFPS(void) {
    UIScreen *s = [UIScreen mainScreen];
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
}
static BOOL GTIsProMotion120(void) { return GTMaxScreenFPS() >= 120; }

static void GTLog(NSString *format, ...) {
    if (!GTLogQueue) return;
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

#pragma mark - Runtime IJK hooks (late-load safe)

typedef id   (*GTInitPlayerIMP)(id, SEL, NSURL *, id);
typedef void (*GTVoidIMP)(id, SEL);
typedef void (*GTRateIMP)(id, SEL, float);
typedef void (*GTOptionIMP)(id, SEL, int64_t, NSString *);
typedef void (*GTDisplayIMP)(id, SEL, void *);

static GTInitPlayerIMP origPlayerInit = NULL;
static GTVoidIMP origPrepareToPlay = NULL;
static GTVoidIMP origPlay = NULL;
static GTRateIMP origSetPlaybackRate = NULL;
static GTOptionIMP origOptionsSetInt = NULL;
static GTDisplayIMP origGLDisplay = NULL;

static void GTSetMaxFPSOnObject(id obj) {
    SEL s = NSSelectorFromString(@"setPlayerOptionIntValue:forKey:");
    if (!GTIsProMotion120() || !obj || ![obj respondsToSelector:s]) return;
    ((void(*)(id,SEL,int64_t,NSString *))objc_msgSend)(obj, s, 120, @"max-fps");
}

static id hookPlayerInit(id self, SEL _cmd, NSURL *url, id options) {
    GTSetMaxFPSOnObject(options);
    id ret = origPlayerInit ? origPlayerInit(self, _cmd, url, options) : nil;
    gActivePlayer = ret;
    GTSetMaxFPSOnObject(ret);
    GTLog(@"PLAYER init class=%@ obj=%p url=%@", NSStringFromClass([ret class]), ret, url.absoluteString ?: @"");
    return ret;
}
static void hookPrepare(id self, SEL _cmd) {
    gActivePlayer = self;
    GTSetMaxFPSOnObject(self);
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
static void hookGLDisplay(id self, SEL _cmd, void *overlay) {
    if (origGLDisplay) origGLDisplay(self, _cmd, overlay);
    if (overlay != NULL) {
        __atomic_add_fetch(&gVideoSubmitCount, 1ULL, __ATOMIC_RELAXED);
        __atomic_store_n(&gVideoEverSubmitted, 1ULL, __ATOMIC_RELAXED);
    }
}

static BOOL GTHookIfPresent(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    MSHookMessageEx(cls, sel, replacement, origOut);
    return YES;
}

static void GTLogCandidatesOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!classes) return;
    n = objc_getClassList(classes, n);
    for (int i = 0; i < n; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (strstr(name, "IJK") || strstr(name, "KSY") || strstr(name, "MoviePlayer") || strstr(name, "SDLGL")) {
            Class c = classes[i];
            BOOL src = class_getInstanceMethod(c, NSSelectorFromString(@"fpsInMeta")) != NULL;
            BOOL out = class_getInstanceMethod(c, NSSelectorFromString(@"fpsAtOutput")) != NULL;
            BOOL disp = class_getInstanceMethod(c, NSSelectorFromString(@"display:")) != NULL;
            BOOL rate = class_getInstanceMethod(c, NSSelectorFromString(@"setPlaybackRate:")) != NULL;
            GTLog(@"CLASS %s fpsInMeta=%d fpsAtOutput=%d display=%d rate=%d", name, src, out, disp, rate);
        }
    }
    free(classes);
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
            any |= GTHookIfPresent(c, NSSelectorFromString(@"initWithContentURL:withOptions:"), (IMP)hookPlayerInit, (IMP *)&origPlayerInit);
            any |= GTHookIfPresent(c, NSSelectorFromString(@"prepareToPlay"), (IMP)hookPrepare, (IMP *)&origPrepareToPlay);
            any |= GTHookIfPresent(c, NSSelectorFromString(@"play"), (IMP)hookPlay, (IMP *)&origPlay);
            any |= GTHookIfPresent(c, NSSelectorFromString(@"setPlaybackRate:"), (IMP)hookRate, (IMP *)&origSetPlaybackRate);
            if (any) {
                gPlayerHooked = YES;
                GTLog(@"HOOK OK IJKFFMoviePlayerController fpsInMeta=%d fpsAtOutput=%d",
                      class_getInstanceMethod(c, NSSelectorFromString(@"fpsInMeta")) != NULL,
                      class_getInstanceMethod(c, NSSelectorFromString(@"fpsAtOutput")) != NULL);
            }
        }
    }

    if (!gGLHooked) {
        Class c = NSClassFromString(@"IJKSDLGLView");
        if (GTHookIfPresent(c, NSSelectorFromString(@"display:"), (IMP)hookGLDisplay, (IMP *)&origGLDisplay)) {
            gGLHooked = YES;
            GTLog(@"HOOK OK IJKSDLGLView display:");
        }
    }

    if ((gPlayerHooked && gGLHooked) || gInstallAttempt >= 40) {
        GTLog(@"HOOK STATUS attempts=%d player=%d options=%d gl=%d", gInstallAttempt, gPlayerHooked, gOptionsHooked, gGLHooked);
        if (!gPlayerHooked || !gGLHooked) GTLogCandidatesOnce();
        return;
    }

    // IJK is often dlopened after tweak construction. Keep retrying for 20 s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GTInstallRuntimeHooks();
    });
}

#pragma mark - Overlay

@interface GTVOverlayController : NSObject
@property(nonatomic, strong) GTVPassthroughWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) uint64_t lastFrames;
@property(nonatomic) CFTimeInterval lastSampleTime;
@property(nonatomic) double smoothedVideoFPS;
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
    CGFloat w = 184.0;
    CGFloat cx = CGRectGetWidth(b) * 0.60;
    CGFloat cy = CGRectGetMinY(sf) + MAX(18.0, CGRectGetHeight(sf)) * 0.5;
    CGFloat x = MAX(2.0, MIN(round(cx - w * 0.5), CGRectGetWidth(b) - w - 2.0));
    CGFloat y = MAX(0.0, round(cy - h * 0.5));
    self.label.frame = CGRectIntegral(CGRectMake(x, y, w, h));
}
- (void)buildOverlay {
    if (self.window) return;
    CGRect b = UIScreen.mainScreen.bounds;
    GTVPassthroughWindow *w = [[GTVPassthroughWindow alloc] initWithFrame:b];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 998.0;
    w.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) { UIWindowScene *s = [self foregroundWindowScene]; if (s) w.windowScene = s; }
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.userInteractionEnabled = NO;
    w.rootViewController = root;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 4.0;
    l.layer.masksToBounds = YES;
    l.userInteractionEnabled = NO;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.68;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) l.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else l.font = [UIFont boldSystemFontOfSize:10.5];
    l.text = @"VID -- | SRC -- | 1.0x";
    [root.view addSubview:l];
    self.window = w; self.label = l;
    [self layoutOverlay];
    w.hidden = NO;
}
- (double)sourceFPSFromActivePlayer {
    id p = gActivePlayer;
    if (!p) return 0.0;
    SEL s = NSSelectorFromString(@"fpsInMeta");
    if ([p respondsToSelector:s]) return ((double(*)(id,SEL))objc_msgSend)(p, s);
    Ivar iv = class_getInstanceVariable([p class], "_fpsInMeta");
    if (iv) {
        ptrdiff_t off = ivar_getOffset(iv);
        double v = 0.0;
        memcpy(&v, ((uint8_t *)(__bridge void *)p) + off, sizeof(double));
        if (v > 0.0 && v < 500.0) return v;
    }
    return 0.0;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self layoutOverlay];
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t frames = __atomic_load_n(&gVideoSubmitCount, __ATOMIC_RELAXED);
    if (self.lastSampleTime <= 0.0) { self.lastSampleTime = now; self.lastFrames = frames; return; }
    double dt = now - self.lastSampleTime;
    uint64_t df = frames - self.lastFrames;
    self.lastSampleTime = now; self.lastFrames = frames;
    double instant = dt > 0.05 ? ((double)df / dt) : 0.0;
    BOOL ever = __atomic_load_n(&gVideoEverSubmitted, __ATOMIC_RELAXED) != 0;
    if (ever) {
        if (self.smoothedVideoFPS <= 0.01 || instant <= 0.01) self.smoothedVideoFPS = instant;
        else self.smoothedVideoFPS = self.smoothedVideoFPS * 0.55 + instant * 0.45;
    }
    double src = [self sourceFPSFromActivePlayer];
    NSString *vidText = ever ? [NSString stringWithFormat:@"%.1f", self.smoothedVideoFPS] : @"--";
    NSString *srcText = src > 0.05 ? [NSString stringWithFormat:@"%.0f", src] : @"--";
    self.label.text = [NSString stringWithFormat:@"VID %@ | SRC %@ | %.1fx", vidText, srcText, gPlaybackRate];
    static int div = 0;
    if ((++div % 2) == 0) GTLog(@"FPS submit=%.3f src=%.3f rate=%.3f player=%@ hooked(P/O/G)=%d/%d/%d", instant, src, gPlaybackRate, gActivePlayer ? NSStringFromClass([gActivePlayer class]) : @"nil", gPlayerHooked, gOptionsHooked, gGLHooked);
}
- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.lastSampleTime = CACurrentMediaTime();
    self.lastFrames = __atomic_load_n(&gVideoSubmitCount, __ATOMIC_RELAXED);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

#pragma mark - UI / danmaku 120Hz lift

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (GTIsProMotion120() && fps == 60) { %orig(120); return; }
    %orig(fps);
}
- (void)setFrameInterval:(NSInteger)interval {
    if (GTIsProMotion120() && interval == 2) { %orig(1); return; }
    %orig(interval);
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;
        GTLogQueue = dispatch_queue_create("com.chatgpt.bilivideofps120.log", DISPATCH_QUEUE_SERIAL);
        GTLog(@"BiliVideoFPS120 0.1.1 START maxScreen=%ld", (long)GTMaxScreenFPS());
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTVOverlayController shared] start];
            GTInstallRuntimeHooks();
        });
        // A later inventory makes diagnosis possible even if this Bilibili build
        // uses renamed/forked IJK classes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gPlayerHooked || !gGLHooked) GTLogCandidatesOnce();
        });
    }
}
