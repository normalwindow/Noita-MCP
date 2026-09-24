# Noita MCP —— 完整版（基础版 + 输入扩展）

完整版是[基础版](../base/README.md)的全部内容，外加 `xinput_hook.dll`：一个 32 位 Windows DLL，
由模组自己载入游戏进程，负责合成 SDL 键盘与鼠标事件。有了它，AI 可以移动、跳跃、按交互键、用法杖
开火；没有它，这些一概做不到，原因见基础版文档。

英文文档：[README.en.md](README.en.md)。主文档：[../README.md](../README.md)。

## 系统要求

基础版的全部要求，外加：

| 要求 | 说明 |
| --- | --- |
| 32 位 MSVC 工具链 | DLL 必须与 32 位的游戏进程匹配。`build.ps1` 自己会调用 `vcvars32`。 |
| Windows PowerShell 5.1 或 PowerShell 7+ | 两者都支持；构建脚本避开了只有 PS7 才有的语法。 |

**从下载包安装不需要任何工具链**——DLL 是编译好的，可以直接复制到另一台机器使用。

## DLL 已经编译好了，直接用

**下载的压缩包里就是编译好的 DLL，不需要任何工具链，不需要构建。**

```
extension\xinput_hook.dll      ← 已编译，install.ps1 会自动装到游戏目录
```

`install.ps1` 会把它复制到 `<Noita>\mods\noita_agent\extensions\`，并**只是放着，不加载**：
模组只在被要求时才载入 DLL，而且载入后也是惰性的，直到调用 `noita_input_install` 才生效。
所以装完不会改变游戏的任何行为。

### 想自己编译（可选）

仓库里有源码 `full/extension/xinput_hook.c` 和 `build.ps1`。**只有开发者需要**，所以它们
**不在下载包里**——下载包里只有成品。

```powershell
cd <仓库>\full\extension
.\build.ps1
```

脚本会读回产物的 PE COFF 头并断言 `Machine == 0x014C`（32 位），所以架构错误的构建会直接报错，
而不是产出一个游戏载入不了的 DLL。

| 开关 | 作用 |
| --- | --- |
| `-Clean` | 先删除构建产物 |
| `-DllOnly` | 只构建 DLL，跳过独立注入器 |
| `-DebugBuild` | 用 `/Od /Zi` 代替 `/O2`（开关名不是 `-Debug`，那个名字已被占用） |

源码默认还会构建 `injector.c`。它是一个独立的 32 位注入器，**正常安装不使用**：模组通过自己的
LuaJIT FFI 载入 DLL，不需要外部注入器。它同样不在下载包里。

## 载入并武装

1. 把 DLL 放到模组能找到的位置：

   ```text
   full\extension\build\xinput_hook.dll   ->   <Noita>\mods\noita_agent\extensions\
   ```

   `<Noita>` 是包含 `noita.exe` 的目录。

2. 基础版安装保持不变：模组已启用、MCP 服务器已配置、游戏**处于局内**。

3. 依次调用两个 MCP 工具，顺序不能反：

   ```text
   noita_input_load      # 把 DLL 映射进游戏进程。惰性。
   noita_input_install   # 安装钩子，从此可以伪造输入
   ```

   **载入是惰性的。** `DllMain` 只解析指针，在调用 `noita_input_install` 之前不会 hook 任何东西。
   仅仅把 DLL 放在目录里，不可能改变游戏行为。已经载入时再调用 `noita_input_load` 是安全的。

4. 验证：

   ```text
   noita_capabilities   ->  mode: "full (input extension loaded)"
   noita_input_status   ->  载入/武装状态、事件计数器、当前按住的键
   ```

状态不对时，读扩展写在 DLL 旁边的标记文件：`xh_status.txt`、`xh_loaded.txt`、
`xh_watchdog_fired.txt`。它们的存在就是为了不靠猜。调用计数器可以把"装上了"和"真的用上了"
区分开（`xh_event_calls`、`xh_peep_calls`、`xh_push_ok`、`xh_push_fail`、`xh_event_real_seen`）。

## 它新增的 9 个工具

| 工具 | 用途 |
| --- | --- |
| `noita_input_move`、`noita_input_key` | 按住某个移动方向；按一个键（跳跃 `SPACE`、交互 `E`、快捷栏数字） |
| `noita_input_fire`、`noita_input_click` | 用法杖开火；在指定坐标点击，引擎据此推导瞄准方向 |
| `noita_input_release` | 释放当前所有按住 |
| `noita_input_status` | 扩展状态、事件计数器、当前按住的键 |
| `noita_input_load`、`noita_input_install`、`noita_input_uninstall` | 载入 DLL（惰性）、武装钩子、解除钩子 |

## 实测输入结果

在真实游戏中端到端测量：

| 动作 | 做法 | 实测结果 |
| --- | --- | --- |
| 向右移动 | 按住 `D` | `vx = +56.84` |
| 向左移动 | 按住 `A` | `vx = -56.81` |
| 开火 | 按住**鼠标左键** | 引擎自己的 `mButtonFrameFire` 计数器随之前进 |
| 飞行 | `SPACE` | 同一路径送达按键事件 |
| 交互 | `E` | 同一路径送达按键事件 |

两个移动结果相对零基线对称。开火用**鼠标左键**，因为 Noita 就是靠左键开火；`SPACE` 是飞行键，按它
不会开火。确认引擎自己的 `mButtonFrameFire` 会前进，是把"事件排进了队列"和"游戏真的响应了"区分
开的关键。

## 它是怎么工作的

扩展不拦截输入，而是从桥接的每帧更新里把事件**合成**进 SDL 自己的队列，让引擎通过正常路径收到一个
正常事件：

```text
桥接帧更新  ->  xh_push_key / xh_push_mouse  ->  SDL_PushEvent  ->  SDL 队列
                                                                        |
引擎下一次轮询  <----------------  一个来自正常路径的正常事件  ---------+
```

SDL2 导出的输入函数是 7 字节的导入 thunk（`mov eax, [imm32]; jmp eax`），不是真实实现，所以扩展
解析出 thunk 内部的真实目标并对它挂钩。`SDL_PushEvent` 从不在钩子内部调用：轮询钩子运行时 SDL 正
持有事件队列锁，在里面 push 会重入该锁；push 发生在帧更新里，完全在 SDL 之外。

## 安全设计

| 性质 | 说明 |
| --- | --- |
| 惰性载入 | `DllMain` 只解析指针。在 `noita_input_install` 之前不会 hook 任何东西。 |
| 全有或全无的安装 | 任何一个钩子分析或安装失败，所有钩子都会回滚。装一半比完全不装更糟。 |
| 心跳看门狗 | 如果 Lua 不再每帧调用 `xh_heartbeat`，后台线程会移除钩子。帧循环卡死时几秒内自行恢复，而不是把输入一直劫持下去。 |
| 按住的时限 | 每个键和鼠标按住都会在自己的帧数到期后自动结束；`noita_input_release` 可以提前结束。 |
| 从不 hook `SDL_PumpEvents` | 常规安装路径刻意排除它：它每帧运行、可能跑在多线程上、还可能重入 SDL 的输入路径，在那里放 trampoline 有无限递归（表现为整机卡死）的风险。 |
| 不写磁盘 | 除了 DLL 旁边的小状态标记文件，不写任何东西。删掉 DLL 或重启游戏，一切消失。 |
| 不碰游戏文件 | 不修改任何游戏二进制。钩子只存在于被载入的进程里。 |

## 卸载

1. 调用 `noita_input_uninstall` 移除钩子并解除武装。游戏继续运行。
2. 删除 `<Noita>\mods\noita_agent\extensions\` 下的 `xinput_hook.dll`。
3. 重启游戏以获得干净状态。

只重启游戏也足够：DLL 从不会被写进游戏文件，所以没有任何东西能跨越进程存活。要移除整个桥接，按
[基础版文档](../base/README.md)的卸载步骤操作。

## 已知限制

- 只合成键盘和鼠标按键事件，不支持摇杆。
- 瞄准通过在鼠标事件里选定点击坐标实现，引擎据此推导瞄准向量。开火这条路已经实测过，但没有针对
  特定目标做过命中验证。
- DLL 未签名，杀毒软件可能误报。它由本目录的 `xinput_hook.c` 在本地构建；请读源码，而不是信任
  二进制。
- 游戏更新可能改变 thunk 布局。目标解析是基于特征的（跟随 `mov eax, [imm32]; jmp eax` 形式），
  理论上能存活，但输入失效时请用计数器重新验证。
- 输入只对局内生效。桥接和扩展在主菜单里都不做任何事。

## 许可

本仓库代码采用 [Apache License 2.0](../LICENSE) 授权。完整文本见仓库根目录的 [LICENSE](../LICENSE)，第三方声明见 [NOTICE](../NOTICE)。

这是一个非商业的粉丝作品。Noita 及其全部内容归 Nolla Games Oy 所有，本项目与 Nolla Games 无隶属关系。Apache 2.0 只覆盖本仓库的代码，不授予 Noita 本身的任何权利，也不改变 Noita 模组协议的条款。
