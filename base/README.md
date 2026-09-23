# Noita MCP——基础版（纯 Lua）

基础版就是模组加 MCP 服务器，**不含 DLL，没有任何外部依赖**。它让 AI 读取正在运行的 Noita 并修改状态：玩家、背包、法杖、法术牌库、物品、世界/地图数据，一共 **55 个 MCP 工具**。

它不能伪造输入。这不是一个可以打开的开关：Noita 的 C++ 无法用 Lua 修改，所以基础版做不到按键。需要这一能力请安装可选扩展，见 [../full/README.md](../full/README.md)。

英文文档：[README.en.md](README.en.md)。主文档：[../README.md](../README.md)。

## 要求

| 要求 | 说明 |
| --- | --- |
| Windows | 游戏和桥接都只在 Windows 上工作 |
| Noita | 必须**处于一局游戏中**；主菜单里桥接不应答 |
| Node.js 18 或更高 | 运行 `mcp_server/server.js`；没有 npm 安装步骤 |
| MCP 客户端 | 任何能启动 stdio 服务器的客户端 |

## 安装

1. 把模组复制进游戏的 mods 目录。`<Noita>` 是包含 `noita.exe` 的目录，例如 `D:\Sware\Steam\steamapps\common\Noita`：

   ```text
   base\mod\noita_agent   ->   <Noita>\mods\noita_agent
   ```

2. 启动 Noita，打开 **Mods**，启用 **Noita AI Agent Bridge**。这里会出现游戏的"不安全的模组"警告，见下文「故障排查」。

3. 把服务器加进 MCP 客户端配置。请使用绝对路径，并对 JSON 里的反斜杠转义：

   ```json
   {"type":"stdio","command":"node","args":["<绝对路径>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita"}}
   ```

4. 自检：

   ```powershell
   .\tools\verify.ps1 -NoitaDir "D:\Sware\Steam\steamapps\common\Noita"
   ```

`base\install.ps1` 是辅助脚本，会完成复制并在 `mod_config.xml` 里启用模组；上面的手动步骤是权威路径。

## MCP 客户端配置与环境变量

所有配置都通过环境变量传入，写在 MCP 客户端的 `env` 块里，或写在启动服务器的 shell 里。

| 变量 | 用途 |
| --- | --- |
| `NOITA_DIR` | 包含 `noita.exe` 的目录。实际上是必需的：服务器靠它推导模组的 `run\` 目录。 |
| `NOITA_REF_DATA` | 解包后的游戏数据目录，供实体蓝图读取使用。 |
| `NOITA_DB` | 覆盖事实数据库文件（默认为 `mcp_server/noita_db.json`）。 |
| `NOITA_ENTITY_INDEX` | 覆盖 `noita_find_entity` 使用的实体索引文件。 |

四个变量一起写进配置：

```json
{"type":"stdio","command":"node","args":["<绝对路径>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita","NOITA_REF_DATA":"D:\\Sware\\Steam\\steamapps\\common\\Noita\\data","NOITA_DB":"<绝对路径>/base/mcp_server/noita_db.json","NOITA_ENTITY_INDEX":"<绝对路径>/base/mcp_server/entity_index.json"}}
```

## 传输方式

模组在 `127.0.0.1` 上开一个 socket，并把选中的端口写进 `<Noita>\mods\noita_agent\run\port.json`。服务器**优先用 socket**；一旦 socket 出问题，会自动**回退到文件桥接**（同一目录下的 `state.json`、`request.json`、`response.json`）。所以防火墙拦截或 `os` API 被禁只会让桥接降级，不会让它彻底失效。`noita_transport` 报告当前实际使用的通道。

## 游戏内面板

按 `\` 键（Noita 默认的调试/控制台键区附近）或直接点击游戏里左上角的 **`[ + ] noita_agent`** 可以展开面板。**折叠时它待在左上角**，只是一个小标签；**展开后居中显示**，因为此时它是一块正在阅读的对话框，而屏幕四角是游戏画自己 HUD 的地方。

面板有四个页签（用鼠标点击切换）：

| 页签 | 内容 |
| --- | --- |
| **Status** | 当前传输通道与端口、请求数、看门狗状态、帧号、玩家是否已找到、RPC 耗时、设置存储后端、延迟调节，以及**传输切换按钮** |
| **Permissions** | 总开关（`ai_enabled`）、只读模式、四个操作类别开关（spawn / player / wands / world）、verbose 日志，以及一行"**实际生效**"的汇总文字 |
| **Extension** | 输入扩展 DLL 的状态：是否已加载、是否已武装 hooks；**如果失败，列出尝试过的每一个路径以及每个路径的失败原因**，并提供加载/武装/解除按钮 |
| **Log** | 最近的日志消息，按严重级别（dbg / inf / WRN / ERR）着色，带级别筛选（all / info+ / warn+ / errors），并显示"共 N 条中的最新 M 条" |

### 面板里的传输切换

**Status 页有两个按钮**：

- 左边那个在 SOCKET 与 FILE bridge 之间**立即切换**当前通道。
- 右边那个设置**新会话默认启动**哪一个（显示为 `startup: SOCKET` 或 `startup: FILE`）。

文件桥接始终在运行，所以切换通道不会让客户端失联——最坏情况只是某个请求多等一帧。也可以用 `noita_set_panel` 从 MCP 侧设置。

### 关于开关的持久化

`ai_enabled`、`read_only` 和面板是否展开**每局重置为默认值**。这是有意的：一个"现在暂停"的安全开关如果被持久化，上一局结束时暂停的会话会在下一局开始时仍然暂停，而操作者可能因此被锁在**唯一能把它打开的那个面板**外面。操作类别开关（spawn / player / wands / world）**是**持久的，因为它们表达的是策略而不是某一刻的状态。

## 工具分组

基础版 55 个工具，按用途分组：

| 分组 | 数量 | 工具 |
| --- | --- | --- |
| 玩家状态（含修改） | 14 | `noita_get_state`、`noita_get_player`、`noita_get_nearby`、`noita_raycast`、`noita_list_perks`、`noita_set_player`、`noita_heal`、`noita_add_gold`、`noita_apply_effect`、`noita_lever_state`、`noita_lever_experiment`、`noita_lever_engage`、`noita_lever_disengage`、`noita_lever_status` |
| 背包与物品 | 9 | `noita_get_inventory`、`noita_inventory`、`noita_switch_item`、`noita_pickup`、`noita_drop_item`、`noita_drop_all`、`noita_launch_projectile`、`noita_get_potion`、`noita_set_potion` |
| 法杖与法术 | 8 | `noita_get_wands`、`noita_list_spells`、`noita_refresh_spells`、`noita_edit_wand`、`noita_set_wand_deck`、`noita_add_spell_to_wand`、`noita_remove_spell_from_wand`、`noita_simulate_wand` |
| 生成 | 4 | `noita_spawn_wand`、`noita_spawn_spell`、`noita_spawn_potion`、`noita_spawn_item` |
| 世界与地图 | 3 | `noita_world`、`noita_biome_at`、`noita_list_materials` |
| 实体与数据库 | 5 | `noita_find_entity`、`noita_entity_info`、`noita_entity_blueprint`、`noita_db_query`、`noita_inspect_component` |
| 权限面板 | 2 | `noita_get_panel`、`noita_set_panel` |
| 诊断 | 10 | `noita_bridge_status`、`noita_capabilities`、`noita_transport`、`noita_latency`、`noita_socket`、`noita_probe_api`、`noita_probe_controls`、`noita_probe_ffi`、`noita_batch`、`noita_raw_rpc` |

九个 `noita_input_*` 工具属于完整版。在基础版模式下它们会拒绝执行，并说明输入扩展缺失以及如何加载——它们不是偷偷按键的后门。

「玩家状态（含修改）」里的五个 `noita_lever_*` 是直接写物理量的杠杆，单独说明见下一节。

## 基础版不能做什么

| 想做的事 | 为什么不行 |
| --- | --- |
| 按键或点击鼠标（移动、跳跃、开火、交互） | Noita 的 C++ 无法用 Lua 修改，基础版没有任何办法把合成输入送进引擎。 |
| 用开火键发射手持法杖 | 同上，基础版做不到按键。`noita_launch_projectile` 是往世界里放一个投射物，不是扣扳机。 |
| 摇杆输入 | 即使装上完整版的输入扩展，也只合成键盘和鼠标按键，不支持摇杆。 |

**能做的替代**：`noita_lever_*` 直接写玩家的速度等物理量，属于物理层面的杠杆，不是按键。请先读 `noita_lever_state`，把它当重型机械对待，用完务必调用 `noita_lever_disengage`。

## 权限面板

模组带一个游戏内面板，包含：

- 总开关 `ai_enabled`——关闭时任何写入都到不了游戏。
- `read_only`——允许观察，拒绝一切修改。
- 按类别的操作开关 `operations.*`：`spawn`、`player`、`wands`、`world`。

被拒绝的调用返回 `ok: false`，并带有 `blocked_by_panel: true`，同时指出该打开哪个开关。读取始终可用。`ai_enabled` 和 `read_only` 在每一局开始时恢复默认值；按操作的开关会保留。

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| Mods 菜单里看不到模组 | 模组必须位于 `<Noita>\mods\noita_agent` 且包含 `mod.xml`。检查是否误复制成了嵌套的 `noita_agent\noita_agent`。 |
| 出现"不安全的模组"警告 | 预期且无法避免。模组需要 `os` 和 `io` 来开 socket、读写文件，因此声明了 `request_no_api_restrictions="1"`。接受后才能继续。 |
| 游戏在跑但 `bridge_live: false` | 桥接只在局内活着。开始或继续一局游戏。 |
| `mod_present: false` | `NOITA_DIR` 未设置或指错了。它必须指向包含 `noita.exe` 的目录。 |
| 局内调用仍然超时 | 游戏窗口失焦导致暂停。Noita 默认在 alt-tab 时暂停，关掉 `application_pause_when_unfocused`。 |
| `state_age_ms` 持续增长 | 同上：游戏没有在更新，模组自然不会应答。 |
| 事实数据库缺失，或实体蓝图报告缺数据 | 用 `tools/build_db.py`、`tools/build_index.py` 从自己的解包数据重建，或用 `NOITA_DB`、`NOITA_ENTITY_INDEX` 指向已有文件。 |
| socket 不可用但桥接仍工作 | 正在用文件回退通道；`noita_transport` 显示当前通道。 |
| 某个调用返回 `ok: false` 而不是 MCP 错误 | 正常：`ok: false` 是桥接给出的结构化回答，不是工具坏了。读 `error`，以及可能存在的 `blocked_by_panel`。 |

## 卸载

1. 删除 `<Noita>\mods\noita_agent`。
2. 从 MCP 客户端配置里删掉服务器条目。

游戏自身的文件从不被修改。`base\install.ps1 -Uninstall` 可以代劳删除目录并在 `mod_config.xml` 里禁用模组。
