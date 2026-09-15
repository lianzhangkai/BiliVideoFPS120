#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// No ijkplayer headers are required. These declarations match the public
// ijkplayer iOS API and are only used when the corresponding selectors exist.
@interface IJKFFOptions : NSObject
- (void)setPlayerOptionIntValue:(int64_t)value forKey:(NSString *)key;
@end

@interface IJKFFMoviePlayerController : NSObject
- (CGFloat)fpsInMeta;
- (CGFloat)fpsAtOutput;
- (void)setPlayerOptionIntValue:(int64_t)value forKey:(NSString *)key;
@end

@interface GTVPassthroughWindow : UIWindow
@end
@implementation GTVPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { (void)point; (void)event; return NO; }
@end

static __weak id gActivePlayer = nil;
static float gPlaybackRate = 1.0f;
static NSString * const GTLogPath = @"/var/mobile/Media/BiliVideoFPS120.log";
static dispatch_queue_t GTLogQueue;

static NSInteger GTMaxScreenFPS(void) {
    UIScreen *s = [UIScreen mainScreen];
    if ([s respondsToSelector:@selector(maximumFramesPerSecond)]) return s.maximumFramesPerSecond;
    return 60;
}

static BOOL GTIsProMotion120(void) {
    return GTMaxScreenFPS() >= 120;
}

static void GTLog(NSString *format, ...) {
    if (!GTLogQueue) return;
    va_list args;
    va_start(args, format);
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
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:data];
                    [fh closeFile];
                }
            }
        }
    });
}

static void GTApplySafePlayerOptions(id obj) {
    if (!GTIsProMotion120() || !obj) return;
    SEL sel = @selector(setPlayerOptionIntValue:forKey:);
    if ([obj respondsToSelector:sel]) {
        // Public ijkplayer describes max-fps as the threshold above which
        // high-FPS source frames are dropped. 120 is inside its supported
        // option range. We intentionally DO NOT force framedrop=0 here:
        // at 3x a 60fps source would require 180 unique frames/s, impossible
        // on a 120Hz panel, so normal late-frame dropping is still needed.
        [(IJKFFMoviePlayerController *)obj setPlayerOptionIntValue:120 forKey:@"max-fps"];
    }
}

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
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) return (UIWindowScene *)scene;
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
    if (CGRectIsEmpty(f)) f = [UIApplication sharedApplication].statusBarFrame;
#pragma clang diagnostic pop
    if (CGRectIsEmpty(f) || CGRectGetHeight(f) < 1.0)
        f = CGRectMake(0, 0, CGRectGetWidth([UIScreen mainScreen].bounds), 20.0);
    return f;
}

- (void)layoutOverlay {
    if (!self.window || !self.label) return;
    CGRect b = [UIScreen mainScreen].bounds;
    self.window.frame = b;
    CGRect sf = [self statusBarFrame];
    CGFloat h = MIN(19.0, MAX(18.0, CGRectGetHeight(sf)));
    CGFloat w = 176.0;
    CGFloat cx = CGRectGetWidth(b) * 0.60; // keep clear of GlobalFPSOverlay at 4/5
    CGFloat cy = CGRectGetMinY(sf) + MAX(18.0, CGRectGetHeight(sf)) * 0.5;
    CGFloat x = MAX(2.0, MIN(round(cx - w * 0.5), CGRectGetWidth(b) - w - 2.0));
    CGFloat y = MAX(0.0, round(cy - h * 0.5));
    self.label.frame = CGRectIntegral(CGRectMake(x, y, w, h));
}

- (void)buildOverlay {
    if (self.window) return;
    CGRect b = [UIScreen mainScreen].bounds;
    GTVPassthroughWindow *w = [[GTVPassthroughWindow alloc] initWithFrame:b];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelAlert + 998.0;
    w.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *s = [self foregroundWindowScene];
        if (s) w.windowScene = s;
    }
    UIViewController *root = [[UIViewController alloc] init];
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
    l.minimumScaleFactor = 0.72;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)])
        l.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    else
        l.font = [UIFont boldSystemFontOfSize:10.5];
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
    id p = gActivePlayer;
    CGFloat src = 0.0;
    CGFloat out = 0.0;
    if (p) {
        if ([p respondsToSelector:@selector(fpsInMeta)]) src = [(IJKFFMoviePlayerController *)p fpsInMeta];
        if ([p respondsToSelector:@selector(fpsAtOutput)]) out = [(IJKFFMoviePlayerController *)p fpsAtOutput];
    }
    if (src > 0.05 || out > 0.05) {
        self.label.text = [NSString stringWithFormat:@"VID %.1f | SRC %.0f | %.1fx", out, src, gPlaybackRate];
    } else {
        self.label.text = [NSString stringWithFormat:@"VID -- | SRC -- | %.1fx", gPlaybackRate];
    }
    static int logDiv = 0;
    if ((++logDiv % 2) == 0 && p) {
        GTLog(@"FPS src=%.3f output=%.3f rate=%.3f maxScreen=%ld", src, out, gPlaybackRate, (long)GTMaxScreenFPS());
    }
}

- (void)start {
    if (self.timer) return;
    [self buildOverlay];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

%hook IJKFFOptions
- (void)setPlayerOptionIntValue:(int64_t)value forKey:(NSString *)key {
    if (GTIsProMotion120() && [key isEqualToString:@"max-fps"] && value < 120) {
        GTLog(@"IJKFFOptions force max-fps %lld -> 120", value);
        %orig(120, key);
        return;
    }
    %orig(value, key);
}
%end

%hook IJKFFMoviePlayerController

- (id)initWithContentURL:(NSURL *)url withOptions:(id)options {
    if (GTIsProMotion120() && [options respondsToSelector:@selector(setPlayerOptionIntValue:forKey:)]) {
        [(IJKFFOptions *)options setPlayerOptionIntValue:120 forKey:@"max-fps"];
    }
    id ret = %orig(url, options);
    gActivePlayer = ret;
    GTApplySafePlayerOptions(ret);
    GTLog(@"PLAYER init=%p url=%@", ret, url.absoluteString ?: @"");
    return ret;
}

- (void)prepareToPlay {
    gActivePlayer = self;
    GTApplySafePlayerOptions(self);
    GTLog(@"PLAYER prepare=%p", self);
    %orig;
}

- (void)setPlaybackRate:(float)rate {
    gActivePlayer = self;
    gPlaybackRate = rate;
    GTLog(@"PLAYER rate=%.3f player=%p", rate, self);
    %orig(rate);
}

%end

// Keep Bilibili's UIKit/danmaku DisplayLinks from explicitly asking for 60
// on a 120Hz panel. This is separate from IJK video presentation itself.
%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (GTIsProMotion120() && fps == 60) {
        %orig(120);
        return;
    }
    %orig(fps);
}
- (void)setFrameInterval:(NSInteger)interval {
    if (GTIsProMotion120() && interval == 2) {
        %orig(1);
        return;
    }
    %orig(interval);
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bid isEqualToString:@"tv.danmaku.bilianime"]) return;
        GTLogQueue = dispatch_queue_create("com.chatgpt.bilivideofps120.log", DISPATCH_QUEUE_SERIAL);
        GTLog(@"BiliVideoFPS120 0.1.0 START maxScreen=%ld", (long)GTMaxScreenFPS());
        dispatch_async(dispatch_get_main_queue(), ^{ [[GTVOverlayController shared] start]; });
    }
}
