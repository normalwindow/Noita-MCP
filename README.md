# Noita MCP

Noita MCP 由一个 MCP（Model Context Protocol）服务器和一个 Noita 模组组成，让 AI 能够观察和操控
**正在运行**的《Noita》。

英文文档：[README.en.md](README.en.md)

调用链是：AI 通过 stdio 与 Node.js 写的 MCP 服务器通信，服务器再与游戏内的模组通信，模组在 Lua 里
执行请求并把结果返回。所有通信都在本机完成，桥接只监听 `127.0.0.1`。

## 这是什么

两个部分，总是一起安装：

- **模组** `noita_agent`（游戏内名称 Noita AI Agent Bridge）——运行在 Noita 进程里，是唯一能碰到
  游戏的东西，对外暴露一组本地 RPC：玩家、背包、法杖、法术牌库、实体、世界/地图数据，以及权限开关。
- **MCP 服务器** `base/mcp_server/server.js`——stdio MCP 服务器，把 `noita_*` 工具调用翻译成桥接
  RPC，再以结构化 JSON 返回。它另外带一个给人用的命令行接口（`--status`、`--list`、`--call`）。

游戏只在局内更新，所以桥接也只在局内应答。**主菜单里什么都不能用。**

## 两层架构

| | 基础版（base） | 完整版（full） |
| --- | --- | --- |
| 内容 | 纯 Lua，不含 DLL | 基础版 + 输入扩展 DLL |
| MCP 工具 | 64 个（55 个可直接使用，9 个 `noita_input_*` 需要输入扩展） | 64 个全部可用 |
| 外部依赖 | 无 | 构建出的 DLL（32 位） |
| 观察游戏 | 可以 | 可以 |
| 修改玩家、物品、法杖、世界 | 可以 | 可以 |
| 伪造输入（移动、跳跃、开火） | **不可以**——Lua 做不到 | 可以 |
| 需要的构建工具链 | 无 | 32 位 MSVC（只用于构建 DLL） |

**基础版**用模组自身的 LuaJIT FFI 在 `127.0.0.1` 上开一个 socket，socket 不可用时回退到基于文件的
桥接。除 Node.js 和游戏本体外不需要任何东西。**完整版**在此之上增加 `xinput_hook.dll`：一个 32 位
Windows DLL，由模组通过同一套 FFI 载入游戏进程（不需要外部注入器），它合成 SDL 键盘与鼠标事件，
因此 AI 可以移动、跳跃、开火。

## 如何选择

- 只想让 AI **观察和修改状态**（背包、法杖、物品、玩家属性、地图）→ 用**基础版**。
- 想让 AI **真正操作玩家**（走路、开火）→ 用**完整版**。
- 基础版完全无法伪造输入：Noita 的 C++ 无法用 Lua 修改，这正是输入扩展 DLL 存在的原因。
- 基础版仍可直接写玩家的速度（`noita_lever_*`），那是物理量上的杠杆，不是按键。详见
  [base/README.md](base/README.md)。

## 系统要求

| 要求 | 说明 |
| --- | --- |
| Windows | 游戏和桥接都只在 Windows 上工作 |
| Noita（Steam） | 当前版本即可；模组目录必须可写 |
| Node.js 18 或更高 | 运行 MCP 服务器；不需要安装任何 npm 包 |
| MCP 客户端 | 任何能启动 stdio 服务器的客户端 |
| 32 位 MSVC 工具链 | **仅完整版**构建 DLL 时需要，`build.ps1` 自己会调用 `vcvars32` |
| 解包后的游戏数据 | **可选**，只影响 `noita_entity_blueprint`、`noita_db_query` 和索引重建 |

## 安装：基础版

1. 把模组复制进游戏的 mods 目录：

   ```text
   base\mod\noita_agent   ->   <Noita>\mods\noita_agent
   ```

   `<Noita>` 是包含 `noita.exe` 的目录，例如 `D:\Sware\Steam\steamapps\common\Noita`。

2. 启动 Noita，打开 **Mods**，启用 **Noita AI Agent Bridge**。

3. 配置 MCP 客户端。请使用绝对路径，并对 JSON 里的反斜杠转义：

   ```json
   {"type":"stdio","command":"node","args":["<绝对路径>/base/mcp_server/server.js"],"env":{"NOITA_DIR":"D:\\Sware\\Steam\\steamapps\\common\\Noita"}}
   ```

   `NOITA_DIR` 必须指向包含 `noita.exe` 的目录。设置后服务器会自己找到模组的 `run\` 目录和回退
   传输通道。

4. 开始或继续一局游戏，然后检查桥接：

   ```powershell
   node "<绝对路径>\base\mcp_server\server.js" --status
   ```

   `bridge_live: true` 表示游戏正在应答。

`base\install.ps1` 是辅助脚本，会完成复制并在 `mod_config.xml` 里启用模组。上面的手动步骤是权威
路径，任何时候都有效。

## 安装：完整版

先完成上面基础版的全部步骤，然后构建并武装扩展。

1. 构建 DLL（脚本自己调用 `vcvars32`，在普通 shell 里运行即可）：

   ```powershell
   cd <仓库>\full\extension
   .\build.ps1
   ```

   产物：`full\extension\build\xinput_hook.dll`。脚本会读回产物的 PE 头并断言它是 32 位。

2. 把它放到模组能找到的位置：

   ```text
   full\extension\build\xinput_hook.dll   ->   <Noita>\mods\noita_agent\extensions\
   ```

3. 在局内依次调用两个 MCP 工具：

   ```text
   noita_input_load      # 把 DLL 映射进游戏进程；此时是惰性的，不 hook 任何东西
   noita_input_install   # 武装：安装 SDL 钩子
   ```

   **载入是惰性的**：仅把 DLL 放进目录不会改变游戏行为，只有 `noita_input_install` 之后才可能伪造
   输入，`noita_input_uninstall` 可以再撤销。

4. 确认模式：

   ```text
   noita_capabilities  ->  mode: "full (input extension loaded)"
   ```

细节、安全设计与实测数据见 [full/README.md](full/README.md)。

## 已实测能力

下面所有内容都在真实游戏中测量过，不是从接口表面推断的。

### 观察与修改

- **观察**：玩家状态（坐标、速度、生命、法力、Perk、状态效果、群系）、背包、法杖、法术牌库、
  附近实体、材质、法术表、Perk 表、事实数据库。
- **修改**：玩家坐标/生命/属性、加金币、生成物品/药水/法术/法杖、编辑法杖牌库与属性、切换手持物、
  拾取、丢弃、发射投射物、施加状态效果。

### 输入伪造（仅完整版）

| 动作 | 做法 | 实测结果 |
| --- | --- | --- |
| 向右移动 | 按住 `D` | `vx = +56.84` |
| 向左移动 | 按住 `A` | `vx = -56.81` |
| 开火 | 按住**鼠标左键** | 引擎自己的 `mButtonFrameFire` 计数器随之前进 |
| 飞行 | `SPACE` | 同一路径送达按键事件 |
| 交互 | `E` | 同一路径送达按键事件 |

左右两个结果相对零基线对称。开火之所以用**鼠标左键**，是因为 Noita 就是靠左键开火；`SPACE` 是飞行
键，不是开火键。`mButtonFrameFire` 会前进这一点，把"事件排进了队列"和"游戏真的响应了"区分开。

### 世界与地图

- 群系名、群系文件路径、群系内深度。
- 平行世界坐标、宝珠数量、NG+ 等级。
- 相机矩形，以及 9x9 的战争迷雾采样。

### 事实数据库（`noita_db_query`）

从游戏数据抽取的**事实**，可用 `sort` 取极值（例如按 `hp` 或 `deck_capacity` 排序）：

| 类别 | 数量 | 内容 |
| --- | --- | --- |
| 敌人 | 610 | 生命、攻击间隔与投射物、克制材质、碰撞体积 |
| 法杖模板 | 87 | 容量、射速、装填、法力 |
| Perk | 153 | —— |
| 材质 | 224 | 密度、危险性、状态效果 |
| 群系 | 150 | —— |
| 宝箱 | 5 | —— |

### 法术剩余用量

牌库每张牌的 `uses_remaining` 可读。实测：FIREBALL 15/15、BLACK_HOLE 3/3、DYNAMITE 16/16、
ROCKET 10/10、LIGHT_BULLET 无限。游戏数据里 `-1` 表示无限。

## 游戏数据与授权

Noita 的 `data/` 目录**不包含**散装的实体 XML——它们打包在 `data.wak`（40.5 MB）里。Noita 模组协议
明确规定模组"不得分发我们受版权保护的代码、内容、资产的实质部分"（must not distribute a
substantial part of our copyrightable code, content, assets）。

因此本仓库**不打包游戏数据**，而是提供 `tools/build_db.py`，由用户用**自己**的解包数据生成事实
数据库。数据库只保存**标识符、数值、枚举和关系**（相当于 wiki 会罗列的信息），不复制游戏源码。

`tools/unpack-data.ps1` 给出获取解包数据的指引，并说明当前版本（2025 年 1 月）的
`noita.exe -wizard_unpak` 开关不再写出解包树（只会打开一个文件管理器窗口）。这个脚本只报告和
指引，不会自动替你启动游戏。

## 已知限制

| 限制 | 说明 |
| --- | --- |
| "不安全的模组"警告 | 模组需要 `request_no_api_restrictions="1"` 才能使用 `os` 和 `io` 做 socket 和文件，因此 Noita 会显示沙箱警告。这是该方案的固有代价，无法去除。 |
| 基础版不能伪造输入 | Noita 的 C++ 无法用 Lua 修改，基础版写进去的控制字段会被引擎每帧覆盖。输入扩展 DLL 正是为此存在。 |
| 只有键盘和鼠标按键 | 输入扩展只合成键盘和鼠标按键事件，不支持摇杆。 |
| DLL 未签名 | 杀毒软件可能误报 `xinput_hook.dll`。源码随包提供（`xinput_hook.c`），请读源码而不是信任二进制。 |
| 桥接只在局内存在 | 主菜单、菜单界面或暂停时桥接不应答。请先开始或继续一局游戏。 |
| 游戏更新可能影响输入扩展 | 扩展依赖 SDL 导入 thunk 的布局；游戏更新后若输入失效，请用 `noita_input_status` 的计数器重新验证。 |

## 验证

项目有四套测试：

| 测试 | 结果 |
| --- | --- |
| Lua 语法 | 18/18 文件通过编译 |
| 模拟游戏 | 41/42 项 |
| MCP 端到端 | 15/15 项 |
| 对运行中游戏的实机冒烟测试 | 23/23 项 |

模拟游戏套件有一项已知失败，这里如实列出，而不是把它排除在外。

## 仓库结构

```text
Noita-MCP/
  README.md            主文档（中文，带链接到 README.en.md）
  README.en.md         英文主文档
  base/                纯 Lua 版本
    README.md  README.en.md
    install.ps1
    mod/noita_agent/...        模组，复制到 <Noita>/mods/
    mcp_server/server.js       MCP stdio 服务器
    mcp_server/noita_db.json   事实数据库
    mcp_server/entity_index.json
  full/                基础版 + 输入扩展
    README.md  README.en.md
    install.ps1
    extension/xinput_hook.c, injector.c, build.ps1, build/xinput_hook.dll
    mod/...  mcp_server/...
  mcp-skill/           智能体 Skill（SKILL.md）+ README
  tools/               unpack-data.ps1, verify.ps1, build_db.py, build_index.py, search_entities.js, noita_db.json, entity_index.json
```

`full/extension/injector.c` 能构建一个独立的 32 位注入器，但正常安装不需要它：模组自己通过 FFI
载入 DLL。

## 文档

- [base/README.md](base/README.md)——基础版：安装、工具分组、不能做什么、故障排查、卸载
- [full/README.md](full/README.md)——完整版：构建与武装 DLL、实测输入结果、安全设计、卸载
- [mcp-skill/README.md](mcp-skill/README.md)——智能体 Skill 是什么、如何安装、包含哪些内容
- [README.en.md](README.en.md)——英文主文档
