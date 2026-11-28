#include "DesktopPolicy.hpp"

#include <cassert>
#include <cstdio>

using zzz::Layout;

int main() {
    assert(zzz::InitialDesktopLayout(Layout::unknown) == Layout::unknown);
    assert(zzz::InitialDesktopLayout(Layout::touch) == Layout::keyboardMouse);
    assert(zzz::InitialDesktopLayout(Layout::keyboardMouse) == Layout::unknown);
    assert(zzz::InitialDesktopLayout(Layout::controller) == Layout::unknown);
    assert(!zzz::IsDesktopLayout(Layout::unknown) && !zzz::IsDesktopLayout(Layout::touch));
    assert(zzz::IsDesktopLayout(Layout::controller) && zzz::IsDesktopLayout(Layout::keyboardMouse));

    using Title = zzz::StartupControllerReadiness::Title;
    zzz::StartupControllerReadiness startup;
    assert(!startup.update(Title::absent));
    assert(!startup.update(Title::opening));
    assert(!startup.update(Title::loading));
    assert(!startup.update(Title::loading));
    assert(startup.update(Title::opening)); // The native progress widget has gone away.
    assert(startup.update(Title::ready));
    assert(startup.update(Title::absent));
    assert(!startup.update(Title::loading)); // A later load can show the progress widget again.
    assert(startup.update(Title::ready));
    zzz::StartupControllerReadiness alreadyReady;
    assert(alreadyReady.update(Title::ready)); // Resources that finish before the first frame.
    zzz::StartupControllerReadiness skippedTitle;
    assert(!skippedTitle.update(Title::opening));
    assert(skippedTitle.update(Title::absent)); // The game has left the startup page.

    zzz::ControllerSwitchRequest request;
    request.request();
    assert(!request.takeIfReady(true, false));
    assert(request.pending());
    assert(request.takeIfReady(true, true));
    assert(!request.takeIfReady(true, true));
    request.request();
    assert(!request.takeIfReady(false, true)); // Focus loss or device disconnection.
    assert(!request.pending());
    request.request();
    request.cancel(); // The player went back to keyboard and mouse while waiting.
    assert(!request.takeIfReady(true, true));

    zzz::ControllerActivity controller;
    assert(!controller.update(0, {0.11F, 0.01F, 0, 0}));
    assert(controller.update(0, {0.35F, 0, 0, 0}));
    assert(!controller.update(0, {0.23F, 0, 0, 0}));
    assert(!controller.update(0, {0.34F, 0, 0, 0}));
    assert(!controller.update(0, {0.13F, 0, 0, 0}));
    assert(controller.update(0, {0.34F, 0, 0, 0}));
    assert(controller.update(1, {0.34F, 0, 0, 0}));
    assert(!controller.update(1, {0.34F, 0, 0, 0}));
    assert(controller.update(3, {0.34F, 0, 0, 0}));

    zzz::PointerActivity motion;
    assert(!motion.update(10.00, 1, 1));
    assert(!motion.update(10.02, -1, -1));
    assert(!motion.update(10.05, 4, 0));
    assert(!motion.update(10.40, 4, 0));
    assert(motion.update(10.43, 5, 0));
    motion.reset();
    assert(!motion.update(10.45, 5, 0));

    zzz::CaptureWarp warp;
    constexpr std::array<double, 2> smallMove{3, -5};
    assert(warp.correct(3, -5) == smallMove);
    warp.reset(210, -180);
    assert((warp.correct(0, 0) == std::array<double, 2>{}));
    assert(warp.correct(213, -185) == smallMove);
    assert(warp.correct(3, -5) == smallMove);
    warp.reset(210, -180);
    assert(warp.correct(3, -5) == smallMove);

    zzz::PointerVisibility pointer;
    assert(!pointer.update(true, true, true));
    assert(!pointer.update(true, true, false));
    assert(!pointer.update(true, true, false));
    assert(pointer.update(true, true, true));
    assert(!pointer.update(true, true, true));
    assert(!pointer.update(true, true, false));
    assert(!pointer.update(false, true, true));
    assert(!pointer.update(true, true, true));
    assert(!pointer.update(true, false, false));
    assert(!pointer.update(true, true, true));

    constexpr std::array<float, 2> neutral{};
    assert(zzz::ShortcutWheelDirection(0, 0, 800) == neutral);
    assert(zzz::ShortcutWheelDirection(3, -4, 800) == neutral);
    assert(zzz::ShortcutWheelDirection(30, 40, 0) == neutral);
    assert((zzz::ShortcutWheelDirection(0, 60, 800) == std::array{0.0F, -1.0F}));
    assert((zzz::ShortcutWheelDirection(-60, 0, 800) == std::array{-1.0F, 0.0F}));
    assert((zzz::ShortcutWheelDirection(30, -40, 800) == std::array{0.6F, 0.8F}));

    zzz::KeyboardState keyboard{};
    constexpr unsigned W = zzz::MacKeys[0x0d];
    constexpr unsigned A = zzz::MacKeys[0x00];
    constexpr unsigned LeftShift = zzz::MacKeys[0x38];
    assert(W == 'w' && A == 'a' && LeftShift == 304);
    assert(zzz::SetKey(keyboard, W, true));
    const auto heldW = keyboard;
    assert(!zzz::SetKey(keyboard, W, true));
    assert(zzz::SetKey(keyboard, A, true));
    assert(zzz::SetKey(keyboard, LeftShift, true));
    assert(zzz::SetKey(keyboard, A, false));
    assert(zzz::SetKey(keyboard, LeftShift, false));
    assert(keyboard == heldW);
    assert(zzz::SetKey(keyboard, W, false));
    assert(!zzz::SetKey(keyboard, 0, true));
    assert(!zzz::SetKey(keyboard, 675, true));
    assert(keyboard == zzz::KeyboardState{});
    static_assert(zzz::FunctionKeyInputIndex(zzz::MacKeys[0x7a]) == 94);
    static_assert(zzz::FunctionKeyInputIndex(zzz::MacKeys[0x78]) == 95);
    static_assert(zzz::FunctionKeyInputIndex(zzz::MacKeys[0x76]) == 97);
    static_assert(zzz::FunctionKeyInputIndex(zzz::MacKeys[0x6f]) == 105);
    static_assert(zzz::FunctionKeyInputIndex(281) == 0 && zzz::FunctionKeyInputIndex(294) == 0);
    static_assert(zzz::FourCC('S', 'T', 'A', 'T') == 0x53544154);
    std::puts("ZenlessDesktopMode input tests passed");
}
