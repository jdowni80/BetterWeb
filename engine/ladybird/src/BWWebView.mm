// One Ladybird top-level browsing context presented in an NSView. Frames arrive as IOSurfaces from the
// compositor and are set straight onto a CALayer; input is translated from NSEvent to Web events.
// Event translation adapted from Ladybird's former AppKit frontend (BSD-2-Clause, Tim Flynn).

#include <AK/Utf8View.h>
#include <LibCore/Resource.h>
#include <LibGfx/Palette.h>
#include <LibGfx/SharedImageBuffer.h>
#include <LibGfx/SystemTheme.h>
#include <LibURL/URL.h>
#include <LibWebCommon/UIEvents/KeyCode.h>
#include <LibWebView/Application.h>
#include <LibWebView/Menu.h>
#include <LibWebView/PlatformColors.h>
#include <LibWebView/Utilities.h>
#include <LibWebView/WebContentClient.h>

#import <Carbon/Carbon.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>

#import "Internal.h"

namespace BetterWeb {

NSString* to_ns_string(StringView string)
{
    return [[NSString alloc] initWithBytes:string.characters_without_null_termination()
                                    length:string.length()
                                  encoding:NSUTF8StringEncoding]
        ?: @"";
}

NSString* to_ns_string(Utf16String const& string)
{
    auto utf8 = string.to_utf8();
    return to_ns_string(utf8.bytes_as_string_view());
}

String from_ns_string(NSString* string)
{
    auto const* utf8 = [string UTF8String] ?: "";
    return MUST(String::from_utf8({ utf8, strlen(utf8) }));
}

Utf16String utf16_from_ns_string(NSString* string)
{
    auto const* utf8 = [string UTF8String] ?: "";
    return Utf16String::from_utf8({ utf8, strlen(utf8) });
}

NSImage* image_from_bitmap(Gfx::Bitmap const& bitmap)
{
    static auto color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto* data = CFDataCreate(kCFAllocatorDefault, bitmap.scanline_u8(0), bitmap.size_in_bytes());
    auto* provider = CGDataProviderCreateWithCFData(data);
    auto* image = CGImageCreate(bitmap.width(), bitmap.height(), 8, 32, bitmap.pitch(), color_space,
        static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst),
        provider, nullptr, NO, kCGRenderingIntentDefault);
    NSImage* result = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(bitmap.width(), bitmap.height())] : nil;
    if (image)
        CGImageRelease(image);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return result;
}

bool system_is_dark()
{
    auto* appearance = NSApp ? [NSApp effectiveAppearance] : [NSAppearance currentDrawingAppearance];
    auto* match = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

static Gfx::Color gfx_color(NSColor* color)
{
    auto* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb)
        return {};
    return { static_cast<u8>(rgb.redComponent * 255), static_cast<u8>(rgb.greenComponent * 255), static_cast<u8>(rgb.blueComponent * 255), static_cast<u8>(rgb.alphaComponent * 255) };
}

Core::AnonymousBuffer create_system_theme(bool dark)
{
    auto theme_file = dark ? "Dark"sv : "Default"sv;
    auto theme_ini = MUST(Core::Resource::load_from_uri(MUST(String::formatted("resource://themes/{}.ini", theme_file))));
    auto theme = Gfx::load_system_theme(theme_ini->filesystem_path().to_byte_string()).release_value_but_fixme_should_propagate_errors();

    auto palette_impl = Gfx::PaletteImpl::create_with_anonymous_buffer(theme);
    auto palette = Gfx::Palette(move(palette_impl));
    palette.set_flag(Gfx::FlagRole::IsDark, dark);
    palette.set_color(Gfx::ColorRole::Accent, gfx_color([NSColor controlAccentColor]));
    palette.set_color(Gfx::ColorRole::Selection, WebView::macos_web_selection_color());
    palette.set_color(Gfx::ColorRole::InactiveSelection, WebView::macos_web_inactive_selection_color());
    palette.set_color(Gfx::ColorRole::InactiveSelectionText, WebView::macos_web_inactive_selection_text_color());
    return theme;
}

// MARK: - ViewImpl

ViewImpl::ViewImpl(BWWebView* host)
    : m_host(host)
{
    set_page_background_color_to_system_canvas(system_is_dark());
}

ViewImpl::~ViewImpl() = default;

NonnullOwnPtr<ViewImpl> ViewImpl::create(BWWebView* host)
{
    auto view = adopt_own(*new ViewImpl(host));
    view->initialize_client(CreateNewClient::Yes);
    return view;
}

NonnullOwnPtr<ViewImpl> ViewImpl::create_child(BWWebView* host, WebView::WebContentClient& page_process, Web::PageId page_index)
{
    auto view = adopt_own(*new ViewImpl(host));
    page_process.register_view(page_index, *view);
    view->initialize_client(CreateNewClient::No);
    return view;
}

Optional<ViewImpl::Paintable> ViewImpl::paintable() const
{
    if (!m_client_state.has_usable_bitmap || !m_client_state.front_bitmap.shared_image_buffer)
        return {};
    return Paintable { m_client_state.front_bitmap.shared_image_buffer.ptr(), m_client_state.front_bitmap.last_painted_size.to_type<int>() };
}

void ViewImpl::set_geometry(Web::DevicePixelSize viewport, double device_pixel_ratio)
{
    if (viewport == m_viewport_size && device_pixel_ratio == m_device_pixel_ratio)
        return;
    m_viewport_size = viewport;
    m_device_pixel_ratio = device_pixel_ratio;
    handle_resize();
}

void ViewImpl::update_theme()
{
    auto dark = system_is_dark();
    set_page_background_color_to_system_canvas(dark);
    if (has_display_page())
        page().async_update_system_theme(create_system_theme(dark));
}

static Vector<Web::DevicePixelRect> screen_rects()
{
    Vector<Web::DevicePixelRect> rects;
    for (NSScreen* screen in [NSScreen screens]) {
        auto frame = screen.frame;
        auto scale = screen.backingScaleFactor;
        rects.append(Web::DevicePixelRect(frame.origin.x, frame.origin.y, frame.size.width * scale, frame.size.height * scale));
    }
    if (rects.is_empty())
        rects.append(Web::DevicePixelRect(0, 0, 1920, 1080));
    return rects;
}

void ViewImpl::update_screens()
{
    if (has_display_page())
        page().async_update_screen_rects(screen_rects(), 0);
}

void ViewImpl::prepare_page_for_tab(WebView::WebContentPage& page)
{
    ViewImplementation::prepare_page_for_tab(page);
    page.async_update_system_theme(create_system_theme(system_is_dark()));
    page.async_update_screen_rects(screen_rects(), 0);
}

void ViewImpl::update_zoom()
{
    ViewImplementation::update_zoom();
    handle_resize();
}

// MARK: - Event translation

static Web::UIEvents::KeyModifier key_modifiers(NSEventModifierFlags flags)
{
    unsigned modifiers = Web::UIEvents::KeyModifier::Mod_None;
    if (flags & NSEventModifierFlagShift)
        modifiers |= Web::UIEvents::KeyModifier::Mod_Shift;
    if (flags & NSEventModifierFlagControl)
        modifiers |= Web::UIEvents::KeyModifier::Mod_Ctrl;
    if (flags & NSEventModifierFlagOption)
        modifiers |= Web::UIEvents::KeyModifier::Mod_Alt;
    if (flags & NSEventModifierFlagCommand)
        modifiers |= Web::UIEvents::KeyModifier::Mod_Super;
    return static_cast<Web::UIEvents::KeyModifier>(modifiers);
}

static Web::UIEvents::MouseButton pressed_buttons()
{
    auto mask = [NSEvent pressedMouseButtons];
    unsigned buttons = 0;
    if (mask & (1 << 0))
        buttons |= to_underlying(Web::UIEvents::MouseButton::Primary);
    if (mask & (1 << 1))
        buttons |= to_underlying(Web::UIEvents::MouseButton::Secondary);
    if (mask & (1 << 2))
        buttons |= to_underlying(Web::UIEvents::MouseButton::Middle);
    if (mask & (1 << 3))
        buttons |= to_underlying(Web::UIEvents::MouseButton::Backward);
    if (mask & (1 << 4))
        buttons |= to_underlying(Web::UIEvents::MouseButton::Forward);
    return static_cast<Web::UIEvents::MouseButton>(buttons);
}

static Web::UIEvents::KeyCode key_code_for(unsigned short key_code, Web::UIEvents::KeyModifier& modifiers)
{
    using Web::UIEvents::KeyCode;
    auto keypad = [&](KeyCode key) {
        modifiers = static_cast<Web::UIEvents::KeyModifier>(static_cast<unsigned>(modifiers) | Web::UIEvents::KeyModifier::Mod_Keypad);
        return key;
    };

    // clang-format off
    switch (key_code) {
    case kVK_ANSI_0: return KeyCode::Key_0;
    case kVK_ANSI_1: return KeyCode::Key_1;
    case kVK_ANSI_2: return KeyCode::Key_2;
    case kVK_ANSI_3: return KeyCode::Key_3;
    case kVK_ANSI_4: return KeyCode::Key_4;
    case kVK_ANSI_5: return KeyCode::Key_5;
    case kVK_ANSI_6: return KeyCode::Key_6;
    case kVK_ANSI_7: return KeyCode::Key_7;
    case kVK_ANSI_8: return KeyCode::Key_8;
    case kVK_ANSI_9: return KeyCode::Key_9;
    case kVK_ANSI_A: return KeyCode::Key_A;
    case kVK_ANSI_B: return KeyCode::Key_B;
    case kVK_ANSI_C: return KeyCode::Key_C;
    case kVK_ANSI_D: return KeyCode::Key_D;
    case kVK_ANSI_E: return KeyCode::Key_E;
    case kVK_ANSI_F: return KeyCode::Key_F;
    case kVK_ANSI_G: return KeyCode::Key_G;
    case kVK_ANSI_H: return KeyCode::Key_H;
    case kVK_ANSI_I: return KeyCode::Key_I;
    case kVK_ANSI_J: return KeyCode::Key_J;
    case kVK_ANSI_K: return KeyCode::Key_K;
    case kVK_ANSI_L: return KeyCode::Key_L;
    case kVK_ANSI_M: return KeyCode::Key_M;
    case kVK_ANSI_N: return KeyCode::Key_N;
    case kVK_ANSI_O: return KeyCode::Key_O;
    case kVK_ANSI_P: return KeyCode::Key_P;
    case kVK_ANSI_Q: return KeyCode::Key_Q;
    case kVK_ANSI_R: return KeyCode::Key_R;
    case kVK_ANSI_S: return KeyCode::Key_S;
    case kVK_ANSI_T: return KeyCode::Key_T;
    case kVK_ANSI_U: return KeyCode::Key_U;
    case kVK_ANSI_V: return KeyCode::Key_V;
    case kVK_ANSI_W: return KeyCode::Key_W;
    case kVK_ANSI_X: return KeyCode::Key_X;
    case kVK_ANSI_Y: return KeyCode::Key_Y;
    case kVK_ANSI_Z: return KeyCode::Key_Z;
    case kVK_ANSI_Backslash: return KeyCode::Key_Backslash;
    case kVK_ANSI_Comma: return KeyCode::Key_Comma;
    case kVK_ANSI_Equal: return KeyCode::Key_Equal;
    case kVK_ANSI_Grave: return KeyCode::Key_Backtick;
    case kVK_ANSI_Keypad0: return keypad(KeyCode::Key_0);
    case kVK_ANSI_Keypad1: return keypad(KeyCode::Key_1);
    case kVK_ANSI_Keypad2: return keypad(KeyCode::Key_2);
    case kVK_ANSI_Keypad3: return keypad(KeyCode::Key_3);
    case kVK_ANSI_Keypad4: return keypad(KeyCode::Key_4);
    case kVK_ANSI_Keypad5: return keypad(KeyCode::Key_5);
    case kVK_ANSI_Keypad6: return keypad(KeyCode::Key_6);
    case kVK_ANSI_Keypad7: return keypad(KeyCode::Key_7);
    case kVK_ANSI_Keypad8: return keypad(KeyCode::Key_8);
    case kVK_ANSI_Keypad9: return keypad(KeyCode::Key_9);
    case kVK_ANSI_KeypadClear: return keypad(KeyCode::Key_Delete);
    case kVK_ANSI_KeypadDecimal: return keypad(KeyCode::Key_Period);
    case kVK_ANSI_KeypadDivide: return keypad(KeyCode::Key_Slash);
    case kVK_ANSI_KeypadEnter: return keypad(KeyCode::Key_Return);
    case kVK_ANSI_KeypadEquals: return keypad(KeyCode::Key_Equal);
    case kVK_ANSI_KeypadMinus: return keypad(KeyCode::Key_Minus);
    case kVK_ANSI_KeypadMultiply: return keypad(KeyCode::Key_Asterisk);
    case kVK_ANSI_KeypadPlus: return keypad(KeyCode::Key_Plus);
    case kVK_ANSI_LeftBracket: return KeyCode::Key_LeftBracket;
    case kVK_ANSI_Minus: return KeyCode::Key_Minus;
    case kVK_ANSI_Period: return KeyCode::Key_Period;
    case kVK_ANSI_Quote: return KeyCode::Key_Apostrophe;
    case kVK_ANSI_RightBracket: return KeyCode::Key_RightBracket;
    case kVK_ANSI_Semicolon: return KeyCode::Key_Semicolon;
    case kVK_ANSI_Slash: return KeyCode::Key_Slash;
    case kVK_CapsLock: return KeyCode::Key_CapsLock;
    case kVK_Command: return KeyCode::Key_LeftSuper;
    case kVK_Control: return KeyCode::Key_LeftControl;
    case kVK_Delete: return KeyCode::Key_Backspace;
    case kVK_DownArrow: return KeyCode::Key_Down;
    case kVK_End: return KeyCode::Key_End;
    case kVK_Escape: return KeyCode::Key_Escape;
    case kVK_F1: return KeyCode::Key_F1;
    case kVK_F2: return KeyCode::Key_F2;
    case kVK_F3: return KeyCode::Key_F3;
    case kVK_F4: return KeyCode::Key_F4;
    case kVK_F5: return KeyCode::Key_F5;
    case kVK_F6: return KeyCode::Key_F6;
    case kVK_F7: return KeyCode::Key_F7;
    case kVK_F8: return KeyCode::Key_F8;
    case kVK_F9: return KeyCode::Key_F9;
    case kVK_F10: return KeyCode::Key_F10;
    case kVK_F11: return KeyCode::Key_F11;
    case kVK_F12: return KeyCode::Key_F12;
    case kVK_ForwardDelete: return KeyCode::Key_Delete;
    case kVK_Home: return KeyCode::Key_Home;
    case kVK_LeftArrow: return KeyCode::Key_Left;
    case kVK_Option: return KeyCode::Key_LeftAlt;
    case kVK_PageDown: return KeyCode::Key_PageDown;
    case kVK_PageUp: return KeyCode::Key_PageUp;
    case kVK_Return: return KeyCode::Key_Return;
    case kVK_RightArrow: return KeyCode::Key_Right;
    case kVK_RightCommand: return KeyCode::Key_RightSuper;
    case kVK_RightControl: return KeyCode::Key_RightControl;
    case kVK_RightOption: return KeyCode::Key_RightAlt;
    case kVK_RightShift: return KeyCode::Key_RightShift;
    case kVK_Shift: return KeyCode::Key_LeftShift;
    case kVK_Space: return KeyCode::Key_Space;
    case kVK_Tab: return KeyCode::Key_Tab;
    case kVK_UpArrow: return KeyCode::Key_Up;
    default: break;
    }
    // clang-format on
    return KeyCode::Key_Invalid;
}

struct KeyData : Web::BrowserInputData {
    explicit KeyData(NSEvent* event)
        : event(event)
    {
    }
    NSEvent* __strong event;
};

static Web::KeyEvent key_event_for(Web::KeyEvent::Type type, NSEvent* event, bool should_insert_text)
{
    auto modifiers = key_modifiers(event.modifierFlags);
    auto key = key_code_for(event.keyCode, modifiers);

    u32 code_point = 0;
    bool repeat = false;
    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        // With ⌃ or ⌘ held, AppKit's `characters` are control codes; the page wants the base key.
        auto* characters = (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) ? event.charactersIgnoringModifiers : event.characters;
        auto const* utf8 = [characters UTF8String] ?: "";
        Utf8View view { StringView { utf8, strlen(utf8) } };
        code_point = view.is_empty() ? 0u : *view.begin();
        repeat = event.isARepeat;
    }
    // AppKit maps function keys (arrows, F-keys…) into the private use area.
    if (code_point >= 0xE000 && code_point <= 0xF8FF)
        code_point = 0;
    if (key == Web::UIEvents::KeyCode::Key_Return)
        code_point = '\n';
    // Only printable characters (plus newline/tab) are text; editing keys are handled as commands.
    if (code_point == 0 || (code_point < 0x20 && code_point != '\n' && code_point != '\t') || code_point == 0x7F)
        should_insert_text = false;

    return { type, key, modifiers, code_point, repeat, should_insert_text, make<KeyData>(event) };
}

}

// MARK: - BWWebView

using namespace BetterWeb;

@interface BWMenuActionTarget : NSObject
- (instancetype)initWithAction:(WebView::Action&)action;
- (void)activate:(id)sender;
@end

@implementation BWMenuActionTarget {
    RefPtr<WebView::Action> m_action;
}
- (instancetype)initWithAction:(WebView::Action&)action
{
    if ((self = [super init]))
        m_action = action;
    return self;
}
- (void)activate:(id)sender
{
    if (m_action)
        m_action->activate();
}
@end

@interface BWWebView () <NSMenuDelegate, NSTextInputClient>
@end

@implementation BWWebView {
    OwnPtr<ViewImpl> m_impl;
    CALayer* m_page_layer;
    NSTrackingArea* m_tracking_area;
    NSEvent* m_current_key_down;
    NSEvent* m_redispatching;
    NSEventModifierFlags m_modifier_flags;
    NSCursor* m_cursor;
    NSMutableArray* m_menu_targets;
    int m_click_count;
    BOOL m_page_visible;
    BOOL m_select_menu_pending;
}

- (instancetype)init
{
    return [self initWithFrame:NSMakeRect(0, 0, 800, 600)];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        [self setUpLayer];
        m_impl = ViewImpl::create(self);
        [self wireCallbacks];
    }
    return self;
}

- (instancetype)initWithParent:(BWWebView*)parent pageProcess:(WebView::WebContentClient&)pageProcess pageIndex:(Web::PageId)pageIndex
{
    if ((self = [super initWithFrame:parent.bounds])) {
        [self setUpLayer];
        m_impl = ViewImpl::create_child(self, pageProcess, pageIndex);
        [self wireCallbacks];
    }
    return self;
}

- (ViewImpl&)impl
{
    return *m_impl;
}

- (void)dealloc
{
    [self close];
}

- (void)setUpLayer
{
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    m_page_layer = [CALayer layer];
    m_page_layer.opaque = YES;
    m_page_layer.masksToBounds = YES;
    m_page_layer.anchorPoint = CGPointZero;
    m_page_layer.actions = @{
        @"contents" : NSNull.null,
        @"contentsRect" : NSNull.null,
        @"contentsScale" : NSNull.null,
        @"bounds" : NSNull.null,
        @"position" : NSNull.null,
        @"backgroundColor" : NSNull.null,
    };
    [self.layer addSublayer:m_page_layer];
    m_cursor = [NSCursor arrowCursor];
    m_menu_targets = [NSMutableArray array];
    m_page_visible = YES;
    [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
}

- (void)wireCallbacks
{
    __weak BWWebView* weak_self = self;
    auto& view = *m_impl;

    view.on_ready_to_paint = [weak_self] {
        [weak_self presentFrame];
    };
    view.on_page_background_color_change = [weak_self](Gfx::Color) {
        [weak_self updateBackgroundColor];
    };
    view.on_url_change = [weak_self](URL::URL const& url) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:didChangeURL:)])
            [self.delegate webView:self didChangeURL:to_ns_string(url.serialize())];
    };
    view.on_title_change = [weak_self](Utf16String const& title) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:didChangeTitle:)])
            [self.delegate webView:self didChangeTitle:to_ns_string(title)];
    };
    view.on_load_start = [weak_self] {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webViewDidStartLoading:)])
            [self.delegate webViewDidStartLoading:self];
    };
    view.on_load_finish = [weak_self](URL::URL const& url) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:didFinishLoadingURL:)])
            [self.delegate webView:self didFinishLoadingURL:to_ns_string(url.serialize())];
    };
    view.on_loading_state_change = [weak_self](bool loading) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:loadingStateChanged:)])
            [self.delegate webView:self loadingStateChanged:loading];
    };
    view.on_link_hover = [weak_self](URL::URL const& url) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:hoveredLink:)])
            [self.delegate webView:self hoveredLink:to_ns_string(url.serialize())];
    };
    view.on_link_unhover = [weak_self] {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:hoveredLink:)])
            [self.delegate webView:self hoveredLink:nil];
    };
    view.on_favicon_change = [weak_self](Optional<Gfx::Bitmap const&> bitmap) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:didChangeFavicon:)])
            [self.delegate webView:self didChangeFavicon:bitmap.has_value() ? image_from_bitmap(*bitmap) : nil];
    };
    view.on_audio_play_state_changed = [weak_self](Web::HTML::AudioPlayState state) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webView:audioStateChanged:)])
            [self.delegate webView:self audioStateChanged:state == Web::HTML::AudioPlayState::Playing ? BWAudioStatePlaying : BWAudioStateSilent];
    };
    view.on_cursor_change = [weak_self](Gfx::Cursor const& cursor) {
        [weak_self applyCursor:cursor];
    };
    view.on_new_web_view = [weak_self](Web::HTML::ActivateTab activate, Web::HTML::WebViewHints, WebView::WebContentClient& page_process, Optional<Web::PageId> page_index) -> String {
        BWWebView* self = weak_self;
        if (!self)
            return {};
        BWWebView* child = page_index.has_value()
            ? [[BWWebView alloc] initWithParent:self pageProcess:page_process pageIndex:*page_index]
            : [[BWWebView alloc] initWithFrame:self.bounds];
        [self adoptChild:child activate:activate == Web::HTML::ActivateTab::Yes];
        return child->m_impl->handle();
    };
    view.on_activate_tab = [weak_self] {
        BWWebView* self = weak_self;
        if (self)
            [self.window makeFirstResponder:self];
    };
    view.on_close = [weak_self] {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webViewDidRequestClose:)])
            [self.delegate webViewDidRequestClose:self];
    };
    view.on_web_content_crashed = [weak_self](auto) {
        BWWebView* self = weak_self;
        if (self && [self.delegate respondsToSelector:@selector(webViewDidCrash:)])
            [self.delegate webViewDidCrash:self];
    };
    view.on_finish_handling_key_event = [weak_self](Web::KeyEvent const& event) {
        [weak_self finishHandlingKeyEvent:event];
    };
    view.on_request_alert = [weak_self](Utf16String const& message) {
        [weak_self showAlert:to_ns_string(message)];
    };
    view.on_request_confirm = [weak_self](Utf16String const& message) {
        [weak_self showConfirm:to_ns_string(message)];
    };
    view.on_request_prompt = [weak_self](Utf16String const& message, Utf16String const& default_value) {
        [weak_self showPrompt:to_ns_string(message) defaultValue:to_ns_string(default_value)];
    };
    view.on_request_select_dropdown = [weak_self](Gfx::IntPoint position, i32 minimum_width, Vector<Web::HTML::SelectItem> items) {
        [weak_self showSelectDropdownAt:position minimumWidth:minimum_width items:items];
    };
    view.on_request_file_picker = [weak_self](Web::HTML::FileFilter const&, Web::HTML::AllowMultipleFiles allow_multiple) {
        [weak_self showFilePicker:allow_multiple == Web::HTML::AllowMultipleFiles::Yes];
    };
    view.on_fullscreen_window = [weak_self] {
        BWWebView* self = weak_self;
        if (!self)
            return;
        self->m_impl->set_is_fullscreen(Web::ViewportIsFullscreen::Yes);
        if ([self.delegate respondsToSelector:@selector(webView:fullscreenChanged:)])
            [self.delegate webView:self fullscreenChanged:YES];
    };
    view.on_exit_fullscreen_window = [weak_self] {
        BWWebView* self = weak_self;
        if (!self)
            return;
        self->m_impl->set_is_fullscreen(Web::ViewportIsFullscreen::No);
        if ([self.delegate respondsToSelector:@selector(webView:fullscreenChanged:)])
            [self.delegate webView:self fullscreenChanged:NO];
    };

    struct HistoryObserver final : WebView::Action::Observer {
        explicit HistoryObserver(BWWebView* view)
            : view(view)
        {
        }
        virtual void on_enabled_state_changed(WebView::Action&) override { [view reportHistoryState]; }
        __weak BWWebView* view;
    };
    view.navigate_back_action().add_observer(make<HistoryObserver>(self));
    view.navigate_forward_action().add_observer(make<HistoryObserver>(self));

    [self wireContextMenu:view.page_context_menu()];
    [self wireContextMenu:view.link_context_menu()];
    [self wireContextMenu:view.selected_text_link_context_menu()];
    [self wireContextMenu:view.image_context_menu()];
    [self wireContextMenu:view.media_context_menu()];
}

- (void)adoptChild:(BWWebView*)child activate:(BOOL)activate
{
    if ([self.delegate respondsToSelector:@selector(webView:didOpenChild:activate:)]) {
        [self.delegate webView:self didOpenChild:child activate:activate];
        return;
    }
    // Nobody to show it: keep it alive until the page closes it.
    static NSMutableSet* orphans = [NSMutableSet set];
    [orphans addObject:child];
}

- (void)reportHistoryState
{
    if ([self.delegate respondsToSelector:@selector(webView:canGoBack:canGoForward:)])
        [self.delegate webView:self canGoBack:self.canGoBack canGoForward:self.canGoForward];
}

// MARK: Presentation

- (void)presentFrame
{
    auto paintable = m_impl->paintable();
    if (!paintable.has_value())
        return;
    auto const& surface = paintable->buffer->iosurface_handle();
    auto surface_width = static_cast<CGFloat>(surface.width());
    auto surface_height = static_cast<CGFloat>(surface.height());
    if (surface_width <= 0 || surface_height <= 0)
        return;
    auto painted_width = MIN(paintable->size.width(), surface_width);
    auto painted_height = MIN(paintable->size.height(), surface_height);
    if (painted_width <= 0 || painted_height <= 0)
        return;

    auto scale = m_impl->device_pixel_ratio();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // One surface pixel per device pixel, anchored top-left; a live resize can pad the surface.
    m_page_layer.contentsScale = scale;
    m_page_layer.contentsGravity = kCAGravityTopLeft;
    m_page_layer.contentsRect = CGRectMake(0, 1 - painted_height / surface_height, painted_width / surface_width, painted_height / surface_height);
    m_page_layer.contents = (__bridge id)surface.core_foundation_pointer();
    [CATransaction commit];
}

- (void)updateBackgroundColor
{
    auto color = m_impl->page_background_color();
    auto* cg = CGColorCreateSRGB(color.red() / 255.0, color.green() / 255.0, color.blue() / 255.0, 1.0);
    m_page_layer.backgroundColor = cg;
    CGColorRelease(cg);
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)layout
{
    [super layout];
    [self syncGeometry];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self syncGeometry];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self syncGeometry];
    [self presentFrame];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self syncGeometry];
    m_impl->update_screens();
    [self updateBackgroundColor];
    [self presentFrame];
    [self updateVisibility];
}

- (void)viewDidHide
{
    [super viewDidHide];
    [self updateVisibility];
}

- (void)viewDidUnhide
{
    [super viewDidUnhide];
    [self updateVisibility];
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    m_impl->update_theme();
    [self updateBackgroundColor];
}

- (void)syncGeometry
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    m_page_layer.frame = self.layer.bounds;
    [CATransaction commit];

    auto scale = self.window ? self.window.backingScaleFactor : (NSScreen.mainScreen.backingScaleFactor ?: 2.0);
    auto size = self.bounds.size;
    if (size.width < 1 || size.height < 1)
        return;
    m_impl->set_geometry({ static_cast<int>(size.width * scale), static_cast<int>(size.height * scale) }, scale);
}

- (void)updateVisibility
{
    BOOL visible = m_page_visible && self.window != nil && !self.isHiddenOrHasHiddenAncestor;
    m_impl->set_system_visibility_state(visible ? Web::HTML::VisibilityState::Visible : Web::HTML::VisibilityState::Hidden);
}

- (BOOL)pageVisible
{
    return m_page_visible;
}

- (void)setPageVisible:(BOOL)visible
{
    m_page_visible = visible;
    [self updateVisibility];
}

// MARK: Public API

- (NSString*)currentURL
{
    return to_ns_string(m_impl->url().serialize());
}

- (NSString*)pageTitle
{
    return to_ns_string(m_impl->title());
}

- (BOOL)canGoBack
{
    return m_impl->navigate_back_action().enabled();
}

- (BOOL)canGoForward
{
    return m_impl->navigate_forward_action().enabled();
}

- (BOOL)isLoading
{
    return m_impl->is_loading();
}

- (double)zoomLevel
{
    return m_impl->zoom_level();
}

- (void)loadURL:(NSString*)url
{
    auto text = from_ns_string(url);
    m_impl->load_from_user_input(text);
}

- (void)goBack
{
    m_impl->traverse_the_history_by_delta(-1);
}

- (void)goForward
{
    m_impl->traverse_the_history_by_delta(1);
}

- (void)reload
{
    m_impl->reload();
}

- (void)stopLoading
{
    m_impl->stop_loading();
}

- (void)setZoom:(double)level
{
    m_impl->set_zoom(level);
    [self reportZoom];
}

- (void)zoomIn
{
    m_impl->zoom_in();
    [self reportZoom];
}

- (void)zoomOut
{
    m_impl->zoom_out();
    [self reportZoom];
}

- (void)resetZoom
{
    m_impl->reset_zoom();
    [self reportZoom];
}

- (void)reportZoom
{
    if ([self.delegate respondsToSelector:@selector(webView:zoomChanged:)])
        [self.delegate webView:self zoomChanged:m_impl->zoom_level()];
}

- (void)findInPage:(NSString*)query
{
    m_impl->find_in_page(utf16_from_ns_string(query));
}

- (void)findNext
{
    m_impl->find_in_page_next_match();
}

- (void)findPrevious
{
    m_impl->find_in_page_previous_match();
}

- (void)requestClose
{
    if (m_impl && !m_impl->handle().is_empty())
        m_impl->request_close();
}

- (void)close
{
    if (!m_impl)
        return;
    m_impl->on_ready_to_paint = nullptr;
    m_impl->on_close = nullptr;
    m_impl->on_web_content_crashed = nullptr;
    if (!m_impl->handle().is_empty() && m_impl->client().is_open())
        m_impl->force_close();
    m_impl = nullptr;
    m_page_layer.contents = nil;
}

// MARK: Cursor

- (void)applyCursor:(Gfx::Cursor const&)cursor
{
    NSCursor* ns_cursor = [NSCursor arrowCursor];
    cursor.visit(
        [&](Gfx::StandardCursor standard) {
            switch (standard) {
            case Gfx::StandardCursor::Hidden:
                [NSCursor setHiddenUntilMouseMoves:YES];
                return;
            case Gfx::StandardCursor::Crosshair:
                ns_cursor = [NSCursor crosshairCursor];
                break;
            case Gfx::StandardCursor::IBeam:
                ns_cursor = [NSCursor IBeamCursor];
                break;
            case Gfx::StandardCursor::ResizeHorizontal:
            case Gfx::StandardCursor::ResizeColumn:
                ns_cursor = [NSCursor resizeLeftRightCursor];
                break;
            case Gfx::StandardCursor::ResizeVertical:
            case Gfx::StandardCursor::ResizeRow:
                ns_cursor = [NSCursor resizeUpDownCursor];
                break;
            case Gfx::StandardCursor::Hand:
                ns_cursor = [NSCursor pointingHandCursor];
                break;
            case Gfx::StandardCursor::OpenHand:
            case Gfx::StandardCursor::Move:
                ns_cursor = [NSCursor openHandCursor];
                break;
            case Gfx::StandardCursor::Drag:
                ns_cursor = [NSCursor closedHandCursor];
                break;
            case Gfx::StandardCursor::DragCopy:
                ns_cursor = [NSCursor dragCopyCursor];
                break;
            case Gfx::StandardCursor::Disallowed:
                ns_cursor = [NSCursor operationNotAllowedCursor];
                break;
            default:
                break;
            }
        },
        [&](Gfx::ImageCursor const& image_cursor) {
            if (auto bitmap = image_cursor.bitmap.bitmap()) {
                if (auto* image = image_from_bitmap(*bitmap))
                    ns_cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(image_cursor.hotspot.x(), image_cursor.hotspot.y())];
            }
        });
    m_cursor = ns_cursor;
    [m_cursor set];
}

- (void)cursorUpdate:(NSEvent*)event
{
    [m_cursor set];
}

// MARK: Mouse

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (m_tracking_area)
        [self removeTrackingArea:m_tracking_area];
    m_tracking_area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                   options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingCursorUpdate
                                                     owner:self
                                                  userInfo:nil];
    [self addTrackingArea:m_tracking_area];
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event
{
    return YES;
}

- (void)sendMouse:(Web::MouseEvent::Type)type event:(NSEvent*)event button:(Web::UIEvents::MouseButton)button
{
    if (!m_impl)
        return;
    auto scale = m_impl->device_pixel_ratio();
    auto point = [self convertPoint:event.locationInWindow fromView:nil];
    auto screen = [NSEvent mouseLocation];
    Web::DevicePixelPoint position { static_cast<int>(point.x * scale), static_cast<int>(point.y * scale) };
    Web::DevicePixelPoint screen_position { static_cast<int>(screen.x * scale), static_cast<int>(screen.y * scale) };

    auto modifiers = key_modifiers(event.modifierFlags);
    // macOS convention: ⌃-click is a secondary click.
    if (button == Web::UIEvents::MouseButton::Primary && (event.modifierFlags & NSEventModifierFlagControl) && type != Web::MouseEvent::Type::MouseMove) {
        button = Web::UIEvents::MouseButton::Secondary;
        modifiers = static_cast<Web::UIEvents::KeyModifier>(modifiers & ~Web::UIEvents::KeyModifier::Mod_Ctrl);
    }

    double wheel_x = 0;
    double wheel_y = 0;
    auto precision = Web::WheelDeltaPrecision::Discrete;
    auto phase = Web::ScrollGesturePhase::None;
    if (type == Web::MouseEvent::Type::MouseWheel) {
        wheel_x = -event.scrollingDeltaX;
        wheel_y = -event.scrollingDeltaY;
        if (event.hasPreciseScrollingDeltas) {
            precision = Web::WheelDeltaPrecision::Precise;
            wheel_x *= scale;
            wheel_y *= scale;
        } else {
            // One notch of a mouse wheel ≈ three lines.
            wheel_x *= 40 * scale;
            wheel_y *= 40 * scale;
        }
        if (event.momentumPhase != NSEventPhaseNone)
            phase = (event.momentumPhase & (NSEventPhaseEnded | NSEventPhaseCancelled)) ? Web::ScrollGesturePhase::Ended : Web::ScrollGesturePhase::Momentum;
        else if (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled))
            phase = Web::ScrollGesturePhase::Ended;
        else if (event.phase != NSEventPhaseNone)
            phase = Web::ScrollGesturePhase::Ongoing;
    }

    if (type == Web::MouseEvent::Type::MouseDown || type == Web::MouseEvent::Type::MouseUp)
        m_click_count = MAX(1, static_cast<int>(event.clickCount));

    m_impl->enqueue_input_event(Web::MouseEvent { type, position, screen_position, button, pressed_buttons(), modifiers, wheel_x, wheel_y, precision, phase, m_click_count, nullptr });
}

- (void)mouseMoved:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseMove event:event button:Web::UIEvents::MouseButton::None];
}

- (void)mouseExited:(NSEvent*)event
{
    if (!m_impl)
        return;
    m_impl->enqueue_input_event(Web::MouseEvent { Web::MouseEvent::Type::MouseLeave, {}, {}, Web::UIEvents::MouseButton::None, Web::UIEvents::MouseButton::None, Web::UIEvents::KeyModifier::Mod_None, 0, 0, Web::WheelDeltaPrecision::Discrete, Web::ScrollGesturePhase::None, 0, nullptr });
    [[NSCursor arrowCursor] set];
}

- (void)scrollWheel:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseWheel event:event button:Web::UIEvents::MouseButton::None];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self];
    [self sendMouse:Web::MouseEvent::Type::MouseDown event:event button:Web::UIEvents::MouseButton::Primary];
}

- (void)mouseUp:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseUp event:event button:Web::UIEvents::MouseButton::Primary];
}

- (void)mouseDragged:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseMove event:event button:Web::UIEvents::MouseButton::None];
}

- (void)rightMouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self];
    [self sendMouse:Web::MouseEvent::Type::MouseDown event:event button:Web::UIEvents::MouseButton::Secondary];
}

- (void)rightMouseUp:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseUp event:event button:Web::UIEvents::MouseButton::Secondary];
}

- (void)rightMouseDragged:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseMove event:event button:Web::UIEvents::MouseButton::None];
}

static Web::UIEvents::MouseButton other_button(NSEvent* event)
{
    switch (event.buttonNumber) {
    case 2:
        return Web::UIEvents::MouseButton::Middle;
    case 3:
        return Web::UIEvents::MouseButton::Backward;
    case 4:
        return Web::UIEvents::MouseButton::Forward;
    default:
        return Web::UIEvents::MouseButton::None;
    }
}

- (void)otherMouseDown:(NSEvent*)event
{
    auto button = other_button(event);
    if (button == Web::UIEvents::MouseButton::None)
        return;
    [self.window makeFirstResponder:self];
    [self sendMouse:Web::MouseEvent::Type::MouseDown event:event button:button];
}

- (void)otherMouseUp:(NSEvent*)event
{
    auto button = other_button(event);
    if (button == Web::UIEvents::MouseButton::None)
        return;
    [self sendMouse:Web::MouseEvent::Type::MouseUp event:event button:button];
}

- (void)otherMouseDragged:(NSEvent*)event
{
    [self sendMouse:Web::MouseEvent::Type::MouseMove event:event button:Web::UIEvents::MouseButton::None];
}

- (void)magnifyWithEvent:(NSEvent*)event
{
    if (!m_impl)
        return;
    auto scale = m_impl->device_pixel_ratio();
    auto point = [self convertPoint:event.locationInWindow fromView:nil];
    Web::PinchEvent pinch;
    pinch.position = { static_cast<int>(point.x * scale), static_cast<int>(point.y * scale) };
    pinch.modifiers = key_modifiers(event.modifierFlags);
    pinch.scale_delta = event.magnification;
    m_impl->enqueue_input_event(move(pinch));
}

// MARK: Keyboard

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)canBecomeKeyView
{
    return YES;
}

- (BOOL)becomeFirstResponder
{
    if (m_impl)
        m_impl->set_has_system_focus(true);
    return YES;
}

- (BOOL)resignFirstResponder
{
    if (m_impl)
        m_impl->set_has_system_focus(false);
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent*)event
{
    // Menu shortcuts (⌘T, ⌘L, …) belong to the browser chrome; the page sees what the menus don't claim.
    if (event.window != self.window || self.window.firstResponder != self || m_redispatching == event)
        return NO;
    if ([[NSApp mainMenu] performKeyEquivalent:event])
        return YES;
    [self keyDown:event];
    return YES;
}

- (void)keyDown:(NSEvent*)event
{
    if (m_redispatching == event || !m_impl)
        return;
    m_current_key_down = event;
    [self interpretKeyEvents:@[ event ]];
    // Keys the input system swallowed without a callback (e.g. ⌘-chords) still go to the page.
    if (m_current_key_down)
        [self sendCurrentKeyDown:NO];
}

- (void)sendCurrentKeyDown:(BOOL)insertText
{
    if (!m_current_key_down)
        return;
    auto event = key_event_for(Web::KeyEvent::Type::KeyDown, m_current_key_down, insertText);
    m_current_key_down = nil;
    m_impl->enqueue_input_event(move(event));
}

- (void)keyUp:(NSEvent*)event
{
    if (m_redispatching == event || !m_impl)
        return;
    m_impl->enqueue_input_event(key_event_for(Web::KeyEvent::Type::KeyUp, event, false));
}

- (void)flagsChanged:(NSEvent*)event
{
    if (m_redispatching == event || !m_impl)
        return;
    auto send_if_changed = [&](NSEventModifierFlags flag) {
        bool now = (event.modifierFlags & flag) != 0;
        bool before = (m_modifier_flags & flag) != 0;
        if (now == before)
            return;
        m_impl->enqueue_input_event(key_event_for(now ? Web::KeyEvent::Type::KeyDown : Web::KeyEvent::Type::KeyUp, event, false));
    };
    send_if_changed(NSEventModifierFlagShift);
    send_if_changed(NSEventModifierFlagControl);
    send_if_changed(NSEventModifierFlagOption);
    send_if_changed(NSEventModifierFlagCommand);
    m_modifier_flags = event.modifierFlags;
}

- (void)finishHandlingKeyEvent:(Web::KeyEvent const&)key_event
{
    // The page didn't consume the key: give the rest of the responder chain (menus, chrome) a turn.
    auto* data = dynamic_cast<KeyData*>(key_event.browser_data.ptr());
    if (!data || !data->event)
        return;
    NSEvent* event = data->event;
    m_redispatching = event;
    [NSApp sendEvent:event];
    m_redispatching = nil;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    [self sendCurrentKeyDown:YES];
}

- (void)doCommandBySelector:(SEL)selector
{
    BOOL inserts = selector == @selector(insertNewline:) || selector == @selector(insertTab:) || selector == @selector(insertLineBreak:);
    [self sendCurrentKeyDown:inserts];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
}

- (void)unmarkText
{
}

- (NSRange)selectedRange
{
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)markedRange
{
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText
{
    return NO;
}

- (nullable NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(nullable NSRangePointer)actualRange
{
    return nil;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText
{
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(nullable NSRangePointer)actualRange
{
    return [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    return NSNotFound;
}

// MARK: Edit menu

- (void)copy:(id)sender
{
    WebView::Application::the().copy_selection_action().activate();
}

- (void)cut:(id)sender
{
    WebView::Application::the().cut_selection_action().activate();
}

- (void)paste:(id)sender
{
    WebView::Application::the().paste_action().activate();
}

- (void)selectAll:(id)sender
{
    WebView::Application::the().select_all_action().activate();
}

// MARK: Context menus

- (void)wireContextMenu:(WebView::Menu&)menu
{
    __weak BWWebView* weak_self = self;
    WeakPtr<WebView::Menu> weak_menu = menu;
    menu.on_activation = [weak_self, weak_menu](Gfx::IntPoint position) {
        BWWebView* self = weak_self;
        if (!self || !weak_menu)
            return;
        [self popUpMenu:*weak_menu at:position];
    };
}

- (NSMenu*)nativeMenuFor:(WebView::Menu&)menu
{
    auto* ns_menu = [[NSMenu alloc] initWithTitle:to_ns_string(menu.title())];
    ns_menu.autoenablesItems = NO;
    for (auto& item : menu.items()) {
        item.visit(
            [&](NonnullRefPtr<WebView::Action>& action) {
                if (!action->visible())
                    return;
                auto* target = [[BWMenuActionTarget alloc] initWithAction:*action];
                [m_menu_targets addObject:target];
                auto* ns_item = [[NSMenuItem alloc] initWithTitle:to_ns_string(action->text()) action:@selector(activate:) keyEquivalent:@""];
                ns_item.target = target;
                ns_item.enabled = action->enabled();
                if (action->is_checkable())
                    ns_item.state = action->checked() ? NSControlStateValueOn : NSControlStateValueOff;
                [ns_menu addItem:ns_item];
            },
            [&](NonnullRefPtr<WebView::Menu>& submenu) {
                if (!submenu->visible())
                    return;
                auto* ns_item = [[NSMenuItem alloc] initWithTitle:to_ns_string(submenu->title()) action:nil keyEquivalent:@""];
                ns_item.submenu = [self nativeMenuFor:*submenu];
                [ns_menu addItem:ns_item];
            },
            [&](WebView::Separator) {
                if (ns_menu.numberOfItems > 0 && !ns_menu.itemArray.lastObject.isSeparatorItem)
                    [ns_menu addItem:[NSMenuItem separatorItem]];
            });
    }
    while (ns_menu.numberOfItems > 0 && ns_menu.itemArray.lastObject.isSeparatorItem)
        [ns_menu removeItemAtIndex:ns_menu.numberOfItems - 1];
    return ns_menu;
}

- (NSPoint)viewPointForDevicePoint:(Gfx::IntPoint)position
{
    auto scale = m_impl ? m_impl->device_pixel_ratio() : 1.0;
    return NSMakePoint(position.x() / scale, position.y() / scale);
}

- (void)popUpMenu:(WebView::Menu&)menu at:(Gfx::IntPoint)position
{
    [m_menu_targets removeAllObjects];
    auto* ns_menu = [self nativeMenuFor:menu];
    if (ns_menu.numberOfItems == 0)
        return;
    [ns_menu popUpMenuPositioningItem:nil atLocation:[self viewPointForDevicePoint:position] inView:self];
}

// MARK: Select dropdowns

- (void)showSelectDropdownAt:(Gfx::IntPoint)position minimumWidth:(i32)minimum_width items:(Vector<Web::HTML::SelectItem> const&)items
{
    auto* menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    menu.minimumWidth = minimum_width / (m_impl ? m_impl->device_pixel_ratio() : 1.0);
    NSMenuItem* selected = nil;

    auto add_option = [&](Web::HTML::SelectItemOption const& option, NSInteger indent) {
        auto* item = [[NSMenuItem alloc] initWithTitle:to_ns_string(option.label) action:@selector(selectDropdownItem:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(option.id);
        item.enabled = !option.disabled;
        item.indentationLevel = indent;
        if (option.selected) {
            item.state = NSControlStateValueOn;
            selected = item;
        }
        [menu addItem:item];
    };
    for (auto const& item : items) {
        item.visit(
            [&](Web::HTML::SelectItemOption const& option) { add_option(option, 0); },
            [&](Web::HTML::SelectItemOptionGroup const& group) {
                auto* header = [[NSMenuItem alloc] initWithTitle:to_ns_string(group.label) action:nil keyEquivalent:@""];
                header.enabled = NO;
                [menu addItem:header];
                for (auto const& option : group.items)
                    add_option(option, 1);
            },
            [&](Web::HTML::SelectItemSeparator const&) { [menu addItem:[NSMenuItem separatorItem]]; });
    }
    m_select_menu_pending = YES;
    [menu popUpMenuPositioningItem:selected atLocation:[self viewPointForDevicePoint:position] inView:self];
    if (m_select_menu_pending && m_impl) {
        m_select_menu_pending = NO;
        m_impl->select_dropdown_closed({});
    }
}

- (void)selectDropdownItem:(NSMenuItem*)item
{
    if (!m_impl)
        return;
    m_select_menu_pending = NO;
    m_impl->select_dropdown_closed([item.representedObject unsignedIntValue]);
}

// MARK: Dialogs

- (void)runSheet:(NSAlert*)alert completion:(void (^)(NSModalResponse))completion
{
    if (self.window) {
        [alert beginSheetModalForWindow:self.window completionHandler:completion];
    } else {
        completion([alert runModal]);
    }
}

- (void)showAlert:(NSString*)message
{
    auto* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    [alert addButtonWithTitle:@"OK"];
    __weak BWWebView* weak_self = self;
    [self runSheet:alert completion:^(NSModalResponse) {
        BWWebView* self = weak_self;
        if (self && self->m_impl)
            self->m_impl->alert_closed();
    }];
}

- (void)showConfirm:(NSString*)message
{
    auto* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak BWWebView* weak_self = self;
    [self runSheet:alert completion:^(NSModalResponse response) {
        BWWebView* self = weak_self;
        if (self && self->m_impl)
            self->m_impl->confirm_closed(response == NSAlertFirstButtonReturn);
    }];
}

- (void)showPrompt:(NSString*)message defaultValue:(NSString*)default_value
{
    auto* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    auto* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    input.stringValue = default_value;
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak BWWebView* weak_self = self;
    [self runSheet:alert completion:^(NSModalResponse response) {
        BWWebView* self = weak_self;
        if (!self || !self->m_impl)
            return;
        if (response == NSAlertFirstButtonReturn)
            self->m_impl->prompt_closed(utf16_from_ns_string(input.stringValue));
        else
            self->m_impl->prompt_closed({});
    }];
}

- (void)showFilePicker:(BOOL)multiple
{
    auto* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = multiple;
    __weak BWWebView* weak_self = self;
    auto finish = ^(NSModalResponse response) {
        BWWebView* self = weak_self;
        if (!self || !self->m_impl)
            return;
        Vector<Web::HTML::SelectedFile> files;
        if (response == NSModalResponseOK) {
            for (NSURL* url in panel.URLs) {
                auto path = ByteString([url.path UTF8String]);
                if (auto file = WebView::create_selected_file(path); !file.is_error())
                    files.append(file.release_value());
            }
        }
        self->m_impl->file_picker_closed(move(files));
    };
    if (self.window)
        [panel beginSheetModalForWindow:self.window completionHandler:finish];
    else
        finish([panel runModal]);
}

// MARK: Drag and drop

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSArray<NSURL*>* urls = [sender.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:nil];
    if (urls.count == 0)
        return NO;
    [self loadURL:urls.firstObject.absoluteString];
    return YES;
}

@end
