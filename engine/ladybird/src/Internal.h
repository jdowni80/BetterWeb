// Private glue shared by BWEngine.mm and BWWebView.mm (Objective-C++ only).

#pragma once

#include <AK/OwnPtr.h>
#include <AK/String.h>
#include <AK/Utf16String.h>
#include <LibGfx/Bitmap.h>
#include <LibGfx/Cursor.h>
#include <LibWebCommon/Page/PageId.h>
#include <LibWebCommon/PixelUnits.h>
#include <LibWebView/ViewImplementation.h>

#import "BWEngine.h"

namespace BetterWeb {

NSString* to_ns_string(StringView);
NSString* to_ns_string(Utf16String const&);
String from_ns_string(NSString*);
Utf16String utf16_from_ns_string(NSString*);
NSImage* image_from_bitmap(Gfx::Bitmap const&);
Core::AnonymousBuffer create_system_theme(bool dark);
bool system_is_dark();

class ViewImpl final : public WebView::ViewImplementation {
public:
    AK_ALLOC_WITH_KMALLOC;

    static NonnullOwnPtr<ViewImpl> create(BWWebView* host);
    static NonnullOwnPtr<ViewImpl> create_child(BWWebView* host, WebView::WebContentClient& page_process, Web::PageId page_index);
    virtual ~ViewImpl() override;

    struct Paintable {
        Gfx::SharedImageBuffer const* buffer { nullptr };
        Gfx::IntSize size;
    };
    Optional<Paintable> paintable() const;

    void set_geometry(Web::DevicePixelSize viewport, double device_pixel_ratio);
    void update_theme();
    void update_screens();

    using ViewImplementation::page_background_color;

    virtual Web::DevicePixelSize viewport_size() const override { return m_viewport_size; }
    virtual Gfx::IntPoint to_content_position(Gfx::IntPoint widget_position) const override { return widget_position; }
    virtual Gfx::IntPoint to_widget_position(Gfx::IntPoint content_position) const override { return content_position; }

private:
    explicit ViewImpl(BWWebView* host);

    virtual void prepare_page_for_tab(WebView::WebContentPage&) override;
    virtual void update_zoom() override;

    __weak BWWebView* m_host { nil };
    Web::DevicePixelSize m_viewport_size { 800, 600 };
};

}

@interface BWWebView ()
- (instancetype)initWithParent:(BWWebView*)parent pageProcess:(WebView::WebContentClient&)pageProcess pageIndex:(Web::PageId)pageIndex NS_DESIGNATED_INITIALIZER;
- (BetterWeb::ViewImpl&)impl;
@end
