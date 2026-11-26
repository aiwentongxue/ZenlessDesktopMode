#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "DesktopPolicy.hpp"
#include "TextInputFocus.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <type_traits>

namespace {

#ifdef ZZZDM_EMBED_CURSOR
#include "EmbeddedCursor.hpp"
#endif

template<class Result = id, class... Args>
Result Send(id object, const char *selector, Args... args) {
    if (object) {
        return reinterpret_cast<Result (*)(id, SEL, Args...)>(objc_msgSend)(
            object, sel_registerName(selector), args...);
    }
    if constexpr (!std::is_void_v<Result>) return Result{};
}

UIView *MetalView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    if ([view.layer isKindOfClass:CAMetalLayer.class]) return view;
    for (UIView *child in view.subviews.reverseObjectEnumerator) {
        if (UIView *found = MetalView(child)) return found;
    }
    return nil;
}

UIView *GameView() {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        UIViewController *root = ((UIWindowScene *)scene).keyWindow.rootViewController;
        if (root.presentedViewController) continue;
        if (UIView *view = MetalView(root.viewIfLoaded)) return view;
    }
    return nil;
}

CGRect Viewport(id window, UIView *view) {
    if (!view.window || !Send<BOOL>(window, "isKeyWindow") || Send<BOOL>(window, "isSheet")) return CGRectNull;
    id responder = Send(window, "firstResponder");
    if ([responder isKindOfClass:NSClassFromString(@"NSTextView")] ||
        [responder isKindOfClass:NSClassFromString(@"NSTextField")]) return CGRectNull;
    CGRect content = Send<CGRect>(window, "contentLayoutRect");
    constexpr NSUInteger WindowFullScreen = 1UL << 14;
    if (Send<NSUInteger>(window, "styleMask") & WindowFullScreen) {
        id macView = Send(window, "contentView");
        if (!macView) return CGRectNull;
        content = Send<CGRect>(macView, "convertRect:toView:", Send<CGRect>(macView, "bounds"), (id)nil);
    }
    content = Send<CGRect>(window, "convertRectToScreen:", content);
    const CGRect bounds = view.window.bounds;
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(content)) return CGRectNull;

    CGRect viewport = [view convertRect:view.bounds toView:view.window];
    const double scaleX = content.size.width / bounds.size.width;
    const double scaleY = content.size.height / bounds.size.height;
    NSArray *screens = Send(NSClassFromString(@"NSScreen"), "screens");
    if (!screens.count) return CGRectNull;
    const double quartzOriginY = CGRectGetMaxY(Send<CGRect>(screens.firstObject, "frame")) - CGRectGetMaxY(content);
    return CGRectMake(content.origin.x + (viewport.origin.x - bounds.origin.x) * scaleX,
                      quartzOriginY + (viewport.origin.y - bounds.origin.y) * scaleY,
                      viewport.size.width * scaleX, viewport.size.height * scaleY);
}

bool IsGameHit(UIView *view, CGRect viewport, CGPoint point) {
    if (!CGRectContainsPoint(viewport, point)) return false;
    const CGRect bounds = view.bounds;
    const CGPoint local = CGPointMake(
        bounds.origin.x + (point.x - viewport.origin.x) * bounds.size.width / viewport.size.width,
        bounds.origin.y + (point.y - viewport.origin.y) * bounds.size.height / viewport.size.height);
    UIView *hit = [view.window hitTest:[view convertPoint:local toView:view.window] withEvent:nil];
    return hit == view || [hit isDescendantOfView:view];
}

CGPoint PointerLocation() {
    NSArray *screens = Send(NSClassFromString(@"NSScreen"), "screens");
    const CGRect primary = Send<CGRect>(screens.firstObject, "frame");
    const CGPoint location = Send<CGPoint>(NSClassFromString(@"NSEvent"), "mouseLocation");
    return CGPointMake(location.x, CGRectGetMaxY(primary) - location.y);
}

CGImageRef CursorFromPNG(NSData *data) CF_RETURNS_RETAINED {
    if (data.length == 0 || data.length > 1024 * 1024) return nullptr;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!source) return nullptr;
    NSDictionary *metadata = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    const bool valid = [(__bridge NSString *)CGImageSourceGetType(source) isEqualToString:@"public.png"] &&
                       CGImageSourceGetCount(source) == 1 &&
                       [metadata[(__bridge NSString *)kCGImagePropertyPixelWidth] intValue] == 64 &&
                       [metadata[(__bridge NSString *)kCGImagePropertyPixelHeight] intValue] == 64;
    CGImageRef raster = valid ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    CFRelease(source);
    return raster;
}

NSURL *SupportDirectory() {
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [library URLByAppendingPathComponent:@"ZenlessDesktopMode" isDirectory:YES];
}

bool Diagnostics() {
    static const bool enabled = [NSFileManager.defaultManager fileExistsAtPath:
        [SupportDirectory() URLByAppendingPathComponent:@"diagnostics"].path];
    return enabled;
}

id MakeGameCursor() {
    NSURL *path = [SupportDirectory() URLByAppendingPathComponent:@"cursor.png"];
    NSNumber *size = nil;
    CGImageRef image = nullptr;
    if ([path getResourceValue:&size forKey:NSURLFileSizeKey error:nil] && size.unsignedIntegerValue <= 1024 * 1024) {
        image = CursorFromPNG([NSData dataWithContentsOfURL:path]);
        if (image) NSLog(@"[ZenlessDesktopMode] cursor source=local");
    }
#ifdef ZZZDM_EMBED_CURSOR
    if (!image) {
        image = CursorFromPNG([NSData dataWithBytes:EmbeddedCursorPNG length:sizeof(EmbeddedCursorPNG)]);
        if (image) NSLog(@"[ZenlessDesktopMode] cursor source=embedded");
    }
#endif
    if (!image) return nil;
    id artwork = Send(Send(NSClassFromString(@"NSImage"), "alloc"), "initWithCGImage:size:",
                      image, CGSizeMake(32, 32));
    CGImageRelease(image);
    return artwork ? Send(Send(NSClassFromString(@"NSCursor"), "alloc"), "initWithImage:hotSpot:",
                          artwork, CGPointMake(2.5, 0.5)) : nil;
}

using CursorSet = void (*)(id, SEL);
CursorSet originalCursorSet;
id gameCursor;
id systemArrow;
bool ownsGameCursor;

void SetGameCursor(id cursor, SEL selector) {
    if (NSThread.isMainThread && ownsGameCursor && cursor == systemArrow) cursor = gameCursor;
    originalCursorSet(cursor, selector);
}

void InstallGameCursor() {
    Class cursor = NSClassFromString(@"NSCursor");
    Method setter = class_getInstanceMethod(cursor, sel_registerName("set"));
    if (!setter) return;
    gameCursor = MakeGameCursor();
    systemArrow = Send(cursor, "arrowCursor");
    if (gameCursor && systemArrow) {
        originalCursorSet = reinterpret_cast<CursorSet>(method_setImplementation(setter, reinterpret_cast<IMP>(SetGameCursor)));
    }
}

double CameraGain() {
    constexpr double DefaultGain = 0.72;
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectoryForUser(NSUserName()) isDirectory:YES];
    NSURL *settings = [home URLByAppendingPathComponent:
        @"Library/Containers/io.playcover.PlayCover/App Settings/com.miHoYo.Nap.plist"];
    NSNumber *value = [NSDictionary dictionaryWithContentsOfURL:settings][@"sensitivity"];
    return [value isKindOfClass:NSNumber.class] && std::isfinite(value.doubleValue)
        ? DefaultGain * (std::clamp(value.doubleValue, 0.0, 100.0) / 50.0)
        : DefaultGain;
}

enum EventType : NSUInteger {
    LeftDown = 1, LeftUp, RightDown, RightUp, Moved, LeftDragged, RightDragged,
    MouseEntered = 8, MouseExited, KeyDown, KeyUp, FlagsChanged,
    CursorUpdate = 17, Wheel = 22, OtherDown = 25, OtherUp, OtherDragged,
};

constexpr NSUInteger EventMask(EventType type) { return 1ULL << type; }
constexpr NSUInteger InputMask = EventMask(LeftDown) | EventMask(LeftUp) | EventMask(RightDown) |
    EventMask(RightUp) | EventMask(Moved) | EventMask(LeftDragged) | EventMask(RightDragged) |
    EventMask(MouseEntered) | EventMask(MouseExited) | EventMask(KeyDown) | EventMask(KeyUp) |
    EventMask(FlagsChanged) | EventMask(CursorUpdate) | EventMask(Wheel) |
    EventMask(OtherDown) | EventMask(OtherUp) | EventMask(OtherDragged);
// AppKit carries these per-side masks on flagsChanged events.
struct Modifier {
    unsigned key;
    NSUInteger side;
};
constexpr std::array Modifiers{
    Modifier{304, 0x02}, Modifier{303, 0x04}, Modifier{308, 0x20}, Modifier{307, 0x40},
    Modifier{306, 0x01}, Modifier{305, 0x2000},
};
constexpr NSUInteger CommandHeld = 1UL << 20;
constexpr NSUInteger OptionHeld = 1UL << 19;
constexpr NSUInteger CapsLockHeld = 1UL << 16;
constexpr NSUInteger FunctionHeld = 1UL << 23;
constexpr unsigned TabKey = zzz::MacKeys[0x30];

bool StartsKeyboardInput(id event, NSUInteger type, unsigned key, NSUInteger flags) {
    if (flags & CommandHeld) return false;
    if (type == KeyDown) return !Send<BOOL>(event, "isARepeat");
    if (type != FlagsChanged) return false;
    for (const auto &modifier : Modifiers) {
        if (modifier.key == key) {
            const bool option = key == 308 || key == 307;
            return (flags & modifier.side) || (option && (flags & OptionHeld) && !(flags & (0x20 | 0x40)));
        }
    }
    return false;
}

using Warp = CGError (*)(CGPoint);
using Associate = CGError (*)(boolean_t);
using CursorDisplay = CGError (*)(CGDirectDisplayID);

const auto warpPointer = reinterpret_cast<Warp>(dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition"));
const auto associatePointer = reinterpret_cast<Associate>(dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition"));
const auto hidePointer = reinterpret_cast<CursorDisplay>(dlsym(RTLD_DEFAULT, "CGDisplayHideCursor"));
const auto showPointer = reinterpret_cast<CursorDisplay>(dlsym(RTLD_DEFAULT, "CGDisplayShowCursor"));

} // namespace

@interface ZZZDMPlayCoverHost : NSObject
- (void)start;
@end

@interface ZZZDMControllerState : NSObject {
@public
    zzz::ControllerActivity activity;
}
@end

@implementation ZZZDMControllerState
@end

@implementation ZZZDMPlayCoverHost {
    CADisplayLink *_link;
    id _inputMonitor;
    __weak id _gameWindow;
    __weak UIView *_gameView;
    CGRect _viewport;
    zzz::KeyboardState _keys;
    zzz::MouseState _mouse;
    std::array<int, 2> _screenSize;
    bool _keyboardRelay;
    bool _mouseRelay;
    bool _pendingMouse;
    double _cameraGain;
    std::array<int, 4> _lastDirections;
    CGPoint _capturePoint;
    CFTimeInterval _captureStarted;
    zzz::CaptureWarp _captureWarp;
    __weak id _cursorRectWindow;
    __weak id _trackingWindow;
    bool _previousMouseTracking;
    bool _pointerUnlocked;
    bool _loading;
    bool _wheelCursorHidden;
    CGPoint _wheelOrigin;
    CGPoint _wheelLastPoint;
    int _wheelSelection;
    zzz::PointerVisibility _visibility;
    zzz::PointerActivity _pointerActivity;
    NSMapTable<GCController *, ZZZDMControllerState *> *_controllerStates;
    zzz::Layout _layout;
    bool _switchingLayout;
    int _lastCursorState;
    bool _captured;
    CFTimeInterval _ignoreMouseMotionUntil;
}

- (void)start {
    desktop::ObserveTextInputFocus();
    InstallGameCursor();
    _controllerStates = [NSMapTable weakToStrongObjectsMapTable];
    _cameraGain = CameraGain();
    if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] camera motion gain=%.3f", _cameraGain);
    Class events = NSClassFromString(@"NSEvent");
    id (^receive)(id) = ^id(id event) { return [self event:event]; };
    _inputMonitor = Send(events, "addLocalMonitorForEventsMatchingMask:handler:", InputMask, receive);
    for (NSString *name in @[@"NSApplicationDidResignActiveNotification", @"NSWindowDidResignKeyNotification",
                              UIApplicationWillResignActiveNotification, UIApplicationWillTerminateNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(releasePointer:)
                                                   name:name object:nil];
    }
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)flushMouse {
    if (!_pendingMouse) return;
    if (_screenSize[0] > 0 && _screenSize[1] > 0) zzz::QueueMouse(_mouse);
    _pendingMouse = false;
    _mouse.dx = _mouse.dy = _mouse.scrollX = _mouse.scrollY = 0;
    _mouse.clickCount = 0;
}

- (void)releaseKeyboard {
    if (_keys.none()) return;
    for (unsigned key = 1; key < _keys.size(); ++key) {
        if (_keys[key]) zzz::SendGameKey(key, false);
    }
    _keys.reset();
}

- (void)releaseMouse {
    _pendingMouse = _mouse.buttons != 0;
    _mouse.dx = _mouse.dy = _mouse.scrollX = _mouse.scrollY = 0;
    _mouse.buttons = 0;
    [self flushMouse];
    _captureWarp.reset();
}

- (bool)keyboardEvent:(id)event type:(NSUInteger)type {
    const auto scancode = Send<unsigned short>(event, "keyCode");
    if (scancode >= zzz::MacKeys.size()) return false;
    const unsigned key = zzz::MacKeys[scancode];
    if (!key) return false;
    const NSUInteger flags = Send<NSUInteger>(event, "modifierFlags");
    if (key == 309 || key == 310) return false;
    if (_layout == zzz::Layout::controller && StartsKeyboardInput(event, type, key, flags)) {
        [self switchLayout:zzz::Layout::keyboardMouse source:"keyboard"];
    }
    bool changed = false;
    const auto update = [&](unsigned code, bool pressed) {
        if (!zzz::SetKey(_keys, code, pressed)) return;
        if (code == TabKey && !pressed && _wheelCursorHidden) {
            [self updateWheelSelectionAt:PointerLocation()];
            const bool confirmed = zzz::ConfirmShortcutWheel(_wheelSelection);
            if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] shortcut wheel release index=%d confirmed=%d",
                                     _wheelSelection, confirmed);
            [self stopShortcutWheel];
        }
        zzz::SendGameKey(code, pressed);
        changed = true;
    };
    if (type == FlagsChanged) {
        for (const auto &modifier : Modifiers) {
            bool pressed = (flags & modifier.side) != 0;
            if (modifier.key == key && (key == 308 || key == 307) &&
                (flags & OptionHeld) && !(flags & (0x20 | 0x40))) pressed = true;
            update(modifier.key, pressed);
        }
        update(301, (flags & CapsLockHeld) != 0);
    } else if (type == KeyUp || !(flags & CommandHeld)) {
        update(key, type == KeyDown);
    }
    if (changed && Diagnostics() &&
        (key == 'w' || key == 'a' || key == 308 || key == 307 || key == 304 || key == 303 ||
         zzz::FunctionKeyInputIndex(key))) {
        NSLog(@"[ZenlessDesktopMode] game keyboard event=%lu key=%u W=%d A=%d leftAlt=%d leftShift=%d Fn=%d",
              (unsigned long)type, key, _keys.test('w'), _keys.test('a'), _keys.test(308), _keys.test(304),
              (flags & FunctionHeld) != 0);
    }
    // Let macOS handle Command shortcuts. Other supported game key edges
    // already reached Unity through the desktop keyboard.
    return type != FlagsChanged && !(flags & CommandHeld);
}

- (void)mousePosition:(CGPoint)point {
    if (CGRectIsEmpty(_viewport)) return;
    const double x = (point.x - _viewport.origin.x) / _viewport.size.width;
    const double y = (point.y - _viewport.origin.y) / _viewport.size.height;
    _mouse.x = static_cast<float>(_screenSize[0] * std::clamp(x, 0.0, 1.0));
    _mouse.y = static_cast<float>(_screenSize[1] * std::clamp(1.0 - y, 0.0, 1.0));
}

- (bool)startsMouseInput:(id)event type:(NSUInteger)type point:(CGPoint)point {
    if (!IsGameHit(_gameView, _viewport, point)) {
        _pointerActivity.reset();
        return false;
    }
    if (type == LeftDown || type == RightDown || type == OtherDown) return true;
    if (type == Wheel) {
        return !Send<NSUInteger>(event, "momentumPhase") &&
            (Send<CGFloat>(event, "scrollingDeltaX") != 0 || Send<CGFloat>(event, "scrollingDeltaY") != 0);
    }
    const CFTimeInterval now = CACurrentMediaTime();
    return type == Moved && now >= _ignoreMouseMotionUntil &&
        _pointerActivity.update(now, Send<CGFloat>(event, "deltaX"), Send<CGFloat>(event, "deltaY"));
}

- (id)event:(id)event {
    id macApp = Send(NSClassFromString(@"NSApplication"), "sharedApplication");
    id window = Send(macApp, "keyWindow");
    if (!Send<BOOL>(macApp, "isActive") || !window || window != _gameWindow ||
        CGRectIsEmpty(Viewport(window, _gameView))) return event;
    id targetWindow = Send(event, "window");
    if (targetWindow && targetWindow != window) return event;

    const auto type = Send<NSUInteger>(event, "type");
    if (type == KeyDown || type == KeyUp || type == FlagsChanged) {
        if (desktop::TextInputFocused()) {
            [self stopShortcutWheel];
            [self releaseKeyboard];
            return event;
        }
        return _keyboardRelay && [self keyboardEvent:event type:type] ? nil : event;
    }
    if (_wheelCursorHidden) {
        [self updateWheelSelectionAt:PointerLocation()];
        return nil;
    }
    if (_layout == zzz::Layout::controller && [self startsMouseInput:event type:type point:PointerLocation()]) {
        [self switchLayout:zzz::Layout::keyboardMouse source:"mouse"];
    }
    if (type == CursorUpdate || type == MouseEntered || type == MouseExited) {
        [self updateCursorAt:PointerLocation() force:true];
        return type == CursorUpdate && ownsGameCursor ? nil : event;
    }
    if (_pointerUnlocked && (type == Moved || type == LeftDragged || type == RightDragged || type == OtherDragged)) {
        [self updateCursorAt:PointerLocation() force:true];
    }
    if (!_mouseRelay || _screenSize[0] <= 0 || _screenSize[1] <= 0) return event;
    const CGPoint point = _captured ? _capturePoint : PointerLocation();
    if (!_captured && !_mouse.buttons && !IsGameHit(_gameView, _viewport, point)) return event;
    [self mousePosition:point];

    const bool down = type == LeftDown || type == RightDown || type == OtherDown;
    const bool up = type == LeftUp || type == RightUp || type == OtherUp;
    if (down || up) {
        const auto button = Send<NSUInteger>(event, "buttonNumber");
        if (button > 4) return event;
        const uint16_t bit = 1U << button;
        // Catalyst delivers the visible pointer's primary button to Unity's
        // iOS UI as a touch. Let the game handle clicks and drags on that path.
        if (button == 0 && _pointerUnlocked && !(_mouse.buttons & bit)) return event;
        _mouse.buttons = down ? _mouse.buttons | bit : _mouse.buttons & ~bit;
        _mouse.clickCount = down ? static_cast<uint16_t>(std::clamp<NSInteger>(Send<NSInteger>(event, "clickCount"), 1, 3)) : 0;
        _pendingMouse = true;
        [self flushMouse];
        return nil;
    }
    if (type == Wheel) {
        const bool precise = Send<BOOL>(event, "hasPreciseScrollingDeltas");
        const double x = Send<CGFloat>(event, "scrollingDeltaX");
        const double y = Send<CGFloat>(event, "scrollingDeltaY");
        const double factor = precise ? 3.0 : 120.0;
        if (Diagnostics() && y != 0) NSLog(@"[ZenlessDesktopMode] wheel y=%.2f captured=%d", y, _captured);
        _mouse.scrollX += x * factor;
        _mouse.scrollY += y * factor;
    } else {
        const double dx = Send<CGFloat>(event, "deltaX");
        const double dy = Send<CGFloat>(event, "deltaY");
        if (_captured) {
            if (Send<CFTimeInterval>(event, "timestamp") < _captureStarted) return event;
            const auto [relativeX, relativeY] = _captureWarp.correct(dx, dy);
            // Camera motion uses relative input, independent of the render scale.
            _mouse.dx += relativeX * _cameraGain;
            _mouse.dy -= relativeY * _cameraGain;
        } else {
            _mouse.dx += dx * (_screenSize[0] / _viewport.size.width);
            _mouse.dy -= dy * (_screenSize[1] / _viewport.size.height);
        }
    }
    _pendingMouse = true;
    return type == Wheel ? nil : event;
}

- (void)trackingWindow:(id)window {
    if (_trackingWindow == window) return;
    Send<void>(_trackingWindow, "setAcceptsMouseMovedEvents:", _previousMouseTracking);
    _trackingWindow = window;
    _previousMouseTracking = Send<BOOL>(window, "acceptsMouseMovedEvents");
    Send<void>(window, "setAcceptsMouseMovedEvents:", YES);
}

- (void)updateCursorAt:(CGPoint)location force:(bool)force {
    if (!originalCursorSet) return;
    const bool wanted = _pointerUnlocked && IsGameHit(_gameView, _viewport, location);
    id window = wanted ? _gameWindow : nil;
    ownsGameCursor = wanted;
    if (_cursorRectWindow != window) {
        Send<void>(_cursorRectWindow, "enableCursorRects");
        _cursorRectWindow = nil;
        if (Send<BOOL>(window, "areCursorRectsEnabled")) {
            Send<void>(window, "disableCursorRects");
            _cursorRectWindow = window;
        }
    }

    // The native cursor stays responsive while Unity is loading a new view.
    id current = Send(NSClassFromString(@"NSCursor"), "currentCursor");
    const auto set = sel_registerName("set");
    if (wanted && (force || current != gameCursor)) originalCursorSet(gameCursor, set);
    else if (!wanted && current == gameCursor) originalCursorSet(systemArrow, set);
}

- (void)capture:(bool)needed center:(CGPoint)center {
    if (!needed && _captured) {
        if (associatePointer(true) != kCGErrorSuccess) return;
        showPointer(kCGNullDirectDisplay);
        _captured = false;
        _mouse.dx = _mouse.dy = 0;
        _captureWarp.reset();
    }
    if (!needed || _captured || !associatePointer || !hidePointer || !showPointer) return;
    const CGPoint before = PointerLocation();
    const bool needsWarp = !CGRectContainsPoint(_viewport, before);
    if (needsWarp && !warpPointer) return;
    if (associatePointer(false) != kCGErrorSuccess) return;
    if (hidePointer(kCGNullDirectDisplay) != kCGErrorSuccess) {
        associatePointer(true);
        return;
    }
    if (needsWarp && warpPointer(center) != kCGErrorSuccess) {
        showPointer(kCGNullDirectDisplay);
        associatePointer(true);
        return;
    }
    _captured = true;
    _captureStarted = NSProcessInfo.processInfo.systemUptime;
    _capturePoint = needsWarp ? center : before;
    _captureWarp.reset(_capturePoint.x - before.x, _capturePoint.y - before.y);
    // Drop movement from the visible pointer before the camera consumes it.
    _mouse.dx = _mouse.dy = 0;
    if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] Quartz pointer captured warp=%d", needsWarp);
}

- (void)updateWheelSelectionAt:(CGPoint)point {
    if (CGPointEqualToPoint(point, _wheelLastPoint)) return;
    _wheelLastPoint = point;
    const auto direction = zzz::ShortcutWheelDirection(point.x - _wheelOrigin.x, point.y - _wheelOrigin.y,
                                                       _viewport.size.height);
    const int selection = zzz::SelectShortcutWheelDirection(direction);
    if (Diagnostics() && selection != _wheelSelection) {
        NSLog(@"[ZenlessDesktopMode] shortcut wheel direction=(%.2f, %.2f) index=%d", direction[0], direction[1], selection);
    }
    _wheelSelection = selection;
}

- (void)startShortcutWheel:(CGPoint)center {
    if (_wheelCursorHidden || _captured || !hidePointer || !showPointer ||
        hidePointer(kCGNullDirectDisplay) != kCGErrorSuccess) return;
    _wheelCursorHidden = true;
    _wheelOrigin = PointerLocation();
    if (warpPointer && warpPointer(center) == kCGErrorSuccess) {
        if (associatePointer) associatePointer(true);
        _wheelOrigin = center;
    }
    _wheelLastPoint = _wheelOrigin;
    _wheelSelection = -1;
    if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] shortcut wheel started");
}

- (void)stopShortcutWheel {
    if (_wheelCursorHidden && showPointer(kCGNullDirectDisplay) == kCGErrorSuccess) _wheelCursorHidden = false;
    _wheelSelection = -1;
}

- (void)releasePointer:(NSNotification *)notification {
    if ([notification.name isEqualToString:@"NSWindowDidResignKeyNotification"] &&
        Send(Send(NSClassFromString(@"NSApplication"), "sharedApplication"), "keyWindow")) return;
    [self capture:false center:CGPointZero];
    [self stopShortcutWheel];
    _pointerUnlocked = false;
    [self updateCursorAt:CGPointZero force:false];
    [self trackingWindow:nil];
    [self releaseKeyboard];
    [self releaseMouse];
    _gameWindow = nil;
    _gameView = nil;
    _keyboardRelay = _mouseRelay = false;
    zzz::SetKeyboardRouteActive(false);
    _visibility.update(false, false, true);
    _pointerActivity.reset();
}

- (void)configureInput:(const zzz::InputState &)input focused:(bool)focused {
    if (_layout != input.layout) {
        [self releaseKeyboard];
        _layout = input.layout;
        _pointerActivity.reset();
        if (_layout == zzz::Layout::controller) _ignoreMouseMotionUntil = CACurrentMediaTime() + 0.20;
        if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] game layout=%d", static_cast<int>(_layout));
    }
    const bool desktop = focused && zzz::IsDesktopLayout(_layout);
    _keyboardRelay = desktop && input.keyboardBridged;
    zzz::SetKeyboardRouteActive(_keyboardRelay);
    _mouseRelay = desktop && input.mouseBridged && _layout == zzz::Layout::keyboardMouse;
    const bool editing = desktop::TextInputFocused();
    if (editing) [self stopShortcutWheel];
    if (!_keyboardRelay || editing) [self releaseKeyboard];
    if (!_mouseRelay) [self releaseMouse];
    if (_mouseRelay) _screenSize = zzz::InputScreenSize();
    [self trackingWindow:desktop ? _gameWindow : nil];
}

- (void)updatePointer:(const zzz::InputState &)input {
    const int cursorState = (input.cursorKnown ? 4 : 0) + (input.cursorVisible ? 2 : 0) + input.cursorLocked;
    if (_lastCursorState != cursorState) {
        _lastCursorState = cursorState;
        if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] cursor known=%d visible=%d locked=%d",
                                 input.cursorKnown, input.cursorVisible, input.cursorLocked);
    }
    const bool active = input.layout == zzz::Layout::keyboardMouse && _gameWindow != nil;
    if (_loading != input.loading) {
        _loading = input.loading;
        if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] loading pointer released=%d", _loading);
    }
    if (active && _keyboardRelay && Diagnostics()) {
        const auto game = zzz::ReadMovementKeys();
        GCKeyboardInput *hardware = GCKeyboard.coalescedKeyboard.keyboardInput;
        const int physical = hardware ? ([hardware buttonForKeyCode:GCKeyCodeKeyW].isPressed |
                                        ([hardware buttonForKeyCode:GCKeyCodeKeyA].isPressed << 1)) : -1;
        const int sent = _keys.test('w') | (_keys.test('a') << 1);
        const std::array directions{physical, sent, game[0], game[1]};
        if (_lastDirections != directions) {
            _lastDirections = directions;
            NSLog(@"[ZenlessDesktopMode] directions physical=%d sent=%d game=%d legacy=%d",
                  physical, sent, game[0], game[1]);
        }
    }
    const CGPoint center = CGPointMake(CGRectGetMidX(_viewport), CGRectGetMidY(_viewport));
    const bool wheel = active && !_loading && _mouseRelay && _keys.test(TabKey) && zzz::ShortcutWheelOpen();
    if (!wheel) [self stopShortcutWheel];
    [self capture:active && !_loading && !wheel && input.cursorKnown && !input.cursorVisible && input.cursorLocked
           center:center];
    if (wheel) [self startShortcutWheel:center];
    const bool visible = (input.cursorVisible || _loading) && !_captured && !_wheelCursorHidden &&
                         !_gameView.window.windowScene.pointerLockState.isLocked;
    _pointerUnlocked = active && visible;
    const bool recenter = _visibility.update(active && !_loading, input.cursorKnown, visible);
    CGPoint point = _captured ? _capturePoint : PointerLocation();
    if (recenter && warpPointer && warpPointer(center) == kCGErrorSuccess) {
        if (associatePointer) associatePointer(true);
        point = center;
        [self mousePosition:center];
        _pendingMouse = _mouseRelay;
        [self flushMouse];
        if (Diagnostics()) {
            const CGPoint actual = PointerLocation();
            NSLog(@"[ZenlessDesktopMode] pointer centered error=(%.2f,%.2f)pt viewport=%.1fx%.1f",
                  actual.x - center.x, actual.y - center.y, _viewport.size.width, _viewport.size.height);
        }
    }
    if (_wheelCursorHidden) [self updateWheelSelectionAt:point];
    [self updateCursorAt:point force:false];
    [self flushMouse];
}

- (bool)switchLayout:(zzz::Layout)layout source:(const char *)source {
    if (_layout == layout) return true;
    if (!_gameWindow || _switchingLayout) return false;
    const auto previous = _layout;
    _switchingLayout = true;
    const bool selected = zzz::SelectGameLayout(layout);
    _switchingLayout = false;
    if (selected) {
        const auto input = zzz::ReadGameInput();
        [self configureInput:input focused:true];
        [self updatePointer:input];
        if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] %s layout %d -> %d", source,
                                 static_cast<int>(previous), static_cast<int>(layout));
    }
    return selected;
}

- (bool)controllerInput:(GCController *)controller {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return false;
    ZZZDMControllerState *state = [_controllerStates objectForKey:controller];
    if (!state) {
        state = [ZZZDMControllerState new];
        [_controllerStates setObject:state forKey:controller];
        if (@available(macCatalyst 17.0, *)) {
            // The live profile is separate from Unity's extended-gamepad handlers.
            GCControllerLiveInput *input = controller.input;
            if (input && !input.elementValueDidChangeHandler) {
                __weak ZZZDMPlayCoverHost *host = self;
                __weak GCController *device = controller;
                input.elementValueDidChangeHandler = ^(id<GCDevicePhysicalInput>, id<GCPhysicalInputElement>) {
                    if (NSThread.isMainThread) [host controllerChanged:device];
                    else dispatch_async(dispatch_get_main_queue(), ^{ [host controllerChanged:device]; });
                };
            }
        }
    }
    const std::array pressed{pad.buttonA.isPressed, pad.buttonB.isPressed, pad.buttonX.isPressed,
        pad.buttonY.isPressed, pad.leftShoulder.isPressed, pad.rightShoulder.isPressed,
        pad.buttonMenu.isPressed, pad.buttonOptions.isPressed, pad.leftThumbstickButton.isPressed,
        pad.rightThumbstickButton.isPressed, pad.dpad.up.isPressed, pad.dpad.down.isPressed,
        pad.dpad.left.isPressed, pad.dpad.right.isPressed};
    uint32_t buttons = 0;
    for (unsigned i = 0; i < pressed.size(); ++i) buttons |= uint32_t(pressed[i]) << i;
    const auto stick = [](GCControllerDirectionPad *axis) {
        return std::hypot(axis.xAxis.value, axis.yAxis.value);
    };
    return state->activity.update(buttons, {stick(pad.leftThumbstick), stick(pad.rightThumbstick),
                                           pad.leftTrigger.value, pad.rightTrigger.value});
}

- (void)controllerChanged:(GCController *)controller {
    if (![self controllerInput:controller] || _layout != zzz::Layout::keyboardMouse) return;
    id macApp = Send(NSClassFromString(@"NSApplication"), "sharedApplication");
    if (Send<BOOL>(macApp, "isActive") && !CGRectIsEmpty(Viewport(_gameWindow, _gameView))) {
        [self switchLayout:zzz::Layout::controller source:"controller"];
    }
}

- (void)frame:(CADisplayLink *)link {
    (void)link;
    auto input = zzz::ReadGameInput();
    // The startup preset must be ready while the login screen is still open.
    // Window focus only controls whether events and pointer capture are routed.
    const auto initial = zzz::InitialDesktopLayout(input.layout);
    if (initial != zzz::Layout::unknown && zzz::SelectGameLayout(initial)) {
        input = zzz::ReadGameInput();
        if (Diagnostics()) NSLog(@"[ZenlessDesktopMode] startup preset selected keyboard and mouse");
    }
    id macApp = Send(NSClassFromString(@"NSApplication"), "sharedApplication");
    id window = Send(macApp, "keyWindow");
    UIView *view = Send<BOOL>(macApp, "isActive") ? GameView() : nil;
    _viewport = Viewport(window, view);
    const bool focused = !CGRectIsEmpty(_viewport);
    _gameWindow = focused ? window : nil;
    _gameView = focused ? view : nil;
    [self configureInput:input focused:focused];

    bool hasController = false;
    bool controllerActivity = false;
    for (GCController *controller in GCController.controllers) {
        hasController |= controller.extendedGamepad != nil;
        controllerActivity |= [self controllerInput:controller];
    }
    if (focused) {
        if (_layout == zzz::Layout::controller && !hasController &&
            [self switchLayout:zzz::Layout::keyboardMouse source:"disconnected controller"]) return;
        if (_layout == zzz::Layout::keyboardMouse && controllerActivity &&
            [self switchLayout:zzz::Layout::controller source:"controller"]) return;
    }
    [self updatePointer:input];
}

@end

namespace {

void FindEngine() {
    static bool started;
    if (started) return;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !std::strstr(path, "/UnityFramework.framework/UnityFramework")) continue;
        const auto *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) return;
        started = true;
        if (zzz::StartGameInput(*reinterpret_cast<const mach_header_64 *>(header), _dyld_get_image_vmaddr_slide(i))) {
            static ZZZDMPlayCoverHost *host;
            host = [ZZZDMPlayCoverHost new];
            [host start];
        }
        return;
    }
}

void EngineLoaded(const mach_header *header, intptr_t) {
    if (header->filetype == MH_DYLIB) dispatch_async(dispatch_get_main_queue(), ^{ FindEngine(); });
}

} // namespace

__attribute__((constructor)) static void LoadZenlessDesktopMode() {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.miHoYo.Nap"]) return;
    if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"3.3.1"] ||
        ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"4"]) {
        NSLog(@"[ZenlessDesktopMode] unsupported game build");
        return;
    }
    _dyld_register_func_for_add_image(EngineLoaded);
}
