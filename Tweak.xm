#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <dlfcn.h>

/*
 * BiliVideoFPS120 0.1.8 CoreVFPSProbe
 *
 * Crash-safe diagnostic build after 0.1.6:
 * - DOES NOT hook EAGLContext, CAMetalLayer, AVSampleBufferDisplayLayer,
 *   IJKSDLGLView display:, or runtime third-party display_pixels: methods.
 * - Tracks only the known-working IJKFFMoviePlayerController methods.
 * - Reads IJK core vfps/vdps directly through ijkmp_get_property_float when available.
 * - Keeps controller.fpsAtOutput and controller.view.fps only as fallbacks.
 * - Reads source FPS from fpsInMeta / monitor.fps.
 * - Keeps the already-proven max-fps 60 -> 120 lift and Bilibili
 *   CADisplayLink 60 -> 120 lift.
 */

@interface GTVPassthroughWindow : UIWindow @end
@implementation GTVPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static NSString *GTLogPath = nil;
static dispatch_queue_t GTLogQueue;
static __weak id gActivePlayer = nil;
static __weak id gActiveRenderView = nil;
static Class gLastLoggedViewClass = Nil;
static float gPlaybackRate = 1.0f;
static BOOL gPlayerHooked = NO;
static BOOL gOptionsHooked = NO;
static int gInstallAttempt = 0;

// IJK core property IDs from ff_ffmsg.h
#define GT_FFP_PROP_FLOAT_VIDEO_DECODE_FPS 10001
#define GT_FFP_PROP_FLOAT_VIDEO_OUTPUT_FPS 10002
#define GT_FFP_PROP_FLOAT_PLAYBACK_RATE    10003

typedef float (*GTIJKGetPropertyFloatFn)(void *mp, int id, float defaultValue);
static GTIJKGetPropertyFloatFn gIJKGetPropertyFloat = NULL;
static BOOL gTriedResolveIJKCore = NO;
static Ivar gMediaPlayerIvar = NULL;

static void GTLog(NSString *format, ...);

static void GTResolveIJKCoreSymbols(void) {
    if (gTriedResolveIJKCore) return;
    gTriedResolveIJKCore = YES;

    void *sym = dlsym(RTLD_DEFAULT, "ijkmp_get_property_float");
    if (!sym) sym = MSFindSymbol(NULL, "_ijkmp_get_property_float");
    gIJKGetPropertyFloat = (GTIJKGetPropertyFloatFn)sym;
    GTLog(@"CORE symbol ijkmp_get_property_float=%p", sym);
}

static void *GTGetMediaPlayerPointer(id player) {
    if (!player) return NULL;
    if (!gMediaPlayerIvar) {
        Class c = [player class];
        while (c && !gMediaPlayerIvar) {
            gMediaPlayerIvar = class_getInstanceVariable(c, "_mediaPlayer");
            c = class_getSuperclass(c);
        }
        GTLog(@"CORE ivar _mediaPlayer=%p", gMediaPlayerIvar);
    }
    if (!gMediaPlayerIvar) return NULL;
    ptrdiff_t off = ivar_getOffset(gMediaPlayerIvar);
    uint8_t *base = (uint8_t *)(__bridge void *)player;
    return *(void **)(base + off);
}

static double GTReadCoreProperty(id player, int prop) {
    GTResolveIJKCoreSymbols();
    if (!gIJKGetPropertyFloat) return 0.0;
    void *mp = GTGetMediaPlayerPointer(player);
    if (!mp) return 0.0;
    float f = gIJKGetPropertyFloat(mp, prop, 0.0f);
    return (f > 0.001f && f < 1000.0f) ? (double)f : 0.0;
}

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

static id GTGetPlayerView(id player) {
    if (!player) return nil;
    SEL s = NSSelectorFromString(@"view");
    if (![player respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(player, s);
}

static void GTRefreshRenderView(id player) {
    id view = GTGetPlayerView(player);
    if (!view) return;
    gActiveRenderView = view;
    Class c = [view class];
    if (c != gLastLoggedViewClass) {
        gLastLoggedViewClass = c;
        BOOL hasFPS = [view respondsToSelector:NSSelectorFromString(@"fps")];
        BOOL hasPixels = [view respondsToSelector:NSSelectorFromString(@"display_pixels:")];
        BOOL hasDisplay = [view respondsToSelector:NSSelectorFromString(@"display:")];
        BOOL third = NO;
        SEL ts = NSSelectorFromString(@"isThirdGLView");
        if ([view respondsToSelector:ts]) third = ((BOOL(*)(id,SEL))objc_msgSend)(view, ts);
        NSString *layerName = @"(none)";
        if ([view isKindOfClass:[UIView class]]) {
            UIView *uv = (UIView *)view;
            CALayer *layer = uv.layer;
            if (layer) layerName = NSStringFromClass([layer class]);
        }
        GTLog(@"RENDERVIEW class=%@ obj=%p layer=%@ third=%d fps=%d display_pixels=%d display=%d",
              NSStringFromClass(c), view, layerName, third, hasFPS, hasPixels, hasDisplay);
    }
}

#pragma mark - Known-safe IJK hooks

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
    GTRefreshRenderView(self);
}

static void hookPlay(id self, SEL _cmd) {
    gActivePlayer = self;
    if (origPlay) origPlay(self, _cmd);
    GTRefreshRenderView(self);
}

static void hookRate(id self, SEL _cmd, float rate) {
    gActivePlayer = self;
    gPlaybackRate = rate;
    GTLog(@"PLAYER rate=%.3f class=%@ obj=%p", rate, NSStringFromClass([self class]), self);
    if (origSetPlaybackRate) origSetPlaybackRate(self, _cmd, rate);
    GTRefreshRenderView(self);
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
                GTLog(@"HOOK OK IJKFFMoviePlayerController fpsInMeta=%d fpsAtOutput=%d view=%d",
                      class_getInstanceMethod(c, NSSelectorFromString(@"fpsInMeta")) != NULL,
                      class_getInstanceMethod(c, NSSelectorFromString(@"fpsAtOutput")) != NULL,
                      class_getInstanceMethod(c, NSSelectorFromString(@"view")) != NULL);
            }
        }
    }

    if (gInstallAttempt >= 120) {
        GTLog(@"HOOK STATUS attempts=%d player=%d options=%d", gInstallAttempt, gPlayerHooked, gOptionsHooked);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GTInstallRuntimeHooks();
    });
}

#pragma mark - FPS readers

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
    if ([player respondsToSelector:monitorSel]) {
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
    CGFloat w = 224.0;
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
    self.window = w;
    self.label = l;
    [self layoutOverlay];
    w.hidden = NO;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self layoutOverlay];
    id player = gActivePlayer;
    if (player) GTRefreshRenderView(player);
    id view = gActiveRenderView;

    double coreOut = GTReadCoreProperty(player, GT_FFP_PROP_FLOAT_VIDEO_OUTPUT_FPS);
    double coreDec = GTReadCoreProperty(player, GT_FFP_PROP_FLOAT_VIDEO_DECODE_FPS);
    double coreRate = GTReadCoreProperty(player, GT_FFP_PROP_FLOAT_PLAYBACK_RATE);
    double viewFPS = GTReadCGFloatSelector(view, @"fps");
    double controllerFPS = GTReadCGFloatSelector(player, @"fpsAtOutput");
    double src = GTSourceFPS(player);

    double out = coreOut > 0.05 ? coreOut : (viewFPS > 0.05 ? viewFPS : controllerFPS);
    NSString *backend = coreOut > 0.05 ? @"CORE" : (viewFPS > 0.05 ? @"VIEW" : (controllerFPS > 0.05 ? @"OUT" : @"--"));
    NSString *vidText = out > 0.05 ? [NSString stringWithFormat:@"%.1f", out] : @"--";
    NSString *srcText = src > 0.05 ? [NSString stringWithFormat:@"%.0f", src] : @"--";
    double shownRate = coreRate > 0.05 ? coreRate : (double)gPlaybackRate;
    self.label.text = [NSString stringWithFormat:@"VID %@ %@ | SRC %@ | %.1fx", vidText, backend, srcText, shownRate];

    static int div = 0;
    if ((++div % 2) == 0) {
        GTLog(@"FPS coreOut=%.3f coreDec=%.3f coreRate=%.3f view=%.3f controller=%.3f src=%.3f hookRate=%.3f player=%@ view=%@",
              coreOut, coreDec, coreRate, viewFPS, controllerFPS, src, gPlaybackRate,
              player ? NSStringFromClass([player class]) : @"nil",
              view ? NSStringFromClass([view class]) : @"nil");
    }
}
- (void)start {
    if (self.timer) return;
    [self buildOverlay];
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
        GTLog(@"BiliVideoFPS120 0.1.8 START maxScreen=%ld home=%@ log=%@", (long)GTMaxScreenFPS(), NSHomeDirectory(), GTLogPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTVOverlayController shared] start];
            GTInstallRuntimeHooks();
        });
    }
}
