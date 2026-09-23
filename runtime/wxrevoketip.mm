//  wxrevoketip.mm — 微信撤回提示增强（x86_64 运行时组件，阶段 A）
//
//  目标版本：WeChat 4.1.15 / CFBundleVersion 270098（x86_64 切片）
//  目标二进制：Contents/Resources/wechat.dylib（__TEXT vmaddr=0，故 VA == 切片内文件偏移）
//
//  原理
//    撤回链路（ADAPT_X64.md「4.1.15 撤回链路全图」）：
//      callback sub_537D8A0(msg, a2)
//        msg+0x1D0 = a2+0x130 的文案                  (原生提示文案，先拷贝)
//        al, flag = sub_537DAD0(msg, a2+0x130, &flag) (★撤回 parser)
//        if (al==0 || flag==1) -> sub_537EF30(msg, &replaceMsg)  执行撤回
//        else                  -> return 1                        静默防撤回
//
//    本组件在 parser 入口下 inline hook（VA：270100 = 0x537DCD0，270098 = 0x537DAD0；
//    下方反汇编片段取自 270098，两版函数体一致、仅整体位移 +0x200）：
//      · 入口 13 字节序言整体替换为  movabs rax,<wrapper> ; jmp rax ; nop
//      · 原序言拷进 trampoline，尾部  FF 25 rel32 + 绝对地址  跳回 entry+13
//      · wrapper 调用原函数后，按开关给 msg+0x1D0（提示文案 std::string）加标记
//
//  兼容静态补丁：如果磁盘上的 parser 已被 config.json 的 revoke 目标改成
//    `b8 01 00 00 00 c3`（mov eax,1; ret），本组件会先在内存里把前 6 字节还原成
//    原始序言 `55 48 89 e5 41 57`，再装 hook。磁盘文件不动。
//
//  环境变量
//    WXRT_APPLY=1        真正改写提示文案（默认 0 = 只观察、只打日志）
//    WXRT_MARKER=<文本>  加在提示前面的标记（默认 "[已拦截] "）
//    WXRT_LOG=<路径>     日志文件（默认 /tmp/wxrevoketip.log）
//
//  注意：只改进程内存，不改磁盘；需要目标进程允许 RWX 内存与越权页改写。

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <string>

// ---------------------------------------------------------------------------
// 可调参数（换微信版本时改这里）
//   正常情况不用改：两个 hook 地址靠特征码运行时自定位（见 find_hook_targets）。
//   特征码失配时（微信大改），才回退到下面的硬编码 VA。
// ---------------------------------------------------------------------------
static const uintptr_t kParserVA      = 0x537DCD0;   // 撤回 parser 入口 VA（270100 兜底）
static const uintptr_t kFinalizerVA   = 0x530CBF0;   // message.cc finalizer（270100 兜底）
static const size_t    kPrologueLen   = 13;          // 被覆盖的序言长度
static const char*     kImageNeedle   = "wechat.dylib";

// ---- 运行时可覆盖项（环境变量，换版救急用，优先级高于特征码/硬编码）----
//   WXRT_PARSER_VA / WXRT_FINALIZER_VA          覆盖两个 hook 入口 VA（0x 前缀或十进制）
//   WXRT_OFF_TYPE / WXRT_OFF_NEWMSGID / WXRT_OFF_REPLACEMSG  parser msg 对象字段偏移
//   WXRT_OFF_SESSION / WXRT_OFF_CONTENT          finalizer a1 字段偏移
// 非平凡初始化顺序无关（都是整型，常量初始化），load_config() 里再按环境变量改写。
static uintptr_t g_hookParserVA    = kParserVA;
static uintptr_t g_hookFinalizerVA = kFinalizerVA;
static size_t    g_offType         = 0x1A8;   // parser msg: std::string msg type
static size_t    g_offNewMsgId     = 0x1C8;   // parser msg: u64 newmsgid
static size_t    g_offReplaceMsg   = 0x1D0;   // parser msg: std::string 提示文案
static size_t    g_offSession      = 0x18;    // finalizer a1: std::string 会话 wxid
static size_t    g_offContent      = 0x130;   // finalizer a1: std::string 原文

// 原始序言（来自 original/wechat-270098.dylib）
static const uint8_t kPrologue[kPrologueLen] = {
    0x55,             // push rbp
    0x48, 0x89, 0xe5, // mov  rbp, rsp
    0x41, 0x57,       // push r15
    0x41, 0x56,       // push r14
    0x41, 0x55,       // push r13
    0x41, 0x54,       // push r12
    0x53              // push rbx
};
// 静态 revoke 补丁的形态：mov eax,1 ; ret ，只覆盖了序言前 6 字节
static const uint8_t kStaticRevoke[6] = {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3};

// ---------------------------------------------------------------------------
// 配置
//   优先级：环境变量 > 配置文件 > 内置默认
//   配置文件：$WXRT_CONFIG，默认 $HOME/wxrevoketip.conf
//   文件格式（shell 风格 key=value，# 开头为注释）：
//     tip=[已拦截] {from} 撤回了：{content}      # 提示模板
//     log=/path/to/wxrevoketip.log               # 日志路径
//   模板占位符：
//     {from}     发送者（从原生提示 "xxx 撤回了一条消息" 里提取）
//     {time}     撤回时间 HH:MM
//     {content}  原文（仅本次微信启动后收到的消息有；无原文时整段省略）
//     {marker}   默认标记 "[已拦截] "（原提示文案原样保留时的前缀）
//   环境变量：WXRT_APPLY=1  WXRT_MARKER  WXRT_LOG  WXRT_CONFIG
// ---------------------------------------------------------------------------
static FILE* g_log = nullptr;
static char  g_logPath[512] = {0};
static bool  g_apply = true;    // 已安装组件默认生效；WXRT_APPLY=0 可关闭
static std::string g_marker = "[已拦截] ";
static std::string g_tipTemplate;          // 空 = 只加 marker，不重排
static char       g_confPath[512] = {0};

static std::string trim_copy(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// 读配置文件（shell 风格 key=value；不存在则静默跳过）
static void load_conf_file(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        std::string s(line);
        // 去注释 / 空行
        size_t hash = s.find('#');
        if (hash != std::string::npos) s = s.substr(0, hash);
        s = trim_copy(s);
        if (s.empty()) continue;
        size_t eq = s.find('=');
        if (eq == std::string::npos) continue;
        std::string key = trim_copy(s.substr(0, eq));
        std::string val = trim_copy(s.substr(eq + 1));
        // 去掉两侧引号
        if (val.size() >= 2 && ((val.front() == '"' && val.back() == '"') ||
                                (val.front() == '\'' && val.back() == '\''))) {
            val = val.substr(1, val.size() - 2);
        }
        if (key == "tip")       g_tipTemplate = val;
        else if (key == "log")  snprintf(g_logPath, sizeof(g_logPath), "%s", val.c_str());
        else if (key == "marker") g_marker = val;
    }
    fclose(f);
}

static void load_config(void) {
    // 先定默认值（不依赖全局静态初始化顺序：构造函数可能早于 g_marker 的非平凡
    // 初始化运行，那时 std::string 还是空串）。这里在构造函数体内赋值，保证可靠。
    g_marker = "[已拦截] ";
    g_tipTemplate.clear();

    // 1) 配置文件（环境变量指定路径，或 $HOME/wxrevoketip.conf）
    const char* conf = getenv("WXRT_CONFIG");
    if (!conf) {
        static char buf[512];
        const char* h = getenv("HOME");
        if (h) { snprintf(buf, sizeof(buf), "%s/wxrevoketip.conf", h); conf = buf; }
    }
    if (conf) {
        snprintf(g_confPath, sizeof(g_confPath), "%s", conf);
        load_conf_file(conf);
    }
    // 2) 环境变量覆盖（空串视为未设置，不覆盖默认/配置文件值）
    if (const char* m = getenv("WXRT_MARKER")) { if (m[0]) g_marker = m; }
    if (const char* t = getenv("WXRT_TIP"))   { if (t[0]) g_tipTemplate = t; }

    // 3) hook 地址 / 结构偏移覆盖（换版特征码失配时的救急通道，免重编译）
    //    传值支持 0x 前缀（strtoul base=0）
    auto envU64 = [](const char* k, uintptr_t* out) {
        if (const char* v = getenv(k)) { if (v[0]) *out = (uintptr_t)strtoull(v, nullptr, 0); }
    };
    auto envSize = [](const char* k, size_t* out) {
        if (const char* v = getenv(k)) { if (v[0]) *out = (size_t)strtoul(v, nullptr, 0); }
    };
    envU64("WXRT_PARSER_VA",    &g_hookParserVA);
    envU64("WXRT_FINALIZER_VA", &g_hookFinalizerVA);
    envSize("WXRT_OFF_TYPE",       &g_offType);
    envSize("WXRT_OFF_NEWMSGID",   &g_offNewMsgId);
    envSize("WXRT_OFF_REPLACEMSG", &g_offReplaceMsg);
    envSize("WXRT_OFF_SESSION",    &g_offSession);
    envSize("WXRT_OFF_CONTENT",    &g_offContent);
}

static void logline(const char* fmt, ...) {
    if (!g_log) {
        // 微信带 app-sandbox，/tmp 只在 sandbox_init 之前可写，所以按优先级找可写路径：
        //   1) 配置文件/环境变量指定的路径（g_logPath 可能已被 conf 填好）
        //   2) $HOME/wxrevoketip.log        （沙盒里 $HOME 就是容器 Data 目录）
        //   3) /tmp/wxrevoketip.log
        const char* cands[3] = { g_logPath[0] ? g_logPath : nullptr, nullptr, "/tmp/wxrevoketip.log" };
        char homePath[512];
        const char* h = getenv("HOME");
        if (h) { snprintf(homePath, sizeof(homePath), "%s/wxrevoketip.log", h); cands[1] = homePath; }
        for (int i = 0; i < 3; i++) {
            if (!cands[i]) continue;
            FILE* f = fopen(cands[i], "a");
            if (f) {
                g_log = f;
                snprintf(g_logPath, sizeof(g_logPath), "%s", cands[i]);
                break;
            }
        }
    }
    if (!g_log) return;
    flockfile(g_log);
    fprintf(g_log, "[wxrevoketip pid=%d] ", getpid());
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    funlockfile(g_log);
    fflush(g_log);
}

// ---------------------------------------------------------------------------
// 轻量内存可读性检查（避免误踩坏指针把微信搞崩）
//   注意：mincore 只能证明「页已映射」，不能证明「可读」；而且 racing 状态下
//   另一个线程可能正在改这块内存。所以 data 指针要单独再验一遍，len 上限收紧。
static bool readable(const void* p, size_t n) {
    if (!p || n == 0) return false;
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) return false;
    uintptr_t start = reinterpret_cast<uintptr_t>(p) & ~(uintptr_t)(ps - 1);
    uintptr_t end   = (reinterpret_cast<uintptr_t>(p) + n + ps - 1) & ~(uintptr_t)(ps - 1);
    size_t pages = (end - start) / (size_t)ps;
    if (pages == 0 || pages > 16) return false;
    char vec[16];
    return mincore(reinterpret_cast<void*>(start), end - start, vec) == 0;
}

// libc++ std::string 24 字节：长串时 raw[0]&1 == 1，[8]=size，[16]=data
//
// ★ 崩溃教训（两次 SIGSEGV @ __grow_by_and_replace / memmove 0x2f）：
//   这个 msg 对象正被微信其它线程并发写。我们读 [8]=len、[16]=data 的瞬间可能
//   撞上「data 指针刚被释放/尚未写入」的中间态 —— readable() 探活通过也白搭，
//   因为探活之后、assign 之前指针随时可能失效。
//   结论：绝不在这里读长串（堆指针），只处理 SSO（≤22 字节，内联在对象里，无指针解引用）。
//   22 字节虽然截断了 XML/提示文案，但对「识别 revokemsg」「判断标记是否存在」够用，
//   而且绝对安全：数据在 24 字节对象内部，只要 readable(s,24) 就一定能读。
static bool inspect_std_string(const std::string* s, std::string* out) {
    if (!readable(s, 24)) return false;
    const unsigned char* raw = reinterpret_cast<const unsigned char*>(s);
    if (raw[0] & 1) return false;                 // 长串：不碰（见上）
    size_t len = raw[0] >> 1;                     // SSO
    if (len > 22) return false;
    const char* data = reinterpret_cast<const char*>(raw + 1);
    if (out) {
        try {
            out->assign(data, len);               // SSO：无指针解引用，安全
        } catch (...) {
            return false;
        }
    }
    return true;
}


// ---------------------------------------------------------------------------
// 镜像筛选
//   "wechat.dylib" 这个 needle 会命中两个镜像：
//     Contents/Frameworks/wechat.dylib  ← 4.1.9 起的 82KB stub（不含目标代码）
//     Contents/Resources/wechat.dylib   ← 真身
//   所以必须再用「__TEXT 段是否覆盖 kParserVA」判定，否则读到未映射页直接 SIGBUS。
// ---------------------------------------------------------------------------
static bool text_range_of(const struct mach_header* mh, uintptr_t* vmaddr, uintptr_t* vmsize) {
    size_t off;
    uint32_t ncmds, sizeofcmds;
    if (mh->magic == MH_MAGIC_64) {
        const mach_header_64* h = reinterpret_cast<const mach_header_64*>(mh);
        off = sizeof(mach_header_64); ncmds = h->ncmds; sizeofcmds = h->sizeofcmds;
    } else if (mh->magic == MH_MAGIC) {
        off = sizeof(mach_header); ncmds = mh->ncmds; sizeofcmds = mh->sizeofcmds;
    } else {
        return false;
    }
    const uint8_t* base = reinterpret_cast<const uint8_t*>(mh);
    size_t end = off + sizeofcmds;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + sizeof(load_command) > end) return false;
        const load_command* lc = reinterpret_cast<const load_command*>(base + off);
        if (lc->cmdsize < sizeof(load_command) || off + lc->cmdsize > end) return false;
        if (lc->cmd == LC_SEGMENT_64) {
            const segment_command_64* sc = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(sc->segname, "__TEXT", 16) == 0) {
                *vmaddr = sc->vmaddr; *vmsize = sc->vmsize;
                return true;
            }
        } else if (lc->cmd == LC_SEGMENT) {
            const segment_command* sc = reinterpret_cast<const segment_command*>(lc);
            if (strncmp(sc->segname, "__TEXT", 16) == 0) {
                *vmaddr = sc->vmaddr; *vmsize = sc->vmsize;
                return true;
            }
        }
        off += lc->cmdsize;
    }
    return false;
}

// ---------------------------------------------------------------------------
// hook
// ---------------------------------------------------------------------------
typedef bool (*ParserFn)(void* msg, void* in, void* flagOut);
static ParserFn g_original = nullptr;

static uint8_t* g_pendingEntry = nullptr;   // 待安装的 parser 入口（由 dyld 回调写入）
static intptr_t g_pendingSlide = 0;
static const char* g_pendingName = nullptr;
static bool g_installRunning = false;
static uintptr_t g_finalizerVA = 0;         // 特征码定位结果（do_install 使用）


static bool field_u64(void* base, size_t off, uint64_t* out) {
    if (!base || !readable(reinterpret_cast<char*>(base) + off, sizeof(uint64_t))) return false;
    memcpy(out, reinterpret_cast<char*>(base) + off, sizeof(uint64_t));
    return true;
}


// ---------------------------------------------------------------------------
// Hook B：普通消息 finalizer（sub_530C9F0，message.cc）
//   收消息时捕获（会话 wxid → 最近一条文本原文）存进内存缓存；
//   撤回时用 XML 里的 <session> 反查原文拼进提示。
//
//   注：参考项目（arm64）用「finalizer 抓 serverId + XML newmsgid join」，
//   x86_64 270098 实测 proto 里 serverId 字段（a2+96）恒为 0，id join 不可行
//   （撤回 XML 的 <msgid> 是另一个域的值，与消息对象里的任何 id 都对不上），
//   故改用「会话最近一条文本」启发式 —— 撤回的几乎总是最近一条。
//
//   对象字段（270098 x86_64 内存 dump 实测）：
//     a1+0x18  : std::string 会话 wxid（SSO，如 "wxid_xxx" / "123@chatroom"）
//     a1+0x130 : std::string content（消息原文；群聊他人消息带 "wxid_xxx:\n" 前缀）
// ---------------------------------------------------------------------------
#include <mutex>
#include <unordered_map>

typedef void (*FinalizerFn)(void* a1, void* a2);
static FinalizerFn g_originalFinalizer = nullptr;

static std::mutex g_contentCacheMutex;
// 启发式 join：id join 已被实测否定（proto 里没有本地 id/服务器 id，见 do_install 注释）。
// 改用「会话 → 最近一条文本」：撤回的几乎总是最近一条，XML 里的 <session> 就是会话 wxid。
struct SessionPreview { std::string content; };
static std::unordered_map<std::string, SessionPreview> g_sessionCache;
static const size_t kSessionCacheMax = 256;
static const size_t kPreviewMaxBytes = 240;

static std::string utf8_truncate(const std::string& in, size_t maxBytes) {
    if (in.size() <= maxBytes) return in;
    size_t cut = maxBytes;
    while (cut > 0 && (in[cut] & 0xC0) == 0x80) cut--;   // 不切断 UTF-8 序列
    return in.substr(0, cut) + "…";
}

// 只缓存纯文本原文（媒体消息没有"原文"可显示）
static void remember_session_text(const std::string& wxid, const std::string& content) {
    if (wxid.empty() || content.empty()) return;
    std::lock_guard<std::mutex> lock(g_contentCacheMutex);
    if (g_sessionCache.size() >= kSessionCacheMax) g_sessionCache.clear();
    g_sessionCache[wxid] = SessionPreview{ utf8_truncate(content, kPreviewMaxBytes) };
}


// 消费式读取：撤回后该条原文就不该再出现，取走即删，避免同会话下一条撤回串台
static bool take_session_text(const std::string& wxid, std::string* out) {
    std::lock_guard<std::mutex> lock(g_contentCacheMutex);
    auto it = g_sessionCache.find(wxid);
    if (it == g_sessionCache.end()) return false;
    *out = it->second.content;
    g_sessionCache.erase(it);
    return true;
}

// 安全读 std::string（SSO 或长串）。返回空串表示不可读/失败。
// 调用时机约束：必须在「本线程正持有该对象」的窗口内（parser/finalizer 刚返回），
// 此时无并发写者，长串读取实测安全；其它时机读长串有 TOCTOU 风险（踩过 2 次 SIGSEGV）。
static std::string read_long_or_sso(const void* obj) {
    std::string out;
    if (!readable(obj, 24)) return out;
    const unsigned char* raw = reinterpret_cast<const unsigned char*>(obj);
    try {
        if (raw[0] & 1) {
            size_t len;
            const char* data;
            memcpy(&len, raw + 8, sizeof(len));
            memcpy(&data, raw + 16, sizeof(data));
            if (len == 0 || len > (1u << 16) || !readable(data, 1)) return out;
            out.assign(data, len);
        } else {
            size_t len = raw[0] >> 1;
            if (len > 22) return out;
            out.assign(reinterpret_cast<const char*>(raw + 1), len);
        }
    } catch (...) {
        out.clear();
    }
    return out;
}


// 判断这个 msg 对象是不是「撤回系统消息」：看 msg+0x1A8 == "revokemsg"。
// 该字段 9 字节，永远 SSO（≤22 字节内联，无堆指针），读它绝对安全。
//
// ★ 时序注意：0x1A8 是 parser 自己写的（0x537dc8e 先 assign("") 清空，
//   解析 XML 后写 type）—— 所以这个判断只能在 parser 返回之后做！
//   进 parser 之前 0x1A8 是空/旧值，拿它当门卫会全部误判（踩过：全透传 → 功能失效）。
static bool is_revoke_msg(void* msg) {
    if (!msg) return false;
    const std::string* s = reinterpret_cast<const std::string*>(
        reinterpret_cast<char*>(msg) + g_offType);
    if (!readable(s, 24)) return false;
    const unsigned char* raw = reinterpret_cast<const unsigned char*>(s);
    if (raw[0] & 1) return false;                    // 长串？不是预期形态
    size_t len = raw[0] >> 1;
    if (len != 9) return false;
    return memcmp(raw + 1, "revokemsg", 9) == 0;
}

// 「自己撤回」识别：原生提示/XML 以「你撤回/你收回/你回收/You recalled」开头或包含该片段。
// 自己撤回必须完全交给原生（原消息正常移除 + 原生提示），不能清 newmsgid、不能加标记。
// ⚠️ 这是文案启发式、不是身份校验：若对方昵称恰好含这些词，可能误判为自己撤回而跳过。
//    与 fzlzjerry/wechat-antirecall PR#71 的做法一致（独立验证过 269630 x86_64）。
static bool contains_self_recall(const std::string& s) {
    static const char* kSelf[] = {"你撤回", "你收回", "你回收",
                                  "You recalled", "you recalled"};
    for (const char* p : kSelf) {
        if (s.find(p) != std::string::npos) return true;
    }
    return false;
}


// 从原生提示 ""坦然" 撤回了一条消息" 里提取发送者（引号内名字）
static std::string extract_from(const std::string& nativeTip) {
    size_t q1 = nativeTip.find('"');
    if (q1 == std::string::npos) return "";
    size_t q2 = nativeTip.find('"', q1 + 1);
    if (q2 == std::string::npos) return "";
    return nativeTip.substr(q1 + 1, q2 - q1 - 1);
}

// HH:MM 当前时间
static std::string now_hhmm(void) {
    time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char buf[8];
    snprintf(buf, sizeof(buf), "%02d:%02d", tmv.tm_hour, tmv.tm_min);
    return buf;
}

// 模板渲染：{from} {time} {content}；{content} 为空时连同前导分隔符整段省略
static std::string render_tip(const std::string& tpl, const std::string& from,
                              const std::string& timeText, const std::string& content) {
    std::string out = tpl;
    auto replaceAll = [&](const std::string& k, const std::string& v) {
        if (v.empty()) return;
        size_t p;
        while ((p = out.find(k)) != std::string::npos) out.replace(p, k.size(), v);
    };
    replaceAll("{from}", from);
    replaceAll("{time}", timeText);
    replaceAll("{marker}", g_marker);
    if (!content.empty()) {
        replaceAll("{content}", content);
    } else {
        // 冷缓存：去掉 "：{content}" / ": {content}" / " {content}" 等前导分隔
        static const char* seps[] = {"：{content}", ": {content}", ":{content}", " {content}"};
        for (const char* sep : seps) {
            size_t p = out.find(sep);
            if (p != std::string::npos) { out.erase(p, strlen(sep)); break; }
        }
        size_t p;
        while ((p = out.find("{content}")) != std::string::npos) out.erase(p, 9);
    }
    return out;
}

static bool wrapper(void* msg, void* in, void* flagOut) {
    static int s_calls = 0;
    int callno = ++s_calls;
    bool verbose = (callno <= 500);   // 防止日志无限增长

    if (!g_apply) {
        // 安全模式：等价静态 revoke 补丁 —— parser 完全不执行。
        // （parser 一跑就会把提示文案写进 msg+0x1D0 / DB，实测只有 return true 拦不住）
        // 回调里 flagOut 已被初始化为 0，al=1 && flag=0 → 走"跳过 apply"分支。
        if (verbose) logline("parser#%d SAFE bypass（parser 未执行）msg=%p", callno, msg);
        return true;
    }

    // ---- tip 模式：让 parser 完整执行，再给渲染文案加标记 ----
    // 门卫必须在 parser 之后查（0x1A8 是 parser 写的，见 is_revoke_msg 注释）。
    // parser 对非撤回消息本来就只是透传处理，这里放行是安全且必要的。

    // 进 parser 前 msg+0x1D0 是原始 sysmsg XML（回调刚拷进来的）。
    // 本线程此刻持有该对象，读它是安全的。提取 <session>（会话 wxid，join 键）。
    std::string xmlSession;
    bool xmlSelfRecall = false;
    {
        std::string xml = read_long_or_sso(
            reinterpret_cast<char*>(msg) + g_offReplaceMsg);
        if (!xml.empty() && xml.find("revokemsg") != std::string::npos) {
            size_t p = xml.find("<session>");
            if (p != std::string::npos) {
                p += 9;
                size_t e = xml.find('<', p);
                if (e != std::string::npos && e > p) xmlSession = xml.substr(p, e - p);
            }
            xmlSelfRecall = contains_self_recall(xml);
            // 诊断：前 3 次打印
            static int s_xmlDumps = 0;
            if (s_xmlDumps < 3) {
                s_xmlDumps++;
                logline("XML#%d session=%s self=%d", s_xmlDumps, xmlSession.c_str(),
                        (int)xmlSelfRecall);
            }
        }
    }

    bool ret = g_original ? g_original(msg, in, flagOut) : false;

    unsigned flag = 0;
    if (flagOut && readable(flagOut, 1)) flag = *reinterpret_cast<unsigned char*>(flagOut);

    if (!is_revoke_msg(msg)) {
        if (verbose) logline("parser#%d passthrough（非撤回）ret=%d", callno, (int)ret);
        return ret;
    }

    // ★ 自己撤回：完全交给原生（原消息正常移除 + 原生提示），不清 newmsgid、不加标记。
    //   必须在清 newmsgid 之前判断，否则自己撤回的消息反而会被留在列表里。
    if (xmlSelfRecall ||
        contains_self_recall(read_long_or_sso(
            reinterpret_cast<char*>(msg) + g_offReplaceMsg))) {
        logline("parser#%d 自己撤回，跳过（保持原生移除 + 原生提示）", callno);
        return ret;
    }

    uint64_t newmsgidOut = 0;
    bool haveNewOut = field_u64(msg, g_offNewMsgId, &newmsgidOut);

    if (verbose) logline("parser#%d ret=%d flag=%u session=%s newmsgid=%s", callno, (int)ret, flag,
            xmlSession.empty() ? "-" : xmlSession.c_str(),
            haveNewOut ? std::to_string(newmsgidOut).c_str() : "--");

    // 用 XML 里的 <session>（会话 wxid）取该会话最近一条文本作原文，拼进提示。
    std::string preview;
    bool havePreview = take_session_text(xmlSession, &preview);

    // 关键一步：把 newmsgid 清 0。
    // apply（sub_537EF30）靠 newmsgid 找 DB 里原消息行并覆盖成提示；
    // 清 0 后它找不到行 → 原消息保留；UI 照样渲染 replacemsg 提示 → 提示+原文都要。
    // （这就是参考项目 PR#71 的 runtime-tip 核心手法）
    // 注意 0x1C8 是 uint64 字段，parser 刚写完、apply 还没跑，这个窗口没有并发写者。
    if (msg && newmsgidOut != 0) {
        *reinterpret_cast<uint64_t*>(reinterpret_cast<char*>(msg) + g_offNewMsgId) = 0;
        logline("   -> newmsgid 清零（原消息行将保留）");
    }

    // 提示整串替换：此刻是「parser 刚返回、本线程正持有该对象」的安全窗口。
    // 只碰 0x1D0（渲染用的提示文案）。
    do {
        if (!msg) break;
        std::string* s = reinterpret_cast<std::string*>(
            reinterpret_cast<char*>(msg) + g_offReplaceMsg);
        std::string cur = read_long_or_sso(s);
        if (cur.empty()) break;
        // 内容门卫：只动「撤回提示」文案；跳过自己撤回的（原生提示保留）
        if (cur.find("撤回") == std::string::npos &&
            cur.find("recalled") == std::string::npos) break;
        if (cur.compare(0, g_marker.size(), g_marker) == 0) break;   // 已处理过

        std::string rendered;
        if (!g_tipTemplate.empty()) {
            rendered = render_tip(g_tipTemplate, extract_from(cur), now_hhmm(),
                                  havePreview ? preview : "");
        } else {
            // 默认风格：保留原生提示，前面加标记，有原文再补【】
            rendered = g_marker + cur;
            if (havePreview) rendered += "【" + preview + "】";
        }
        try {
            s->assign(rendered);
            logline("   -> marked msg+0x%zx（%s原文）", g_offReplaceMsg,
                    havePreview ? "带" : "无");
        } catch (...) { break; }
    } while (false);

    return ret;   // 保持原生控制流（apply 与否交给微信自己）
}


// 通用 13 字节序言 inline hook 安装器（两个 hook 共用）
static bool install_inline_hook(uint8_t* entry, void* wrapperFn, void** outTrampoline,
                                const uint8_t* expectPrologue, const char* tag) {
    if (!readable(entry, kPrologueLen)) return false;
    if (memcmp(entry, expectPrologue, kPrologueLen) != 0) {
        logline("%s 序言不匹配 @ %p：%02x %02x %02x %02x %02x %02x ...，跳过",
                tag, entry, entry[0], entry[1], entry[2], entry[3], entry[4], entry[5]);
        return false;
    }
    long pageSize = sysconf(_SC_PAGESIZE);
    uintptr_t pageStart = reinterpret_cast<uintptr_t>(entry) & ~(uintptr_t)(pageSize - 1);
    uintptr_t pageEnd   = (reinterpret_cast<uintptr_t>(entry) + kPrologueLen + pageSize - 1)
                          & ~(uintptr_t)(pageSize - 1);
    if (mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart,
                 PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        logline("%s mprotect 失败（errno=%d）", tag, errno);
        return false;
    }
    uint8_t* tramp = reinterpret_cast<uint8_t*>(
        mmap(nullptr, 64, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0));
    if (tramp == MAP_FAILED) {
        logline("%s mmap 失败", tag);
        mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart, PROT_READ | PROT_EXEC);
        return false;
    }
    memcpy(tramp, entry, kPrologueLen);
    tramp[kPrologueLen + 0] = 0xFF;
    tramp[kPrologueLen + 1] = 0x25;
    memset(tramp + kPrologueLen + 2, 0, 4);
    *reinterpret_cast<uint64_t*>(tramp + kPrologueLen + 6) =
        reinterpret_cast<uint64_t>(entry + kPrologueLen);

    uint8_t patch[kPrologueLen];
    patch[0] = 0x48;
    patch[1] = 0xB8;
    *reinterpret_cast<uint64_t*>(patch + 2) = reinterpret_cast<uint64_t>(wrapperFn);
    patch[10] = 0xFF;
    patch[11] = 0xE0;
    patch[12] = 0x90;
    memcpy(entry, patch, kPrologueLen);
    __builtin___clear_cache(reinterpret_cast<char*>(entry), reinterpret_cast<char*>(entry + kPrologueLen));
    mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart, PROT_READ | PROT_EXEC);

    *outTrampoline = tramp;
    logline("%s hook 已安装: entry=%p tramp=%p", tag, entry, tramp);
    return true;
}

static void finalizer_wrapper(void* a1, void* a2) {
    FinalizerFn orig = g_originalFinalizer;
    if (orig) orig(a1, a2);          // 先让原函数把字段填好

    // 捕获（只读；对象此刻仍在本线程调用栈内）
    // 已实证：a1+0x18 = 会话 wxid（SSO string，flag 字节 0x26=2*19），a1+0x130 = 原文。
    do {
        if (!a1 || !readable(a1, g_offContent + 0x18)) break;
        std::string wxid;
        const std::string* w = reinterpret_cast<const std::string*>(
            reinterpret_cast<char*>(a1) + g_offSession);   // ★ 0x18（0x10 是别的字段）
        if (!inspect_std_string(w, &wxid) || wxid.empty()) break;
        if (wxid.find("wxid_") == std::string::npos &&
            wxid.find("@chatroom") == std::string::npos &&
            wxid.find("gh_") == std::string::npos) break;

        std::string content = read_long_or_sso(
            reinterpret_cast<char*>(a1) + g_offContent);
        if (content.empty()) break;

        // 只缓存"纯文本"：图片/视频等消息的 content 是 XML（以 "<" 开头），
        // 撤回 XML/系统消息同样以 "<" 开头 —— 一律不缓存（没有"原文"可显示）
        if (content[0] == '<') break;
        // 群聊里 content 形如 "wxid_xxx:\n消息正文"，去掉前缀
        size_t strip = 0;
        if (content.compare(0, wxid.size(), wxid) == 0 &&
            content.size() > wxid.size() + 2 &&
            content[wxid.size()] == ':' && content[wxid.size() + 1] == '\n') {
            strip = wxid.size() + 2;
        }
        std::string text = content.substr(strip);
        if (text.empty() || text[0] == '@') break;

        remember_session_text(wxid, text);
        logline("capture wxid=%s len=%zu", wxid.c_str(), text.size());
    } while (false);
}

// 真正的安装动作（在独立线程里跑，避免在 dyld 通知回调里做 mmap/mprotect/IO）
static void do_install(void) {
    uint8_t* entry = g_pendingEntry;
    const char* name = g_pendingName;
    if (!entry) return;

    // ★ 必须先开写权限再动 __TEXT：wechat.dylib 的 __TEXT 是 r-x，
    //   直接写会 SIGBUS / KERN_PROTECTION_FAILURE（踩过）
    long pageSize = sysconf(_SC_PAGESIZE);
    uintptr_t pageStart = reinterpret_cast<uintptr_t>(entry) & ~(uintptr_t)(pageSize - 1);
    uintptr_t pageEnd   = (reinterpret_cast<uintptr_t>(entry) + kPrologueLen + pageSize - 1)
                          & ~(uintptr_t)(pageSize - 1);
    if (mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart,
                 PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        logline("mprotect(RWX) 失败（errno=%d）：%s", errno, name);
        return;
    }

    uint8_t* parserEntry = entry;
    if (memcmp(parserEntry, kPrologue, kPrologueLen) != 0) {
        // 兼容「静态 revoke 补丁已打在磁盘上」：前 6 字节被换成 mov eax,1; ret，
        // 后面 7 字节仍是原序言 → 内存里还原前 6 字节即可。
        if (memcmp(parserEntry, kStaticRevoke, sizeof(kStaticRevoke)) == 0 &&
            memcmp(parserEntry + sizeof(kStaticRevoke), kPrologue + sizeof(kStaticRevoke),
                   kPrologueLen - sizeof(kStaticRevoke)) == 0) {
            logline("检测到静态 revoke 补丁，内存中还原前 6 字节序言");
            memcpy(parserEntry, kPrologue, sizeof(kStaticRevoke));
        } else {
            logline("序言不匹配 @ %p (%s)：%02x %02x %02x %02x %02x %02x ... — 版本可能已变，跳过",
                    parserEntry, name, parserEntry[0], parserEntry[1], parserEntry[2],
                    parserEntry[3], parserEntry[4], parserEntry[5]);
            mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart, PROT_READ | PROT_EXEC);
            return;
        }
    }

    // Hook B（finalizer）：序言相同，同一安装器
    uint8_t* finalizerEntry = reinterpret_cast<uint8_t*>(
        g_pendingSlide + (g_finalizerVA ? g_finalizerVA : g_hookFinalizerVA));
    void* finTramp = nullptr;
    install_inline_hook(finalizerEntry, (void*)&finalizer_wrapper, &finTramp,
                        kPrologue, "[finalizer]");
    if (finTramp) g_originalFinalizer = reinterpret_cast<FinalizerFn>(finTramp);

    // Hook A（parser）
    void* parserTramp = nullptr;
    if (!install_inline_hook(parserEntry, (void*)&wrapper, &parserTramp,
                             kPrologue, "[parser]")) {
        mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart, PROT_READ | PROT_EXEC);
        return;
    }
    g_original = reinterpret_cast<ParserFn>(parserTramp);   // 最后一步：对外可见即已装好
    logline("全部 hook 完成 apply=%d marker=\"%s\"", (int)g_apply, g_marker.c_str());
    mprotect(reinterpret_cast<void*>(pageStart), pageEnd - pageStart, PROT_READ | PROT_EXEC);
}

// ---------------------------------------------------------------------------
// 特征码定位（微信小版本升级时地址漂移，这里运行时自定位，无需改代码）
//   parser    : 函数内联了 movabs "session\0" 和 movabs "newmsgid"（相距 <2KB），
//               从锚点向前回溯 13 字节标准序言即函数入口。
//   finalizer : 函数入口的栈帧布局唯一（序言13B + sub rsp,0x178 + mov r12,rsp + mov rbx,rdi）。
//   都在 270098 原版 wechat.dylib x86_64 切片上验证过唯一命中。
//   定位失败时回退硬编码 VA（上面 kParserVA / kFinalizerVA）。
// ---------------------------------------------------------------------------
struct HookTargets {
    uintptr_t parserVA;
    uintptr_t finalizerVA;
    uintptr_t anchorVA  = 0;   // sigscan 命中的锚点 VA（诊断）
    intptr_t  backtrack = 0;   // 锚点回溯到函数入口的字节数（诊断）
};

// ---- 函数身份校验（回退路径专用）----
// 13 字节序言极通用，仅凭序言无法区分函数；回退到硬编码/环境变量 VA 时，
// 必须再做一次"这个函数确实是目标"的强校验，否则宁可装不上也不能 hook 错函数（会崩）。
static bool verify_parser_identity(const uint8_t* text, size_t textLen,
                                   uintptr_t textVMaddr, uintptr_t va) {
    if (va < textVMaddr) return false;
    size_t off = (size_t)(va - textVMaddr);
    if (off + 0x1000 > textLen) return false;
    const uint8_t sess[] = {'s','e','s','s','i','o','n','\0'};
    const uint8_t nmsg[] = {'n','e','w','m','s','g','i','d'};
    bool hasSess = false, hasNew = false;
    for (size_t j = off; j + 10 < off + 0x1000 && j + 10 < textLen; j++) {
        if (text[j] == 0x48 && text[j+1] == 0xB8) {
            if (memcmp(text + j + 2, sess, sizeof(sess)) == 0) hasSess = true;
            if (memcmp(text + j + 2, nmsg, sizeof(nmsg)) == 0) hasNew = true;
            if (hasSess && hasNew) return true;
        }
    }
    return false;
}

static bool verify_finalizer_identity(const uint8_t* text, size_t textLen,
                                      uintptr_t textVMaddr, uintptr_t va) {
    if (va < textVMaddr) return false;
    size_t off = (size_t)(va - textVMaddr);
    if (off + 26 > textLen) return false;
    // 序言 13B 后紧跟 sub rsp,imm32 / mov r12,rsp / mov rbx,rdi
    const uint8_t* p = text + off + kPrologueLen;
    if (p[0] != 0x48 || p[1] != 0x81 || p[2] != 0xEC) return false;      // sub rsp, imm32
    if (p[7] != 0x49 || p[8] != 0x89 || p[9] != 0xF4) return false;      // mov r12, rsp
    if (p[10] != 0x48 || p[11] != 0x89 || p[12] != 0xFB) return false;   // mov rbx, rdi
    return true;
}


static bool find_hook_targets(const uint8_t* text, size_t textLen,
                              uintptr_t textVMaddr, HookTargets* out) {
    // ---- parser：movabs rax,"session\0" + 2KB 内 movabs rax,"newmsgid" ----
    //   注意 "session\0" 是完整 9 字节字符串（\0 在 movabs 立即数最高字节），
    //   "newmsgid" 9 字节装不下 → movabs 立即数只有前 8 字节 'newmsgid'（无 \0）
    const uint8_t sess[]  = {'s','e','s','s','i','o','n','\0'};
    const uint8_t nmsg[]  = {'n','e','w','m','s','g','i','d'};
    const uint8_t movabs  = 0x48, b8 = 0xB8;
    uintptr_t parserVA = 0;
    for (size_t i = 0; i + sizeof(sess) + 2 <= textLen; i++) {
        if (text[i] != movabs || text[i+1] != b8) continue;
        if (memcmp(text + i + 2, sess, sizeof(sess)) != 0) continue;
        // 在其后 2KB 内找 movabs "newmsgid"（8 字节立即数）
        bool hasNew = false;
        for (size_t j = i; j < i + 0x800 && j + sizeof(nmsg) + 2 <= textLen; j++) {
            if (text[j] == movabs && text[j+1] == b8 &&
                memcmp(text + j + 2, nmsg, sizeof(nmsg)) == 0) { hasNew = true; break; }
        }
        if (!hasNew) continue;
        // 回溯函数入口（限制在 2KB 内，防止跨到别的函数）
        // 两种入口形态都认：
        //   原始序言  55 48 89 e5 41 57 41 56 41 55 41 54 53
        //   静态补丁  b8 01 00 00 00 c3 + 序言后 7 字节（磁盘 revoke 补丁把前 6 字节改了）
        size_t searchFrom = i > 0x2000 ? i - 0x2000 : 0;
        const uint8_t pro[] = {0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,
                               0x41,0x55,0x41,0x54,0x53};
        const uint8_t proStatic[] = {0xB8,0x01,0x00,0x00,0x00,0xC3,
                                     0x41,0x56,0x41,0x55,0x41,0x54,0x53};
        size_t k = i;
        uintptr_t found = 0;
        while (k >= searchFrom + sizeof(pro)) {
            if (memcmp(text + k, pro, sizeof(pro)) == 0 ||
                memcmp(text + k, proStatic, sizeof(proStatic)) == 0) { found = 1; break; }
            k--;
        }
        if (!found) continue;
        parserVA = textVMaddr + k;
        out->anchorVA  = textVMaddr + i;
        out->backtrack = (intptr_t)(i - k);
        break;
    }
    if (!parserVA) return false;

    // ---- finalizer：入口 26 字节特征 ----
    const uint8_t finSig[] = {
        0x55,0x48,0x89,0xe5,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,
        0x48,0x81,0xec,0x78,0x01,0x00,0x00,       // sub rsp, 0x178
        0x49,0x89,0xf4,                            // mov r12, rsp
        0x48,0x89,0xfb                             // mov rbx, rdi
    };
    uintptr_t finalizerVA = 0;
    int finHits = 0;
    for (size_t i = 0; i + sizeof(finSig) <= textLen; i++) {
        if (memcmp(text + i, finSig, sizeof(finSig)) == 0) {
            finalizerVA = textVMaddr + i;
            finHits++;
        }
    }
    if (finHits != 1) return false;

    out->parserVA = parserVA;
    out->finalizerVA = finalizerVA;
    return true;
}

static void* install_thread(void*) {
    logline("install thread start, wait 200ms for dlopen");
    usleep(200 * 1000);          // 等 dlopen 把镜像映射完
    do_install();
    return nullptr;
}

static void install_hook_for_image(const struct mach_header* mh, intptr_t slide) {
    if (g_original || g_pendingEntry) return;   // 只认第一个合格的镜像

    const char* name = nullptr;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (_dyld_get_image_header(i) == mh) { name = _dyld_get_image_name(i); break; }
    }
    if (!name || !strstr(name, kImageNeedle)) return;

    // 关键：排除 Contents/Frameworks/wechat.dylib 那个 82KB stub
    uintptr_t vmaddr = 0, vmsize = 0;
    if (!text_range_of(mh, &vmaddr, &vmsize)) return;
    if (g_hookParserVA < vmaddr || g_hookParserVA + kPrologueLen > vmaddr + vmsize) {
        logline("skip %s (__TEXT 0x%lx+0x%lx doesn't cover 0x%lx, stub)",
                name, (unsigned long)vmaddr, (unsigned long)vmsize, (unsigned long)g_hookParserVA);
        return;
    }

    // 定位顺序：环境变量强制覆盖 > 特征码自定位 > 硬编码 VA（带身份校验）
    HookTargets targets = { g_hookParserVA, g_hookFinalizerVA };
    // __TEXT 在 vmaddr=0 时 mmap 内容即文件内容，可直接从 slide+vmaddr 读
    const uint8_t* textBase = reinterpret_cast<const uint8_t*>(slide + vmaddr);
    const char* envP = getenv("WXRT_PARSER_VA");
    const char* envF = getenv("WXRT_FINALIZER_VA");
    bool overridden = (envP && envP[0]) || (envF && envF[0]);

    if (overridden) {
        // 显式覆盖：完全信任用户值（hook 安装器仍会校验 13 字节序言兜底）
        logline("hook VA 由环境变量强制覆盖，跳过 sigscan（parser=0x%lx finalizer=0x%lx）",
                (unsigned long)targets.parserVA, (unsigned long)targets.finalizerVA);
    } else if (find_hook_targets(textBase, (size_t)vmsize, vmaddr, &targets)) {
        logline("sigscan: parser=0x%lx finalizer=0x%lx（锚点 0x%lx，回溯 %ld 字节）",
                (unsigned long)targets.parserVA, (unsigned long)targets.finalizerVA,
                (unsigned long)targets.anchorVA, (long)targets.backtrack);
    } else {
        // ★ 安全闸：硬编码兜底 VA 必须通过"函数身份校验"才允许 hook。
        //   13 字节序言太通用，光靠序言会把 hook 打到别的同序言函数上 → 崩溃。
        logline("sigscan 失败，回退硬编码 VA（parser=0x%lx finalizer=0x%lx），做身份校验",
                (unsigned long)targets.parserVA, (unsigned long)targets.finalizerVA);
        if (!verify_parser_identity(textBase, (size_t)vmsize, vmaddr, targets.parserVA) ||
            !verify_finalizer_identity(textBase, (size_t)vmsize, vmaddr, targets.finalizerVA)) {
            logline("硬编码 VA 身份校验不通过 → 放弃安装 hook（微信版本可能已变，"
                    "可用 WXRT_PARSER_VA/WXRT_FINALIZER_VA 手动指定）");
            return;
        }
        logline("硬编码 VA 身份校验通过");
    }

    g_pendingEntry   = reinterpret_cast<uint8_t*>(slide + targets.parserVA);
    g_pendingSlide   = slide;
    g_pendingName    = name;
    g_finalizerVA    = targets.finalizerVA;
    logline("matched %s (slide=0x%lx) -> entry=%p, install in 200ms",
            name, (unsigned long)slide, g_pendingEntry);

    if (!g_installRunning) {
        g_installRunning = true;
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&t, &attr, install_thread, nullptr);
        pthread_attr_destroy(&attr);
    }
}

__attribute__((constructor)) static void wxrevoketip_init(void) {
    load_config();
    // 默认生效（已作为 app 组件安装）；WXRT_APPLY=0/关闭值 可停用
    if (const char* a = getenv("WXRT_APPLY")) {
        g_apply = !(a[0] == '0' || a[0] == 'n' || a[0] == 'N' || a[0] == 'f' || a[0] == 'F');
    }

    logline("=== loaded (pid=%d) apply=%d marker=\"%s\" tip=%s conf=%s ===",
            getpid(), (int)g_apply, g_marker.c_str(),
            g_tipTemplate.empty() ? "(默认)" : g_tipTemplate.c_str(),
            g_confPath[0] ? g_confPath : "(无)");
    logline("阈值: parserVA=0x%lx finalizerVA=0x%lx | off type=0x%zx newmsgid=0x%zx "
            "replacemsg=0x%zx session=0x%zx content=0x%zx",
            (unsigned long)g_hookParserVA, (unsigned long)g_hookFinalizerVA,
            g_offType, g_offNewMsgId, g_offReplaceMsg, g_offSession, g_offContent);
    // wechat.dylib 是后加载的（dlopen），必须靠回调等它出现
    _dyld_register_func_for_add_image(install_hook_for_image);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        install_hook_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
}
