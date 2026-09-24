# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/tanranv5/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 客户端多开
- 撤回提示增强（x86_64 运行时组件，随 app 自动加载）：`[已拦截] "XX" 撤回了一条消息【原文】`，支持自定义模板
- 屏蔽微信自动更新（**默认开启**）：打补丁后不再被自动升级覆盖；需要升级时用 `--no-block-update`

## 说明

- 当前仓库暂时只维护 x64 版本。
- 本项目仅限学习与技术交流使用，禁止用于任何违法用途。
## 安装&使用

### 迁移说明

- 需要改用 `tanranv5/WeChatTweak` 和 `tanranv5/tap/wechattweak`，因为旧版 Homebrew 打包产物只会 patch `Contents/MacOS/WeChat`，不支持通过 `config.json` 的 `binary` 字段按版本指定不同二进制路径（如 `Contents/Frameworks/wechat.dylib` 或 `Contents/Resources/wechat.dylib`）。
- 如果机器上已经装过原版，请先卸载原版打包，再安装这里维护的版本。

```bash
# 原版可能来自多个 tap，先卸掉旧包
brew uninstall sunnyyoung/tap/wechattweak || brew uninstall wechattweak
```

### Brew 安装

```bash
# 安装
brew install tanranv5/tap/wechattweak

# 更新（微信升级后建议执行，见下一节）
brew upgrade tanranv5/tap/wechattweak

# 执行 Patch（默认目标是 /Applications/WeChat.app，可用 --app 覆盖）
wechattweak patch

# 默认即屏蔽自动更新（微信不会再自动升级覆盖补丁）
wechattweak patch

# 需要升级微信时：不屏蔽，并把已打的屏蔽撤销回原版
wechattweak patch --no-block-update

# 显式指定 tanranv5 仓库的 config.json
wechattweak patch -c https://raw.githubusercontent.com/tanranv5/WeChatTweak/refs/heads/master/config.json

#多开
open -n /Applications/WeChat.app

# 查看当前 WeChat 版本 + 支持列表
wechattweak versions

# 从备份还原成官方原版（patch 时自动备份）
wechattweak restore
```

### 微信更新后怎么办

`patch` **默认会屏蔽微信自动更新**，所以一般不会出现"被悄悄升级、补丁失效"的情况。
一旦升级发生（你主动用 `--no-block-update` 放开、或手工装官方 dmg），**补丁会被整体覆盖**，需要重新打一遍：

1. 确认当前版本是否已支持：`wechattweak versions`
2. **建议先更新工具**：`brew upgrade tanranv5/tap/wechattweak`
   - 补丁配置（`config.json`）是**运行时从远端拉取**的，所以多数情况下不更新工具也能适配新版本；
   - 但更新工具能让重签名更规范（保留 app 沙盒、嵌套二进制签名自洽），也可能带来对新版本的必要支持，**推荐顺手更新**。
3. 重新打补丁：`wechattweak patch`（默认目标是 `/Applications/WeChat.app`，bundle 名不同时加 `--app`）

> 打补丁前无需退出微信，但打完后要**重启微信**才生效（建议先退出，避免归档写入期间文件被占用）。

### 不切换 brew 时的手工打包方式

如果你不想切到 `tanranv5/tap/wechattweak`，就不要继续使用旧版 brew 产物，而是手工打包当前仓库：

```bash
git clone https://github.com/tanranv5/WeChatTweak.git
cd WeChatTweak
make build

# 使用本地构建产物
./wechattweak patch -c ./config.json
```

## 最新适配

- `wx.app (4.1.15 / 270100)` 当前最新（另支持 270098）
- 历史版本下载：https://github.com/canc3s/wechat-versions/releases

## 撤回提示增强

在静默防撤回的基础上，额外显示撤回提示和原文：

```
[已拦截] "XX" 撤回了一条消息【原文内容】
```

- 原消息保留 + 提示显示，两者兼得（静态补丁只能二选一，这是运行时组件）
- 发送者、时间、原文均可在模板里自定义
- 作为组件**直接装进微信 app**（通过 `LC_LOAD_WEAK_DYLIB` 注入），从 Dock / 启动台正常打开微信即自动生效，**不需要**每次手动注入

### 使用

```bash
# 打完静态补丁的同时把撤回提示组件也装进 app，并写好默认模板
# （app 默认 /Applications/WeChat.app，config 默认远程 config.json，均可不写）
wechattweak patch --tip

# 自定义模板（可选，改完重启微信即可）
# 注意：--tip 是开关（不带值），模板要用 --tip-template 传
wechattweak patch --tip --tip-template "[已拦截] {from} 于 {time} 撤回了：{content}"
```

组件加载后默认即生效（`apply=1`）。如需临时关闭：`WXRT_APPLY=0` 环境变量，或在配置文件里写 `marker=`。

### 自定义提示


```
tip=[已拦截] {from} 撤回了：{content}
```

占位符说明：

| 占位符 | 显示内容 |
|---|---|
| `{from}` | 发送者（从原生提示里提取的名字）|
| `{time}` | 撤回时间（HH:MM）|
| `{content}` | 文字原文；图片/视频等显示为无（省略该段）|
| `{marker}` | 默认标记 `[已拦截] `（可用 `marker=` 改）|

> 环境变量 `WXRT_TIP` / `WXRT_MARKER` 可覆盖配置文件，空串不覆盖默认值。


## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)
- [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall) —— Apple Silicon 版同类工具；本仓库的撤回提示增强（运行时组件）参考了其双 hook 方案，并按 x86_64 重新逆向了全部地址与结构偏移

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
