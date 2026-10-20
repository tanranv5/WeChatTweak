// Opt-in probe of the two verified private functions. This never calls
// FlueMain or opens the account database. All messages target a receive
// right owned by this test process. See docs/mini-program-repair.md.
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    Dl_info image = {};
    void *entry = dlsym(library, "FlueMain");
    if (!entry || !dladdr(entry, &image)) return 2;
    auto base = reinterpret_cast<uintptr_t>(image.dli_fbase);
#if defined(__arm64__)
    constexpr uintptr_t sender_offset = 0x5871468, metadata_offset = 0x586ac54;
#elif defined(__x86_64__)
    constexpr uintptr_t sender_offset = 0x63a22d0, metadata_offset = 0x639b330;
#else
#error Unsupported architecture
#endif
    auto sender = reinterpret_cast<kern_return_t (*)(mach_port_t, const char *, unsigned)>(
        base + sender_offset);
    auto metadata = reinterpret_cast<bool (*)(void *, const void *)>(
        base + metadata_offset);
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) ||
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND))
        return 3;
    mach_port_limits_t limits = {1};
    if (mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
                                reinterpret_cast<mach_port_info_t>(&limits),
                                MACH_PORT_LIMITS_INFO_COUNT)) return 4;
    alarm(3); // The original full-queue call must not hang the test runner.
    if (!strcmp(argv[2], "full")) {
        mach_msg_header_t message = {};
        message.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
        message.msgh_remote_port = port;
        if (mach_msg(&message, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                     sizeof(message), 0, 0, 0, 0)) return 5;
        kern_return_t result = sender(port, "{}", 2);
        printf("send=%#x\n", result);
        return result == MACH_SEND_TIMED_OUT ? 0 : 6;
    }
    if (!strcmp(argv[2], "resource") || !strcmp(argv[2], "legitimate")) {
        exception_mask_t mask = EXC_MASK_RESOURCE;
        if (!strcmp(argv[2], "legitimate")) mask |= EXC_MASK_BAD_ACCESS;
        if (task_set_exception_ports(mach_task_self(), mask, port,
                                     EXCEPTION_DEFAULT, MACHINE_THREAD_STATE)) return 7;
        alignas(16) unsigned char client[40] = {}; // The inspected method reads its port at +32.
        // The inspected framework uses libc++'s alternate SSO layout on both
        // slices: inline bytes at +0 and short length at +23. Do not pass the
        // current SDK's std::string; its x86_64 ABI can differ.
        alignas(8) unsigned char vendor_string[24] = {'{', '}'};
        vendor_string[23] = 2;
        bool result = metadata(client, vendor_string);
        mach_port_status_t status = {};
        mach_msg_type_number_t count = MACH_PORT_RECEIVE_STATUS_COUNT;
        if (mach_port_get_attributes(mach_task_self(), port, MACH_PORT_RECEIVE_STATUS,
                                     reinterpret_cast<mach_port_info_t>(&status), &count))
            return 8;
        printf("metadata=%d queued=%u\n", result, status.mps_msgcount);
        return 0;
    }
    return 64;
}
