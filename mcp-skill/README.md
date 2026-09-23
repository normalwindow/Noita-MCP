# Noita MCP Skill

`SKILL.md` 是给 Noita MCP 服务器用的智能体 Skill。它教 AI 正确驱动 `noita_*` 工具：先调用什么、
自己处在哪一层因而可以承诺什么、哪些动作已在真实游戏中验证过、哪些根本做不到。

Skill 提供的是知识，不是能力。它描述的每个工具都来自 MCP 服务器；Skill 自己不增加任何代码，也不
增加任何权限。

英文文档：[README.en.md](README.en.md)。主文档：[../README.md](../README.md)。

## 它解决什么问题

没有它，智能体倾向于猜。有两类失败尤其常见，Skill 都直接针对：

- 以为自己能伪造输入。在基础版里做不到，因此 Skill 要求智能体在承诺任何操作之前先查
  `noita_capabilities`。
- 声称做过没验证过的动作，例如实际只是直接写了速度，却说成"玩家按了 W"。Skill 明确写出这个区别
  以及背后的实测证据。

## 安装

把文件复制进你的智能体加载 skill 的目录。对 dsh 项目来说就是 `<项目>\.dsh\skills\`，一个 skill
一个子目录：

```text
mcp-skill\SKILL.md   ->   <项目>\.dsh\skills\noita-mcp\SKILL.md
```

```powershell
New-Item -ItemType Directory -Force "$project\.dsh\skills\noita-mcp" | Out-Null
Copy-Item .\mcp-skill\SKILL.md "$project\.dsh\skills\noita-mcp\SKILL.md"
```

然后开一个新的智能体会话，或重新加载 skill 目录，让 Skill 被发现。没有 skill 加载器的运行时，可以
把同一个文件当作系统提示或项目说明的一部分交给它；内容就是一份带少量 YAML 头的普通 Markdown。

`base\install.ps1` 在检测到安装器时会调用它；这一步是可选的，上面的复制方式任何时候都有效。

## 内容目录

| 章节 | 内容 |
| --- | --- |
| 每次会话这样开始 | `noita_bridge_status`、`noita_capabilities`、`noita_get_panel`、`noita_get_state`，以及桥接不活时停下来问人 |
| 两种模式 | 基础版与完整版的区别、为什么输入工具在基础版会被拒绝、`unlocked_by_extension` |
| 硬性规则 | 不声称未验证的动作；读到拒绝就去读原因，不要绕开；`ok: false` 是正常回答而不是工具坏了；破坏性操作先确认意图；用法术和材质 id 之前先解析 |
| 直接移动 | 把 `noita_lever_*` 当重型机械：先读状态，用完解除，并提醒人类 |
| 玩家的装备 | 读取和更换手持物、拾取、丢弃、发射 |
| 伪造输入 | 扩展提供的工具，以及什么时候该释放 |
| 管理扩展 | 载入、武装、解除武装、查状态 |
| 生成 | 生成任何东西之前先查它是否存在 |
| 世界、地图与目录 | 群系和地图读取；游戏自带的法术、材质、实体列表 |
| 标准流程 | 观察周围、读装备、给物品、改写法杖、模拟法杖、移动／治疗／加状态 |
| 做不到的事 | 经过验证的"不可能"清单，四条同一个根因，外加引擎对自己的控制状态暴露了什么 |
| 面板与权限 | 各个开关，以及优先请人类去改 |
| 故障排查 | 现象到操作的对照表，包括 MCP 服务器自带的命令行接口 |
| 回答风格 | 如实报告游戏返回了什么；纠正预期，而不是换一个动作来搪塞 |

## 说明

- Skill 和服务器请保持同一版本。工具名和拒绝信息都跟版本绑定；旧 Skill 配新服务器会描述已经不存在
  的工具。
- 安装 Skill 不会带来任何权限。如果人类把模组的面板开关关掉了，装了 Skill 的调用一样会被拒绝。
- Skill 是写给智能体的，不是写给人看的。安装和限制请看 [../base/README.md](../base/README.md) 与
  [../full/README.md](../full/README.md)。

## 许可

本仓库代码采用 [Apache License 2.0](../LICENSE) 授权。完整文本见仓库根目录的 [LICENSE](../LICENSE)，第三方声明见 [NOTICE](../NOTICE)。

这是一个非商业的粉丝作品。Noita 及其全部内容归 Nolla Games Oy 所有，本项目与 Nolla Games 无隶属关系。Apache 2.0 只覆盖本仓库的代码，不授予 Noita 本身的任何权利，也不改变 Noita 模组协议的条款。
