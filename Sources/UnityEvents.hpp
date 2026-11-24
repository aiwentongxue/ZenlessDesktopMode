#pragma once

#include <array>
#include <bitset>
#include <cstddef>
#include <cstdint>

namespace zzz {

constexpr uint32_t FourCC(char a, char b, char c, char d) {
    return (uint32_t(a) << 24) | (uint32_t(b) << 16) | (uint32_t(c) << 8) | uint32_t(d);
}

// Unity's event headers are aligned to 4 bytes. The payload starts at byte 24.
#pragma pack(push, 1)
struct StateHeader {
    uint32_t type;
    uint16_t size;
    uint16_t device;
    double time;
    uint32_t eventId;
    uint32_t format;
};

struct MouseState {
    float x = 0;
    float y = 0;
    float dx = 0;
    float dy = 0;
    float scrollX = 0;
    float scrollY = 0;
    uint16_t buttons = 0;
    uint16_t displayIndex = 0;
    uint16_t clickCount = 0;
};

template<class Payload>
struct alignas(4) StateEvent {
    StateHeader header;
    Payload state;
};
#pragma pack(pop)

static_assert(sizeof(StateHeader) == 24);
static_assert(sizeof(MouseState) == 30);
static_assert(offsetof(StateEvent<MouseState>, state) == 24);

using KeyboardState = std::bitset<675>;

inline bool SetKey(KeyboardState &state, unsigned key, bool pressed) {
    if (!key || key >= state.size() || state[key] == pressed) return false;
    state[key] = pressed;
    return true;
}

// KeyCode.F1–F12 and InputSystem.Key.F1–F12 use different ranges.
constexpr unsigned FunctionKeyInputIndex(unsigned key) {
    return key >= 282 && key <= 293 ? 94 + (key - 282) : 0;
}

// AppKit physical scancodes to Unity KeyCode. Adapted from StarRailDesktopMode.
constexpr std::array<uint16_t, 128> MacKeys{
    'a', 's', 'd', 'f', 'h', 'g', 'z', 'x', 'c', 'v', 0, 'b', 'q', 'w', 'e', 'r',
    'y', 't', '1', '2', '3', '4', '6', '5', '=', '9', '7', '-', '8', '0', ']', 'o',
    'u', '[', 'i', 'p', 13, 'l', 'j', 39, 'k', ';', 92, ',', '/', 'n', 'm', '.',
    9, ' ', '`', 8, 0, 27, 309, 310, 304, 301, 308, 306, 303, 307, 305, 0,
    671, 266, 0, 268, 0, 270, 300, 0, 0, 0, 0, 267, 271, 0, 269, 672,
    673, 272, 256, 257, 258, 259, 260, 261, 262, 263, 674, 264, 265, 0, 0, 0,
    286, 287, 288, 284, 289, 290, 0, 292, 0, 294, 670, 295, 0, 291, 0, 293,
    0, 296, 315, 278, 280, 127, 285, 279, 283, 281, 282, 276, 275, 274, 273, 0,
};

} // namespace zzz
