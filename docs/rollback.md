# Rollback

The guard and Mini Programs commands prepare new application copies. Keep a
verified copy of the app before installing either change. App copies do not
contain a backup of the WeChat account container.

## Select the restore point

| Restore point | Result |
| --- | --- |
| Before the guard | Removes the guard and the later Mini Programs repair. Preserves any modifications already present in that copy. |
| After the guard, before the Mini Programs repair | Keeps the guard and removes the Mini Programs repair. The earlier helper startup fault can return. |

For the local installation verified on 2026-10-20, these copies are retained
outside this repository:

```text
$HOME/sources/WeChatTweak-rollbacks/20261020T051709Z/WeChat.app
$HOME/sources/WeChatTweak-rollbacks/20261020T051709Z/mini-program-repair/WeChat-before-mini-fix.app
```

Each deployment directory has a `deployment.json` and `ROLLBACK.md`.
The Mini Programs directory also has `vendor-probe-results.json`. These local
records identify the installed and retained copies. Keep the records with
their app copies. Do not commit the app bundles or account data.

## Restore an application

1. Quit WeChat. Wait for WeChat and its helper processes to exit.
2. Move `/Applications/WeChat.app` to a new recovery path outside Applications.
   Keep it until the restored app passes the checks below.
3. Copy the selected retained app to `/Applications/WeChat.app`. Keep the
   retained copy unchanged. Do not launch it from the rollback directory.
4. Verify the copied bundle:

   ```sh
   codesign --verify --deep --strict /Applications/WeChat.app
   ```

5. If the copy or verification fails, move the unsuccessful copy aside and
   return the app from step 2 to `/Applications/WeChat.app`.
6. Launch only `/Applications/WeChat.app`. Check normal startup and the
   features needed from the selected restore point.

Do not replace, move, or delete the WeChat account container. Do not run two
app copies against it at the same time.

## Check the restored state

From the built tool's directory:

```sh
./wechattweak hot-patch status --app /Applications/WeChat.app
./wechattweak mini-program status --app /Applications/WeChat.app
```

These commands inspect app files. They do not prove that a running process
loaded those files. A pre-guard copy should have no guard dependency or guard
library. A copy from before the Mini Programs repair should report `original`
for both framework architectures. Unknown builds are rejected.

Use the retained complete app for rollback. The existing `wechattweak restore`
command belongs to the upstream patch workflow; it is not a restore command
for these two prepared-copy workflows.
