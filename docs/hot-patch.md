# Native hot-patch guard

The `hot-patch` command prepares a separate application with guards for the
`Magic` and `Magicdy` native patch paths. It does not run `patch`, change
anti-recall behavior, or modify the source application.

## Supported layout

Initial support is limited to WeChat **4.1.9.58, build 268602**, on arm64 and
x86_64, with this loader:

```text
Contents/Frameworks/WCDY.framework/Versions/A/WCDY
```

The tool checks the app identifier, build, architectures, WCDY UUIDs, hashes of
its executable `__text` sections, and the exported/imported `setConfig` symbol.
An unknown build, changed loader, or `WCDYWrapper.framework` layout is rejected.
The catalog is local to `runtime/hotpatch.py`; this command does not fetch the
upstream patch configuration.

These checks identify the inspected loader. Startup and guard interception
were verified in a live arm64 process on 2026-10-20, as described below.
New vendor patch delivery was not forced. Qualification of a new build must
include its own startup and loader checks before expanding the catalog.

## Build and inspect

Requires macOS, Xcode command-line tools, Swift, and Python 3.9 or later.

```sh
make build hotpatch-runtime
./wechattweak hot-patch status --app /Applications/WeChat.app
```

`status` is read-only. Its JSON output separates the recognized loader layout,
the weak library dependency, and the presence of the guard file.
`running_process_verified` is always `false`: installed files do not prove
that a running process uses them.

## Prepare an application copy

Use a new output path outside the source bundle:

```sh
./wechattweak hot-patch prepare \
  --app /Applications/WeChat.app \
  --output "$HOME/sources/WeChat-guarded.app"
```

The command:

1. Checks the source layout and guard architectures.
2. Copies the application to a temporary directory beside the output path.
3. Appends a weak load command for `libwxhotpatchguard.dylib` to each main
   executable slice. Existing dependency ordinals are preserved.
4. Signs the copy with an ad-hoc signature, preserving existing entitlements.
5. Verifies its signature and guard dependency, then publishes the copy.

It refuses an existing output, a destination inside the source app, external
bundle symlinks, and insufficient Mach-O header space. A failed preparation
removes its temporary directory and leaves the source app unchanged.

The command does not launch or install the copy. Do not run both copies against
the same WeChat account container at the same time. To return to the previous
behavior, quit the prepared copy and use the unchanged source app.

## Mechanism

The universal guard library uses dyld interposition:

| Entry point | Behavior |
| --- | --- |
| `WCDY::setConfig(const char *, const char *)` | Preserves the bundled-code root and replaces the downloaded-code root with `/dev/null`. Child lookups under this file fail. |
| `dlopen` | Rejects patch paths and provides a `dlerror` value. Other libraries remain available. |
| `open`, `openat`, `fopen` | Rejects artifact access in the four patch directories below. Other file operations retain their original arguments. |

The guarded directories are relative to
`Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/`:

```text
magic/
magicdy/
xplugin/plugins/Magic/
xplugin/plugins/Magicdy/
```

The guard resolves relative paths, dot components, and existing symlink aliases.
It returns `EACCES` for denied file operations. It emits one stderr notice for
artifact denial and one for WCDY configuration interception. The same events
are sent to the macOS unified log. Notices contain no account data or file paths.

WCDY also loads bundled application code. Returning failure from every
`WCDY::open` call, deleting the framework, or disabling `setConfig` entirely
would affect that path. This implementation keeps those operations available.

## Scope and limits

- This is distinct from Sparkle's full-application update controls and the
  existing `wcdyIntegrityBypass` patch.
- Plugin registration, polling, and downloads are not disabled. The guard
  restricts the known artifact access and downloaded-code loading paths.
- This is not a security boundary. Direct system calls, unhandled APIs,
  hard-link aliases, code received through other channels, and already-loaded
  patches are outside its coverage.
- Only a new process that loads the prepared app receives the guard. It cannot
  undo a patch already applied in another running process.
- The existing anti-recall runtime is independent. Neither component implies
  that the other is installed or functioning.

## Evidence and tests

The 2026-10-20 local inspection found:

- The loader exports `__ZN4WCDY9setConfigEPKcS1_`.
- Its implementation identifies its arguments as `mainBundleDir` and
  `downloadDir`, stores both roots, and appends path separators.
- The main executable imports that symbol.
- The loader contains a native Mach-O loader and C++ function replacement code.
- Local `Magic` artifacts contain architecture-specific configuration, symbol
  tables, and an `update` Mach-O library. The local process also has
  `Magicdy` plugin metadata.

No vendor binaries, account data, or patch payloads are stored in this repo.

```sh
make test-hotpatch
```

Tests compile disposable universal applications and a fake WCDY library. They
run the guard through an injected load command, check root selection, reject
patch file access and `dlopen`, preserve other plugins and file creation, and
verify copy preparation, signature validation, idempotence, and refusal cases.
Both architectures run when Rosetta is available. These fixtures test the
mechanism; they do not establish end-to-end WeChat acceptance.

### Live check on 2026-10-20

The guard was installed in a copy of the inspected build, with the pre-guard
app retained for rollback. The arm64 app reached its normal signed-in main
window. Process mappings showed the guard, WCDY, and the bundled
`Resources/wechat.dylib` loaded together. That same process emitted:

```text
WeChatTweakHotPatch: wcdy-download-root-disabled
WeChatTweakHotPatch: artifact-access-denied
```

This proves that the configuration interception and at least one artifact
denial occurred during real startup. It does not identify the denied artifact
or prove that every possible patch path is covered. Fresh vendor push delivery,
live x86_64 startup, and unhandled loading APIs remain unverified.

For a fresh check, inspect the current process, not only the app files. Filter
unified logs by that exact PID: fixture executables can emit the same event
names. The `status` command remains a file inspection and does not claim live
process verification.
