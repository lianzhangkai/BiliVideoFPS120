#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <stdint.h>
#include <string.h>

/*
 * BiliVideoFPS120 0.1.6
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

static NSString *GTLogPath = nil;
static dispatch_queue_t GTLogQueue;
static __weak id gActivePlayer = nil;
static float gPlaybackRate = 1.0f;

static volatile uint64_t gVideoSubmitCount = 0;
static volatile uint64_t gVideoEverSubmitted = 0;
static volatile uint64_t gEAGLPresentCount = 0;
static volatile uint64_t gEAGLEverPresented = 0;
static volatile uint64_t gSampleBufferCount = 0;
static volatile uint64_t gSampleBufferEver = 0;
static volatile uint64_t gMetalDrawableCount = 0;
static volatile uint64_t gMetalDrawableEver = 0;
static volatile uint64_t gThirdPixelsCount = 0;
static volatile uint64_t gThirdPixelsEver = 0;

static BOOL gPlayerHooked = NO;
static BOOL gOptionsHooked = NO;
static BOOL gGLHooked = NO;
static BOOL gEAGLHooked = NO;
static BOOL gSampleBufferHooked = NO;
static BOOL gMetalLayerHooked = NO;
static BOOL gThirdPixelsHooked = NO;
static __weak id gActiveRenderView = nil;
static Class gActiveRenderViewClass = Nil;
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
typedef BOOL (*GTEAGLPresentIMP)(id, SEL, NSUInteger);
typedef void (*GTSampleBufferEnqueueIMP)(id, SEL, CMSampleBufferRef);
typedef id   (*GTMetalNextDrawableIMP)(id, SEL);
typedef void (*GTDisplayPixelsIMP)(id, SEL, void *);

static GTInitPlayerIMP origPlayerInit = NULL;
static GTVoidIMP origPrepareToPlay = NULL;
static GTVoidIMP origPlay = NULL;
static GTRateIMP origSetPlaybackRate = NULL;
static GTOptionIMP origOptionsSetInt = NULL;
static GTDisplayIMP origGLDisplay = NULL;
static GTEAGLPresentIMP origEAGLPresent = NULL;
static GTSampleBufferEnqueueIMP origSampleBufferEnqueue = NULL;
static GTMetalNextDrawableIMP origMetalNextDrawable = NULL;
static GTDisplayPixelsIMP origThirdDisplayPixels = NULL;

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
static void hookThirdDisplayPixels(id self, SEL _cmd, void *overlay) {
    if (origThirdDisplayPixels) origThirdDisplayPixels(self, _cmd, overlay);
    if (overlay != NULL) {
        __atomic_add_fetch(&gThirdPixelsCount, 1ULL, __ATOMIC_RELAXED);
        __atomic_store_n(&gThirdPixelsEver, 1ULL, __ATOMIC_RELAXED);
    }
}

static void GTProbePlayerRenderView(id player) {
    if (!player) return;
    SEL viewSel = NSSelectorFromString(@"view");
    if (![player respondsToSelector:viewSel]) return;
    id view = ((id(*)(id,SEL))objc_msgSend)(player, viewSel);
    if (!view) return;
    gActiveRenderView = view;
    Class vc = object_getClass(view) ? [view class] : Nil;
    if (!vc) return;

    BOOL hasPixels = class_getInstanceMethod(vc, NSSelectorFromString(@"display_pixels:")) != NULL;
    BOOL hasDisplay = class_getInstanceMethod(vc, NSSelectorFromString(@"display:")) != NULL;
    BOOL hasFPS = class_getInstanceMethod(vc, NSSelectorFromString(@"fps")) != NULL;
    BOOL third = NO;
    SEL thirdSel = NSSelectorFromString(@"isThirdGLView");
    if ([view respondsToSelector:thirdSel]) third = ((BOOL(*)(id,SEL))objc_msgSend)(view, thirdSel);
    // `view` is intentionally typed as id because Bilibili may supply a custom
    // IJK renderer.  Cast to UIView before asking for -layer; otherwise old
    // iOS 13 SDK headers expose several unrelated `layer` methods/properties
    // (UIView, CAMetalLayer, AVMovieTrack) and clang treats `[view layer]` as
    // ambiguous under -Werror.
    UIView *renderView = [view isKindOfClass:[UIView class]] ? (UIView *)view : nil;
    CALayer *renderLayer = renderView ? renderView.layer : nil;
    NSString *layerClassName = renderLayer ? NSStringFromClass([renderLayer class]) : @"(none)";
    GTLog(@"RENDERVIEW class=%@ obj=%p layer=%@ third=%d display_pixels=%d display=%d fps=%d",
          NSStringFromClass(vc), view, layerClassName, third, hasPixels, hasDisplay, hasFPS);

    if (hasPixels && (!gThirdPixelsHooked || gActiveRenderViewClass != vc)) {
        // IJK's third-party render protocol sends decoded overlays through
        // -display_pixels:. Hook the concrete runtime class, not IJKSDLGLView.
        IMP old = NULL;
        MSHookMessageEx(vc, NSSelectorFromString(@"display_pixels:"), (IMP)hookThirdDisplayPixels, &old);
        origThirdDisplayPixels = (GTDisplayPixelsIMP)old;
        gThirdPixelsHooked = YES;
        gActiveRenderViewClass = vc;
        GTLog(@"HOOK OK third GL view %@ display_pixels: orig=%p", NSStringFromClass(vc), old);
    }
}

static void hookPrepare(id self, SEL _cmd) {
    gActivePlayer = self;
    GTSetMaxFPSOnObject(self);
    GTLog(@"PLAYER prepare class=%@ obj=%p", NSStringFromClass([self class]), self);
    GTProbePlayerRenderView(self);
    if (origPrepareToPlay) origPrepareToPlay(self, _cmd);
    GTProbePlayerRenderView(self);
}
static void hookPlay(id self, SEL _cmd) {
    gActivePlayer = self;
    GTProbePlayerRenderView(self);
    if (origPlay) origPlay(self, _cmd);
}
static void hookRate(id self, SEL _cmd, float rate) {
    gActivePlayer = self;
    gPlaybackRate = rate;
    GTProbePlayerRenderView(self);
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


static BOOL hookEAGLPresent(id self, SEL _cmd, NSUInteger target) {
    BOOL ok = origEAGLPresent ? origEAGLPresent(self, _cmd, target) : NO;
    // GL_RENDERBUFFER = 0x8D41. Count successful presents only. UIKit/CoreAnimation
    // does not use EAGL presentRenderbuffer:, so in this old Bilibili build this is
    // a much more reliable video-output probe than depending on a private IJK class name.
    if (ok && target == 0x8D41) {
        __atomic_add_fetch(&gEAGLPresentCount, 1ULL, __ATOMIC_RELAXED);
        __atomic_store_n(&gEAGLEverPresented, 1ULL, __ATOMIC_RELAXED);
    }
    return ok;
}

static void hookSampleBufferEnqueue(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    if (origSampleBufferEnqueue) origSampleBufferEnqueue(self, _cmd, sbuf);
    if (sbuf) {
        __atomic_add_fetch(&gSampleBufferCount, 1ULL, __ATOMIC_RELAXED);
        __atomic_store_n(&gSampleBufferEver, 1ULL, __ATOMIC_RELAXED);
    }
}

static id hookMetalNextDrawable(id self, SEL _cmd) {
    id drawable = origMetalNextDrawable ? origMetalNextDrawable(self, _cmd) : nil;
    if (drawable) {
        __atomic_add_fetch(&gMetalDrawableCount, 1ULL, __ATOMIC_RELAXED);
        __atomic_store_n(&gMetalDrawableEver, 1ULL, __ATOMIC_RELAXED);
    }
    return drawable;
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
        if (strstr(name, "IJK") || strstr(name, "KSY") || strstr(name, "MoviePlayer") || strstr(name, "SDLGL") || strstr(name, "Video") || strstr(name, "Render")) {
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

    if (!gEAGLHooked) {
        Class eagl = NSClassFromString(@"EAGLContext");
        if (GTHookIfPresent(eagl, NSSelectorFromString(@"presentRenderbuffer:"), (IMP)hookEAGLPresent, (IMP *)&origEAGLPresent)) {
            gEAGLHooked = YES;
            GTLog(@"HOOK OK EAGLContext presentRenderbuffer:");
        }
    }

    if (!gSampleBufferHooked) {
        Class sb = NSClassFromString(@"AVSampleBufferDisplayLayer");
        if (GTHookIfPresent(sb, NSSelectorFromString(@"enqueueSampleBuffer:"), (IMP)hookSampleBufferEnqueue, (IMP *)&origSampleBufferEnqueue)) {
            gSampleBufferHooked = YES;
            GTLog(@"HOOK OK AVSampleBufferDisplayLayer enqueueSampleBuffer:");
        }
    }

    if (!gMetalLayerHooked) {
        Class metal = NSClassFromString(@"CAMetalLayer");
        if (GTHookIfPresent(metal, NSSelectorFromString(@"nextDrawable"), (IMP)hookMetalNextDrawable, (IMP *)&origMetalNextDrawable)) {
            gMetalLayerHooked = YES;
            GTLog(@"HOOK OK CAMetalLayer nextDrawable");
        }
    }

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

    if (gInstallAttempt >= 120) {
        GTLog(@"HOOK STATUS attempts=%d player=%d options=%d ijkGL=%d eagl=%d sampleBuffer=%d metal=%d", gInstallAttempt, gPlayerHooked, gOptionsHooked, gGLHooked, gEAGLHooked, gSampleBufferHooked, gMetalLayerHooked);
        GTLogCandidatesOnce();
        return;
    }

    // Keep retrying for up to 60 s; some old Bilibili builds dlopen the renderer only when playback starts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GTInstallRuntimeHooks();
    });
}

static void GTLogViewTreeRecursive(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return;
    NSString *indent = [@"                " substringToIndex:MIN((NSUInteger)(depth * 2), (NSUInteger)16)];
    GTLog(@"VIEW %@%@ frame=%@ hidden=%d layer=%@", indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame), v.hidden, NSStringFromClass([v.layer class]));
    for (UIView *sub in v.subviews) GTLogViewTreeRecursive(sub, depth + 1);
}

static void GTLogVisibleViewTree(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSArray *windows = app.windows;
    GTLog(@"VIEWTREE windows=%lu", (unsigned long)windows.count);
    for (UIWindow *w in windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        GTLog(@"WINDOW %@ level=%.1f frame=%@ root=%@", NSStringFromClass([w class]), w.windowLevel, NSStringFromCGRect(w.frame), NSStringFromClass([w.rootViewController class]));
        GTLogViewTreeRecursive(w, 0);
    }
}

#pragma mark - Overlay

@interface GTVOverlayController : NSObject
@property(nonatomic, strong) GTVPassthroughWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) uint64_t lastFrames;
@property(nonatomic) uint64_t lastEAGLFrames;
@property(nonatomic) uint64_t lastSampleBufferFrames;
@property(nonatomic) uint64_t lastMetalFrames;
@property(nonatomic) uint64_t lastThirdPixels;
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
    CGFloat w = 224.0;
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
    l.text = @"VID -- | H P0 T0 E0 I0 S0 M0 | 1.0x";
    [root.view addSubview:l];
    self.window = w; self.label = l;
    [self layoutOverlay];
    w.hidden = NO;
}
- (double)sourceFPSFromActivePlayer {
    id p = gActivePlayer;
    if (!p) return 0.0;
    SEL s = NSSelectorFromString(@"fpsInMeta");
    if ([p respondsToSelector:s]) {
        double v = ((double(*)(id,SEL))objc_msgSend)(p, s);
        if (v > 0.05 && v < 500.0) return v;
    }
    // IJKFFMonitor exposes the stream/meta fps and is a useful fallback in
    // Bilibili forks where controller.fpsInMeta remains zero.
    SEL monitorSel = NSSelectorFromString(@"monitor");
    if ([p respondsToSelector:monitorSel]) {
        id monitor = ((id(*)(id,SEL))objc_msgSend)(p, monitorSel);
        SEL fpsSel = NSSelectorFromString(@"fps");
        if (monitor && [monitor respondsToSelector:fpsSel]) {
            float f = ((float(*)(id,SEL))objc_msgSend)(monitor, fpsSel);
            if (f > 0.05f && f < 500.0f) return (double)f;
        }
    }
    Ivar iv = class_getInstanceVariable([p class], "_fpsInMeta");
    if (iv) {
        ptrdiff_t off = ivar_getOffset(iv);
        double v = 0.0;
        memcpy(&v, ((uint8_t *)(__bridge void *)p) + off, sizeof(double));
        if (v > 0.0 && v < 500.0) return v;
    }
    return 0.0;
}
- (double)reportedRenderViewFPS {
    id v = gActiveRenderView;
    if (!v) return 0.0;
    SEL s = NSSelectorFromString(@"fps");
    if (![v respondsToSelector:s]) return 0.0;
    CGFloat f = ((CGFloat(*)(id,SEL))objc_msgSend)(v, s);
    return (f > 0.05 && f < 500.0) ? (double)f : 0.0;
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self layoutOverlay];
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t frames = __atomic_load_n(&gVideoSubmitCount, __ATOMIC_RELAXED);
    uint64_t eaglFrames = __atomic_load_n(&gEAGLPresentCount, __ATOMIC_RELAXED);
    uint64_t sbFrames = __atomic_load_n(&gSampleBufferCount, __ATOMIC_RELAXED);
    uint64_t metalFrames = __atomic_load_n(&gMetalDrawableCount, __ATOMIC_RELAXED);
    uint64_t thirdPixels = __atomic_load_n(&gThirdPixelsCount, __ATOMIC_RELAXED);
    if (self.lastSampleTime <= 0.0) { self.lastSampleTime = now; self.lastFrames = frames; self.lastEAGLFrames = eaglFrames; self.lastSampleBufferFrames = sbFrames; self.lastMetalFrames = metalFrames; self.lastThirdPixels = thirdPixels; return; }
    double dt = now - self.lastSampleTime;
    uint64_t dfIJK = frames - self.lastFrames;
    uint64_t dfEAGL = eaglFrames - self.lastEAGLFrames;
    uint64_t dfSB = sbFrames - self.lastSampleBufferFrames;
    uint64_t dfMetal = metalFrames - self.lastMetalFrames;
    uint64_t dfThird = thirdPixels - self.lastThirdPixels;
    self.lastSampleTime = now; self.lastFrames = frames; self.lastEAGLFrames = eaglFrames; self.lastSampleBufferFrames = sbFrames; self.lastMetalFrames = metalFrames; self.lastThirdPixels = thirdPixels;
    BOOL sbEver = __atomic_load_n(&gSampleBufferEver, __ATOMIC_RELAXED) != 0;
    BOOL eaglEver = __atomic_load_n(&gEAGLEverPresented, __ATOMIC_RELAXED) != 0;
    BOOL ijkEver = __atomic_load_n(&gVideoEverSubmitted, __ATOMIC_RELAXED) != 0;
    BOOL metalEver = __atomic_load_n(&gMetalDrawableEver, __ATOMIC_RELAXED) != 0;
    BOOL thirdEver = __atomic_load_n(&gThirdPixelsEver, __ATOMIC_RELAXED) != 0;
    uint64_t df = thirdEver ? dfThird : (sbEver ? dfSB : (eaglEver ? dfEAGL : (ijkEver ? dfIJK : dfMetal)));
    double instant = dt > 0.05 ? ((double)df / dt) : 0.0;
    BOOL ever = thirdEver || sbEver || eaglEver || ijkEver || metalEver;
    NSString *backend = thirdEver ? @"PIX" : (sbEver ? @"SB" : (eaglEver ? @"GL" : (ijkEver ? @"IJK" : (metalEver ? @"MTL" : @"--"))));
    if (ever) {
        if (self.smoothedVideoFPS <= 0.01 || instant <= 0.01) self.smoothedVideoFPS = instant;
        else self.smoothedVideoFPS = self.smoothedVideoFPS * 0.55 + instant * 0.45;
    }
    double src = [self sourceFPSFromActivePlayer];
    double viewFPS = [self reportedRenderViewFPS];
    if (!ever && viewFPS > 0.05) {
        ever = YES;
        self.smoothedVideoFPS = viewFPS;
        backend = @"VFP";
    }
    NSString *vidText = ever ? [NSString stringWithFormat:@"%.1f", self.smoothedVideoFPS] : @"--";
    NSString *srcText = src > 0.05 ? [NSString stringWithFormat:@"%.0f", src] : @"--";
    if (ever) {
        self.label.text = [NSString stringWithFormat:@"VID %@ %@ | SRC %@ | %.1fx", vidText, backend, srcText, gPlaybackRate];
    } else {
        // H=hook installed. Order: EAGL/IJK/SampleBuffer/Metal. This is intentionally
        // different from a frame-seen flag so we can distinguish "hook exists but unused".
        self.label.text = [NSString stringWithFormat:@"VID -- | H P%d T%d E%d I%d S%d M%d | %.1fx", gPlayerHooked?1:0, gThirdPixelsHooked?1:0, gEAGLHooked?1:0, gGLHooked?1:0, gSampleBufferHooked?1:0, gMetalLayerHooked?1:0, gPlaybackRate];
    }
    static int div = 0;
    if ((++div % 2) == 0) GTLog(@"FPS chosen=%.3f backend=%@ dPIX=%llu dSB=%llu dEAGL=%llu dIJK=%llu dMTL=%llu viewFPS=%.3f src=%.3f rate=%.3f player=%@ view=%@ hooked(P/O/T/I/E/S/M)=%d/%d/%d/%d/%d/%d/%d", instant, backend, (unsigned long long)dfThird, (unsigned long long)dfSB, (unsigned long long)dfEAGL, (unsigned long long)dfIJK, (unsigned long long)dfMetal, viewFPS, src, gPlaybackRate, gActivePlayer ? NSStringFromClass([gActivePlayer class]) : @"nil", gActiveRenderView ? NSStringFromClass([gActiveRenderView class]) : @"nil", gPlayerHooked, gOptionsHooked, gThirdPixelsHooked, gGLHooked, gEAGLHooked, gSampleBufferHooked, gMetalLayerHooked);
}
- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.lastSampleTime = CACurrentMediaTime();
    self.lastFrames = __atomic_load_n(&gVideoSubmitCount, __ATOMIC_RELAXED);
    self.lastEAGLFrames = __atomic_load_n(&gEAGLPresentCount, __ATOMIC_RELAXED);
    self.lastSampleBufferFrames = __atomic_load_n(&gSampleBufferCount, __ATOMIC_RELAXED);
    self.lastMetalFrames = __atomic_load_n(&gMetalDrawableCount, __ATOMIC_RELAXED);
    self.lastThirdPixels = __atomic_load_n(&gThirdPixelsCount, __ATOMIC_RELAXED);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

#pragma mark - UI / danmaku 120Hz lift

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    NSInteger adjustedFPS = fps;
    if (GTIsProMotion120() && fps == 60) {
        adjustedFPS = 120;
    }
    %orig(adjustedFPS);
}
- (void)setFrameInterval:(NSInteger)interval {
    NSInteger adjustedInterval = interval;
    if (GTIsProMotion120() && interval == 2) {
        adjustedInterval = 1;
    }
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
        GTLog(@"BiliVideoFPS120 0.1.5 START maxScreen=%ld home=%@ log=%@", (long)GTMaxScreenFPS(), NSHomeDirectory(), GTLogPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[GTVOverlayController shared] start];
            GTInstallRuntimeHooks();
        });
        // A later inventory makes diagnosis possible even if this Bilibili build
        // uses renamed/forked IJK classes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTLogCandidatesOnce();
            GTLogVisibleViewTree();
        });
    }
}
