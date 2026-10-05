// Boots Ladybird's browser process inside BetterWeb. The SwiftUI app *is* the browser process:
// LibWebView spawns WebContent/RequestServer/ImageDecoder/Compositor helpers next to our executable
// and talks to them over Mach IPC, while this file supplies the platform pieces Qt used to.

#include <AK/ByteString.h>
#include <AK/LexicalPath.h>
#include <LibCore/EventLoop.h>
#include <LibCore/System.h>
#include <LibMain/Main.h>
#include <LibWebView/Application.h>
#include <LibWebView/FileDownloader.h>
#include <LibWebView/Settings.h>

#import "EventLoopCF.h"
#import "Internal.h"

namespace BetterWeb {

static __weak id<BWEngineDelegate> s_delegate;

static BWWebView* focused_web_view()
{
    if (s_delegate && [s_delegate respondsToSelector:@selector(engineActiveWebView)]) {
        if (auto* view = [s_delegate engineActiveWebView])
            return view;
    }
    id responder = NSApp.keyWindow.firstResponder;
    return [responder isKindOfClass:BWWebView.class] ? responder : nil;
}

class Application final : public WebView::Application {
    WEB_VIEW_APPLICATION(Application)

public:
    virtual ~Application() override = default;

private:
    Application() = default;

    virtual Core::EventLoop& create_platform_event_loop() override
    {
        Core::EventLoopManager::install(*new EventLoopManagerCF);
        return WebView::Application::create_platform_event_loop();
    }

    // BetterWeb is its own app; never hand URLs to (or wait on) a running Ladybird.
    virtual bool should_coordinate_browser_process() const override { return false; }

    virtual Optional<WebView::ViewImplementation&> active_web_view() const override
    {
        if (auto* view = focused_web_view())
            return [view impl];
        return {};
    }

    virtual Optional<WebView::ViewImplementation&> open_blank_new_tab(Web::HTML::ActivateTab activate) const override
    {
        if (!s_delegate)
            return {};
        auto* view = [s_delegate engineRequestsNewTabActivating:activate == Web::HTML::ActivateTab::Yes];
        if (!view)
            return {};
        return [view impl];
    }

    virtual void open_url_in_new_window(URL::URL const& url, WebView::IsPrivate) override
    {
        open_url_in_new_tab(url, Web::HTML::ActivateTab::Yes);
    }

    virtual void open_navigation_in_new_window(Web::HTML::PreparedNavigationDescriptor navigation, WebView::IsPrivate) override
    {
        open_navigation_in_new_tab(move(navigation), Web::HTML::ActivateTab::Yes);
    }

    virtual bool supports_clipboard_type(ClipboardType type) const override
    {
        return type == ClipboardType::Text;
    }

    virtual Utf16String clipboard_text(ClipboardType) const override
    {
        auto* text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return utf16_from_ns_string(text ?: @"");
    }

    virtual void set_clipboard_text(String text, ClipboardType) override
    {
        auto* pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:to_ns_string(text.bytes_as_string_view()) forType:NSPasteboardTypeString];
    }

    virtual Web::Clipboard::SystemClipboardItem clipboard_item() const override
    {
        Vector<Web::Clipboard::SystemClipboardRepresentation> representations;
        auto* pasteboard = [NSPasteboard generalPasteboard];
        if (auto* html = [pasteboard stringForType:NSPasteboardTypeHTML])
            representations.empend("text/html"_string, ByteString([html UTF8String]));
        if (auto* text = [pasteboard stringForType:NSPasteboardTypeString])
            representations.empend("text/plain"_string, ByteString([text UTF8String]));
        return { move(representations) };
    }

    virtual void insert_clipboard_item(Web::Clipboard::SystemClipboardItem item) override
    {
        auto* pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        for (auto const& entry : item.system_clipboard_representations) {
            auto const* data = entry.data.get_pointer<ByteString>();
            if (!data)
                continue;
            auto* value = to_ns_string(data->view());
            if (entry.name == "text/plain"sv)
                [pasteboard setString:value forType:NSPasteboardTypeString];
            else if (entry.name == "text/html"sv)
                [pasteboard setString:value forType:NSPasteboardTypeHTML];
        }
    }

    virtual void display_error_dialog(StringView message) const override
    {
        auto* alert = [[NSAlert alloc] init];
        alert.messageText = to_ns_string(message);
        alert.alertStyle = NSAlertStyleWarning;
        [alert runModal];
    }

    virtual void display_download_confirmation_dialog(StringView download_name, LexicalPath const& path) const override
    {
        // Downloads land in ~/Downloads quietly; a toast in the chrome is enough.
        (void)download_name;
        (void)path;
    }

    virtual void open_download(WebView::FileDownloader::Download const& download) const override
    {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:to_ns_string(download.destination.string().view())]];
    }

    virtual void show_download_in_folder(WebView::FileDownloader::Download const& download) const override
    {
        auto* url = [NSURL fileURLWithPath:to_ns_string(download.destination.string().view())];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ url ]];
    }
};

static OwnPtr<Application> s_application;

}

using namespace BetterWeb;

@implementation BWEngine

+ (BOOL)startWithProfile:(NSString*)profileName arguments:(NSArray<NSString*>*)arguments error:(NSError**)error
{
    NSAssert(NSThread.isMainThread, @"BWEngine must start on the main thread");
    if (s_application)
        return YES;

    if (auto result = Core::System::set_resource_limits(RLIMIT_NOFILE, 65536); result.is_error())
        warnln("Unable to increase open file limit: {}", result.error());

    // Ladybird parses a real argv; keep the storage alive for the life of the process.
    static Vector<ByteString> storage;
    static Vector<StringView> views;
    static Vector<char*> argv;
    storage.append(ByteString([NSProcessInfo.processInfo.arguments.firstObject UTF8String]));
    storage.append("--profile"sv);
    storage.append(ByteString([profileName UTF8String]));
    for (NSString* argument in arguments)
        storage.append(ByteString([argument UTF8String]));
    for (auto& string : storage) {
        views.append(string.view());
        argv.append(const_cast<char*>(string.characters()));
    }
    argv.append(nullptr);

    Main::Arguments main_arguments {
        .argc = static_cast<int>(storage.size()),
        .argv = argv.data(),
        .strings = views.span(),
    };

    auto app = Application::create(main_arguments);
    if (app.is_error()) {
        auto message = ByteString::formatted("{}", app.error());
        if (error)
            *error = [NSError errorWithDomain:@"BWEngine" code:1 userInfo:@{ NSLocalizedDescriptionKey : to_ns_string(message.view()) }];
        return NO;
    }
    s_application = app.release_value();
    return YES;
}

+ (BOOL)isRunning
{
    return s_application != nullptr;
}

+ (NSString*)engineName
{
    return @"Ladybird (LibWeb + LibJS)";
}

+ (id<BWEngineDelegate>)delegate
{
    return s_delegate;
}

+ (void)setDelegate:(id<BWEngineDelegate>)delegate
{
    s_delegate = delegate;
}

+ (NSArray<NSDictionary<NSString*, id>*>*)contentBlockerLists
{
    if (!s_application)
        return @[];
    NSMutableArray* lists = [NSMutableArray array];
    for (auto const& list : WebView::Application::settings().content_blocker_lists()) {
        [lists addObject:@{
            @"id" : to_ns_string(list.identifier.bytes_as_string_view()),
            @"name" : to_ns_string(list.name.bytes_as_string_view()),
            @"enabled" : @(list.enabled),
            @"description" : to_ns_string(list.description.bytes_as_string_view()),
        }];
    }
    return lists;
}

+ (void)setContentBlockerList:(NSString*)identifier enabled:(BOOL)enabled
{
    if (!s_application)
        return;
    WebView::Application::settings().set_content_blocker_list_enabled(from_ns_string(identifier), enabled);
}

+ (void)setCustomContentFilters:(NSString*)filters
{
    if (!s_application)
        return;
    auto value = from_ns_string(filters);
    if (WebView::Application::settings().custom_content_blocker_filters() != value)
        WebView::Application::settings().set_custom_content_blocker_filters(move(value));
}

+ (void)clearSiteDataWithCompletion:(void (^)(void))completion
{
    if (!s_application) {
        if (completion)
            completion();
        return;
    }
    WebView::Application::ClearBrowsingDataOptions options;
    options.delete_cached_files = WebView::Application::ClearBrowsingDataOptions::Delete::Yes;
    options.delete_site_data = WebView::Application::ClearBrowsingDataOptions::Delete::Yes;
    auto promise = s_application->clear_browsing_data(options);
    void (^done)(void) = [completion copy];
    promise->when_resolved([done](Empty) -> ErrorOr<void> {
        if (done)
            done();
        return {};
    });
}

@end
