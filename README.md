# codexSwitch

一个面向 macOS 上 Codex Desktop 的多账号切换脚本。

它解决的问题很直接：当你同时维护多个 Codex / ChatGPT 账号时，官方客户端没有提供快捷切换入口，而手动替换 `~/.codex/auth.json` 既繁琐，也容易覆盖当前账号。`codexSwitch` 把这件事做成了一次可重复、可恢复、尽量安全的操作流程。

## 项目定位

`codexSwitch` 不是一个“管理所有 OpenAI 账号”的平台，也不是浏览器插件。

它是一个本地脚本工具，专注解决下面这件事：

- 在多个已登录过的 Codex Desktop 账号之间快速切换
- 自动退出并重新启动 Codex 应用
- 自动为当前账号创建可回退副本，避免 `auth.json` 被覆盖后无法恢复
- 尽量从本地会话记录中恢复各账号的额度使用状态，方便判断该切到哪个账号

如果你平时会在个人账号、团队账号、实验账号之间来回切，这个工具的价值会非常直接。

## 核心特性

- 自动扫描 `~/.codex` 下的 `auth.json` 和 `auth*.json`
- 解析认证信息，展示账号邮箱与套餐类型
- 读取本地会话记录，尽量显示最近的额度剩余情况
- 展示 5 小时窗口 / 7 天窗口重置时间
- 切换前自动退出 Codex，切换后自动重新启动
- 当前账号如果还没有备份，会自动生成一个命名合理的副本
- 为历史账号缓存最近一次额度状态，减少“切走之后就看不到剩余额度”的问题
- 支持通过环境变量自定义 Codex 安装路径、认证目录和缓存路径

## 为什么这个项目值得开源

这个项目最有价值的地方，不是“复制一个文件”，而是把一套容易出错的手工流程收敛成了一个稳定的切换动作：

1. 识别当前账号和候选账号
2. 展示足够的信息让你做选择
3. 安全退出运行中的 Codex
4. 缓存当前账号的额度信息
5. 确保当前账号有可恢复副本
6. 用目标账号覆盖 `auth.json`
7. 重新启动 Codex

这让它非常适合作为一个开源小工具项目：场景明确、依赖少、可立即使用、问题也足够具体。

## 适用场景

- 你有多个 Codex / ChatGPT 账号，需要频繁切换
- 你希望在切换前知道哪个账号剩余额度更多
- 你不想每次都手动备份 `auth.json`
- 你希望切换后自动重新打开 Codex Desktop

## 工作原理

脚本默认以 `~/.codex` 为工作目录，并把其中的文件理解为：

- `auth.json`: 当前正在被 Codex Desktop 使用的认证文件
- `auth_*.json` 或其他 `auth*.json`: 你保存下来的其他账号副本
- `account_usage_cache.json`: 脚本生成的本地缓存，用于保存账号的最近额度状态
- `~/.codex/sessions/**/*.jsonl`: Codex 会话日志，脚本会从中尝试提取额度使用信息

切换时，脚本会：

1. 枚举当前账号和可切换账号
2. 从认证信息中提取邮箱、套餐类型等信息
3. 从本地 session 日志和缓存中推断最近额度状态
4. 优雅退出 Codex；必要时会尝试结束主进程
5. 为当前账号生成备份副本
6. 用目标账号覆盖 `auth.json`
7. 记录激活时间并重启 Codex

## 环境要求

- macOS
- 已安装 Codex Desktop
- 默认应用路径为 `/Applications/Codex.app`
- 建议系统已安装 `python3`

没有 `python3` 也能运行脚本，但账号信息展示和额度解析会退化成更基础的模式。

## 安装

```bash
git clone <your-repo-url>
cd codexSwitch
chmod +x switch_codex_auth.sh
```

如果你希望全局调用，可以自行建立软链接：

```bash
ln -s "$(pwd)/switch_codex_auth.sh" /usr/local/bin/codex-switch
```

## 使用前准备

你至少需要准备两个账号文件。

第一次登录某个账号后，可以把当前 `auth.json` 复制成一个带名字的备份文件，例如：

```bash
cp ~/.codex/auth.json ~/.codex/auth_personal.json
cp ~/.codex/auth.json ~/.codex/auth_team.json
cp ~/.codex/auth.json ~/.codex/auth_lab.json
```

之后切换到其他账号重复一次这个动作，就能逐步积累自己的账号池。

如果你忘了提前备份当前账号，脚本在切换时也会尝试自动为当前 `auth.json` 生成副本。

## 使用方式

最常见的用法：

```bash
./switch_codex_auth.sh
```

或者指定自定义 Codex 配置目录：

```bash
./switch_codex_auth.sh /path/to/.codex
```

运行后你会看到一个交互式列表，类似：

```text
Codex 认证目录: /Users/you/.codex
可切换账号列表:
  No  Now  Email              Plan   Left                    5h Reset          7d Reset
  --  ---  -----              ----   -----                   --------          --------
  1   *    personal@xxx.com   pro    5小时 82% | 7天 64%     2026-04-19 22:30 2026-04-23 08:00
  2        team@xxx.com       pro    5小时 15% | 7天 12%     2026-04-19 20:10 2026-04-21 08:00
  3        lab@xxx.com        plus   unknown                 -                 -
```

然后输入：

- `1`, `2`, `3` 等数字切换账号
- `r` 刷新列表
- `q` 退出

## 可选环境变量

你可以通过环境变量覆盖默认行为：

```bash
CODEX_DIR="$HOME/.codex" \
CODEX_APP_NAME="Codex" \
CODEX_APP_PATH="/Applications/Codex.app" \
CACHE_FILE="$HOME/.codex/account_usage_cache.json" \
./switch_codex_auth.sh
```

主要变量说明：

- `CODEX_DIR`: Codex 配置目录，默认 `~/.codex`
- `CODEX_APP_NAME`: 应用名，默认 `Codex`
- `CODEX_APP_PATH`: 应用路径，默认 `/Applications/Codex.app`
- `CODEX_BINARY_PATH`: 应用主二进制路径，通常无需手动设置
- `CACHE_FILE`: 账号额度缓存文件路径
- `SESSIONS_DIR`: 会话日志目录，默认 `~/.codex/sessions`

## 输出信息说明

列表中的字段含义：

- `No`: 账号序号
- `Now`: 当前正在使用的账号，`*` 表示当前账号
- `Email`: 从认证信息里解析出的邮箱
- `Plan`: 套餐类型
- `Left`: 最近一次可推断出的额度剩余情况
- `5h Reset`: 5 小时窗口重置时间
- `7d Reset`: 7 天窗口重置时间

其中 `Left` 和重置时间是基于本地日志与缓存推断的“最近已知状态”，不是官方实时 API 查询结果。

## 安全说明

这个项目会接触到本地认证文件，因此请务必注意：

- `auth.json` 和 `auth*.json` 都包含敏感认证信息，不要提交到 Git 仓库
- 不要把这些文件发给别人，也不要在 issue 里粘贴内容
- 开源发布的应当只有脚本和文档，不应包含任何真实认证文件
- 如果你怀疑认证文件泄露，应立即重新登录并使旧凭据失效

## 已知限制

- 当前仅面向 macOS 设计
- 依赖 Codex Desktop 当前的认证文件格式和 session 日志结构
- 额度显示来自本地历史记录推断，不保证绝对实时
- 目前是交互式脚本，不支持完整的非交互批处理参数
- 如果目标账号本身凭据已经失效，切换后仍可能需要重新登录

## 适合在 GitHub 首页强调的卖点

如果你准备把它公开发布，建议重点突出这几点：

- 这是一个真实解决高频痛点的工具，不是演示性质脚本
- 它把“多账号切换”做成了一个尽量安全、可恢复的流程
- 它不仅能切换账号，还尽量保留每个账号最近的额度状态
- 代码体量小、依赖少、容易审查，适合个人工具型开源项目

一句话版本可以写成：

> A practical macOS utility for switching Codex Desktop accounts safely, with auto-backup, session-based usage hints, and one-step app restart.

## 后续可以继续增强的方向

- 支持命令行参数直接切换到指定账号
- 增加 `--list` / `--current` / `--switch <name>` 等非交互模式
- 增加账号重命名和账号导入功能
- 输出更明确的状态诊断信息
- 提供英文 README 或中英双语 README

## License

如果你准备正式开源，建议补充一个明确许可证，例如 `MIT`。

在补充许可证前，也可以先保留：

```text
License: TBD
```
