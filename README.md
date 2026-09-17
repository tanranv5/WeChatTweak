# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/tanranv5/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 客户端多开

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

# 执行 Patch（默认目标是 /Applications/WeChat.app）
wechattweak patch

# 若你的微信 bundle 名不是 WeChat.app（部分客户端是 wx.app），显式指定：
#   ls -d /Applications/*.app | grep -i wechat   # 先确认名字
wechattweak patch --app /Applications/wx.app

# 显式指定 tanranv5 仓库的 config.json
wechattweak patch -c https://raw.githubusercontent.com/tanranv5/WeChatTweak/refs/heads/master/config.json

#多开
open -n /Applications/WeChat.app

# 查看当前 WeChat 版本 + 支持列表
wechattweak versions
```

### 微信更新后怎么办

微信自动更新会**覆盖已打的补丁**，所以每次微信升级后都要重新打一遍：

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

- `wx.app (4.1.15 / 270098)` 当前最新
- 历史版本下载：https://github.com/canc3s/wechat-versions/releases

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
