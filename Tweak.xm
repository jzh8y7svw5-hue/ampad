// AmbientMusic - standby-style now playing screen for iOS 8 (SpringBoard)
// Shows when: device is locked AND music is playing. Tap the screen to dismiss.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// ---- private classes (declared only so the compiler knows the selectors) ----
@interface SBBacklightController : NSObject
+ (id)sharedInstance;
- (void)turnOnScreenFullyWithBacklightSource:(int)source;
- (void)resetLockScreenIdleTimer;
@end

@interface SBLockScreenManager : NSObject
+ (id)sharedInstance;
- (BOOL)isUILocked;
@end

// ---- MediaRemote (loaded at runtime, no linking needed) ----
typedef void (^AMInfoBlock)(NSDictionary *info);
typedef void (^AMPlayingBlock)(Boolean playing);
static void (*MRGetInfo)(dispatch_queue_t, AMInfoBlock);
static void (*MRGetPlaying)(dispatch_queue_t, AMPlayingBlock);
static void (*MRRegister)(dispatch_queue_t);

static NSString *const kInfoTitle    = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kInfoArtist   = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kInfoArt      = @"kMRMediaRemoteNowPlayingInfoArtworkData";
static NSString *const kInfoDuration = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kInfoElapsed  = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
static NSString *const kInfoRate     = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";
static NSString *const kInfoStamp    = @"kMRMediaRemoteNowPlayingInfoTimestamp";

// ---- state ----
static BOOL gPlaying = NO;
static NSString *gTitle = nil;
static NSString *gArtist = nil;
static UIImage *gArt = nil;
static double gElapsed = 0, gDuration = 0, gRate = 1;
static NSDate *gStamp = nil;
static BOOL gDismissed = NO, gWasLocked = NO, gShown = NO;
static CGFloat gSavedBrightness = -1;
static dispatch_source_t gTimer = nil;

static void AMDismiss(void);

static NSString *AMTimeString(double t) {
    if (t < 0 || t != t) t = 0;
    int s = (int)t;
    return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

static UIImage *AMTiny(UIImage *src) {
    if (!src) return nil;
    CGSize s = CGSizeMake(24, 24);
    UIGraphicsBeginImageContextWithOptions(s, YES, 1);
    [src drawInRect:CGRectMake(0, 0, s.width, s.height)];
    UIImage *r = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return r;
}

// ================= UI =================

@interface AMView : UIView
@property (nonatomic, strong) UIImageView *bg;
@property (nonatomic, strong) UIVisualEffectView *fx;
@property (nonatomic, strong) UIView *shade;
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *clock, *dateL, *titleL, *artistL, *elapsedL, *durationL;
@property (nonatomic, strong) UIView *track, *fill;
@property (nonatomic, assign) CGFloat ratio;
- (void)setArtwork:(UIImage *)img title:(NSString *)t artist:(NSString *)a;
- (void)updateElapsed:(double)e duration:(double)d;
- (void)tickClock;
@end

@implementation AMView

- (UILabel *)makeLabel:(NSString *)font size:(CGFloat)size alpha:(CGFloat)alpha align:(NSTextAlignment)al {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont fontWithName:font size:size] ?: [UIFont systemFontOfSize:size];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.textAlignment = al;
    l.backgroundColor = [UIColor clearColor];
    [self addSubview:l];
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _bg = [[UIImageView alloc] init];
        _bg.contentMode = UIViewContentModeScaleAspectFill;
        _bg.clipsToBounds = YES;
        _bg.layer.magnificationFilter = kCAFilterLinear;
        [self addSubview:_bg];

        _fx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        [self addSubview:_fx];

        _shade = [[UIView alloc] init];
        _shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
        [self addSubview:_shade];

        _cover = [[UIImageView alloc] init];
        _cover.contentMode = UIViewContentModeScaleAspectFill;
        _cover.clipsToBounds = YES;
        _cover.layer.cornerRadius = 18;
        _cover.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        [self addSubview:_cover];

        _clock = [self makeLabel:@"HelveticaNeue-UltraLight" size:96 alpha:0.95 align:NSTextAlignmentCenter];
        _dateL = [self makeLabel:@"HelveticaNeue-Light" size:22 alpha:0.7 align:NSTextAlignmentCenter];
        _titleL = [self makeLabel:@"HelveticaNeue-Bold" size:30 alpha:1.0 align:NSTextAlignmentCenter];
        _artistL = [self makeLabel:@"HelveticaNeue" size:22 alpha:0.7 align:NSTextAlignmentCenter];
        _elapsedL = [self makeLabel:@"HelveticaNeue" size:14 alpha:0.6 align:NSTextAlignmentLeft];
        _durationL = [self makeLabel:@"HelveticaNeue" size:14 alpha:0.6 align:NSTextAlignmentRight];

        _track = [[UIView alloc] init];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        _track.layer.cornerRadius = 2;
        _track.clipsToBounds = YES;
        [self addSubview:_track];
        _fill = [[UIView alloc] init];
        _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
        [_track addSubview:_fill];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];

        [self tickClock];
    }
    return self;
}

- (void)handleTap { AMDismiss(); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _bg.frame = self.bounds;
    _fx.frame = self.bounds;
    _shade.frame = self.bounds;
    _clock.frame = CGRectMake(0, H * 0.06, W, 110);
    _dateL.frame = CGRectMake(0, H * 0.06 + 108, W, 30);
    CGFloat s = MIN(W, H) * 0.46, cy = H * 0.30;
    _cover.frame = CGRectMake((W - s) / 2, cy, s, s);
    CGFloat y = cy + s + 34;
    _titleL.frame = CGRectMake(40, y, W - 80, 38);
    _artistL.frame = CGRectMake(40, y + 40, W - 80, 28);
    CGFloat tw = W * 0.6, tx = (W - tw) / 2, ty = y + 100;
    _track.frame = CGRectMake(tx, ty, tw, 4);
    _fill.frame = CGRectMake(0, 0, tw * _ratio, 4);
    _elapsedL.frame = CGRectMake(tx, ty + 10, 80, 18);
    _durationL.frame = CGRectMake(tx + tw - 80, ty + 10, 80, 18);
}

- (void)setArtwork:(UIImage *)img title:(NSString *)t artist:(NSString *)a {
    _cover.image = img;
    _bg.image = AMTiny(img);
    _titleL.text = t.length ? t : @"";
    _artistL.text = a.length ? a : @"";
}

- (void)updateElapsed:(double)e duration:(double)d {
    CGFloat r = (d > 0) ? (CGFloat)(e / d) : 0;
    if (r < 0) r = 0;
    if (r > 1) r = 1;
    _ratio = r;
    _fill.frame = CGRectMake(0, 0, _track.bounds.size.width * r, 4);
    _elapsedL.text = AMTimeString(e);
    _durationL.text = d > 0 ? AMTimeString(d) : @"";
}

- (void)tickClock {
    static NSDateFormatter *tf, *df;
    if (!tf) {
        tf = [[NSDateFormatter alloc] init];
        tf.dateFormat = @"HH:mm";
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"MMMMdEEEE" options:0 locale:[NSLocale currentLocale]];
    }
    NSDate *now = [NSDate date];
    _clock.text = [tf stringFromDate:now];
    _dateL.text = [df stringFromDate:now];
}

@end

@interface AMVC : UIViewController
@end
@implementation AMVC
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static UIWindow *gWindow = nil;
static AMView *gView = nil;

static void AMApplyToView(void) {
    if (gView) [gView setArtwork:gArt title:gTitle artist:gArtist];
}

// ================= Now playing =================

static void AMRefreshInfo(void) {
    if (!MRGetInfo) return;
    MRGetInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        id t = info[kInfoTitle];  gTitle  = [t isKindOfClass:[NSString class]] ? t : nil;
        id a = info[kInfoArtist]; gArtist = [a isKindOfClass:[NSString class]] ? a : nil;
        id d = info[kInfoArt];    gArt    = [d isKindOfClass:[NSData class]] ? [UIImage imageWithData:d] : nil;
        gDuration = [info[kInfoDuration] doubleValue];
        gElapsed  = [info[kInfoElapsed] doubleValue];
        id r = info[kInfoRate];   gRate   = [r isKindOfClass:[NSNumber class]] ? [r doubleValue] : 1;
        if (gRate <= 0) gRate = 1;
        id s = info[kInfoStamp];  gStamp  = [s isKindOfClass:[NSDate class]] ? s : [NSDate date];
        AMApplyToView();
    });
}

static void AMRefreshPlaying(void) {
    if (!MRGetPlaying) return;
    MRGetPlaying(dispatch_get_main_queue(), ^(Boolean p) { gPlaying = p; });
}

// ================= Show / hide =================

static void AMShow(void) {
    if (gShown) return;
    if (!gWindow) {
        gView = [[AMView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        AMVC *vc = [[AMVC alloc] init];
        vc.view = gView;
        gWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gWindow.windowLevel = 100000;
        gWindow.rootViewController = vc;
    }
    AMApplyToView();

    if (gSavedBrightness < 0) gSavedBrightness = [UIScreen mainScreen].brightness;
    [UIScreen mainScreen].brightness = 0.1;

    id bl = [%c(SBBacklightController) sharedInstance];
    if ([bl respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)])
        [bl turnOnScreenFullyWithBacklightSource:1];

    gWindow.alpha = 0;
    gWindow.hidden = NO;
    [UIView animateWithDuration:0.4 animations:^{ gWindow.alpha = 1; }];
    gShown = YES;
}

static void AMHide(void) {
    if (!gShown) return;
    gShown = NO;
    if (gSavedBrightness >= 0) {
        [UIScreen mainScreen].brightness = gSavedBrightness;
        gSavedBrightness = -1;
    }
    [UIView animateWithDuration:0.3 animations:^{ gWindow.alpha = 0; }
                     completion:^(BOOL f) { if (!gShown) gWindow.hidden = YES; }];
}

static void AMDismiss(void) {
    gDismissed = YES;
    AMHide();
}

// ================= 1 Hz tick =================

static void AMTick(void) {
    AMRefreshPlaying();

    BOOL locked = NO;
    id mgr = [%c(SBLockScreenManager) sharedInstance];
    if ([mgr respondsToSelector:@selector(isUILocked)]) locked = [mgr isUILocked];
    if (locked && !gWasLocked) gDismissed = NO;
    gWasLocked = locked;

    if (locked && gPlaying && !gDismissed) {
        if (!gShown) AMShow();
    } else if (gShown) {
        AMHide();
    }

    if (gShown) {
        [gView tickClock];
        double e = gElapsed;
        if (gPlaying && gStamp) e += [[NSDate date] timeIntervalSinceDate:gStamp] * gRate;
        if (gDuration > 0 && e > gDuration) e = gDuration;
        [gView updateElapsed:e duration:gDuration];

        // keep the lock screen from auto-dimming while the overlay is up
        id bl = [%c(SBBacklightController) sharedInstance];
        if ([bl respondsToSelector:@selector(resetLockScreenIdleTimer)])
            [bl resetLockScreenIdleTimer];
    }
}

// ================= Entry =================

%ctor {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) return;
        MRGetInfo    = (void (*)(dispatch_queue_t, AMInfoBlock))dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRGetPlaying = (void (*)(dispatch_queue_t, AMPlayingBlock))dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRRegister   = (void (*)(dispatch_queue_t))dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!MRGetInfo) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (MRRegister) MRRegister(dispatch_get_main_queue());
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            void (^refresh)(NSNotification *) = ^(NSNotification *n) { AMRefreshInfo(); AMRefreshPlaying(); };
            [nc addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification"
                            object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
            [nc addObserverForName:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
                            object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];

            AMRefreshInfo();
            AMRefreshPlaying();

            gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                      NSEC_PER_SEC, NSEC_PER_SEC / 10);
            dispatch_source_set_event_handler(gTimer, ^{ AMTick(); });
            dispatch_resume(gTimer);
        });
    }
}
