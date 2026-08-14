# onboard-code-projects

[English](./README.md) | [简体中文](./README.zh-CN.md)

[![Windows tests](https://github.com/libaie/onboard-code-projects/actions/workflows/windows-tests.yml/badge.svg)](https://github.com/libaie/onboard-code-projects/actions/workflows/windows-tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![状态：预览版](https://img.shields.io/badge/status-preview-orange.svg)](#环境要求与只读诊断)

开源仓库：[libaie/onboard-code-projects](https://github.com/libaie/onboard-code-projects)

`onboard-code-projects` 是减少 Codex Desktop 多仓库上下文污染的工作流隔离 Skill：为每个仓库建立独立、经过核验且可复用的项目任务和 `codebase-memory` 索引，并通过可选中控协调跨项目工作、沉淀并复用有证据支撑的成功与确定性失败经验。

- **适用于：** 工作横跨两个及以上仓库。
- **你会得到：** 绑定到精确根目录、经过核验的项目入口任务，每个仓库对应一个 `codebase-memory` 索引，以及负责跨项目协作的可选中控。
- **它不会：** 创建或保存 Codex 项目，也不会代替用户授权或批准权限。
- **它不是：** 安全沙箱，也不会部署软件。

> **状态：预览版。** 当前支持的发布面是 Windows 和 Codex Desktop，其他平台尚未完成发布级端到端验证。

## 它解决什么痛点

| 痛点 | Skill 的处理方式 |
| --- | --- |
| 上下文污染 | 每个精确项目根目录、项目指令、证据和修改都留在独立且可复用的任务中。 |
| 仓库与基线漂移 | 执行前核验已保存项目、根目录、分支、HEAD、工作区和索引。 |
| 任务膨胀 | 普通工作与同范围返工复用同一个项目入口任务。 |
| 完成状态丢失 | 支持前台监控；插件能力满足时，还可使用耐久结果回传。 |
| 中控记忆膨胀 | 对长期跨项目工作使用有界记忆，不把不断增长的任务台账全部加载进会话。 |

适用于一个功能、故障或发布涉及两个以上仓库，并且各仓库有不同项目指令、分支规则、测试命令或写权限边界的场景。普通单仓库工作直接使用该仓库的项目任务即可。

### 选择合适的上下文边界

| 方式 | 上下文与生命周期 | 适合场景 |
| --- | --- | --- |
| 单一长会话 | 多个仓库共享一个持续增长的上下文。 | 仓库规则没有差异的快速、低风险检查。 |
| Subagent | 当前任务内的短期并行工作。 | 不需要复用项目身份的独立子任务。 |
| 本 Skill | 每个仓库使用一个绑定精确根目录、可复用的入口任务；可选中控只保留跨项目信息。 | 横跨多个仓库的功能、故障和发布。 |

项目入口任务内部仍可使用 subagent，两者可以配合使用。

## 你会得到什么

- 每个 source：一个已核验的保存项目绑定、一个可复用的本地入口任务和一个 `codebase-memory` 索引。
- 可选：位于所有业务仓库之外的一个中控目录和中控任务。
- 可选：耐久结果回传需要插件 Stop Hook 与 Node.js；自动唤醒还需要额外的规则、worker 和自动化能力。

Skill 不能创建 Codex 已保存项目。用户需先在 Codex Desktop 中添加每个精确目录，Skill 再核验并使用该身份。

## 核心流程

下面四张图覆盖对用户可见的完整生命周期。精确 payload、哈希、reason code 和恢复命令仍放在[中控运行时参考](./references/controller-runtime.md)中。

### 1. 接入或复用每个仓库

```mermaid
flowchart TD
    O1["本地路径或 Git URL"] --> O2["加载或确认已保存的索引模式，再解析输入并执行只读依赖预检"]
    O2 --> O3{"source 类型？"}
    O3 -->|本地目录| O7{"当前主机上是否存在唯一精确的已保存项目？"}
    O3 -->|Git URL| O4["只克隆到 cloneRoot 的新子目录"]
    O4 --> O5["返回 needs-project-add"]
    O5 --> O6["用户保存精确克隆目录后重跑"]
    O6 --> O7
    O7 -->|不存在或有歧义| O8["阻断并返回明确的下一步"]
    O7 -->|是| O9["读取 AGENTS，核验根目录、分支、HEAD 和脏工作区"]
    O9 --> O10["创建或复用一个项目绑定入口任务"]
    O10 --> O11["按所选模式建立或刷新 codebase-memory 索引"]
    O11 --> O12["核验索引根目录与版本"]
    O12 --> O13["仓库通道就绪，可直接工作"]
    O13 -.->|可选跨项目工作| O14["核验或初始化仓库外中控，并登记该入口"]
    O14 -.->|中控不可用或创建结果未知| O15["保持已就绪仓库；报告待登记状态，或根据权威证据恢复且不重试"]
```

Codex 已保存项目仍由用户管理。Skill 不创建 projectless 任务或 worktree；可选中控必须位于所有业务仓库之外。

### 2. 协调、派发并验收跨项目工作

```mermaid
flowchart TD
    D1["跨项目请求"] --> D2["四象限接收；冻结目标、契约、范围和验收标准"]
    D2 --> D3["按项目进入队列"]
    D3 -->|同一项目只运行一个活动任务并按 FIFO 排队| D4
    D3 -->|独立项目并行执行| D4
    D4["密封派发包，并按难度与风险选择模型等级"] --> D5["只发送给已核验的项目入口任务"]
    D5 -.->|超时或空返回| D15["只停止或挂起当前通道；禁止盲目重发或扩大授权"]
    D5 -->|已送达| D6["重读 AGENTS，核验根目录、基线和范围"]
    D6 --> D7{"需要运行时授权？"}
    D7 -->|是| D8["只等待当前项目，其他通道继续"]
    D7 -->|否| D9["在仓库内实现并测试"]
    D8 -->|已批准| D9
    D8 -.->|已拒绝| D15
    D9 --> D10{"当前可用的回传通道？"}
    D10 -->|Hook 回执，可选自动唤醒| D11["中控重读分支、HEAD、diff、测试和契约；唤醒不等于验收"]
    D10 -->|native-callback| D11
    D10 -->|foreground| D11
    D11 --> D12{"结果与证据应如何处置？"}
    D12 -->|已接受的成功| D13["记录成功、释放租约并启动下一个 FIFO 项"]
    D12 -->|符合条件的业务或评审失败| D14["保留租约并进入下方有界收敛流程"]
    D12 -->|已取消、拒绝授权或不可重试的阻断| D15
```

中控只写治理状态。仓库修改和测试始终留在精确项目入口任务中；callback 或 receipt 只表示已有证据可供读取，不代表任务已通过验收。

### 3. 复用有证据支撑的经验并终止重试循环

```mermaid
flowchart TD
    E1["规范 goal 日志与绑定证据的人工导入"] --> E2["ExperienceRead 核验有界经验索引"]
    E2 --> E3["匹配问题、策略族和关键前提"]
    E3 --> E4{"此前已核验结果？"}
    E4 -->|已接受的成功| E5["复用已证明策略，并重新核验当前 readiness"]
    E4 -->|确定性失败：拒绝相同机制| E6["预留下一个允许的策略"]
    E4 -->|无匹配或已证明关键前提变化| E6
    E5 --> E7["执行、测试并收集本次证据"]
    E6 --> E7
    E7 --> E8{"评审结果？"}
    E8 -->|已接受的成功| E9["把可复用成功写入有界索引并关闭通道"]
    E8 -->|确定性失败| E10["把硬失败写入有界索引"]
    E8 -->|瞬态、环境阻断、被取代、取消或授权结果| E11["只记审计，不拉黑；取消或拒绝授权会终止当前通道"]
    E10 --> E12{"失败发生在哪次业务尝试？"}
    E11 -.->|符合条件的环境变化或策略取代| E12
    E12 -->|初始尝试| E13["执行一次完整修复"]
    E12 -->|修复尝试| E14["执行一次全目标重新基线"]
    E12 -->|重新基线| E15["convergence-failed：停止并等待用户决策"]
    E13 --> E2
    E14 --> E2
```

这是证据复用，不是自动学习。关键前提变化必须有直接规范证据；改任务名、新开会话或修改未经证明的哈希，都不能抹掉已知确定性失败。只有仓库零写入的 transport、tool-bootstrap 或 payload-parse 失败，才允许一次不消耗业务尝试的同 attempt 预检重放。

### 4. 刷新长期运行的中控任务组

```mermaid
flowchart TD
    R1["由集合外 coordinator 显式请求重置"] --> R2{"精确生成的 v3、任务 API、Node.js、单根目录且状态静默？"}
    R2 -->|否| R3["不修改也不删除任务，安全阻断"]
    R2 -->|是| R4["只读 Plan 返回 planHash"]
    R4 --> R5["单独授权的 Apply 使用精确 planHash"]
    R5 --> R6["重读完整历史、静默状态与活动工作；准备运行时 fence"]
    R6 --> R7["仅创建一次 bootstrap 待命任务；项目在前，中控最后"]
    R7 --> R8["读取、脱敏、限长并哈希每个旧任务的完整历史"]
    R8 --> R9["先归档旧项目任务，再归档旧中控，并逐一回读"]
    R9 --> R10{"归档后的历史发生变化？"}
    R10 -->|是| R11["重新读取并重建完整最终交接"]
    R10 -->|否| R12["持久化并发送有界交接；核验待命任务确认"]
    R11 --> R12
    R12 --> R13["原子切换整组任务；提交并回读运行时状态"]
    R13 --> R14["封存、恢复并解冻；继续使用同一个 heartbeat"]
    R14 --> R15["新任务继承规范状态；旧任务保持归档；coordinator 最后归档"]
```

Apply 是前向恢复流程。中断时保持冻结并继续同一 operation；不会回滚、删除任务、修改规范工作记录，也不会重试结果未知的任务创建。

## 快速开始

### 1. 安装

在 Codex 中发送：

```text
使用 $skill-installer 从 https://github.com/libaie/onboard-code-projects 安装，参数为 `--repo libaie/onboard-code-projects --path . --name onboard-code-projects`。报告安装后的 SKILL.md 路径，不要修改任何项目仓库。
```

如果 Codex 没有发现 Skill，请重启 Codex Desktop。使用时显式调用 `$onboard-code-projects`。

### 2. 分别保存项目根目录

把每个仓库的精确绝对根目录分别添加为 Codex 项目。不要把包含多个仓库的父目录保存为一个项目。

### 3. 接入本地项目

```text
使用 $onboard-code-projects。

sources:
- source: C:\work\service-a
- source: C:\work\web-app
indexMode: full

为每个精确的已保存项目创建或复用一个常驻本地入口任务，然后建立 full codebase-memory 索引。不要创建 worktree 或 projectless 任务。
```

首次使用时确认默认索引模式：`fast`、`moderate` 或 `full`。推荐 `full`；保存后的默认值仍可在单次调用中覆盖。

### 4. 只有跨项目工作才增加中控

在所有业务仓库之外创建一个空目录，并把它保存为 Codex 项目。然后运行：

```text
使用 $onboard-code-projects。

sources:
- source: C:\work\service-a
- source: C:\work\web-app

controllerRoot: C:\work\multi-project-control
controllerName: Multi-Project Control Center
initializeController: true
createControllerTask: true
dispatchReturnMode: foreground

初始化中控，并登记这些项目入口任务。
```

没有插件 Stop Hook 时，`native-callback` 可用则优先使用；否则使用 `foreground`。只有从可信来源安装插件后，才选择 `receipts` 或 `receipts-and-wake`。

初始化后，直接用自然语言把跨项目问题交给中控：

```text
全链路排查 H5 推广海报登录流程，涉及 H5、商城后端和会员服务。先只读排查，冻结共享接口契约，再把各仓库检查下发到已有项目入口，最后回传端到端证据。
```

### 刷新长期运行的中控任务

当中控及其项目入口任务需要使用新会话时，精确生成的 v3 支持可替换当前绑定的整组任务，并继承已核验的历史记录。请从被替换集合之外的独立 coordinator 任务触发；该任务最后归档。如果仍有工作未静默、无法完整读取任务历史，或中控属于自定义、旧版、已有状态存储的 v2，而不是精确生成的 v3，操作会安全阻断。

```text
resetControllerTasks: true
Action: Plan
# 检查返回的 planHash，再使用相同请求发送：
Action: Apply
planHash: <返回的 planHash>
```

Plan 不会写入，只授权稳定的替换范围；用户查看 Plan 期间即使任务历史变化，也无需重新批准。Apply 只接受返回的精确哈希，先创建仅含唯一创建标记、不含业务交接的待命任务，再完整核验并冻结旧历史，发送最终有界脱敏交接后才激活新任务组。系统不删除任务；如执行中断，只继续同一操作。高级行为与恢复方式见[中控运行时参考](./references/controller-runtime.md)。

重置还要求 Codex 任务 API 可用，且每个替换目标都是根目录唯一的精确已保存项目；根目录有歧义或无法回读任务 cwd 时会安全阻断。

## Git URL 接入

Git source 使用封闭的逐项目对象：

```text
使用 $onboard-code-projects。

sources:
- source: https://github.com/example/service-a.git
  cloneRoot: C:\work\repos
  ref: main
  fullLfsCheckout: false
indexMode: full
```

Skill 只克隆到 `cloneRoot` 的新子目录，随后返回 `needs-project-add`。把精确克隆目录保存为 Codex 项目，再使用相同请求重跑。只有根目录、不含凭据的 origin 以及请求的 branch 或 ref 均通过核验时，才会复用既有克隆。

## 能力边界

这是**工作流隔离（workflow isolation）**，不是安全沙箱。它不会改变文件系统权限；人为在一个任务中混合多个仓库时，上下文污染仍会回来。

## 输入

| 字段 | 是否必需 | 含义 |
| --- | --- | --- |
| `sources` | 是 | 一个或多个本地绝对目录，或不含凭据的 Git URL 对象。 |
| `sources[].source` | 是 | 本地绝对目录或 HTTPS/SSH Git URL。 |
| `sources[].cloneRoot` | 仅 Git | 新克隆子目录的既有绝对父目录。 |
| `sources[].branch` / `sources[].ref` | 否 | 每个 source 最多指定一种 Git 身份。 |
| `sources[].fullLfsCheckout` | 否 | 是否获取完整 LFS 内容，默认 `false`。 |
| `indexMode` | 否 | 本次使用 `fast`、`moderate` 或 `full`。 |
| `controllerRoot` | 仅中控 | 位于所有业务仓库之外的目录。 |
| `controllerName` | 否 | 默认 `Multi-Project Control Center`。 |
| `initializeController` | 否 | 授权初始化中控脚手架。 |
| `createControllerTask` | 否 | 授权创建中控任务。 |
| `resetControllerTasks` | 否 | 显式请求先安全 Plan，再替换当前中控任务组。 |
| `dispatchReturnMode` | 否 | `foreground`、`native-callback`、`receipts` 或 `receipts-and-wake`。 |

高级升级和恢复输入见[中控运行时参考](./references/controller-runtime.md)。

## 环境要求与只读诊断

| 组件 | 使用场景 |
| --- | --- |
| Codex Desktop | 保存项目和项目绑定任务。 |
| Windows PowerShell 5.1 | 当前支持的执行环境。 |
| [`codebase-memory`](https://github.com/DeusData/codebase-memory-mcp) | 所有项目接入都必需：仓库索引和代码图谱查询。 |
| Git | Git URL 和 Git 元数据。 |
| OpenSSH | 仅 SSH Git URL。 |
| Git LFS | 仅 `fullLfsCheckout: true`。 |
| Node.js 18+ | 中控任务组重置、耐久 Stop 回执和自动唤醒。 |

以下 read-only 预检不会创建项目、任务、索引、中控文件或 Git 状态：

```powershell
# Local 本地目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1
# HTTPS Git URL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -RequireGit
# SSH Git URL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -RequireGit -RequireSsh
# 仅完整 LFS 检出时，在适用 Git 命令后追加 -RequireLfs。
# 中控任务组重置或耐久事件回传
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1 -RequireNode
```

仅安装 Skill 时可使用项目隔离、索引、可选中控和前台监控。中控任务组重置需要 Node.js 18+。耐久回执需要插件 Stop Hook 与 Node.js；自动唤醒还需要 Skill 验证对应运行时能力。

## 权限与本地数据

在明确请求时，Skill 可以保存索引偏好、克隆到新子目录、创建项目绑定任务、刷新索引或初始化可选中控。仅请求项目接入时，它不会创建 Codex 已保存项目，也不会切换分支、提交、推送、部署、写数据库或运行项目构建。

操作系统或工具运行时批准属于实际发起调用的精确项目任务，中控不能代替批准；其他独立项目可以继续。

新任务推荐使用以下原生默认值：

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"
approvals_reviewer = "auto_review"
```

未经明确授权，Skill 不会改写全局配置。已有任务可能保留任务级权限模式覆盖项，应在该任务中一次选择所需模式，而不是重新创建入口。自动评审不会扩大沙箱，也不会取消高风险操作和 Computer Use 确认。

可选插件只在派发匹配时，把相关路径和任务标识保存在本机；它不保存完整回复，随附运行时也不会发起网络请求。卸载 Skill 或插件不会删除既有本地中控状态。信任边界与漏洞报告方式见[安全策略](./SECURITY.md)。

## 常见问题

- `needs-project-add`：在 Codex Desktop 保存报告的精确项目根，然后重跑相同请求。
- `needs-controller-project-add`：把精确中控目录保存为 Codex 项目。
- `controller-thread-unknown`：不要再次创建中控任务；检查已有任务后，按返回的 `nextAction` 恢复。
- `index-unavailable`：恢复 `codebase-memory`，并核对精确根、分支和 HEAD。
- 运行时批准：在对应项目任务中允许或拒绝，中控不能替代该决定。
- `safeToRerun=false`：不要自动重试，使用返回的恢复动作。

## 已知限制

- Codex 已保存项目仍需用户操作。
- Windows 是唯一由确定性自动化测试覆盖的平台。
- 真实 Codex Desktop 任务行为和 MCP 集成仍需通过发布检查清单中的门禁。
- 工作流隔离不能强制操作系统权限，也不能阻止人为混合上下文。
- 耐久自动结果回传依赖插件 Hook 和额外的已验证运行时能力。
- 不含交互式 dashboard 或部署自动化。

## 文档

- [中控运行时参考](./references/controller-runtime.md)：高级行为与恢复契约。
- [安全策略](./SECURITY.md)：信任边界、本地数据与漏洞报告。
- [贡献指南](./CONTRIBUTING.md)：开发与验证命令。
- [发布检查清单](./docs/release-checklist.md)：维护者发布与回滚门禁。
- [MIT 许可证](./LICENSE)
