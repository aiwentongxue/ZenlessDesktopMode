#import "TextInputFocus.hpp"
#import <UIKit/UIKit.h>

namespace desktop {
namespace {

__weak UIView *textEditor;

} // namespace

void ObserveTextInputFocus() {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UITextFieldTextDidBeginEditingNotification,
                                      UITextViewTextDidBeginEditingNotification]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            textEditor = note.object;
        }];
    }
    for (NSNotificationName name in @[UITextFieldTextDidEndEditingNotification,
                                      UITextViewTextDidEndEditingNotification]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (note.object == textEditor) textEditor = nil;
        }];
    }
}

bool TextInputFocused() {
    // Catalyst's AppKit first responder can still be the hosting view while
    // Unity's UIKit text editor has focus.
    UIView *editor = textEditor;
    return editor.isFirstResponder && editor.window.isKeyWindow;
}

} // namespace desktop
