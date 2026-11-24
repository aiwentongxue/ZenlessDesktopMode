#pragma once

#include <cmath>
#include "GameInput.hpp"

namespace zzz {

class PointerVisibility {
public:
    bool update(bool active, bool known, bool visible) {
        const bool recenter = active && known && visible && wasHidden_;
        wasHidden_ = active && known && !visible;
        return recenter;
    }

private:
    bool wasHidden_ = false;
};

inline Layout InitialDesktopLayout(Layout current, bool hasController) {
    if (current == Layout::unknown || current == Layout::keyboardMouse) return Layout::unknown;
    if (current == Layout::controller) return hasController ? Layout::unknown : Layout::keyboardMouse;
    return hasController ? Layout::controller : Layout::keyboardMouse;
}

inline bool IsDesktopLayout(Layout layout) {
    return layout == Layout::keyboardMouse || layout == Layout::controller;
}

class ControllerActivity {
public:
    bool update(uint32_t buttons, const std::array<float, 4> &axes) {
        uint32_t engaged = buttons;
        for (unsigned i = 0; i < axes.size(); ++i) {
            const uint32_t bit = 1U << (16 + i);
            const float threshold = (engaged_ & bit) ? 0.18F : 0.30F;
            if (axes[i] >= threshold) engaged |= bit;
        }
        const bool newInput = (engaged & ~engaged_) != 0;
        engaged_ = engaged;
        return newInput;
    }

private:
    uint32_t engaged_ = 0;
};

class PointerActivity {
public:
    bool update(double time, double dx, double dy) {
        if (!sampled_ || time < started_ || time - started_ > 0.15) {
            x_ = y_ = 0;
            started_ = time;
            sampled_ = true;
        }
        x_ += dx;
        y_ += dy;
        return x_ * x_ + y_ * y_ >= 64;
    }

    void reset() { sampled_ = false; }

private:
    double x_ = 0;
    double y_ = 0;
    double started_ = 0;
    bool sampled_ = false;
};

class CaptureWarp {
public:
    void reset(double x = 0, double y = 0) { x_ = x; y_ = y; }

    std::array<double, 2> correct(double dx, double dy) {
        if (dx == 0 && dy == 0) return {};
        const double x = x_;
        const double y = y_;
        reset();
        const double warp = x * x + y * y;
        const double realX = dx - x;
        const double realY = dy - y;
        // AppKit can combine the warp and a real movement in one packet.
        if (warp > 16 && realX * realX + realY * realY < warp / 4) return {realX, realY};
        return {dx, dy};
    }

private:
    double x_ = 0;
    double y_ = 0;
};

inline std::array<float, 2> ShortcutWheelDirection(double dx, double dy, double viewportHeight) {
    const double distance = std::hypot(dx, dy);
    if (viewportHeight <= 0 || distance < viewportHeight * 0.018) return {};
    return {static_cast<float>(dx / distance), static_cast<float>(-dy / distance)};
}

} // namespace zzz
