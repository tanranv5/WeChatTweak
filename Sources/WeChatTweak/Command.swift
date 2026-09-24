//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import Darwin
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(command: "defaults read \(app.appendingPathComponent("Contents/Info.plist").path) CFBundleVersion")
    }

    /// 备份根目录：~/Library/Application Support/WeChatTweak/backup/<version>/
    static func backupDir(version: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/Library/Application Support/WeChatTweak/backup/\(version)").expandingTildeInPath)
    }

    private static func listRegularFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    /// 同步 sleep（async 上下文里 Thread.sleep 不可用）
    private static func sleepSeconds(_ s: Double) {
        var req = timespec(tv_sec: time_t(s), tv_nsec: Int((s - Double(Int(s))) * 1_000_000_000))
        var rem = timespec()
        while nanosleep(&req, &rem) != 0 { req = rem }
    }

    /// patch 前把将要修改的二进制备份下来（按 app 内相对路径存放）。
    /// 已存在的备份不覆盖 —— 备份必须永远是原版，重复 patch 也不会污染。
    /// ⚠️ 主二进制（Contents/MacOS/WeChat）特殊：它会被 LC 注入修改，因此
    ///    备份前必须校验「不含我们的 LC」，否则拒绝备份（防止把补丁后的文件当原版存）。
    static func backupBinaries(app: URL, version: String, binaries: [String]) throws {
        let fm = FileManager.default
        let dir = backupDir(version: version)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for rel in binaries {
            let dst = dir.appendingPathComponent(rel)
            guard !fm.fileExists(atPath: dst.path) else {
                print("Backup exists, keep original: \(dst.path)")
                continue
            }
            let src = app.appendingPathComponent(rel)
            // 防污染闸：文件里已有我们注入的痕迹 → 它不是原版，不能存为备份。
            // 两个特征：① LC 注入的 "wxrevoketip" 字符串；② 静态 revoke 补丁的
            // 「mov eax,1; ret」序言形态（b8 01 00 00 00 c3，紧随其后的字节仍是序言尾巴）。
            if let data = try? Data(contentsOf: src, options: .mappedIfSafe) {
                if data.range(of: Data("wxrevoketip".utf8)) != nil {
                    throw Tweak.Error.backupSourceTainted(path: src.path)
                }
                // 静态 revoke 补丁形态：b8 01 00 00 00 c3 + 序言尾巴 41 56 41 55 41 54 53（共 13B）。
                // ★ 判据必须带序言尾巴：只看 6 字节的「mov eax,1; ret」在原版 wechat.dylib 里
                //   就有 56 处（常见指令序列），必然误报 —— 曾导致新版本首次 patch 被自己拦住
                //   （只有「备份已存在」时跳过检查才侥幸没炸）。
                if rel.hasSuffix("wechat.dylib"),
                   data.range(of: Data([0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3,
                                        0x41, 0x56, 0x41, 0x55, 0x41, 0x54, 0x53])) != nil {
                    throw Tweak.Error.backupSourceTainted(path: src.path)
                }
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
            print("Backup: \(src.path) -> \(dst.path)")
        }
    }

    /// 一键还原：退出微信 → 用备份覆盖回去 → 删除注入的 dylib。
    /// 备份文件是腾讯原签名，覆盖后 app 恢复官方状态（签名随内容自动恢复有效）。
    static func restore(app: URL) async throws {
        let fm = FileManager.default
        let version = (try? await Command.version(app: app)) ?? "unknown"
        let dir = backupDir(version: version)

        guard fm.fileExists(atPath: dir.path) else {
            throw Tweak.Error.backupNotFound(version: version, path: dir.path)
        }

        print("------ Quit WeChat ------")
        // NSAppleScript 不支持 shell 语法（重定向/分号），退出和清理分开做；
        // Thread.sleep 在 async 上下文不可用，用同步的 sleepSeconds
        try? await Command.execute(command: "osascript -e 'quit app id \"com.tencent.xinWeChat\"'")
        Command.sleepSeconds(3)
        try? await Command.execute(command: "pkill -9 -f '\(app.path)/Contents/MacOS/WeChat'")
        Command.sleepSeconds(1)

        print("------ Restore binaries ------")
        // FileManager.enumerator 不能在 async 上下文里直接迭代，先在同步函数里收齐文件列表
        let backupFiles = listRegularFiles(in: dir)
        if backupFiles.isEmpty {
            throw Tweak.Error.backupNotFound(version: version, path: dir.path)
        }
        var restored = 0
        for backup in backupFiles {
            let rel = String(backup.path.dropFirst(dir.path.count + 1))
            let dst = app.appendingPathComponent(rel)
            guard fm.fileExists(atPath: dst.path) else {
                print("Skip (not in app): \(rel)")
                continue
            }
            try fm.removeItem(at: dst)
            try fm.copyItem(at: backup, to: dst)
            print("Restored: \(rel)")
            restored += 1
        }

        print("------ Remove runtime dylib ------")
        let dylib = app.appendingPathComponent("Contents/Resources/libwxrevoketip.dylib")
        if fm.fileExists(atPath: dylib.path) {
            try fm.removeItem(at: dylib)
            print("Removed: \(dylib.path)")
        } else {
            print("Runtime dylib not present, skip")
        }

        if restored == 0 {
            print("⚠️  没有还原任何文件，请检查备份目录: \(dir.path)")
        }

        // ★ 还原后必须重签：备份里主二进制嵌的是我们早前的 adhoc 签名（腾讯原始签名
        //   在第一次 patch 重签时就被覆盖了，不可恢复）。只还原内容会让「签名 seal」
        //   与内容不匹配 → macOS 拒绝启动（踩过：还原后微信打不开）。
        print("------ Resign ------")
        try await Command.resign(app: app)

        print("Done! \(restored) file(s) restored from \(dir.path)")
        print("WeChat 已还原为原版功能（已重签，可直接启动）。")
    }

    /// 撤销「屏蔽自动更新」补丁：把 blockUpdate 的各入口字节写回原版，
    /// 让微信能重新检查/下载更新。只有 config 里带 `expected` 的条目可撤销。
    static func revertBlockUpdate(app: URL, config: Config) async throws {
        guard let target = config.targets.first(where: { $0.identifier == "blockUpdate" }) else {
            print("⚠️  当前版本 config 里没有 blockUpdate，无需撤销")
            return
        }
        let binaryRel = target.binary ?? "Contents/MacOS/WeChat"
        let binaryURL = app.appendingPathComponent(binaryRel)
        try Patcher.revert(binary: binaryURL,
                           config: Config(version: config.version, targets: [target]))
        // 二进制内容变了 → 嵌入签名失效，必须重签，否则 WCDYWrapper 完整性校验会让启动失败
        if binaryRel != "Contents/MacOS/WeChat" {
            try await Command.execute(command: "codesign --force --sign - \(binaryURL.path)")
        }
    }

    static func patch(app: URL, config: Config) async throws {
        let defaultBinary = "Contents/MacOS/WeChat"
        let grouped = Dictionary(grouping: config.targets) { target in
            target.binary ?? defaultBinary
        }

        // patch 前备份将要修改的二进制（供 restore 一键还原）。
        // 主二进制即使 config 不打它，--tip 的 LC 注入也会改它，必须一并备份。
        var toBackup = Set(grouped.keys)
        toBackup.insert(defaultBinary)
        try Command.backupBinaries(app: app, version: config.version,
                                   binaries: toBackup.sorted())

        for (binary, targets) in grouped {
            let binaryURL = app.appendingPathComponent(binary)
            let subConfig = Config(version: config.version, targets: targets)
            print("------ Patch \(binary) ------")
            try Patcher.patch(binary: binaryURL, config: subConfig)

            // 嵌套二进制必须显式重签。`codesign --deep` 不会重签
            // Resources/wechat.dylib 这类大文件（实测 4.1.15+ 会保留腾讯原始签名），
            // 内容一改其嵌入签名即失效，WCDYWrapper 的完整性校验就会让 app 启动失败。
            if binary != defaultBinary {
                // 大二进制（wechat.dylib 约 340MB）签名要几秒且全程无输出 —— 先说一声，免得被当成卡死
                print("------ Sign \(binary)（无输出属正常，稍候）------")
                try await Command.execute(command: "codesign --force --sign - \(binaryURL.path)")
            }
        }
    }

    static func resign(app: URL) async throws {
        // 整包 `--deep` 重签要遍历全部嵌套二进制，1.4G 的 app 通常数十秒，全程无输出。
        // 先说一声，免得被当成卡死（曾有人在这里等出疑问）。
        print("  → 整包 codesign --deep 重签中（1.4G app 通常数十秒，无输出属正常）…")
        // ★ 只能用 --preserve-metadata=entitlements，**不能**传 --entitlements <某文件>：
        //   `--deep` 会把 --entitlements 指定的那一份 entitlements **盖到所有嵌套二进制**上。
        //   嵌套 helper（WeChatAppEx / WeChatHelper / XPlayer / *.appex / *.xpc）各有自己的
        //   entitlements（多为 app-sandbox + inherit，且**不带** application-identifier）；
        //   一旦被盖上主 app 的 application-identifier（5A4RE8SF68.com.tencent.xinWeChat），
        //   就与该 helper 自身的 code identifier 不符 → 沙盒初始化 _libsecinit_appsandbox
        //   直接 SIGILL → 小程序 / 视频播放 / 分享扩展启动即崩（踩过）。
        //   --preserve-metadata=entitlements 保留每个二进制**自己的** entitlements，实测
        //   在二进制已被改动（嵌入签名失效）后依然能正确读到。
        try await Command.execute(command:
            "codesign --force --deep --sign - --preserve-metadata=entitlements \(app.path)")
        // ★ 只清 quarantine，绝不能用 `xattr -cr`：它会连非 Mach-O 文件的 xattr 代码签名
        //   一起抹掉（例如 XPlayer.app/Contents/Frameworks/vk_swiftshader_icd.json 的签名
        //   就存在 xattr 里），导致下次 `--deep` 重签报
        //   "code object is not signed at all" 而失败。
        //   个别只读文件清不动属正常，用 `; true` 吞掉非零退出（签名已生效）。
        try await Command.execute(command: "xattr -r -d com.apple.quarantine \(app.path) 2>/dev/null; true")
    }

    /// 运行时组件（libwxrevoketip.dylib / add_load_dylib.py）的搜索目录，覆盖三种布局：
    ///   1. 开发：<repo>/wechattweak 与 <repo>/runtime/build/
    ///   2. 扁平分发（release tarball 解压）：与可执行文件同目录
    ///   3. brew：Cellar/<ver>/bin 与 Cellar/<ver>/libexec（解析符号链接后定位）
    private static func runtimeAssetDirs() -> [URL] {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WXRT_RUNTIME_DIR"], !override.isEmpty {
            dirs.append(URL(fileURLWithPath: override))
        }
        // 真实可执行文件路径（解析符号链接 → 兼容 brew Cellar 布局）
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        var realBinDir: URL?
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let real = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
            realBinDir = real.deletingLastPathComponent()
        }
        let argvDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for base in [realBinDir, argvDir].compactMap({ $0 }) {
            dirs.append(base)                                         // 扁平：同目录
            dirs.append(base.deletingLastPathComponent()
                .appendingPathComponent("libexec"))                   // brew keg
            dirs.append(base.appendingPathComponent("runtime"))       // 开发
            dirs.append(base.appendingPathComponent("runtime/build")) // 开发
        }
        return dirs
    }

    private static func firstExistingRuntimeAsset(_ name: String) -> URL? {
        let fm = FileManager.default
        return runtimeAssetDirs()
            .map { $0.appendingPathComponent(name) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// 安装撤回提示运行时组件：
    /// 1. 把 libwxrevoketip.dylib 拷进 Contents/Resources/
    /// 2. 向主二进制加 LC_LOAD_WEAK_DYLIB（弱依赖，dylib 缺失不影响启动）
    /// 3. 写配置文件（提示模板）到 app 容器可读位置
    /// 注：必须在 resign 之前调用（本函数改主二进制，重签要放在最后）。
    static func installTipRuntime(app: URL, template: String) async throws {
        let fm = FileManager.default

        // 本 dylib 只编了 x86_64；arm64 原生跑微信时弱依赖会被 dyld 静默跳过，功能不生效。
        if let host = try? await Command.execute(command: "uname -m")?
            .trimmingCharacters(in: .whitespacesAndNewlines), host == "arm64" {
            print("⚠️  撤回提示组件目前仅支持 x86_64；本机为 arm64，微信原生运行时该组件不会生效。")
        }

        // 1. 定位随包分发的 dylib
        guard let dylibSrc = firstExistingRuntimeAsset("libwxrevoketip.dylib") else {
            throw Tweak.Error.runtimeDylibNotFound
        }

        // 2. 拷贝到 Resources/
        let dylibDst = app.appendingPathComponent("Contents/Resources/libwxrevoketip.dylib")
        if fm.fileExists(atPath: dylibDst.path) { try fm.removeItem(at: dylibDst) }
        try fm.copyItem(at: dylibSrc, to: dylibDst)

        // 3. 主二进制加 LC_LOAD_WEAK_DYLIB（幂等：已有则跳过）
        let mainBinary = app.appendingPathComponent("Contents/MacOS/WeChat")
        let loadName = "@executable_path/../Resources/libwxrevoketip.dylib"
        let alreadyLinked = try await Command.execute(
            command: "otool -l \(mainBinary.path) | grep -c wxrevoketip || true"
        ) ?? "0"
        if alreadyLinked.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            guard let pySrc = firstExistingRuntimeAsset("add_load_dylib.py") else {
                throw Tweak.Error.runtimeDylibNotFound
            }
            try await Command.execute(
                command: "python3 \(pySrc.path) \(mainBinary.path) '\(loadName)'"
            )
        } else {
            print("Runtime dylib already linked, skip LC injection")
        }

        // 4. 写模板配置。组件运行时按 $HOME 读 ~/wxrevoketip.conf：
        //    - 沙盒（patch 会把原始 entitlements 重签回，含 sandbox）：$HOME 映射到容器 Data 目录
        //    - 非沙盒：$HOME = 真实主目录
        //    只写实际会被读取的那一处；写另一处只会留下一个永远读不到的文件。
        let containerData = URL(fileURLWithPath: NSString(string: "~/Library/Containers/com.tencent.xinWeChat/Data").expandingTildeInPath)
        let confURL: URL
        if FileManager.default.fileExists(atPath: containerData.path) {
            confURL = containerData.appendingPathComponent("wxrevoketip.conf")
        } else {
            confURL = URL(fileURLWithPath: NSString(string: "~/wxrevoketip.conf").expandingTildeInPath)
        }
        try "tip=\(template)\n".write(to: confURL, atomically: true, encoding: .utf8)
        print("Tip template written: \(confURL.path)")
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
            throw Error.executing(
                command: command,
                error: ["error": "Create script failed."]
            )
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error = error {
            throw Error.executing(
                command: command,
                error: error
            )
        } else {
            return descriptor.stringValue
        }
    }
}
