// BetterWeb's embedding API for the Ladybird engine (LibWeb/LibJS/LibWebView).
// Plain Objective-C so Swift can import it; everything C++ lives behind it.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BWWebView;

typedef NS_ENUM(NSInteger, BWAudioState) {
    BWAudioStateSilent = 0,
    BWAudioStatePlaying = 1,
};

@protocol BWWebViewDelegate <NSObject>
@optional
- (void)webView:(BWWebView*)webView didChangeURL:(NSString*)url;
- (void)webView:(BWWebView*)webView didChangeTitle:(NSString*)title;
- (void)webViewDidStartLoading:(BWWebView*)webView;
- (void)webView:(BWWebView*)webView didFinishLoadingURL:(NSString*)url;
- (void)webView:(BWWebView*)webView loadingStateChanged:(BOOL)loading;
- (void)webView:(BWWebView*)webView canGoBack:(BOOL)back canGoForward:(BOOL)forward;
- (void)webView:(BWWebView*)webView hoveredLink:(nullable NSString*)url;
- (void)webView:(BWWebView*)webView didChangeFavicon:(nullable NSImage*)favicon;
- (void)webView:(BWWebView*)webView audioStateChanged:(BWAudioState)state;
- (void)webView:(BWWebView*)webView zoomChanged:(double)level;
/// The page opened a new browsing context (window.open, target=_blank, middle click, context menu).
/// `child` is already connected to its opener; the delegate must keep it alive and show it.
- (void)webView:(BWWebView*)webView didOpenChild:(BWWebView*)child activate:(BOOL)activate;
- (void)webViewDidRequestClose:(BWWebView*)webView;
- (void)webView:(BWWebView*)webView fullscreenChanged:(BOOL)fullscreen;
- (void)webViewDidCrash:(BWWebView*)webView;
@end

@protocol BWEngineDelegate <NSObject>
/// Engine wants a new top-level tab (e.g. "Open Link in New Tab"). Return a view you will display.
- (nullable BWWebView*)engineRequestsNewTabActivating:(BOOL)activate NS_SWIFT_NAME(engineRequestsNewTab(activating:));
@optional
- (nullable BWWebView*)engineActiveWebView;
@end

@interface BWEngine : NSObject

/// Boots the Ladybird browser process inside this app: spawns RequestServer, ImageDecoder and the
/// compositor, installs the CFRunLoop event loop on the main thread. Must be called on the main thread
/// after NSApplication exists. `arguments` are extra Ladybird command-line switches.
+ (BOOL)startWithProfile:(NSString*)profileName
               arguments:(NSArray<NSString*>*)arguments
                   error:(NSError**)error;

+ (BOOL)isRunning;
+ (NSString*)engineName;

@property (class, nonatomic, weak, nullable) id<BWEngineDelegate> delegate;

/// Ladybird's built-in filter lists (EasyList, EasyPrivacy, cookie/annoyance lists, …), refreshed daily.
/// Each entry: @{ @"id", @"name", @"enabled" (NSNumber BOOL), @"description" }.
+ (NSArray<NSDictionary<NSString*, id>*>*)contentBlockerLists;
+ (void)setContentBlockerList:(NSString*)identifier enabled:(BOOL)enabled;
/// Extra Adblock Plus–syntax rules applied on top of the lists.
+ (void)setCustomContentFilters:(NSString*)filters;

/// Deletes cookies, site storage and the HTTP cache. History is BetterWeb's own and untouched.
+ (void)clearSiteDataWithCompletion:(void (^_Nullable)(void))completion;

@end

@interface BWWebView : NSView

- (instancetype)init;
- (instancetype)initWithFrame:(NSRect)frame NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<BWWebViewDelegate> delegate;
@property (nonatomic, readonly) NSString* currentURL;
@property (nonatomic, readonly) NSString* pageTitle;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) double zoomLevel;
/// Hidden views report `visibilityState = hidden`, throttle timers and pause rendering.
@property (nonatomic) BOOL pageVisible;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)setZoom:(double)level;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (void)findInPage:(NSString*)query;
- (void)findNext;
- (void)findPrevious;

/// Asks the page to close (runs beforeunload); the delegate receives webViewDidRequestClose.
- (void)requestClose;
/// Tears the page down immediately.
- (void)close;

@end

NS_ASSUME_NONNULL_END
