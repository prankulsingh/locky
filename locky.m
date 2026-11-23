// locky — a friendly, non-secure "don't touch my laptop" overlay.
//
// Puts a semi-transparent panel on every screen so you can still see what's
// behind it, asks for a password, and gets out of the way the moment you type
// it. It is deliberately NOT a security tool — no screen lock, no
// permissions, no privileged APIs. It just makes the machine look occupied so
// nobody sends a prank message on your behalf while the agents keep running.
//
// By default it gets out of your way visually too: after a few idle seconds the
// banner fades out and all that's left is a small lock in each screen's corner,
// so you can watch your agents work. Any key, click or mouse move brings it
// straight back. The window never actually leaves — going "idle" is purely
// cosmetic, so clicks stay blocked and keystrokes still land in the password
// field the whole time.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>   // CAMediaTimingFunction for the fades
#import <CoreAudio/CoreAudio.h>     // muting, without asking anyone's permission
#include <signal.h>

// A floor of black under every overlay, even when the banner has faded out.
// Imperceptible (1.5%), but it guarantees the window still has substance for
// hit-testing rather than being an entirely empty pane the clicks might fall
// through. The visible tint lives in the backdrop view on top of this.
static const CGFloat kFloorAlpha = 0.015;

// Asymmetric on purpose: leaving is unobtrusive, arriving should feel like it
// slammed up. It's a deterrent, not a polite notification.
static const CGFloat kFadeOutSeconds = 0.45;
static const CGFloat kFadeInSeconds  = 0.12;

// Cursor drift and desk knocks shouldn't summon the banner all afternoon.
static const CGFloat kMoveThreshold = 6.0;

static const CGFloat kCornerAlpha = 0.75;

// Long enough to read as a deliberate change of state rather than a glitch,
// short enough that it still feels like a reaction to what you just did.
static const CGFloat kLockdownFadeSeconds = 0.2;

// Lockdown. 120s is already far longer than anyone will stand in front of a
// screen that is doing nothing, and a repeat offender is no longer somebody who
// pressed a key by accident, so the second one costs a great deal more.
static const NSTimeInterval kLockdownFirst  = 120.0;
static const NSTimeInterval kLockdownRepeat = 300.0;

// Two probes inside ten seconds, and the score decays to nothing after that.
// A single stray ⌘ from the owner walking past still costs nothing, but there
// is no third strike: anyone deliberately trying combinations produces two
// almost immediately, because a shortcut delivers the modifier and the key as
// separate events.
static const int           kThreatThreshold = 2;
static const NSTimeInterval kThreatWindow   = 10.0;

// One click is a person sitting down; a second one is somebody who saw that
// the first did nothing and is checking whether anything underneath responds.
// Two clicks score the same as one modifier press, so four clicks reach a
// lockdown by the same route two ⌘s do.
static const int           kClickBurst      = 2;
static const NSTimeInterval kClickWindow    = 2.0;

#pragma mark - window

// Borderless windows refuse key status by default; we need typed input.
@interface OverlayWindow : NSWindow
@end

@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

#pragma mark - app

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate,
                                   NSGestureRecognizerDelegate>
@property (nonatomic) CGFloat alpha;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *password;
@property (nonatomic) BOOL grabFocus;
@property (nonatomic) BOOL debug;
@property (nonatomic) BOOL strict;
@property (nonatomic) BOOL banner;          // pin the banner up, never idle
@property (nonatomic) BOOL logging;         // forensics log (on by default)
@property (nonatomic, copy) NSString *escapeKey;  // ⌘<key> quits; nil (default) = none
@property (nonatomic) BOOL muting;           // silence the speakers (on by default)
@property (nonatomic) NSTimeInterval idleDelay;
@end

@implementation AppDelegate {
    NSMutableArray<OverlayWindow *> *_windows;
    NSMutableArray<NSTextField *> *_clocks;
    NSMutableArray<NSSecureTextField *> *_fields;
    NSMutableArray<NSView *> *_backdrops;
    NSMutableArray<NSView *> *_panels;      // the whole centred banner stack
    NSMutableArray<NSTextField *> *_corners;
    NSTimer *_clockTimer;
    NSTimer *_idleTimer;
    NSTimer *_focusTimer;
    NSString *_stolenBy;     // who last took focus, so we log once per intrusion
    NSTimer *_lockdownTimer;

    // Kept so lockdown can rewrite the banner in place; the stack itself is
    // already in _panels, but the text has to change, not just the opacity.
    NSMutableArray<NSTextField *> *_icons;
    NSMutableArray<NSTextField *> *_titles;
    NSMutableArray<NSTextField *> *_subs;

    int _threatScore;
    NSTimeInterval _lastThreat;
    int _clickCount;
    NSTimeInterval _firstClick;
    int _lockdownCount;       // how many times this session; the 2nd is pricier
    BOOL _inLockdown;

    AudioObjectID _audioDev;
    UInt32 _origMute;
    BOOL _muted;              // we changed it and owe a restore
    NSDateFormatter *_clockFormat;
    NSArray<NSString *> *_screenFrames;
    NSTimeInterval _lastActivity;
    NSPoint _lastMouse;
    BOOL _awake;
    BOOL _quitting;
    FILE *_log;
    NSDateFormatter *_logFormat;
    NSMutableArray *_signalSources;
}

#pragma mark - volume

// Muting goes through CoreAudio rather than shelling out to osascript: no
// subprocess, no permission prompt, and we get the exact prior value back to
// restore instead of a rounded-off percentage.
//
// Note what is deliberately absent: any attempt to hold the mute against the
// user. This silences the speakers so a prank can't be heard, and puts them
// back exactly as they were.

static AudioObjectID DefaultOutputDevice(void) {
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDefaultOutputDevice,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                   0, NULL, &size, &dev) != noErr)
        return kAudioObjectUnknown;
    return dev;
}

static AudioObjectPropertyAddress MuteAddr(void) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyMute,
                                     kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    return a;
}

// A breadcrumb for the wrapper's watcher process. SIGKILL is the one exit we
// cannot handle, and it would leave the speakers off with nothing to explain
// why. The watcher reads this file after we die, puts the sound back, and
// deletes it. Written next to the caffeinate pidfile, for the same reason.
static NSString *AudioCrumbPath(void) {
    NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
    return [tmp stringByAppendingPathComponent:@"locky.audio"];
}

// Returns NO when the device simply has no settable mute — some USB and
// Bluetooth outputs don't — which is a reason to carry on quietly, not to fail.
- (BOOL)silence {
    if (_muted) return YES;
    _audioDev = DefaultOutputDevice();
    if (_audioDev == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress addr = MuteAddr();
    if (!AudioObjectHasProperty(_audioDev, &addr)) return NO;
    Boolean settable = false;
    if (AudioObjectIsPropertySettable(_audioDev, &addr, &settable) != noErr || !settable)
        return NO;
    UInt32 size = sizeof(_origMute);
    if (AudioObjectGetPropertyData(_audioDev, &addr, 0, NULL, &size, &_origMute) != noErr)
        return NO;
    UInt32 on = 1;
    if (AudioObjectSetPropertyData(_audioDev, &addr, 0, NULL, sizeof(on), &on) != noErr)
        return NO;
    _muted = YES;
    [[NSString stringWithFormat:@"%u\n", _origMute]
        writeToFile:AudioCrumbPath() atomically:YES
           encoding:NSUTF8StringEncoding error:NULL];
    [self note:@"AUDIO muted (was %@)", _origMute ? @"muted" : @"unmuted"];
    return YES;
}

- (void)restoreAudio {
    if (!_muted) return;
    AudioObjectPropertyAddress addr = MuteAddr();
    AudioObjectSetPropertyData(_audioDev, &addr, 0, NULL,
                               sizeof(_origMute), &_origMute);
    _muted = NO;
    [NSFileManager.defaultManager removeItemAtPath:AudioCrumbPath() error:NULL];
    [self note:@"AUDIO restored"];
}

#pragma mark - forensics

// This exists to answer exactly one question: how did somebody get past the
// overlay? locky can only see what is delivered to it, and that gap is the
// point — a shortcut handled by the window server (Mission Control, Spotlight)
// never reaches our monitor, so its *absence* from the log right before another
// app takes over is itself the finding. Appended to a file rather than stdout
// because a Spotlight launch has no terminal to print to.
//
// Plain unmodified keystrokes are deliberately NOT logged: the password is
// typed as ordinary key events, and it has no business sitting in a plaintext
// log. Only modifier combos and named keys are recorded, which is all that a
// bypass could ever be anyway.

static NSString *ModifierString(NSEventModifierFlags f) {
    NSMutableString *out = [NSMutableString string];
    if (f & NSEventModifierFlagControl)  [out appendString:@"^"];
    if (f & NSEventModifierFlagOption)   [out appendString:@"~"];
    if (f & NSEventModifierFlagShift)    [out appendString:@"+"];
    if (f & NSEventModifierFlagCommand)  [out appendString:@"@"];
    if (f & NSEventModifierFlagFunction) [out appendString:@"fn"];
    return out.length ? out : @"-";
}

// Named where a name is clearer, and never the raw character for a plain key.
static NSString *KeyLabel(NSEvent *e) {
    switch (e.keyCode) {
        case 53:  return @"esc";
        case 36:  return @"return";
        case 48:  return @"tab";
        case 49:  return @"space";
        case 51:  return @"delete";
        case 123: return @"left";
        case 124: return @"right";
        case 125: return @"down";
        case 126: return @"up";
        case 122: return @"F1";  case 120: return @"F2";
        case 99:  return @"F3";  case 118: return @"F4";
        case 96:  return @"F5";  case 97:  return @"F6";
        case 98:  return @"F7";  case 100: return @"F8";
        case 101: return @"F9";  case 109: return @"F10";
        case 103: return @"F11"; case 111: return @"F12";
    }
    NSEventModifierFlags interesting = NSEventModifierFlagCommand |
                                       NSEventModifierFlagControl |
                                       NSEventModifierFlagOption  |
                                       NSEventModifierFlagFunction;
    if (!(e.modifierFlags & interesting)) return nil;   // plain typing: not ours to record
    NSString *c = e.charactersIgnoringModifiers;
    if (c.length && [c characterAtIndex:0] > 0x20) return c;
    return [NSString stringWithFormat:@"keycode %d", (int)e.keyCode];
}

- (void)openLog {
    if (!self.logging) return;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    NSString *path = [dir stringByAppendingPathComponent:@"locky.log"];
    _log = fopen(path.fileSystemRepresentation, "a");
    if (!_log) {
        fprintf(stderr, "locky: cannot write %s\n", path.UTF8String);
        return;
    }
    // Line buffered on purpose. A force-quit is a SIGKILL, and anything still
    // sitting in a stdio buffer would die with us — losing precisely the last
    // few lines that say what happened.
    setlinebuf(_log);
    _logFormat = [[NSDateFormatter alloc] init];
    _logFormat.dateFormat = @"MM-dd HH:mm:ss.SSS";
}

- (void)note:(NSString *)fmt, ... {
    if (!_log) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(_log, "%s  %s\n",
            [_logFormat stringFromDate:NSDate.date].UTF8String, msg.UTF8String);
}

// Catchable signals only. SIGKILL cannot be caught by anyone, so a log that
// simply stops with no "exit" line is the signature of a force-quit or a
// `kill -9` — which is a diagnosis, not a gap.
- (void)watchSignals {
    if (!_log) return;
    _signalSources = [NSMutableArray array];
    int sigs[] = { SIGTERM, SIGINT, SIGHUP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(*sigs); i++) {
        int sig = sigs[i];
        signal(sig, SIG_IGN);   // the dispatch source only sees it if the default action is off
        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, dispatch_get_main_queue());
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(src, ^{
            [weakSelf note:@"EXIT  signal %d", sig];
            [weakSelf dismiss];
        });
        dispatch_resume(src);
        [_signalSources addObject:src];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self openLog];
    [self watchSignals];
    [self note:@"---- up  pid %d  strict=%d  banner=%d  hatch=%@  mute=%d ----",
               getpid(), self.strict, self.banner,
               self.escapeKey ? @"on" : @"off", self.muting];

    // Muted up front rather than on first threat: the point is that a prank
    // makes no noise, and by the time we have detected anything it has already
    // played. --nomute opts out of this, but not out of the lockdown mute.
    if (self.muting && ![self silence])
        [self note:@"AUDIO no settable mute on the default output"];

    _windows   = [NSMutableArray array];
    _clocks    = [NSMutableArray array];
    _fields    = [NSMutableArray array];
    _backdrops = [NSMutableArray array];
    _panels    = [NSMutableArray array];
    _icons     = [NSMutableArray array];
    _titles    = [NSMutableArray array];
    _subs      = [NSMutableArray array];
    _corners   = [NSMutableArray array];

    _clockFormat = [[NSDateFormatter alloc] init];
    _clockFormat.dateFormat = @"EEE d MMM  ·  HH:mm:ss";

    // Always start with the banner up so launching looks like it always has;
    // the idle timer takes it away a few seconds later.
    _awake = YES;
    _lastActivity = NSDate.timeIntervalSinceReferenceDate;
    _lastMouse = NSEvent.mouseLocation;

    [self buildWindows];

    // occlusionState is stale at build; re-dump once the compositor has settled
    // so a failing secondary display shows up as visible=1 but occlusionVisible=0.
    if (self.debug) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self dumpSettledCoverage]; });
    }

    if (!self.banner) {
        _idleTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                     repeats:YES
                                                       block:^(NSTimer *t) { [self checkIdle]; }];
    }

    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  repeats:YES
                                                    block:^(NSTimer *t) { [self tickClock]; }];

    // Deliberately unconditional: this is the safety net, so it runs even when
    // --banner or a missing idle timer means nothing else is ticking. Half a
    // second bounds how long anyone can type into whatever they surfaced, and
    // costs one cheap frontmost-app lookup per tick.
    _focusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  repeats:YES
                                                    block:^(NSTimer *t) {
        [self checkFocus];
        // Also reconcile screens here, not only on the parameter-change
        // notification: a display that was already attached but enumerated a
        // beat after launch never fires that notification, so it would be
        // missed for the whole session. This re-check is near-free — it bails
        // immediately when the frames are unchanged — and self-heals that race
        // within half a second. (See screensChanged.)
        [self screensChanged];
        // And keep every secondary-display window asserted at shield level and
        // fronted, in case one was occluded or demoted after launch.
        [self assertCoverage];
    }];
    [self tickClock];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(screensChanged)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];

    // There is no escape hatch unless --escape-key asks for one. The password
    // is the way out; ⌘<escapeKey> is an opt-in convenience on top of it.
    // Esc is deliberately NOT a way out either: it's the first thing anyone
    // pokes at (it still wakes the banner, though — poking at it should be
    // exactly as discouraging as it looks).
    __weak typeof(self) weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        typeof(self) self_ = weakSelf;
        if (!self_) return e;
        [self_ noteActivity];
        NSString *label = KeyLabel(e);
        if (label) [self_ note:@"key   %@ %@", ModifierString(e.modifierFlags), label];
        // The hatch is checked before anything scores it. A shortcut arrives as
        // two events — the modifier, then the key — which is two probes, so the
        // owner's own way out would otherwise black the screen for the instant
        // before it quits. Also placed before the ⌘Q swallow further down, so
        // --escape-key q genuinely makes ⌘Q the hatch rather than being eaten.
        if (self_.escapeKey && (e.modifierFlags & NSEventModifierFlagCommand) &&
            [e.charactersIgnoringModifiers.lowercaseString
                isEqualToString:self_.escapeKey]) {
            [self_ note:@"EXIT  escape hatch"];
            [self_ dismiss];
            return nil;
        }
        if ([self_ keyIsShady:e]) [self_ noteThreat:label ?: @"key"];
        else                      [self_ noteOrdinaryKey];
        if (e.keyCode == 53) return nil;  // swallow Esc
        if (e.modifierFlags & NSEventModifierFlagCommand) {
            NSString *key = e.charactersIgnoringModifiers.lowercaseString;
            // ⌘Q is the combination anyone reaches for first, so it's the one
            // that must go nowhere. We build no menu, so nothing would act on
            // it anyway — swallowing it just makes that explicit and immune to
            // a menu being added later.
            if ([key isEqualToString:@"q"]) return nil;
        }
        return e;
    }];

    // The other half of "wake on anything". We need no global monitor and no
    // Accessibility permission for this: our window covers every screen and
    // we're the active app, so every click and every mouse move is already
    // being delivered to us.
    NSEventMask activity = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                           NSEventMaskOtherMouseDown | NSEventMaskScrollWheel |
                           NSEventMaskFlagsChanged;
    [NSEvent addLocalMonitorForEventsMatchingMask:activity
                                          handler:^NSEvent *(NSEvent *e) {
        typeof(self) self_ = weakSelf;
        if (!self_) return e;
        [self_ noteActivity];
        // Modifier presses matter even with no key after them: a held ^ or @
        // followed by silence and then another app going active means the
        // shortcut was eaten above us, by the window server.
        if (e.type == NSEventTypeFlagsChanged) {
            [self_ note:@"mod   %@", ModifierString(e.modifierFlags)];
            // Only on the way down — the flags go to zero on release, and
            // counting that too would score every probe twice. Shift is absent
            // from this mask on purpose; see -keyIsShady:.
            NSEventModifierFlags shady = NSEventModifierFlagCommand |
                                         NSEventModifierFlagControl |
                                         NSEventModifierFlagOption  |
                                         NSEventModifierFlagFunction;
            if (e.modifierFlags & shady) [self_ noteThreat:@"modifier"];
        } else if (e.type == NSEventTypeLeftMouseDown ||
                   e.type == NSEventTypeRightMouseDown ||
                   e.type == NSEventTypeOtherMouseDown) {
            [self_ noteClick];
        }
        return e;
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                          handler:^NSEvent *(NSEvent *e) {
        [weakSelf noteMouseMoved];
        return e;
    }];

    // If another app somehow becomes frontmost, snap back immediately —
    // otherwise the keyboard belongs to whatever they switched to.
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
           selector:@selector(otherAppActivated:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];

    [NSApp activateIgnoringOtherApps:YES];
    [self applyKioskOptions];
}

// Kiosk presentation options: the permission-free way to shut down ⌘Tab,
// ⌘H and the Dock/menu bar. They only hold while we're the active app, and
// the system restores everything the moment this process dies — including a
// SIGKILL — so this can't leave the Mac wedged.
- (void)applyKioskOptions {
    NSApplicationPresentationOptions opts =
        NSApplicationPresentationHideDock |               // required for the rest
        NSApplicationPresentationHideMenuBar |
        NSApplicationPresentationDisableProcessSwitching | // kills ⌘Tab
        NSApplicationPresentationDisableHideApplication;   // kills ⌘H

    if (self.strict) {
        // On by default, because ⌘⌥Esc was the one thing that actually got past
        // this in the wild: Force Quit, pick locky, gone — no password, no
        // escape hatch. Confirmed by hand, and it was the *only* combination
        // that worked. Everything else people tried (⌘⌥⇧Esc held, Mission
        // Control, Spaces, ⌘F3, ⌃⌘Q) bounced off the options above.
        //
        // It also takes the power-button restart/shutdown dialog with it, which
        // is why this used to be opt-in. Losing those OS escape hatches is the
        // price of the deterrent working at all; --no-strict gives them back.
        opts |= NSApplicationPresentationDisableForceQuit |
                NSApplicationPresentationDisableSessionTermination;
    }

    @try {
        [NSApp setPresentationOptions:opts];
    } @catch (NSException *e) {
        fprintf(stderr, "locky: could not apply kiosk options (%s)\n",
                e.reason.UTF8String);
        return;
    }

    if (self.debug) {
        printf("kiosk: requested 0x%lx  active=%d  readback 0x%lx  %s\n",
               (unsigned long)opts, NSApp.isActive,
               (unsigned long)NSApp.presentationOptions,
               NSApp.presentationOptions == opts ? "APPLIED" : "NOT APPLIED");
        fflush(stdout);
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    if (_quitting) return;
    [self applyKioskOptions];  // options only hold while we're active
}

- (void)otherAppActivated:(NSNotification *)note {
    if (_quitting) return;
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier == getpid()) return;   // identity by pid; see checkFocus
    // Logged before the grabFocus check: knowing *what* took the screen is the
    // single most useful line in the log, whether or not we snatch it back.
    [self note:@"FOCUS lost to %@ (%@)", app.localizedName, app.bundleIdentifier];
    if (!self.grabFocus) return;
    [NSApp activateIgnoringOtherApps:YES];
    [self focusPrimaryField];
}

#pragma mark building

- (void)buildWindows {
    for (OverlayWindow *w in _windows) [w orderOut:nil];
    [_windows removeAllObjects];
    [_clocks removeAllObjects];
    [_fields removeAllObjects];
    [_backdrops removeAllObjects];
    [_panels removeAllObjects];
    [_icons removeAllObjects];
    [_titles removeAllObjects];
    [_subs removeAllObjects];
    [_corners removeAllObjects];

    NSScreen *main = NSScreen.mainScreen;
    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        [_windows addObject:[self windowForScreen:screen primary:(screen == main)]];
        [frames addObject:NSStringFromRect(screen.frame)];
    }
    _screenFrames = frames;
    [self focusPrimaryField];

    if (self.debug) {
        printf("screens: %lu\n", (unsigned long)NSScreen.screens.count);
        NSArray<NSScreen *> *screens = NSScreen.screens;
        for (NSUInteger i = 0; i < screens.count; i++) {
            NSRect s = screens[i].frame;
            NSRect w = _windows[i].frame;
            printf("  [%lu] screen %.0f,%.0f %.0fx%.0f  window %.0f,%.0f %.0fx%.0f  visible=%d space=%d level=%ld  %s\n",
                   (unsigned long)i,
                   s.origin.x, s.origin.y, s.size.width, s.size.height,
                   w.origin.x, w.origin.y, w.size.width, w.size.height,
                   _windows[i].isVisible, _windows[i].isOnActiveSpace,
                   (long)_windows[i].level,
                   NSEqualRects(s, w) ? "MATCH" : "MISMATCH");
        }
        fflush(stdout);
    }
}

// The build-time dump above reports geometry, but occlusionState is only
// meaningful once the compositor has settled — at build it is stale. This runs a
// couple of seconds after launch and answers the question isVisible can't: is
// each window *actually* on screen and unoccluded? A secondary-display window
// that reads visible=1 but occlusionVisible=0 is the real failure — AppKit
// thinks it's up, the window server has it covered.
- (void)dumpSettledCoverage {
    if (!self.debug || _quitting) return;
    printf("settled coverage (%lu windows):\n", (unsigned long)_windows.count);
    for (NSUInteger i = 0; i < _windows.count; i++) {
        OverlayWindow *w = _windows[i];
        BOOL occVisible = (w.occlusionState & NSWindowOcclusionStateVisible) != 0;
        printf("  [%lu] visible=%d onActiveSpace=%d occlusionVisible=%d level=%ld screen=%s\n",
               (unsigned long)i, w.isVisible, w.isOnActiveSpace, occVisible,
               (long)w.level, w.screen ? "set" : "nil");
    }
    fflush(stdout);
}

// Secondary-display coverage can be lost after launch even while AppKit still
// reports the window visible: another elevated window can occlude it, or the
// window server can demote a shield-level window on a non-active display. The
// focus timer calls this every tick to re-assert each window at the shielding
// level and re-front it. It deliberately skips the key window, so the focused
// password field — and anything being typed into it — is never disturbed.
- (void)assertCoverage {
    if (_quitting) return;
    NSWindowLevel shield = CGShieldingWindowLevel();
    for (OverlayWindow *w in _windows) {
        if (w.level != shield) w.level = shield;
        if (!w.isKeyWindow) [w orderFrontRegardless];
    }
}

- (OverlayWindow *)windowForScreen:(NSScreen *)screen primary:(BOOL)primary {
    // screen:nil on purpose — passing a screen makes contentRect relative to
    // that screen's origin, which double-offsets every non-primary display.
    // With nil the rect is global, which is exactly what screen.frame is.
    OverlayWindow *window = [[OverlayWindow alloc] initWithContentRect:screen.frame
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO
                                                                screen:nil];
    [window setFrame:screen.frame display:NO];
    // The window keeps only the invisible floor; the tint that actually fades
    // lives in the backdrop view below, because animating window.alphaValue is
    // a trap — a window at alpha 0 stops receiving mouse events, which would
    // silently un-block the mouse for the entire idle period.
    window.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:kFloorAlpha];
    window.opaque = NO;
    window.hasShadow = NO;
    window.ignoresMouseEvents = NO;
    window.acceptsMouseMovedEvents = YES;
    window.level = CGShieldingWindowLevel();
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorIgnoresCycle;
    window.releasedWhenClosed = NO;

    NSView *content = [[NSView alloc] initWithFrame:screen.frame];
    content.wantsLayer = YES;  // composited alpha, or the fades judder
    window.contentView = content;

    NSView *backdrop = [[NSView alloc] initWithFrame:content.bounds];
    backdrop.wantsLayer = YES;
    // Full black in lockdown, so a display plugged in mid-lockdown comes up
    // just as dark as the others rather than a helpful window onto the desktop.
    backdrop.layer.backgroundColor =
        [NSColor.blackColor colorWithAlphaComponent:
            _inLockdown ? 1.0 : self.alpha].CGColor;
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.alphaValue = _awake ? 1.0 : 0.0;
    [content addSubview:backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:content.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    [_backdrops addObject:backdrop];

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.wantsLayer = YES;
    stack.alphaValue = _awake ? 1.0 : 0.0;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ]];
    [_panels addObject:stack];

    NSTextField *icon = [self label:_inLockdown ? @"🚨" : @"🔒"
                                font:[NSFont systemFontOfSize:64]
                               alpha:0.95];
    [stack addArrangedSubview:icon];
    [_icons addObject:icon];

    NSTextField *head = [self label:_inLockdown ? @"Threat Detected" : self.title
                                font:[NSFont systemFontOfSize:40 weight:NSFontWeightSemibold]
                               alpha:0.95];
    [stack addArrangedSubview:head];
    [_titles addObject:head];
    // The subtitle is the line that actually does the work — it's the hero,
    // deliberately larger than "Locked". Wraps so a long --subtitle can't run
    // off the edge of the screen.
    NSTextField *sub = [self label:_inLockdown ? @"Initiating Lockdown Mode"
                                              : self.subtitle
                              font:[NSFont systemFontOfSize:44 weight:NSFontWeightSemibold]
                             alpha:0.92];
    sub.lineBreakMode = NSLineBreakByWordWrapping;
    sub.maximumNumberOfLines = 3;
    sub.preferredMaxLayoutWidth = screen.frame.size.width * 0.8;
    [sub.widthAnchor constraintLessThanOrEqualToConstant:screen.frame.size.width * 0.8].active = YES;
    [stack addArrangedSubview:sub];
    [_subs addObject:sub];

    NSTextField *clock = [self label:@""
                                font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]
                               alpha:0.55];
    [stack setCustomSpacing:22 afterView:sub];
    [stack addArrangedSubview:clock];
    [_clocks addObject:clock];

    NSSecureTextField *field = [[NSSecureTextField alloc] init];
    field.placeholderString = @"password";
    field.alignment = NSTextAlignmentCenter;
    field.font = [NSFont systemFontOfSize:15];
    field.delegate = self;
    field.bezeled = YES;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.focusRingType = NSFocusRingTypeNone;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintEqualToConstant:220].active = YES;
    [_fields addObject:field];

    // Anything left in the field when you walk up is a prankster's, so give it
    // a one-click wipe. (Enter on a wrong entry already clears it too.)
    NSButton *clear = [NSButton buttonWithTitle:@"✕" target:self action:@selector(clearFields:)];
    clear.bezelStyle = NSBezelStyleCircular;
    clear.toolTip = @"Clear";
    clear.focusRingType = NSFocusRingTypeNone;

    NSStackView *row = [NSStackView stackViewWithViews:@[field, clear]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    [stack setCustomSpacing:22 afterView:clock];
    [stack addArrangedSubview:row];

    // No "press X to dismiss" hint on purpose — advertising the way out is the
    // whole thing this is meant to prevent. ⌘K is the quiet escape hatch.

    // The idle-state marker. A separate view from the banner's big 🔒 so the two
    // can cross-fade by opacity, which is far less fiddly than animating one
    // glyph's constraints and font size across the screen.
    NSTextField *corner = [self label:@"🔒" font:[NSFont systemFontOfSize:22] alpha:0.9];
    corner.translatesAutoresizingMaskIntoConstraints = NO;
    corner.wantsLayer = YES;
    corner.alphaValue = _awake ? 0.0 : kCornerAlpha;
    [content addSubview:corner];
    [NSLayoutConstraint activateConstraints:@[
        [corner.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [corner.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-22],
    ]];
    [_corners addObject:corner];

    // Clicking anywhere on this screen's overlay moves the caret here.
    NSClickGestureRecognizer *click =
        [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(overlayClicked:)];
    click.delegate = self;
    [content addGestureRecognizer:click];

    [window orderFrontRegardless];
    if (primary) [window makeKeyWindow];
    return window;
}

- (NSTextField *)label:(NSString *)text font:(NSFont *)font alpha:(CGFloat)alpha {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = font;
    l.alignment = NSTextAlignmentCenter;
    l.textColor = [NSColor.whiteColor colorWithAlphaComponent:alpha];
    return l;
}

#pragma mark threat / lockdown

// The honest position first: while locky holds focus, none of these keys can
// actually *do* anything — they land in a password field that ignores them. So
// this is not a defence, it is a tell. Somebody typing letters is trying to
// guess the password; somebody cycling ⌘, ⌃, fn and Esc is hunting for a way
// out, and that is worth reacting to.
//
// Shift is the deliberate exception to "modifiers are suspicious". It is the
// one modifier you must press to type an ordinary password, so shift with a
// printable key is just typing — treating it as an attack would black the
// screen on anyone whose password contains a capital letter.
- (BOOL)keyIsShady:(NSEvent *)e {
    if (e.keyCode == 53 || e.keyCode == 48) return YES;      // esc, tab
    NSEventModifierFlags shady = NSEventModifierFlagCommand  |
                                 NSEventModifierFlagControl  |
                                 NSEventModifierFlagOption   |
                                 NSEventModifierFlagFunction;
    return (e.modifierFlags & shady) != 0;
}

// Note that an ordinary double-click is two clicks, so it scores as a probe on
// its own. That is the intent: nothing under the shield can be double-clicked,
// so trying it is already someone testing what the overlay will let through.
- (void)noteClick {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - _firstClick > kClickWindow) { _firstClick = now; _clickCount = 0; }
    if (++_clickCount >= kClickBurst) {
        _clickCount = 0;
        [self noteThreat:@"click burst"];
    }
}

// A probe followed by ordinary typing is its own tell: somebody tried a
// shortcut, found that it did nothing, and moved on to guessing the password.
// Neither half means much alone — plain typing is exactly what the field is
// for — but the pair inside one window is not somebody who brushed a key.
- (void)noteOrdinaryKey {
    if (_quitting || _inLockdown) return;
    if (_threatScore < 1) return;                      // nothing to pair with
    if (NSDate.timeIntervalSinceReferenceDate - _lastThreat > kThreatWindow) {
        _threatScore = 0;                              // the probe already decayed
        return;
    }
    [self note:@"THREAT hotkey then ordinary key"];
    [self enterLockdown];
}

- (void)noteThreat:(NSString *)why {
    if (_quitting) return;
    // Already black and silent: nothing further to escalate to, and re-arming
    // the timer on every keypress would let someone hold it dark forever.
    if (_inLockdown) return;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - _lastThreat > kThreatWindow) _threatScore = 0;   // decayed
    _lastThreat = now;
    _threatScore++;
    [self note:@"THREAT %@ (%d/%d)", why, _threatScore, kThreatThreshold];
    if (_threatScore >= kThreatThreshold) [self enterLockdown];
}

// The idle fade animates each view's alphaValue, which is already spoken for —
// it's what hides the banner. Lockdown changes a different thing: the tint's own
// opacity, living in the layer's background colour. Layer-backed views suppress
// implicit animations, so this is an explicit one. The model value is set first
// and the animation added second, which is the ordering that stops the layer
// snapping back to where it started when the animation finishes.
- (void)fadeBackdropsTo:(CGFloat)alpha {
    CGColorRef to = [NSColor.blackColor colorWithAlphaComponent:alpha].CGColor;
    for (NSView *v in _backdrops) {
        CABasicAnimation *fade =
            [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        fade.fromValue = (__bridge id)v.layer.backgroundColor;
        fade.toValue   = (__bridge id)to;
        fade.duration  = kLockdownFadeSeconds;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseInEaseOut];
        v.layer.backgroundColor = to;
        [v.layer addAnimation:fade forKey:@"lockdownFade"];
    }
}

- (void)enterLockdown {
    if (_inLockdown || _quitting) return;
    _inLockdown = YES;
    _threatScore = 0;
    NSTimeInterval secs = (++_lockdownCount > 1) ? kLockdownRepeat : kLockdownFirst;
    [self note:@"LOCKDOWN start %.0fs (#%d)", secs, _lockdownCount];

    // Silenced regardless of --nomute. Someone is actively probing the machine,
    // and whatever they were lining up to play is the entire reason this exists.
    // It stays muted until locky quits rather than coming back with the banner —
    // giving the sound back after two minutes just invites a second go.
    [self silence];

    [self setAwake:YES];      // never fade out mid-lockdown

    for (NSTextField *l in _icons)  l.stringValue = @"🚨";
    for (NSTextField *l in _titles) l.stringValue = @"Threat Detected";
    for (NSTextField *l in _subs)   l.stringValue = @"Initiating Lockdown Mode";
    [self fadeBackdropsTo:1.0];

    // No countdown on screen, on purpose: a visible timer tells whoever is
    // standing there exactly how long they need to wait.
    _lockdownTimer = [NSTimer scheduledTimerWithTimeInterval:secs
                                                     repeats:NO
                                                       block:^(NSTimer *t) {
        [self exitLockdown];
    }];
}

- (void)exitLockdown {
    if (!_inLockdown || _quitting) return;
    _inLockdown = NO;
    [_lockdownTimer invalidate];
    _lockdownTimer = nil;
    [self note:@"LOCKDOWN end"];

    for (NSTextField *l in _icons)  l.stringValue = @"🔒";
    for (NSTextField *l in _titles) l.stringValue = self.title;
    for (NSTextField *l in _subs)   l.stringValue = self.subtitle;
    [self fadeBackdropsTo:self.alpha];

    // Audio is deliberately left muted until we quit; see enterLockdown.
    _lastActivity = NSDate.timeIntervalSinceReferenceDate;
}

#pragma mark idle / wake

// Any input at all resets the countdown. Cheap enough to call from a monitor
// that fires on every mouse move: the common case is one float compare.
- (void)noteActivity {
    if (_quitting) return;
    _lastActivity = NSDate.timeIntervalSinceReferenceDate;
    if (!_awake) [self setAwake:YES];
}

- (void)noteMouseMoved {
    NSPoint now = NSEvent.mouseLocation;
    // Only refresh the reference point once we've actually accepted a move, so
    // slow genuine drift still accumulates past the threshold rather than being
    // nibbled away one sub-pixel at a time.
    if (fabs(now.x - _lastMouse.x) < kMoveThreshold &&
        fabs(now.y - _lastMouse.y) < kMoveThreshold) return;
    _lastMouse = now;
    [self noteActivity];
}

- (void)checkIdle {
    if (_quitting || !_awake) return;
    if (_inLockdown) return;   // the black screen is the point; don't fade it
    if (NSDate.timeIntervalSinceReferenceDate - _lastActivity < self.idleDelay) return;
    [self setAwake:NO];
}

- (void)setAwake:(BOOL)awake {
    if (_awake == awake || _quitting) return;
    if (!awake && self.banner) return;
    _awake = awake;

    if (!awake) {
        // Nobody's typing, so whatever is in the field is a prankster's mashing
        // or an abandoned attempt. Clear it while it's invisible.
        for (NSSecureTextField *f in _fields) f.stringValue = @"";
    }

    CGFloat panel  = awake ? 1.0 : 0.0;
    CGFloat corner = awake ? 0.0 : kCornerAlpha;

    // One animation group across every screen, so they move in lockstep.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = awake ? kFadeInSeconds : kFadeOutSeconds;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:
            awake ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseInEaseOut];
        for (NSView *v in self->_backdrops) v.animator.alphaValue = panel;
        for (NSView *v in self->_panels)    v.animator.alphaValue = panel;
        for (NSView *v in self->_corners)   v.animator.alphaValue = corner;
    }];

    // Deliberately no `hidden = YES` after the fade: hiding the stack would
    // resign the password field's first-responder status, and keeping that is
    // the entire point — you walk up to an apparently-idle Mac and type.
    if (self.debug) {
        printf("state: %s\n", awake ? "awake" : "idle");
        fflush(stdout);
    }
}

#pragma mark behaviour

// This recogniser exists only to move the caret when you click bare overlay —
// don't let it shadow the clear button or the field's own click handling.
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)gr
    shouldAttemptToRecognizeWithEvent:(NSEvent *)event {
    NSView *hit = [gr.view hitTest:event.locationInWindow];
    return ![hit isKindOfClass:NSControl.class] &&
           ![hit.superview isKindOfClass:NSControl.class];
}

- (void)overlayClicked:(NSClickGestureRecognizer *)sender {
    [self noteActivity];
    NSWindow *window = sender.view.window;
    if (!window) return;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    for (NSSecureTextField *f in _fields) {
        if (f.window == window) { [window makeFirstResponder:f]; break; }
    }
}

// Called two ways: from NSApplicationDidChangeScreenParametersNotification, and
// every 0.5s from the focus timer as a safety net for a display the notification
// never reported (one already attached at launch but enumerated late). Both
// fire for more than real display changes — hiding the menu bar/dock shifts
// every screen's visibleFrame and re-fires the notification — and rebuilding
// then would wipe a half-typed password, so only rebuild when the frames really
// moved. The frame-equality guard makes the periodic call cheap and safe.
- (void)screensChanged {
    NSMutableArray<NSString *> *now = [NSMutableArray array];
    for (NSScreen *s in NSScreen.screens) [now addObject:NSStringFromRect(s.frame)];
    if ([now isEqualToArray:_screenFrames]) return;
    [self buildWindows];
}

- (void)focusPrimaryField {
    OverlayWindow *target = nil;
    for (OverlayWindow *w in _windows) { if (w.isKeyWindow) { target = w; break; } }
    if (!target) target = _windows.firstObject;
    if (!target) return;

    [target makeKeyAndOrderFront:nil];
    for (NSSecureTextField *f in _fields) {
        if (f.window == target) { [target makeFirstResponder:f]; break; }
    }
}

// The two handlers above are edge-triggered: one activation notification, one
// attempt to take focus back. That is fast, but it is not a guarantee — if an
// app wins the race and never activates again, or grabs focus in a way we never
// get told about, nothing retries and we stay in the background for good.
//
// This is the level-triggered backstop. It doesn't care how focus was lost; it
// just asks who is frontmost and takes it back if the answer isn't us. That is
// the difference between locky usually getting focus back and always getting it
// back. Launchpad is the reason: it can launch anything, and the launched app
// activates on its own schedule, long after any notification we already handled.
- (void)checkFocus {
    if (_quitting || !self.grabFocus) return;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    // Identity by pid, which is unambiguous and says exactly what we mean: is
    // that me? It matters more than it looks — a second locky instance is a
    // genuinely different app that we *should* fight for focus, and the pid is
    // what separates that case from mistaking ourselves for the thief.
    if (!front || front.processIdentifier == getpid()) {
        _stolenBy = nil;   // we're back on top; the next theft is a fresh one
        return;
    }
    NSString *bid = front.bundleIdentifier ?: front.localizedName ?: @"?";
    // Never fight the real screen lock or the screen saver. If the Mac has
    // genuinely locked, that is a far better deterrent than we are, and clawing
    // focus back from the login window would be both useless and obnoxious.
    if ([bid isEqualToString:@"com.apple.loginwindow"] ||
        [bid isEqualToString:@"com.apple.ScreenSaver.Engine"]) return;
    // One line per intrusion rather than one per tick, or a determined app would
    // flood the log at 2 Hz and bury the thing you actually want to read.
    if (![bid isEqualToString:_stolenBy]) {
        [self note:@"REGRAB from %@ (%@)", front.localizedName, bid];
        _stolenBy = bid;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self focusPrimaryField];
}

- (void)tickClock {
    NSString *now = [_clockFormat stringFromDate:[NSDate date]];
    for (NSTextField *c in _clocks) c.stringValue = now;
}

- (void)applicationDidResignActive:(NSNotification *)note {
    if (!self.grabFocus || _quitting) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_quitting || !self.grabFocus) return;
        [NSApp activateIgnoringOtherApps:YES];
        [self focusPrimaryField];
    });
}

// Typing the password unlocks as soon as it matches — no Enter needed.
// Exact match: a prankster's leftovers in the field are yours to clear, either
// with the ✕ button or by pressing Enter on a wrong entry.
- (void)controlTextDidChange:(NSNotification *)note {
    NSTextField *field = note.object;
    if ([field.stringValue isEqualToString:self.password]) {
        [self note:@"EXIT  password"];
        [self dismiss];
    }
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:)) {
        if ([control.stringValue isEqualToString:self.password]) {
            [self note:@"EXIT  password"];
            [self dismiss];
        } else {
            control.stringValue = @"";
        }
        return YES;
    }
    return NO;
}

// Wipes every screen's field, not just the one clicked, so there's never a
// stale entry waiting on another display.
- (void)clearFields:(id)sender {
    [self noteActivity];
    for (NSSecureTextField *f in _fields) f.stringValue = @"";
    NSWindow *window = [sender isKindOfClass:NSView.class] ? [sender window] : nil;
    for (NSSecureTextField *f in _fields) {
        if (f.window == window) { [window makeFirstResponder:f]; break; }
    }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self restoreAudio];   // idempotent; dismiss normally got here first
    [self note:@"EXIT  clean shutdown"];
    if (_log) fclose(_log);
    _log = NULL;
}

- (void)dismiss {
    if (_quitting) return;
    _quitting = YES;
    [_clockTimer invalidate];
    [_idleTimer invalidate];
    [_focusTimer invalidate];
    [_lockdownTimer invalidate];
    [self restoreAudio];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    for (OverlayWindow *w in _windows) [w orderOut:nil];
    [NSApp terminate:nil];
}

@end

#pragma mark - main

static NSString *LoadPassword(void) {
    NSString *path = [@"~/pass.txt" stringByExpandingTildeInPath];
    NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : nil;
}

static void PrintUsage(void) {
    printf(
        "locky — semi-transparent \"don't touch my laptop\" overlay\n"
        "\n"
        "  locky [options]\n"
        "\n"
        "  -a, --alpha <0.05-0.95>   overlay opacity (default 0.55)\n"
        "  -m, --message <text>      main line (default \"Locked\")\n"
        "  -s, --subtitle <text>     second line\n"
        "  -p, --password <text>     override the password from ~/pass.txt\n"
        "      --banner              keep the banner up permanently, never idle\n"
        "      --idle-delay <sec>    seconds of no input before the banner fades\n"
        "                            out to a corner lock (default 5)\n"
        "      --no-focus-grab       don't pull focus back when you switch apps\n"
        "      --no-strict           allow ⌘⌥Esc force-quit and the power-button\n"
        "                            shutdown dialog (both blocked by default)\n"
        "      --escape-key <c>      add a ⌘<c> escape hatch that quits without\n"
        "                            the password (default: none at all)\n"
        "      --nomute              leave the system volume alone (locky mutes\n"
        "                            on start and restores it on exit)\n"
        "      --no-log              don't write ~/Library/Logs/locky.log\n"
        "      --debug               print screen/window geometry on startup\n"
        "  -h, --help                this\n"
        "\n"
        "The banner fades to a small corner lock after a few idle seconds and\n"
        "comes back on any key, click or mouse move. Clicks stay blocked and\n"
        "typing still goes to the password box the whole time — only the paint\n"
        "goes away, so you can watch what's running behind it.\n"
        "\n"
        "Dismiss by typing the password (from ~/pass.txt, default 8888). There is\n"
        "no escape hatch unless you add one with --escape-key; Esc and ⌘Q do\n"
        "nothing on purpose. A deterrent, not a lock.\n"
        "\n"
        "Poking at it is noticed. Modifier keys, Esc, Tab and bursts of clicking\n"
        "score as probing. Two of them within ten seconds — or one followed by\n"
        "ordinary typing — fades the screen to black for two minutes (five for a\n"
        "repeat) behind a 🚨 banner, and mutes the speakers even under --nomute.\n"
        "Sound comes back when locky quits, and the password and escape hatch\n"
        "both still work throughout.\n"
        "\n"
        "Modifier keystrokes, focus changes and how locky exited are appended to\n"
        "~/Library/Logs/locky.log, so you can see how somebody got past it. Plain\n"
        "typing is never logged — your password would be in it. --no-log opts out.\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        AppDelegate *delegate = [[AppDelegate alloc] init];
        delegate.alpha = 0.55;
        delegate.title = @"Locked";
        delegate.subtitle = @"Agents running — please don't touch 🤖";
        delegate.password = LoadPassword() ?: @"8888";
        delegate.grabFocus = YES;
        delegate.idleDelay = 5.0;
        delegate.logging = YES;
        delegate.strict = YES;
        delegate.muting = YES;

        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            NSString *next = (i + 1 < argc) ? @(argv[i + 1]) : nil;

            if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
                PrintUsage();
                return 0;
            } else if (([arg isEqualToString:@"-a"] || [arg isEqualToString:@"--alpha"]) && next) {
                delegate.alpha = MIN(MAX(next.doubleValue, 0.05), 0.95);
                i++;
            } else if (([arg isEqualToString:@"-m"] || [arg isEqualToString:@"--message"]) && next) {
                delegate.title = next; i++;
            } else if (([arg isEqualToString:@"-s"] || [arg isEqualToString:@"--subtitle"]) && next) {
                delegate.subtitle = next; i++;
            } else if (([arg isEqualToString:@"-p"] || [arg isEqualToString:@"--password"]) && next) {
                delegate.password = next; i++;
            } else if ([arg isEqualToString:@"--banner"]) {
                delegate.banner = YES;
            } else if ([arg isEqualToString:@"--idle-delay"] && next) {
                delegate.idleDelay = MIN(MAX(next.doubleValue, 1.0), 3600.0);
                i++;
            } else if ([arg isEqualToString:@"--no-focus-grab"]) {
                delegate.grabFocus = NO;
            } else if ([arg isEqualToString:@"--debug"]) {
                delegate.debug = YES;
            } else if ([arg isEqualToString:@"--strict"]) {
                delegate.strict = YES;      // now the default; kept so old aliases still work
            } else if ([arg isEqualToString:@"--no-strict"]) {
                delegate.strict = NO;
            } else if ([arg isEqualToString:@"--escape-key"]) {
                if (!next) {
                    fprintf(stderr, "locky: --escape-key needs a character or "
                                    "NONE\n");
                    return 1;
                }
                NSString *want = next.lowercaseString;
                if ([want isEqualToString:@"none"]) {
                    delegate.escapeKey = nil;
                } else if (want.length == 1) {
                    delegate.escapeKey = want;
                } else {
                    fprintf(stderr, "locky: --escape-key takes one character or "
                                    "NONE (got \"%s\")\n", next.UTF8String);
                    return 1;
                }
                i++;
            } else if ([arg isEqualToString:@"--nomute"] ||
                       [arg isEqualToString:@"--no-mute"]) {
                delegate.muting = NO;
            } else if ([arg isEqualToString:@"--no-log"]) {
                delegate.logging = NO;
            }
        }

        NSApplication *app = NSApplication.sharedApplication;
        // .regular, not .accessory: kiosk presentation options (DisableProcessSwitching
        // in particular) are only enforced for an app that owns the menu bar. The dock
        // icon and menu bar that .regular brings are both hidden by those same options.
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
