/*
 * Ladybird event loop driven by CFRunLoop. Adapted from Ladybird's former AppKit frontend
 * (EventLoopImplementationMacOS, BSD-2-Clause, Tim Flynn), extended to work on any thread:
 * the main thread rides NSApp's run loop, helper threads spin their own CFRunLoop.
 */

#include <AK/Assertions.h>
#include <AK/HashMap.h>
#include <AK/IDAllocator.h>
#include <AK/Singleton.h>
#include <AK/TemporaryChange.h>
#include <LibCore/Event.h>
#include <LibCore/EventReceiver.h>
#include <LibCore/Notifier.h>
#include <LibCore/ThreadEventQueue.h>

#include "EventLoopCF.h"

#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>

#include <pthread.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/types.h>

namespace BetterWeb {

static bool is_main_thread() { return pthread_main_np() != 0; }

struct ThreadData;
static thread_local OwnPtr<ThreadData> s_this_thread_data;
static HashMap<pthread_t, ThreadData*> s_thread_data;
static pthread_mutex_t s_thread_data_lock = PTHREAD_MUTEX_INITIALIZER;

struct ThreadDataLock {
    ThreadDataLock() { pthread_mutex_lock(&s_thread_data_lock); }
    ~ThreadDataLock() { pthread_mutex_unlock(&s_thread_data_lock); }
};

// Everything a thread's run loop needs: its timers, its socket notifiers, and one source that drains
// the thread's Core::ThreadEventQueue whenever an event is posted to it.
struct ThreadData {
    AK_ALLOC_WITH_KMALLOC;

    static ThreadData& the()
    {
        if (!s_this_thread_data) {
            s_this_thread_data = make<ThreadData>();
            ThreadDataLock locker;
            s_thread_data.set(s_this_thread_data->thread, s_this_thread_data.ptr());
        }
        return *s_this_thread_data;
    }

    static ThreadData* for_thread(pthread_t thread_id)
    {
        ThreadDataLock locker;
        return s_thread_data.get(thread_id).value_or(nullptr);
    }

    ThreadData()
        : thread(pthread_self())
        , run_loop(CFRunLoopGetCurrent())
    {
        CFRetain(run_loop);
        CFRunLoopSourceContext context {};
        context.info = this;
        context.perform = [](void*) {
            Core::ThreadEventQueue::current().process();
        };
        queue_source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
        CFRunLoopAddSource(run_loop, queue_source, kCFRunLoopCommonModes);
    }

    ~ThreadData()
    {
        {
            ThreadDataLock locker;
            s_thread_data.remove(thread);
        }
        CFRunLoopRemoveSource(run_loop, queue_source, kCFRunLoopCommonModes);
        CFRelease(queue_source);
        CFRelease(run_loop);
    }

    void signal_queue()
    {
        CFRunLoopSourceSignal(queue_source);
        CFRunLoopWakeUp(run_loop);
    }

    pthread_t thread;
    CFRunLoopRef run_loop { nullptr };
    CFRunLoopSourceRef queue_source { nullptr };

    IDAllocator timer_id_allocator;
    HashMap<int, CFRunLoopTimerRef> timers;
    struct NotifierState {
        CFSocketRef socket { nullptr };
        CFRunLoopSourceRef source { nullptr };
        CFRunLoopRef run_loop { nullptr };
    };
    HashMap<Core::Notifier*, NotifierState> notifiers;
};

class SignalHandlers : public RefCounted<SignalHandlers> {
    AK_MAKE_NONCOPYABLE(SignalHandlers);
    AK_MAKE_NONMOVABLE(SignalHandlers);
    AK_ALLOC_WITH_KMALLOC;

public:
    SignalHandlers(int signal_number, CFFileDescriptorCallBack);
    ~SignalHandlers();

    void dispatch();
    int add(Function<void(int)>&& handler);
    bool remove(int handler_id);

    bool is_empty() const
    {
        if (m_calling_handlers) {
            for (auto const& handler : m_handlers_pending) {
                if (handler.value)
                    return false;
            }
        }
        return m_handlers.is_empty();
    }

    int m_signal_number;
    void (*m_original_handler)(int);
    HashMap<int, Function<void(int)>> m_handlers;
    HashMap<int, Function<void(int)>> m_handlers_pending;
    bool m_calling_handlers { false };
    CFRunLoopSourceRef m_source { nullptr };
    int m_kevent_fd = { -1 };
};

SignalHandlers::SignalHandlers(int signal_number, CFFileDescriptorCallBack handle_signal)
    : m_signal_number(signal_number)
    , m_original_handler(signal(signal_number, [](int) { }))
{
    m_kevent_fd = kqueue();
    VERIFY(m_kevent_fd >= 0);

    struct kevent changes = {};
    EV_SET(&changes, signal_number, EVFILT_SIGNAL, EV_ADD | EV_RECEIPT, 0, 0, nullptr);
    if (auto res = kevent(m_kevent_fd, &changes, 1, &changes, 1, NULL); res < 0) {
        dbgln("Unable to register signal {}: {}", signal_number, strerror(errno));
        VERIFY_NOT_REACHED();
    }

    CFFileDescriptorContext context = { 0, this, nullptr, nullptr, nullptr };
    CFFileDescriptorRef kq_ref = CFFileDescriptorCreate(kCFAllocatorDefault, m_kevent_fd, FALSE, handle_signal, &context);

    m_source = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, kq_ref, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), m_source, kCFRunLoopCommonModes);

    CFFileDescriptorEnableCallBacks(kq_ref, kCFFileDescriptorReadCallBack);
    CFRelease(kq_ref);
}

SignalHandlers::~SignalHandlers()
{
    CFRunLoopRemoveSource(CFRunLoopGetMain(), m_source, kCFRunLoopCommonModes);
    CFRelease(m_source);
    (void)::signal(m_signal_number, m_original_handler);
    ::close(m_kevent_fd);
}

struct SignalHandlersInfo {
    HashMap<int, NonnullRefPtr<SignalHandlers>> signal_handlers;
    int next_signal_id { 0 };
};

static Singleton<SignalHandlersInfo> s_signals;
static SignalHandlersInfo* signals_info()
{
    return s_signals.ptr();
}

void SignalHandlers::dispatch()
{
    TemporaryChange change(m_calling_handlers, true);
    for (auto& handler : m_handlers)
        handler.value(m_signal_number);
    if (!m_handlers_pending.is_empty()) {
        for (auto& handler : m_handlers_pending) {
            if (handler.value) {
                auto result = m_handlers.set(handler.key, move(handler.value));
                VERIFY(result == AK::HashSetResult::InsertedNewEntry);
            } else {
                m_handlers.remove(handler.key);
            }
        }
        m_handlers_pending.clear();
    }
}

int SignalHandlers::add(Function<void(int)>&& handler)
{
    int id = ++signals_info()->next_signal_id;
    if (m_calling_handlers)
        m_handlers_pending.set(id, move(handler));
    else
        m_handlers.set(id, move(handler));
    return id;
}

bool SignalHandlers::remove(int handler_id)
{
    VERIFY(handler_id != 0);
    if (m_calling_handlers) {
        auto it = m_handlers.find(handler_id);
        if (it != m_handlers.end()) {
            m_handlers_pending.set(handler_id, {});
            return true;
        }
        it = m_handlers_pending.find(handler_id);
        if (it != m_handlers_pending.end()) {
            if (!it->value)
                return false;
            it->value = nullptr;
            return true;
        }
        return false;
    }
    return m_handlers.remove(handler_id);
}

struct EventLoopImplementationCF::Impl {
    AK_ALLOC_WITH_KMALLOC;
    ThreadData* thread_data { nullptr };
};

EventLoopImplementationCF::EventLoopImplementationCF()
    : m_impl(make<Impl>())
{
    m_impl->thread_data = &ThreadData::the();
}

EventLoopImplementationCF::~EventLoopImplementationCF() = default;

NonnullOwnPtr<EventLoopImplementationCF> EventLoopImplementationCF::create()
{
    return adopt_own(*new EventLoopImplementationCF);
}

NonnullOwnPtr<Core::EventLoopImplementation> EventLoopManagerCF::make_implementation()
{
    return EventLoopImplementationCF::create();
}

intptr_t EventLoopManagerCF::register_timer(Core::EventReceiver& receiver, int interval_milliseconds, bool should_reload)
{
    auto& thread_data = ThreadData::the();

    auto timer_id = thread_data.timer_id_allocator.allocate();
    auto weak_receiver = receiver.make_weak_ptr();

    auto interval_seconds = static_cast<double>(interval_milliseconds) / 1000.0;
    auto first_fire_time = CFAbsoluteTimeGetCurrent() + interval_seconds;

    auto* timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, first_fire_time, should_reload ? interval_seconds : 0, 0, 0,
        ^(CFRunLoopTimerRef) {
            auto receiver = weak_receiver.strong_ref();
            if (!receiver)
                return;
            Core::TimerEvent event;
            receiver->dispatch_event(event);
        });

    // Common modes keep timers firing through window resizes and menu tracking.
    CFRunLoopAddTimer(thread_data.run_loop, timer, kCFRunLoopCommonModes);
    thread_data.timers.set(timer_id, timer);

    return timer_id;
}

void EventLoopManagerCF::unregister_timer(intptr_t timer_id)
{
    auto& thread_data = ThreadData::the();
    thread_data.timer_id_allocator.deallocate(static_cast<int>(timer_id));

    auto timer = thread_data.timers.take(static_cast<int>(timer_id));
    if (!timer.has_value())
        return;
    CFRunLoopTimerInvalidate(*timer);
    CFRelease(*timer);
}

struct SocketNotifierCallbackContext : public RefCounted<SocketNotifierCallbackContext> {
    AK_ALLOC_WITH_KMALLOC;
    WeakPtr<Core::EventReceiver> notifier;
};

static void const* retain_socket_notifier_callback_context(void const* info)
{
    auto const* context = static_cast<SocketNotifierCallbackContext const*>(info);
    context->ref();
    return context;
}

static void release_socket_notifier_callback_context(void const* info)
{
    auto const* context = static_cast<SocketNotifierCallbackContext const*>(info);
    context->unref();
}

static void socket_notifier(CFSocketRef socket, CFSocketCallBackType notification_type, CFDataRef, void const*, void* info)
{
    if (!info)
        return;
    auto& callback_context = *static_cast<SocketNotifierCallbackContext*>(info);
    auto receiver = callback_context.notifier.strong_ref();
    if (!receiver)
        return;
    auto& notifier = as<Core::Notifier>(*receiver);

    // Re-arm before dispatching: a handler may block on a nested pump that needs this socket again.
    CFSocketEnableCallBacks(socket, notification_type);

    Core::NotifierActivationEvent event;
    notifier.dispatch_event(event);
}

void EventLoopManagerCF::register_notifier(Core::Notifier& notifier)
{
    CFOptionFlags notification_type = kCFSocketNoCallBack;
    if (has_flag(notifier.type(), Core::NotificationType::Read))
        notification_type |= kCFSocketReadCallBack;
    if (has_flag(notifier.type(), Core::NotificationType::Write))
        notification_type |= kCFSocketWriteCallBack;
    if (notification_type == kCFSocketNoCallBack)
        notification_type = kCFSocketReadCallBack;

    auto callback_context = adopt_ref(*new SocketNotifierCallbackContext);
    callback_context->notifier = notifier.make_weak_ptr();
    CFSocketContext context { .version = 0, .info = callback_context.ptr(), .retain = retain_socket_notifier_callback_context, .release = release_socket_notifier_callback_context, .copyDescription = nullptr };
    auto* socket = CFSocketCreateWithNative(kCFAllocatorDefault, notifier.fd(), notification_type, &socket_notifier, &context);

    CFOptionFlags sockopt = CFSocketGetSocketFlags(socket);
    sockopt &= ~kCFSocketAutomaticallyReenableReadCallBack;
    sockopt &= ~kCFSocketCloseOnInvalidate;
    CFSocketSetSocketFlags(socket, sockopt);

    auto& thread_data = ThreadData::the();
    auto* source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(thread_data.run_loop, source, kCFRunLoopCommonModes);

    CFRelease(socket);

    thread_data.notifiers.set(&notifier, { socket, source, thread_data.run_loop });
    notifier.set_owner_thread(thread_data.thread);
}

void EventLoopManagerCF::unregister_notifier(Core::Notifier& notifier)
{
    auto* thread_data = ThreadData::for_thread(notifier.owner_thread());
    if (!thread_data)
        return;
    auto state = thread_data->notifiers.take(&notifier);
    if (!state.has_value())
        return;
    CFSocketInvalidate(state->socket);
    CFRunLoopRemoveSource(state->run_loop, state->source, kCFRunLoopCommonModes);
    CFRelease(state->source);
}

void EventLoopManagerCF::did_post_event()
{
    ThreadData::the().signal_queue();
}

static void handle_signal(CFFileDescriptorRef f, CFOptionFlags callback_types, void* info)
{
    VERIFY(callback_types & kCFFileDescriptorReadCallBack);
    auto* signal_handlers = static_cast<SignalHandlers*>(info);

    struct kevent event {};
    (void)::kevent(CFFileDescriptorGetNativeDescriptor(f), nullptr, 0, &event, 1, nullptr);
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);

    signal_handlers->dispatch();
}

int EventLoopManagerCF::register_signal(int signal_number, Function<void(int)> handler)
{
    VERIFY(signal_number != 0);
    auto& info = *signals_info();
    auto handlers = info.signal_handlers.find(signal_number);
    if (handlers == info.signal_handlers.end()) {
        auto signal_handlers = adopt_ref(*new SignalHandlers(signal_number, &handle_signal));
        auto handler_id = signal_handlers->add(move(handler));
        info.signal_handlers.set(signal_number, move(signal_handlers));
        return handler_id;
    }
    return handlers->value->add(move(handler));
}

void EventLoopManagerCF::unregister_signal(int handler_id)
{
    VERIFY(handler_id != 0);
    int remove_signal_number = 0;
    auto& info = *signals_info();
    for (auto& h : info.signal_handlers) {
        auto& handlers = *h.value;
        if (handlers.remove(handler_id)) {
            if (handlers.is_empty())
                remove_signal_number = handlers.m_signal_number;
            break;
        }
    }
    if (remove_signal_number != 0)
        info.signal_handlers.remove(remove_signal_number);
}

int EventLoopImplementationCF::exec()
{
    // The host app owns the main run loop; a nested exec just spins until asked to stop.
    while (!was_exit_requested())
        pump(PumpMode::WaitForEvents);
    return exit_code_if_requested().value_or(0);
}

size_t EventLoopImplementationCF::pump(PumpMode mode)
{
    // Run one batch of run-loop work (our queue source, timers, sockets, or AppKit's event port).
    auto seconds = mode == PumpMode::WaitForEvents ? 1.0e10 : 0.0;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);

    // A nested pump on the main thread must keep the UI alive, so dispatch whatever AppKit queued.
    if (is_main_thread() && NSApp != nil) {
        while (auto* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES]) {
            [NSApp sendEvent:event];
        }
    }
    return m_thread_event_queue.process();
}

void EventLoopImplementationCF::quit(int exit_code)
{
    request_exit(exit_code);
    wake();
}

void EventLoopImplementationCF::wake()
{
    m_impl->thread_data->signal_queue();
}

}
