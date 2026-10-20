# Mini Programs startup repair

This optional repair supports the inspected WeChat 4.1.9.58 build 268602.
It changes two instructions in each architecture of the bundled
`WeChatAppEx Framework`. Unknown executable code is rejected.

## Cause

The Mini Programs helper stopped during crash-metadata setup, before its
normal browser startup. Its metadata sender selected an inherited
`EXC_RESOURCE` Mach exception port and sent a private message with no send
timeout. The port queue was full, so startup waited inside `mach_msg`.

Administrator inspection matched the helper's send right to the launchd
endpoint for `gui/503/com.apple.ReportCrash`. This is a local Mach IPC port,
not a TCP or UDP port. The service was not stopped or changed.

The user reported that the problem existed before the hot-patch guard.
The earlier vendor hot patch was not retained, so this inspection cannot
establish that it caused the fault.

## Change

The repair changes only the inspected metadata path:

- Query exception mask `0x1bfe` becomes `0x03fe`. Resource-only and guard-only
  endpoints are excluded from this private metadata exchange.
- Send options include `MACH_SEND_TIMEOUT`. The existing zero timeout lets a
  message queue immediately or return an error when the queue is full.

The repair does not change the installed exception handlers. It preserves
the hot-patch guard and verifies its file hash after preparation. Signing
data also changes when the application copy is signed.

## Use

```sh
make build
./wechattweak mini-program status --app /Applications/WeChat.app
./wechattweak mini-program prepare --app /Applications/WeChat.app \
  --output "$HOME/sources/WeChat-mini-repaired.app"
```

`status` inspects files only. `prepare` creates and signs a new application
copy. It does not install or launch it. The output must not already exist.
Keep the source app for rollback, quit WeChat before replacement, and do not
run two copies against the same account container.

## Verification

On 2026-10-20:

- Seven repair tests passed, together with fourteen hot-patch guard tests.
- Twelve isolated calls into the original and repaired vendor framework
  covered arm64 and x86_64, with Rosetta used for x86_64.
- The original sender waited on a full test queue until the three-second
  alarm ended the probe. The repaired sender returned `MACH_SEND_TIMED_OUT`.
- A resource-only test port received metadata from the original code and
  none from the repaired code. A port also registered for `EXC_BAD_ACCESS`
  continued to receive metadata.
- The installed arm64 app started its browser, GPU, and renderer helpers.
  The user opened Mini Programs and confirmed that it worked.
- The running WeChat process logged WCDY downloaded-root interception after
  repair. The guard file hash was unchanged.

Run the synthetic checks with:

```sh
make test-hotpatch test-miniprogram
```

`tests/vendor_metadata_probe.cc` is an opt-in diagnostic for the exact
framework identified in `runtime/miniprogram.py`. Check both UUIDs and
executable hashes before using its private function offsets. The probe
creates its own receive right, does not call `FlueMain`, and does not open
the account database. It uses the inspected vendor string layout because
the current SDK's x86_64 string ABI differs.

Full x86_64 WeChat startup and future vendor builds remain unverified.
Successful startup does not prove that every crash-reporting path works.
No vendor framework or account data is included in this repository.
