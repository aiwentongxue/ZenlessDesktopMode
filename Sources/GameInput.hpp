#pragma once

#include <mach-o/loader.h>
#include <cstdint>
#include "UnityEvents.hpp"

namespace zzz {

enum class Layout { unknown, touch, keyboardMouse, controller };

struct InputState {
    Layout layout = Layout::unknown;
    bool cursorKnown = false;
    bool cursorVisible = true;
    bool cursorLocked = false;
    bool keyboardBridged = false;
    bool mouseBridged = false;
    bool loading = false;
};

bool StartGameInput(const mach_header_64 &image, intptr_t slide);
InputState ReadGameInput();
bool StartupControllerReady();
bool SelectGameLayout(Layout layout);
void SetKeyboardRouteActive(bool active);
void SendGameKey(unsigned key, bool pressed);
void QueueMouse(const MouseState &state);
bool ShortcutWheelOpen();
int SelectShortcutWheelDirection(const std::array<float, 2> &direction);
bool ConfirmShortcutWheel(int selection);
std::array<int, 2> InputScreenSize();
std::array<int, 2> ReadMovementKeys();

} // namespace zzz
