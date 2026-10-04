/*
 * Ladybird event loop driven by CFRunLoop, so the engine shares the main thread with AppKit/SwiftUI.
 * Adapted from Ladybird's former AppKit frontend (BSD-2-Clause, Tim Flynn).
 */

#pragma once

#include <AK/Function.h>
#include <AK/NonnullOwnPtr.h>
#include <LibCore/EventLoopImplementation.h>

namespace BetterWeb {

class EventLoopManagerCF final : public Core::EventLoopManager {
public:
    virtual NonnullOwnPtr<Core::EventLoopImplementation> make_implementation() override;

    virtual intptr_t register_timer(Core::EventReceiver&, int interval_milliseconds, bool should_reload) override;
    virtual void unregister_timer(intptr_t timer_id) override;

    virtual void register_notifier(Core::Notifier&) override;
    virtual void unregister_notifier(Core::Notifier&) override;

    virtual void did_post_event() override;

    virtual int register_signal(int, Function<void(int)>) override;
    virtual void unregister_signal(int) override;
};

class EventLoopImplementationCF final : public Core::EventLoopImplementation {
public:
    AK_ALLOC_WITH_KMALLOC;

    static NonnullOwnPtr<EventLoopImplementationCF> create();

    virtual int exec() override;
    virtual size_t pump(PumpMode) override;
    virtual void quit(int) override;
    virtual void wake() override;

    virtual ~EventLoopImplementationCF() override;

private:
    EventLoopImplementationCF();

    struct Impl;
    NonnullOwnPtr<Impl> m_impl;
};

}
