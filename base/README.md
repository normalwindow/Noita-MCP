# Noita MCP —— 基础版（纯 Lua）

基础版是模组加 MCP 服务器，**不含 DLL，也没有外部依赖**。它让 AI 读取正在运行的 Noita 并修改其
状态：玩家、背包、法杖、法术牌库、物品、世界与地图数据。

它**不能伪造输入**。这不是一个开关：Noita 的 C++ 无法用 Lua 修改，所以基础版按不出任何键。想要
让 AI 真正操作玩家，请看 [../full/README.md](../full/README.md) 里的可选输入扩展。

英文文档：[README.en.md](README.en.md)。主文档：[../README.md](../README.md)。

## 系统要求

| 要求 | 说明 |
| --- | --- |
| Windows | 游戏和桥接都只在 Windows 上工作 |
| Noita | 必须处于**局内**；主菜单里桥接不应答 |
| Node.js 18 或更高 | 运行 `mcp_server/server.js`；不需要 `npm install` |
| MCP 客户端 | 任何能启动 stdio 服务器的客户端 |

## 安装

1. 把模组复制进游戏的 mods 目录。`<Noita>` 是包含 `noita.exe` 的目录，例如
   `D:\Sware\Steam\steamapps\common\Noita`：

   ```text
   base\mod\noita_agent   ->   <Noita>\mods\noita_agent
   ```

2. 启动 Noita，打开 **Mods**，启用 **Noita AI Agent Bridge**。这里会出现游戏的"不安全的模组"
   警告，原因见下面的故障排查。

3. 把服务器加进 MCP 客户端配置。使用绝对路径，并对 JSON 里的反斜杠转义：

   ```json
   {"type":"stdio","command":"node","args":["<绝对路径>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita"}}
   ```

`base\install.ps1` 是辅助脚本，会完成复制并在 `mod_config.xml` 里启用模组。上面的手动步骤是权威
路径。

## 验证安装

服务器带一个给人用的命令行接口，不用 MCP 客户端也能检查桥接：

```powershell
node "<绝对路径>\base\mcp_server\server.js" --status        # 桥接健康状况
node "<绝对路径>\base\mcp_server\server.js" --list          # 列出工具
node "<绝对路径>\base\mcp_server\server.js" --call noita_bridge_status
```

`--status` 会打印 `mod_present`、`bridge_live`、`state_age_ms` 和最后的桥接日志行。
`bridge_live: true` 表示游戏正处于局内并在应答。

## 配置

配置全部走环境变量，写在 MCP 客户端的 `env` 块里，或写在启动服务器的 shell 里。

| 变量 | 用途 |
| --- | --- |
| `NOITA_DIR` | 包含 `noita.exe` 的目录。实际使用中必需：服务器由它推导模组的 `run\` 目录。 |
| `NOITA_REF_DATA` | 解包后的游戏数据目录，供 `noita_entity_blueprint` 使用。 |
| `NOITA_DB` | 事实数据库文件路径，默认用服务器旁边的 `noita_db.json`。 |
| `NOITA_ENTITY_INDEX` | 覆盖 `noita_find_entity` 使用的实体索引文件。 |
| `NOITA_AGENT_RUN_DIR` | 覆盖桥接的 `run\` 目录，主要给测试用。 |
| `NOITA_PYTHON` | 法杖模拟（`noita_simulate_wand`）使用的 Python 可执行文件。 |
| `NOITA_WAND_SIM` | 法杖模拟器入口路径。 |

## 传输方式

模组在 `127.0.0.1` 上开一个 socket，并把选中的端口写进
`<Noita>\mods\noita_agent\run\port.json`。服务器优先使用它，一旦 socket 出问题会自动回退到基于
文件的桥接（同一目录下的 `state.json`、`request.json`、`response.json`），所以防火墙或 `os` API
被挡住只会让桥接降级，而不是直接失效。`noita_transport` 会报告当前实际使用的通道。

## 工具分组

服务器注册 64 个工具，其中 9 个是 `noita_input_*`，属于完整版的输入扩展。基础版可直接使用的 55 个工具
按用途分组如下：

| 分组 | 工具 |
| --- | --- |
| 桥接与诊断 | `noita_bridge_status`, `noita_capabilities`, `noita_transport`, `noita_latency`, `noita_socket` |
| 观察 | `noita_get_state`, `noita_get_player`, `noita_get_nearby`, `noita_raycast`, `noita_get_inventory`, `noita_get_wands`, `noita_world`, `noita_biome_at`, `noita_list_spells`, `noita_list_materials`, `noita_list_perks`, `noita_refresh_spells` |
| 实体目录 | `noita_find_entity`, `noita_entity_info`, `noita_entity_blueprint` |
| 玩家修改 | `noita_set_player`, `noita_heal`, `noita_add_gold`, `noita_apply_effect` |
| 物品与手持 | `noita_inventory`, `noita_switch_item`, `noita_pickup`, `noita_drop_item`, `noita_drop_all`, `noita_launch_projectile`, `noita_spawn_item` |
| 药水 | `noita_get_potion`, `noita_set_potion`, `noita_spawn_potion` |
| 法杖与法术 | `noita_spawn_wand`, `noita_edit_wand`, `noita_set_wand_deck`, `noita_add_spell_to_wand`, `noita_remove_spell_from_wand`, `noita_spawn_spell`, `noita_simulate_wand` |
| 直接运动杠杆 | `noita_lever_state`, `noita_lever_experiment`, `noita_lever_engage`, `noita_lever_disengage`, `noita_lever_status` |
| 权限面板 | `noita_get_panel`, `noita_set_panel` |
| 探针 | `noita_probe_api`, `noita_probe_controls`, `noita_probe_ffi`, `noita_inspect_component` |
| 批处理与逃生口 | `noita_batch`, `noita_raw_rpc` |

事实数据库由 `noita_db_query` 查询：610 个敌人、87 个法杖模板、153 个 Perk、224 种材质、
150 个群系、5 种宝箱，支持 `sort` 取极值（例如按 `hp` 或 `deck_capacity` 排序）。数据库由
`tools/build_db.py` 从本机解包的游戏数据生成，仓库不打包游戏数据，原因见
[../README.md](../README.md) 的"游戏数据与授权"。

## 基础版不能做什么

| 想要 | 为什么不行 |
| --- | --- |
| 按键或点鼠标 | 引擎每帧用真实输入重写自己的控制字段，写进去的合成值既不会被读取也不会保留。 |
| 靠写 `mButtonDownFire` 开火 | 实测：写入被接受，但按住期间 `mButtonFrameFire` 始终为 0。`noita_launch_projectile` 只是往世界里放一个投射物，那不是法杖开火。 |
| 瞄准法杖 | `mAimingVector` 可写，但在任何代码读到它之前就被重算。根因同上。 |
| 读地形或截图 | Lua 没有格点或像素读取接口。请改用 `noita_raycast` 和 `noita_get_nearby`。 |
| 使用物品（喝药水、读法术） | 没有能触发"使用"的引擎函数。可以生成一个新的，或直接改它的内容物。 |
| 引擎自己的投掷 | `mThrowItem` 只是一个请求，投掷仍然需要按键。`noita_drop_item` 会用真实的物理释放物品。 |

**移动方面确实有效的做法**：`noita_lever_*` 直接写玩家的物理量（速度、重力、质量、移动门控）。
实测：一次 `vx = 250` 的 30 帧测试把玩家位移了 126.3 px，与写入值吻合。这是对物理的杠杆，不是
按键。请先读 `noita_lever_state`，把它当重型机械对待，并且每次都以 `noita_lever_disengage` 收尾。

## 权限面板

模组有一个游戏内面板，包含总开关 `ai_enabled`、`read_only` 开关，以及按类别的开关（生成、玩家、
法杖、世界操作）。被拒绝的调用返回 `ok: false` 和 `blocked_by_panel: true`，并指出要打开哪个开关。
读取永远可用。`ai_enabled` 和 `read_only` 每局开始时恢复默认值，按操作的开关会保留。

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| Mods 菜单里看不到模组 | 模组目录必须正好是 `<Noita>\mods\noita_agent` 且包含 `mod.xml`。检查是否因为复制方式不对而出现 `noita_agent\noita_agent` 的嵌套。 |
| 提示"不安全的模组"／沙箱警告 | 预期之内，无法去除。模组设置了 `request_no_api_restrictions="1"`，因为它需要 `os` 和 `io` 做 socket 和文件。接受后才能继续。 |
| 游戏在运行但 `bridge_live: false` | 桥接只活在**局内**。请开始或继续一局游戏。 |
| `bridge_live: false` 且 `mod_present: false` | `NOITA_DIR` 写错了或没设置，它必须指向包含 `noita.exe` 的目录。 |
| 局内调用超时 | 窗口失焦导致游戏暂停。Noita 默认在切出窗口时暂停；关闭 `application_pause_when_unfocused`，或运行 `install.ps1 -PauseOnUnfocus` 切换该设置。 |
| `state_age_ms` 持续增大 | 与上一条同因：游戏没有更新，模组自然不会应答。 |
| `noita_db_query` 报数据库缺失 | `noita_db.json` 没有放在服务器目录旁边。用 `tools/build_db.py` 从本机解包的数据重新生成，或用 `NOITA_DB` 指向已有文件。 |
| `noita_entity_blueprint` 报缺少数据 | 游戏的实体 XML 打包在 `data\data.wak` 里。请按 `tools/unpack-data.ps1` 的指引解包并设置 `NOITA_REF_DATA`。 |
| 调用返回 `ok: false` 而不是 MCP 错误 | 这是正常的：`ok: false` 是桥接给出的结构化回答，不代表工具坏了。读 `error`，以及可能存在的 `blocked_by_panel`。 |
| socket 不可用但桥接仍工作 | 正在使用文件回退通道。`noita_transport` 会显示实际通道。 |

## 卸载

1. 删除 `<Noita>\mods\noita_agent`。
2. 从 MCP 客户端配置里移除服务器条目。

游戏自身的文件从未被修改。`base\install.ps1 -Uninstall` 会完成目录删除并在 `mod_config.xml` 里
停用模组。
