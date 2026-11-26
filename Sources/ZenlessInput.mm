#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "GameInput.hpp"
#include "MachOImage.hpp"
#include "TextInputFocus.hpp"

#include <array>
#include <cstring>

namespace zzz {
namespace {

constexpr ImageUUID CNSDK331{0xc1, 0x97, 0x5e, 0x80, 0x31, 0xbe, 0x34, 0x6f,
                              0x91, 0x63, 0x4e, 0xae, 0x22, 0xfc, 0xaf, 0xce};
constexpr uint32_t GetActiveLayout = 0x0bcc5ac0;
constexpr uint32_t ApplyDesktopLayout = 0x0bcc90a4;
constexpr uint32_t LayoutClass = 0x1b4c9660;
constexpr uint32_t GameServices = 0x1b479c78;
constexpr uint32_t LayoutInitialized = 0x1b483eea;
constexpr uint32_t SettingsService = 0x1b616190;
constexpr uint32_t SettingsEvents = 0x1b615948;
constexpr uint32_t SettingChangedBinding = 0x1b6372e8;
constexpr uint32_t FindSetting = 0x0bb987d0;
constexpr uint32_t SetSettingSelection = 0x0cdd0e60;
constexpr uint32_t NotifySettingChanged = 0x07c50c98;
constexpr uint32_t UIManager = 0x1b615800;
constexpr uint32_t GameObjectActive = 0x12e53ec0;
constexpr uint32_t DirectionToWheelIndex = 0x0feda90c;
constexpr uint32_t SetWheelSelection = 0x0fed95f8;
constexpr uint32_t DrawWheelDirection = 0x0fed93b0;
constexpr uint32_t WheelButtonAt = 0x0e733d90;
constexpr uint32_t ActivateWheelButton = 0x0cea994c;
constexpr int LayoutSetting = 41;
constexpr int SettingChanged = 824;
constexpr int KeyboardMouseLayout = 2;
constexpr int ControllerLayout = 4;
constexpr uint32_t CursorTable = 0x1b4708c8;
constexpr uint32_t InputTimeSlot = 0x1b479438;
constexpr uint32_t AllocateDeviceSlot = 0x1b479448;
constexpr uint32_t QueueEventSlot = 0x1b479450;
constexpr uint32_t ScreenSizeTable = 0x1b46fee8;
constexpr uint32_t NewManagedString = 0x130a6e08;
constexpr uint32_t NotifyDevice = 0x12efeb38;
constexpr uint32_t FindManagedMethod = 0x140aff14;
constexpr uint32_t MethodParameterCount = 0x1304ba34;
constexpr uint32_t KeyCommandEntry = 0x6de8;
constexpr uint32_t NativeKeyEvent = 0x14767754;
constexpr uint32_t NativeKeyLookup = 0x1477161c;
constexpr uint32_t NativeKeyboardSlot = 0x1b98c9d8;
constexpr uintptr_t NativeKeyMap = 0x80;
constexpr uintptr_t DeviceDiscoveryCallback = 0x281b0;
constexpr uintptr_t CurrentKeyboard = 0x2b2f0;
constexpr uintptr_t CurrentMouse = 0x2b4f0;

// Keep the real iOS platform and expose the desktop presets in its settings.
constexpr std::array EnableKeyboardMouse{
    InstructionChange{0x0cbf7498, 0x54000181, 0x1400000c}, // continue to the keyboard binding path
    InstructionChange{0x0a8a68e4, 0x37000d20, 0x35000ea0}, // allow the preset in the layout selector
    InstructionChange{0x0a8a6928, 0x37000c80, 0x37000b00}, // skip the touch preset in the iOS selector
};

uintptr_t slideAddress;
const mach_header_64 *engineHeader;
using Time = double (*)();
using Queue = void (*)(const void *);
Time inputTime;
Queue queueEvent;
using KeyEvent = void (*)(int, int);
using KeyCommands = id (*)(id, SEL);
KeyEvent keyEvent;
KeyCommands originalKeyCommands;
bool keyboardRouteActive;
uint16_t mouseId;
bool devicesChecked;
bool layoutSettingSupported;
int syncedLayoutSetting;
bool loadingSupported;
bool shortcutWheelSupported;

id GameKeyCommands(id view, SEL selector) {
    return keyboardRouteActive && !desktop::TextInputFocused() ? @[] : originalKeyCommands(view, selector);
}

uintptr_t ReadPointer(uintptr_t at) {
    return *reinterpret_cast<const uintptr_t *>(at);
}

uintptr_t Services() {
    return ReadPointer(slideAddress + GameServices);
}

uintptr_t GameSingleton(uint32_t slot) {
    auto instance = ReadPointer(slideAddress + slot);
    for (auto offset : {0x8u, 0x60u, 0x10u, 0x78u, 0u}) {
        if (instance <= UINT32_MAX || instance % alignof(uintptr_t)) return 0;
        instance = ReadPointer(instance + offset);
    }
    return instance;
}

bool HasClass(uintptr_t object, const char *expected) {
    const auto klass = object ? ReadPointer(object) : 0;
    const auto *name = klass ? reinterpret_cast<const char *>(ReadPointer(klass + 0x58)) : nullptr;
    return name && std::strcmp(name, expected) == 0;
}

// The UI manager maintains separate lists for pages and pop-up windows.
uintptr_t FindUIController(const char *name, unsigned listOffset) {
    const auto manager = GameSingleton(UIManager);
    if (!HasClass(manager, "PNEJKKMEAOJ")) return 0;
    const auto lists = ReadPointer(manager + 0x40);
    if (!HasClass(lists, "IALNODFDBEG")) return 0;
    const auto list = ReadPointer(lists + listOffset);
    if (!HasClass(list, "List`1")) return 0;
    const auto entries = ReadPointer(list + 0x10);
    const auto count = *reinterpret_cast<const int *>(list + 0x18);
    if (!entries || count < 0 || count > 256 || ReadPointer(entries + 0x18) < static_cast<unsigned>(count)) return 0;
    for (int i = 0; i < count; ++i) {
        const auto controller = ReadPointer(entries + 0x20 + i * sizeof(uintptr_t));
        if (HasClass(controller, name)) return controller;
    }
    return 0;
}

bool IsActiveGameObject(uintptr_t object) {
    return HasClass(object, "GameObject") && ReadPointer(object + 0x10) &&
        reinterpret_cast<bool (*)(uintptr_t)>(slideAddress + GameObjectActive)(object);
}

bool LoadingUIVisible() {
    if (!loadingSupported) return false;
    for (const auto *name : {"UILoadingPopWindowController", "UITransitionPanelPopWindowController"}) {
        const auto controller = FindUIController(name, 0x20);
        if (controller && IsActiveGameObject(ReadPointer(controller + 0x240))) return true;
    }
    return false;
}

uintptr_t OpenShortcutWheel() {
    if (!shortcutWheelSupported) return 0;
    const auto hud = FindUIController("UIMainCityPageController", 0x10);
    if (!hud || *reinterpret_cast<const uint8_t *>(hud + 0x578) != 1) return 0;
    const auto wheel = ReadPointer(hud + 0x4f0);
    return HasClass(wheel, "UIMainCityRoulettWidgetControllerV2") ? wheel : 0;
}

bool SyncLayoutSetting(int layout) {
    const auto settings = GameSingleton(SettingsService);
    const auto events = GameSingleton(SettingsEvents);
    const auto binding = ReadPointer(slideAddress + SettingChangedBinding);
    if (!binding || !HasClass(settings, "NGFOHFNPGHJ") || !HasClass(events, "APCKGCCCMJJ")) return false;

    using Find = uintptr_t (*)(uintptr_t, int, const void *);
    const auto unit = reinterpret_cast<Find>(slideAddress + FindSetting)(settings, LayoutSetting, nullptr);
    if (!HasClass(unit, "HMPLLIBCJAC")) return false;
    const auto entry = ReadPointer(unit + 0x10);
    if (!HasClass(entry, "LayoutPlatformSettingEntry")) return false;
    const auto options = ReadPointer(entry + 0x30);
    if (!options) return false;
    const auto count = *reinterpret_cast<const int *>(options + 0x18);
    const auto items = ReadPointer(options + 0x10);
    if (!items || count < 1 || count > 16 || ReadPointer(items + 0x18) < static_cast<unsigned>(count)) return false;

    for (int index = 0; index < count; ++index) {
        const auto option = ReadPointer(items + 0x20 + index * sizeof(uintptr_t));
        if (!HasClass(option, "LayoutPlatformSettingContext") ||
            *reinterpret_cast<const int *>(option + 0x24) != layout) continue;
        // The input page keeps a selection separate from the game's active layout.
        using Set = void (*)(uintptr_t, int, bool, const void *);
        reinterpret_cast<Set>(slideAddress + SetSettingSelection)(unit, index, false, nullptr);
        using Notify = void (*)(uintptr_t, int, int, uintptr_t);
        reinterpret_cast<Notify>(slideAddress + NotifySettingChanged)(events, SettingChanged, LayoutSetting, binding);
        return true;
    }
    return false;
}

bool CanCall(uintptr_t address) {
    const MachOImage image(*engineHeader, slideAddress);
    return address && image.contains("__TEXT", "__text", image.offset(address), sizeof(uint32_t));
}

const uintptr_t *ManagedMethod(const char *module, const char *space, const char *type, const char *name,
                              unsigned arguments) {
    using Find = const uintptr_t *(*)(const char *, const char *, const char *, const char *);
    using Count = unsigned (*)(const void *);
    const auto find = reinterpret_cast<Find>(slideAddress + FindManagedMethod);
    const auto count = reinterpret_cast<Count>(slideAddress + MethodParameterCount);
    const auto *method = find(module, space, type, name);
    return method && CanCall(method[0]) && count(method) == arguments ? method : nullptr;
}

const uintptr_t *InputMethod(const char *type, const char *name, unsigned arguments) {
    return ManagedMethod("Unity.InputSystem.dll", "UnityEngine.InputSystem", type, name, arguments);
}

void TryDesktopDevices() {
    if (devicesChecked) return;
    const auto services = Services();
    if (!services || !ReadPointer(services + DeviceDiscoveryCallback)) return;
    const auto time = ReadPointer(slideAddress + InputTimeSlot);
    const auto allocate = ReadPointer(slideAddress + AllocateDeviceSlot);
    const auto queue = ReadPointer(slideAddress + QueueEventSlot);
    if (!CanCall(time) || !CanCall(allocate) || !CanCall(queue)) return;

    devicesChecked = true;
    inputTime = reinterpret_cast<Time>(time);
    queueEvent = reinterpret_cast<Queue>(queue);
    const auto *getId = InputMethod("InputDevice", "get_deviceId", 0);
    const auto allocateDevice = reinterpret_cast<int (*)()>(allocate);
    const auto makeString = reinterpret_cast<void *(*)(const char *)>(slideAddress + NewManagedString);
    const auto notify = reinterpret_cast<void (*)(int, void *, const void *)>(slideAddress + NotifyDevice);
    const auto add = [&](uintptr_t current, const char *description) -> uint16_t {
        if (!getId) return 0;
        const auto previous = ReadPointer(services + current);
        const int id = allocateDevice();
        if (id <= 0 || id > UINT16_MAX) return 0;
        void *json = makeString(description);
        if (!json) return 0;
        notify(id, json, nullptr);
        const auto device = ReadPointer(services + current);
        using GetId = int (*)(uintptr_t, const void *);
        const auto readId = reinterpret_cast<GetId>(getId[0]);
        return device && device != previous && readId(device, getId) == id ? static_cast<uint16_t>(id) : 0;
    };

    if (!ReadPointer(services + CurrentMouse)) {
        mouseId = add(CurrentMouse, R"({"interface":"ZenlessDesktopMode","type":"Mouse","product":"Mouse"})");
    }
    NSLog(@"[ZenlessDesktopMode] input devices keyboard=%s mouse=%s",
          keyEvent ? "native edges" : "unavailable",
          mouseId ? "bridged" : ReadPointer(services + CurrentMouse) ? "native" : "unavailable");
}

bool LayoutReady() {
    if (!slideAddress || !ReadPointer(slideAddress + LayoutClass)) return false;
    const auto services = Services();
    const auto ui = services ? ReadPointer(services + 0x300a0) : 0;
    return ui && ReadPointer(ui + 0x88) && ReadPointer(ui + 0x90);
}

void ReadCursor(InputState &state) {
    const auto *table = reinterpret_cast<const uintptr_t *>(slideAddress + CursorTable);
    if (!CanCall(table[0]) || !CanCall(table[2])) return;
    state.cursorKnown = true;
    state.cursorLocked = reinterpret_cast<int (*)()>(table[2])() == 1;
    state.cursorVisible = !state.cursorLocked && reinterpret_cast<bool (*)()>(table[0])();
}

} // namespace

bool StartGameInput(const mach_header_64 &header, intptr_t slide) {
    const MachOImage image(header, slide);
    if (!image.hasUUID(CNSDK331)) {
        NSLog(@"[ZenlessDesktopMode] unsupported UnityFramework UUID");
        return false;
    }
    constexpr std::array StringEntry{0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu, 0xaa0003f3u, 0x952b4034u};
    constexpr std::array DiscoveryEntry{0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu, 0xaa0103f3u};
    constexpr std::array KeyboardEntry{0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu, 0xaa0103f4u};
    constexpr std::array KeyboardLookup{0x8b35ca88u, 0xb9408108u, 0x11001d09u};
    constexpr std::array CountEntry{0x14013a69u};
    constexpr std::array FindMethodEntry{0xd10343ffu, 0xa90a57f6u, 0xa90b4ff4u, 0xa90c7bfdu};
    constexpr std::array GetterEntry{0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu};
    constexpr std::array SetterEntry{0xa9bc5ff8u, 0xa90157f6u, 0xa9024ff4u, 0xa9037bfdu, 0x9100c3fdu};
    constexpr std::array FindSettingEntry{0xd100c3ffu, 0xa9014ff4u, 0xa9027bfdu, 0x910083fdu, 0xaa0103f3u};
    constexpr std::array SetSelectionEntry{0xa9bd57f6u, 0xa9014ff4u, 0xa9027bfdu, 0x910083fdu, 0xaa0203f3u};
    constexpr std::array NotifySettingEntry{0x16798c7au};
    constexpr std::array PresetCheck{0x94509473u, 0x37000d20u, 0xb9402660u};
    constexpr std::array BindingCheck{0x7100227fu, 0x54000181u, 0x14000018u};
    const SEL commands = sel_registerName("keyCommands");
    Method keyCommands = class_getInstanceMethod(NSClassFromString(@"UnityView"), commands);
    if (!keyCommands || reinterpret_cast<uintptr_t>(method_getImplementation(keyCommands)) != image.address(KeyCommandEntry) ||
        !image.matchesCode(NativeKeyEvent, KeyboardEntry) ||
        !image.matchesCode(NativeKeyLookup, KeyboardLookup) ||
        !image.matchesCode(GetActiveLayout, GetterEntry) ||
        !image.matchesCode(ApplyDesktopLayout, SetterEntry) ||
        !image.matchesCode(0x0a8a68e0, PresetCheck) ||
        !image.matchesCode(0x0cbf7494, BindingCheck) ||
        !image.matchesCode(NewManagedString, StringEntry) ||
        !image.matchesCode(NotifyDevice, DiscoveryEntry) ||
        !image.matchesCode(FindManagedMethod, FindMethodEntry) ||
        !image.matchesCode(MethodParameterCount, CountEntry) ||
        !image.contains("__DATA", "__common", InputTimeSlot, 4 * sizeof(uintptr_t)) ||
        !image.contains("__DATA", "__common", ScreenSizeTable, 2 * sizeof(uintptr_t)) ||
        !image.contains("__DATA", "__common", LayoutClass, sizeof(uintptr_t)) ||
        !image.contains("__DATA", "__common", GameServices, sizeof(uintptr_t)) ||
        !image.contains("__DATA", "__common", NativeKeyboardSlot, sizeof(uintptr_t)) ||
        !image.contains("__DATA", "__common", LayoutInitialized, 1) ||
        !image.contains("__DATA", "__common", CursorTable, 4 * sizeof(uintptr_t)) ||
        !image.changeCode(EnableKeyboardMouse)) {
        NSLog(@"[ZenlessDesktopMode] input compatibility checks failed");
        return false;
    }
    slideAddress = image.address(0);
    engineHeader = &header;
    layoutSettingSupported = image.contains("__DATA", "__common", SettingsService, sizeof(uintptr_t)) &&
        image.contains("__DATA", "__common", SettingsEvents, sizeof(uintptr_t)) &&
        image.contains("__DATA", "__common", SettingChangedBinding, sizeof(uintptr_t)) &&
        image.matchesCode(FindSetting, FindSettingEntry) && image.matchesCode(SetSettingSelection, SetSelectionEntry) &&
        image.matchesCode(NotifySettingChanged, NotifySettingEntry);
    constexpr std::array GameObjectActiveEntry{0x900430e8u, 0x91278108u, 0xf95cdd01u, 0xd61f0020u};
    constexpr std::array DirectionToIndexEntry{0xd10283ffu, 0x6d033befu, 0x6d0433edu};
    constexpr std::array SetWheelSelectionEntry{0xa9bd57f6u, 0xa9014ff4u, 0xa9027bfdu, 0x910083fdu};
    constexpr std::array DrawWheelDirectionEntry{0xd10143ffu, 0x6d0223e9u, 0xa9034ff4u};
    constexpr std::array WheelButtonAtEntry{0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu, 0xaa0103f3u};
    constexpr std::array ActivateWheelButtonEntry{0x6dbb23e9u, 0xa9015ff8u, 0xa90257f6u, 0xa9034ff4u};
    const bool uiSupported = image.contains("__DATA", "__common", UIManager, sizeof(uintptr_t)) &&
        image.matchesCode(GameObjectActive, GameObjectActiveEntry);
    loadingSupported = uiSupported;
    shortcutWheelSupported = uiSupported && image.matchesCode(DirectionToWheelIndex, DirectionToIndexEntry) &&
        image.matchesCode(SetWheelSelection, SetWheelSelectionEntry) &&
        image.matchesCode(DrawWheelDirection, DrawWheelDirectionEntry) &&
        image.matchesCode(WheelButtonAt, WheelButtonAtEntry) &&
        image.matchesCode(ActivateWheelButton, ActivateWheelButtonEntry);
    keyEvent = reinterpret_cast<KeyEvent>(image.address(NativeKeyEvent));
    originalKeyCommands = reinterpret_cast<KeyCommands>(method_getImplementation(keyCommands));
    method_setImplementation(keyCommands, reinterpret_cast<IMP>(GameKeyCommands));
    NSLog(@"[ZenlessDesktopMode] native desktop layouts enabled for CN 3.3.1 (4)");
    return true;
}

InputState ReadGameInput() {
    if (!slideAddress) return {};
    TryDesktopDevices();
    if (!LayoutReady()) return {};
    using Get = int (*)(const void *);
    const int current = reinterpret_cast<Get>(slideAddress + GetActiveLayout)(nullptr);
    InputState state;
    switch (current) {
    case 1: state.layout = Layout::touch; break;
    case KeyboardMouseLayout: state.layout = Layout::keyboardMouse; break;
    case 3:
    case ControllerLayout: state.layout = Layout::controller; break;
    default: break;
    }
    const int displayLayout = state.layout == Layout::keyboardMouse ? KeyboardMouseLayout
        : state.layout == Layout::controller ? ControllerLayout : 0;
    if (layoutSettingSupported && displayLayout != syncedLayoutSetting &&
        (!displayLayout || SyncLayoutSetting(displayLayout))) {
        syncedLayoutSetting = displayLayout;
    }
    state.keyboardBridged = keyEvent != nullptr;
    state.mouseBridged = mouseId != 0;
    state.loading = state.layout == Layout::keyboardMouse && LoadingUIVisible();
    ReadCursor(state);
    return state;
}

bool SelectGameLayout(Layout layout) {
    if (!LayoutReady() || *reinterpret_cast<const uint8_t *>(slideAddress + LayoutInitialized) != 1) return false;
    if (layout != Layout::keyboardMouse && layout != Layout::controller) return false;
    // Set the value used by the settings selector and clear the temporary layout override.
    using Select = void (*)(int, bool, int, const void *);
    reinterpret_cast<Select>(slideAddress + ApplyDesktopLayout)(
        layout == Layout::keyboardMouse ? KeyboardMouseLayout : ControllerLayout, true, 0, nullptr);
    return ReadGameInput().layout == layout;
}

template<class Payload>
void QueueState(uint16_t id, uint32_t format, const Payload &state) {
    if (!id || !queueEvent) return;
    const StateEvent<Payload> event{
        {FourCC('S', 'T', 'A', 'T'), sizeof(StateHeader) + sizeof(Payload), id, inputTime(), 0, format},
        state,
    };
    queueEvent(&event);
}

void SetKeyboardRouteActive(bool active) {
    keyboardRouteActive = active;
}

void SendGameKey(unsigned key, bool pressed) {
    if (!keyEvent) return;
    if (const unsigned index = FunctionKeyInputIndex(key)) {
        // The iOS keyboard's table leaves these desktop bindings empty.
        const auto keyboard = ReadPointer(slideAddress + NativeKeyboardSlot);
        auto *mapping = keyboard ? reinterpret_cast<uint32_t *>(keyboard + NativeKeyMap) : nullptr;
        if (mapping && mapping[key] == 0 && mapping['a'] == 15 && mapping['w'] == 37 && mapping[304] == 51) {
            mapping[key] = index;
        }
    }
    keyEvent(static_cast<int>(key), pressed ? 1 : 0);
}

void QueueMouse(const MouseState &state) {
    QueueState(mouseId, FourCC('M', 'O', 'U', 'S'), state);
}

bool ShortcutWheelOpen() {
    return OpenShortcutWheel() != 0;
}

int SelectShortcutWheelDirection(const std::array<float, 2> &direction) {
    const auto wheel = OpenShortcutWheel();
    if (!wheel) return -1;
    struct Vector2 { float x; float y; };
    const Vector2 vector{direction[0], direction[1]};
    const bool moved = vector.x != 0 || vector.y != 0;
    // Use the game's angular bounds. The host already applies the mouse dead zone.
    using GetIndex = int (*)(uintptr_t, Vector2, bool, const void *);
    const int index = moved ? reinterpret_cast<GetIndex>(slideAddress + DirectionToWheelIndex)(
        wheel, vector, true, nullptr) : -1;
    using SetIndex = void (*)(uintptr_t, int, bool, const void *);
    reinterpret_cast<SetIndex>(slideAddress + SetWheelSelection)(wheel, index, false, nullptr);
    using Draw = void (*)(uintptr_t, Vector2, bool, const void *);
    reinterpret_cast<Draw>(slideAddress + DrawWheelDirection)(wheel, vector, index >= 0, nullptr);
    return index;
}

bool ConfirmShortcutWheel(int selection) {
    const auto wheel = OpenShortcutWheel();
    if (!wheel || selection < 0) return false;
    const auto view = ReadPointer(wheel + 0x330);
    const auto buttons = view ? ReadPointer(view + 0x40) : 0;
    if (!HasClass(buttons, "List`1") || selection >= *reinterpret_cast<const int *>(buttons + 0x18)) return false;
    using GetButton = uintptr_t (*)(uintptr_t, int, const void *);
    const auto button = reinterpret_cast<GetButton>(slideAddress + WheelButtonAt)(wheel, selection, nullptr);
    if (!HasClass(button, "LGINJIKKBJA") || !IsActiveGameObject(ReadPointer(button + 0x18)) ||
        !HasClass(ReadPointer(button + 0x40), "UnityAction")) return false;
    // Invoke the original button, including the action configured for this slot in game.
    reinterpret_cast<void (*)(uintptr_t, const void *)>(slideAddress + ActivateWheelButton)(button, nullptr);
    return true;
}

std::array<int, 2> InputScreenSize() {
    const auto *table = reinterpret_cast<const uintptr_t *>(slideAddress + ScreenSizeTable);
    if (!CanCall(table[0]) || !CanCall(table[1])) return {};
    return {reinterpret_cast<int (*)()>(table[0])(), reinterpret_cast<int (*)()>(table[1])()};
}

std::array<int, 2> ReadMovementKeys() {
    using ReadControl = uintptr_t (*)(uintptr_t, const void *);
    using Pressed = bool (*)(uintptr_t, const void *);
    using LegacyPressed = bool (*)(int, const void *);
    if (!slideAddress || !keyEvent) return {-1, -1};
    static const auto *wKey = InputMethod("Keyboard", "get_wKey", 0);
    static const auto *aKey = InputMethod("Keyboard", "get_aKey", 0);
    static const auto *isPressed = ManagedMethod("Unity.InputSystem.dll", "UnityEngine.InputSystem.Controls",
                                                 "ButtonControl", "get_isPressed", 0);
    static const auto *legacy = ManagedMethod("UnityEngine.InputLegacyModule.dll", "UnityEngine", "Input",
                                              "GetKeyInt", 1);
    const auto services = Services();
    const auto keyboard = services ? ReadPointer(services + CurrentKeyboard) : 0;
    std::array<int, 2> result{-1, -1};
    if (keyboard && wKey && aKey && isPressed) {
        const auto w = reinterpret_cast<ReadControl>(wKey[0])(keyboard, wKey);
        const auto a = reinterpret_cast<ReadControl>(aKey[0])(keyboard, aKey);
        const auto read = reinterpret_cast<Pressed>(isPressed[0]);
        if (w && a) result[0] = read(w, isPressed) | (read(a, isPressed) << 1);
    }
    static bool canReadLegacy = legacy != nullptr;
    if (canReadLegacy) {
        try {
            const auto read = reinterpret_cast<LegacyPressed>(legacy[0]);
            result[1] = read('w', legacy) | (read('a', legacy) << 1);
        } catch (...) {
            canReadLegacy = false;
        }
    }
    return result;
}

} // namespace zzz
