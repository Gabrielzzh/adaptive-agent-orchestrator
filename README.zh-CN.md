# Adaptive Agent Orchestrator

[English](README.md) · [v0.7.16 正式版说明](docs/releases/v0.7.16.md) · [版本历史](docs/releases/README.md) · [安装](#安装) · [工作原理](#工作原理) · [当前限制](#当前限制)

![Adaptive Agent Orchestrator v0.7.0 发布图](docs/assets/adaptive-agent-orchestrator-v0.7.0-launch.png)

`adaptive-agent-orchestrator` 是一个适用于研究、开发、写作、分析、创意和
运营任务的 Codex Skill。主 Agent继续承担主线生产，只把可隔离、可验收且
值得并行的工作交给临时 subagent 或长期独立任务，从而减少重复读取、重复
推理和等待时间。

目标是降低完整任务的总 Token 消耗。用户不需要配置 Token budget；Skill
也不会假装能预测一个开放式持续改进任务的最终消耗。节省效果必须由公平的
端到端 benchmark 证明。

## 为什么值得使用？

- **减少上下文复制：** Worker 接收路径、来源 ID、产物指针和必要片段，
  而不是重复复制完整对话。
- **限制上下文选择：** 项目根目录、全部文件等宽泛占位引用会被拒绝；可选
  的选择理由只留在主 Agent 控制面，不进入 Worker prompt。
- **渐进披露：** Skill 正文保持精简；reference 和项目文件只在当前工作流
  真正需要时读取。
- **默认单 Agent：** 小任务、强顺序、高上下文重叠和窄范围修改留在主
  Agent。
- **值得时使用长期任务：** 独立、有边界、可验收，且能使用更小上下文或
  更低成本模型的工作会主动建议创建可见的 Codex 长期任务，而不是静默留在
  昂贵的主上下文中。
- **动态工作所有权：** 主 Agent负责全局主线与最终整合；任务入口和关键
  事件点重新判断哪些工作自己做、临时委派、长期负责、暂缓或停止。
- **0–2 个首波 Worker：** 简单任务不派；一个独立工作面派一个；两个同时
  就绪且上下文完全分离的工作面最多并行两个。
- **独立上下文：** 原生 subagent 默认不继承完整对话，只接收紧凑任务包和
  稳定引用；大量日志、资料和搜索结果留在其独立上下文。
- **直接 Worker 快速路径：** 单个临时只读 Worker 不创建持久计划、日志或
  存储角色，也不创建缩小版状态机。
- **创建过程可见：** 每个 Worker 创建前都说明角色和必要性，创建后报告
  真实身份与状态；选择角色本身不会自动创建 Worker。
- **创建结果核对：** 后台创建调用无论返回成功还是错误，都要用任务列表
  核对真实实体；未知状态不会触发盲目重试，重复实体会被识别并停止扩张。
- **相邻物化恢复：** 如果新任务的 ID 被调用方提前一格写入生命周期，只有
  紧邻的 `materializing -> materialized` 才能沿用同一 ID，并且必须同时
  具备唯一任务列表匹配、启动预留、精确握手，以及“更早历史和其他节点均未
  使用该 ID”的证据；身份字段互相冲突时直接拒绝。
- **结果回收门：** 独立后台 Agent 的最终回答必须被显式读取并生成哈希回执，
  否则必需节点不能通过完成门。
- **长期审核闭环：** 长期研究或 Skill 研发可在多个里程碑复用只读领域角色
  与反方角色；主 Agent仍是唯一 Writer，并必须逐项回应每份审核发现。
- **独立来源不可互替：** 每个审核来源保留自己的报告、证据、处置与复审义务；
  一个来源不能替代另一个，未解决 P0/P1 始终阻断完成。
- **替代席位连续性：** 已采纳的 replacement 只有通过一次性、同来源/角色/
  thread 的追加式推进，才能继续下一个 checkpoint。若当前两位长期审核员
  已无法提供独立结论，只允许把全部开放问题原样转入一个 fresh run，并启用
  两个全新的长期只读、无委派审核席位；旧任务不会被重新使用。
- **跨里程碑审核推进：** 同一个长期审核 run 可通过追加式收据激活下一条已
  声明里程碑，精确绑定来源链并要求主 Agent重新验收；无需改写 plan，也不
  会按文件时间猜测“最新结果”。
- **分阶段问题守恒：** 当前里程碑已完成本阶段职责、但仍保留后续阶段的
  P0/P1 时，可先固定唯一的 scope transition，再按计划进入下一里程碑。
  每条问题必须按来源、严重度与原文继续存在或经同来源复审解决；阶段推进不
  等于主任务最终验收。
- **首里程碑版本复审：** 在推进下一里程碑前，可事先授权一次版本复审，
  让每个必需的只读来源重新审查，并只采用一组精确、完整的新结论；旧证据
  继续保留，但不能事后冒充本轮正式结果。
- **可审计 successor run：** 最后一条预声明里程碑用完后，新 run 可通过
  哈希绑定的 predecessor export 与 successor adoption 精确继承全部未解决
  P1。旧 run 保持不可变，来源/thread 连续性不丢失；同一来源完成处置和复审
  前，新 run 始终不能完成。
- **final 缺失恢复：** 任务显示 completed 却没有 final 时进入
  `result_pending`，绝不当作成功。同一 original durable source 的每个新
  checkpoint/input 都建立独立哈希绑定的恢复 cycle，每个 cycle 最多三次
  同 thread 回收；旧 cycle 不能延长或重置新 cycle。已经 adopted 的来源
  只有在不同 checkpoint/input 存在未使用的 attempt-1 cycle 时才能重新进入
  恢复，普通 `adopted` 仍是终态。若后续里程碑只选定了较新的同来源复审链，
  却没有新增节点生命周期，恢复入口会绑定该里程碑的精确 result、disposition
  与 activation event，而不是误读上一阶段证据。历史恢复收据按各自记录的
  里程碑和 activation epoch 复验；不可变的版本复审选择按当时固定的生命周期
  sequence/hash 读取，不会被后来同来源事件重新解释。替代角色必须经过主控授权，
  并保持来源、
  角色、checkpoint、input 和恢复链连续性。如果 replacement 也丢失 final，
  只能使用自己独立的三次恢复阶段，不能再创建
  replacement-of-replacement。
- **诚实接入旧任务：** 对旧任务只捕获真实存在的角色、checkpoint、input、
  turn 与授权材料；平台从未提供的机器身份字段明确标为 unknown，不补造。
- **旧 run 可审计激活：** 内部一致的旧 run 可通过追加式收据采用当前运行
  策略，无需改写 plan、run metadata、genesis 或既有 journal；已存在的
  replacement 继续绑定原来源与连续性证据。
- **不可信结果边界：** 主 Agent 的控制面政策把 Worker 输出视为不可信数据，
  而不是直接授权；已验证、推断和假设类发现采用不同的复核与采纳规则。
- **回执绑定归档：** durable task 的结果回执消失或被修改后，不能进入归档。
- **派遣前预览：** 可在创建持久 Worker 前查看角色、拓扑、模型、权限、引用
  数量和初始任务包字符量，但不会把字符数冒充 Token 或金额。
- **平台观测校准：** 项目内追加保存去标识化的 reconciliation 区间观测，
  按运行环境分组提供诊断；现有证据不足时明确抑制窗口建议。
- **受保护的活动容量：** 目标最多六个活动 Worker，其中四个可供常驻
  Worker 使用，另外两个保留给临时 subagent；实际数量服从运行时容量。
- **静态模型路由：** Luna 处理边界明确的机械任务，Sol 负责判断、写作、
  实现和审查；Terra 只在用户明确指定时使用，正式任务前不会额外启动模型
  测试 Agent。平台不公开实际模型时，请求模型与实际模型保持分离，实际模型
  明确记为 unverified。
- **确定性模式：** `auto` 在轻量快速路径、独立团队和可恢复工作流之间
  选择，不创建额外调度 Agent。
- **可复用研究证据：** 只有多条下游工作流需要复用同一来源集时，才按需
  启用资料整理角色。
- **行业角色按需加载：** 内置部分行业角色包，只加载被选中的合同；后续
  扩展行业时也不会把全部角色塞入每个 Worker 的上下文。
- **通用产物所有权：** 专业 Worker可拥有边界明确的章节、模块、调查、
  数据集或设计面；缺陷返回原所有者，主 Agent保持全局主线和最终合并。
- **轻量项目知识：** 只有长期或跨工作流复用时才保存决策、已验证事实、
  接口和未解决风险；普通一次性任务不创建知识库。
- **明确角色寿命：** 一次性、项目级和用户拥有角色不会混在一起；用户明确
  要求复用的角色不会被系统自动降级或删除。
- **按风险审阅：** 低风险跳过 Reviewer；中风险抽查关键输出；高风险才使用
  一个独立 Reviewer。
- **差量重试：** 只传原产物指针、失败证据和修复指令，不重放整个任务包；
  只有同一哈希计划中已记录为失败的同一节点才能进入差量模式；确定性失败
  后再次创建 Worker 必须绑定该失败事件并由用户确认。
- **单一总控：** Worker 不能递归创建 Worker。
- **可恢复执行：** 不可变计划、哈希链事件、仅在恢复/复用需要时生成的
  handoff、写入范围检查和可执行完成门。

## 设计参考

v0.4 从 GitHub 一手来源中只吸收狭窄、可验证的机制：

- [Agent Skills specification](https://github.com/agentskills/agentskills)：
  metadata → Skill 正文 → 按需资源的渐进披露；
- [OpenAI Skill Creator](https://github.com/openai/skills/blob/main/skills/.system/skill-creator/SKILL.md)：
  Skill 只保留任务必需指令，脚本无需读入模型上下文即可执行；
- [Supabase Agent Skills guidance](https://github.com/supabase/agent-skills/blob/main/AGENTS.md)：
  每一段文字都必须证明自己的 Token 价值，高级细节放入 references；
- [Superpowers parallel-agent guidance](https://github.com/obra/superpowers/blob/main/skills/dispatching-parallel-agents/SKILL.md)：
  只拆独立问题域，并隔离 Worker 上下文；
- [Acontext](https://github.com/memodb-io/Acontext)：按需读取明确的 Skill
  文件，而不是把不透明记忆注入每次上下文；
- [oh-my-codex](https://github.com/Yeachan-Heo/oh-my-codex)：把 economy
  路由作为产品目标。

我们明确不照搬冗长强制思考仪式、实时 DAG 重写、多 Reviewer ensemble、
完整日志回灌或面向用户的 Token budget。GPT‑5.6 本来就会普通拆分和工具
选择，重复教学只会增加过度思考和上下文成本。

## 包含文件

```text
skills/adaptive-agent-orchestrator/
├── SKILL.md          # 精简运行规则
├── agents/           # Codex 展示元数据
├── references/       # 只在相关路径按需加载的合同
└── scripts/          # 确定性校验、状态和诊断工具
```

## 安装

对 Codex 说：

```text
$skill-installer install https://github.com/Gabrielzzh/adaptive-agent-orchestrator/tree/main/skills/adaptive-agent-orchestrator
```

安装后重启 Codex。手动安装时，把完整
`skills/adaptive-agent-orchestrator` 目录复制到
`$HOME/.codex/skills/adaptive-agent-orchestrator`。确定性脚本需要
PowerShell 7.5 或更高版本。

## 快速开始

```text
只有当这个迁移任务包含真正独立的工作流时，才使用
$adaptive-agent-orchestrator。共享上下文留在主 Agent，Worker 只拿引用，
并且渐进派遣。
```

```text
使用 $adaptive-agent-orchestrator 创建一个需求预测 Reviewer 角色。派遣前
协助我定义身份、非目标、证据规则、提问条件和升级条件。
```

```text
使用 $adaptive-agent-orchestrator 完成这个供应链研究。先展示精简角色图，
说明哪些职责由主 Agent 承担；没有自动组队授权的 Worker 必须先征得我同意。
```

```text
使用 $adaptive-agent-orchestrator 从计划和事件日志恢复中断的工作流，不要
重放失败上下文。
```

## 与官方 Codex subagent 的区别

官方 subagent 是执行原语；本 Skill 是它上面的上下文效率和治理层，不替代
官方功能。

| 能力 | 官方 subagent | Adaptive Agent Orchestrator |
| --- | --- | --- |
| 一次性委派 | 原生、更简单 | 主动让路 |
| 上下文选择 | 依赖总控判断 | 引用优先、排除项、重叠检查 |
| 派遣时机 | Prompt 驱动 | 动态所有权判断，首波0–2个独立Worker |
| 审阅 | 依赖总控判断 | 按风险或抽样，不默认多 Reviewer |
| 重试 | 依赖当前会话 | 差量修复任务包与失败分类 |
| 写入所有权 | 依赖 Prompt/沙箱 | 执行前拒绝重叠 Writer |
| 恢复 | 线程历史与摘要 | 哈希计划、追加日志、不可变 handoff |
| 完成判断 | 主 Agent 汇总 | 节点、产物、证据和人工门检查 |
| Token 节省 | 不自动测量 | 离线端到端 benchmark 门 |

短而明确的委派直接用官方 subagent。协调本身会制造风险或重复上下文时，
再使用本 Skill。

## 工作原理

```text
请求
  ↓
主 Agent取得全局主线和自己的生产工作
  ↓
寻找可用更小上下文独立完成的工作面
  ↓
按需要启动0–2个首波Worker
  ↓
主 Agent继续生产并验证Worker证据与产物
  ↓
只有产生新采纳价值时才启动后续波次
  ↓
按风险审阅 + 主 Agent 直接整合
  ↓
产物、证据和人工决策完成门
```

脚本负责结构和生命周期状态校验。Codex 主 Agent 仍负责选择可用执行工具、
创建 Worker、读取真实线程、整合结果和执行已授权的外部动作。

## 验证情况

v0.7.16 正式版本通过：

- 54 个 PowerShell 脚本语法解析；
- 45 项物化连续性断言，其中包含 13 个非法案例；
- 91 项恢复协议专项断言；
- 149 项 durable milestone、revision 与 successor-run 专项断言；
- 15 项 run policy activation 专项断言；
- 883 项完整自测断言；
- 59 份故意构造的非法负面案例均被正确拦截；
- 8 个 reference JSON 文件严格解析；
- 计划、元数据、日志、handoff、依赖、幂等、所有权、上下文重叠、渐进
  派遣、短任务包、长期任务选择、排队创建、worktree 预检、任务收据、
  长期审核、结果恢复、替代连续性和完成门测试；
- 严格 JSON 解析与真实 Windows Junction/reparse point 实体测试；
- Skill Creator 校验；
- 13 项原始 capture 兼容断言，以及独立 27/27 动态复攻，覆盖当前
  `thread.id`、两种历史身份字段、冲突或空身份、仅大小写不同和期望 ID
  不匹配；
- 同一独立审核角色对 predecessor export、successor adoption、谱系字段、
  来源连续性与一致性重签完成动态复攻，最终 GREEN，P0/P1/P2 均为 0；
  额外攻击集 28/28 通过；
- 使用真实长期审核 run 的临时副本完成采用测试：两个来源的 17/17 条 P1
  全部继承，完成门继续正确保持 `BLOCKED`；
- 两份真实 Codex 原始 capture 无需调用方转换，分别生成 schema 1.3
  result 与 disposition 收据。
- 真实 cancelled successor 依次完成 authorization、export 和 fresh
  adoption：两个来源的 18/18 条 P1 完整继承，已消耗 attempt 保留，P0
  没有回流，完成门继续正确保持 `BLOCKED`。
- 同一长期 original source 在 checkpoint08 建立了与 checkpoint07 隔离的
  recovery cycle，回收同源正式 final 并生成 schema 1.3 result/disposition；
  开放业务 P1 和未完成节点继续让 completion 正确保持 `BLOCKED`。
- 真实首里程碑版本复审在授权后重新启用同一两组只读来源，取得累计复审
  结果并唯一选定 checkpoint10：11 条后续 P1 来源记录全部保留，旧的已解决
  问题没有回流，且没有发现新的 Orchestrator P0/P1；占卜研发已进入下一组。
- 真实 37-event run 通过预授权进入计划内 Group2：11 条 P1 中 4 条经同
  来源复审解决、7 条继续保留；completion 仍因这 7 条问题和缺少主任务最终
  验收保持 `BLOCKED`，P1-03 至 P1-06 没有回流。
- 真实 39-event run 完整保留旧前缀；同一传统部来源随后通过当前 Group2
  result、disposition 与 activation event 的精确绑定进入 checkpoint12
  `result_pending` 和 `running`。原长期任务返回了正式 final；其中尚未完成的
  领域审查继续作为未完成工作，而没有被误写成 Orchestrator 成功。
- 真实 checkpoint13 恢复与旧 recovery cycle、旧首里程碑选择同时存在时，
  当前恢复仍能合法推进；原来源 3/3 耗尽后，只创建一个同角色 replacement，
  并通过独立有界恢复取得正式 final。九项问题全部保持 open，completion 继续
  正确 `BLOCKED`。
- 独立 source-rotation 验收为 GREEN，P0/P1/P2 均为 0；真实长期审核 run
  随后把 7/7 条开放 P1 完整带入两个全新的长期只读审核席位，没有复用旧任务。
- 真实 fresh-review run 通过受限相邻物化路径接回一个已经创建的任务，只再
  创建一位审核员；两份正式复审都在原任务内完成恢复，并生成各自的 result 与
  disposition。completion 继续因 multi-divination 产品 P0、7 条开放 P1 和
  缺少主任务最终验收而 `BLOCKED`，没有发现新的 Orchestrator P0/P1。
- 真实 checkpoint15 revision 对两条误绑的 `validated` 事件追加了一份完整
  来源集合的生命周期证据纠正，再生成 schema 1.2 selection；两个来源仍为
  adopted，旧 35 条事件前缀逐字节不变。completion 继续因 1 个产品 P0、
  6 条开放 P1 和缺少主任务验收而 `BLOCKED`，已解决的 P1 没有回流。
- 真实 checkpoint16 在前一轮已经完整选定、但仍保留开放问题且没有最终主
  验收的情况下，合法授权 revision index 2。两个长期来源都返回 fresh
  result/disposition，唯一 schema 1.1 selection 被追加，旧 37 条事件前缀
  逐字节不变；completion 继续因 1 个开放 P0、5 条开放 P1 来源记录和缺少
  主任务最终验收而 `BLOCKED`，本轮同来源解决的两项问题没有回流。

```powershell
pwsh -NoProfile -File `
  .\skills\adaptive-agent-orchestrator\scripts\Test-Self.ps1
```

## 当前限制

- 这是治理 Skill，不是独立 Agent 托管平台。
- 生命周期证据纠正只适用于所有选定来源都精确满足
  `completed=result`、`validated=result`、`adopted=disposition` 的错误
  形态；它不是通用的日志编辑或生命周期修复机制。
- Skill 不修复平台自身的 `systemError` 或 final 丢失；它保证这些状态不会
  被误报为成功，并使恢复与替代连续性可核验。
- source rotation 只更换审核席位并继承控制义务，不迁移、判断或修复被审核
  产品。
- Skill 不迁移业务产物；policy activation 只允许既有不可变 run 采用新的
  编排合同。
- successor adoption 只继承编排义务和身份，不复制项目文件或业务状态；
  successor plan 必须自行声明后续里程碑。
- abandoned-successor 恢复只适用于首个 durable milestone 与任何复审消息
  或结果生命周期之前；它创建 fresh run，不会在旧 run 中复活 cancelled
  source。
- 自然语言排除项无法删除宿主已经注入的历史；应使用 fresh Worker 和明确
  输入引用。
- 精确重叠检查无法发现“不同名称但语义相同”的材料，主 Agent 仍需拒绝。
- 不同项目之间没有共享机器级校准账本；根任务总上限由主 Agent 执行，
  恢复后必须先核对可见状态再继续创建 Worker。
- 校准账本记录的是快照观测区间，不是精确平台可见延迟。
- 只有执行面提供 telemetry 时，Token 用量才可用于诊断。
- 中位数节省 20% 是发布 benchmark 目标，不是已经证实的生产声明；合成
  测试不能证明真实 Token 节省。
- Windows 符号链接夹具因当前环境不允许创建链接而跳过。
- 当前只在 Windows 10 + PowerShell 7.6.3 动态验证，macOS/Linux 尚未
  动态验证。

## 安全模型

Skill 拒绝递归委派、Writer 范围重叠、不安全路径、伪造运行元数据、日志
篡改、未验证 handoff 哈希，以及没有用户证据的人工门完成。发布、删除、
支付、账号修改和生产操作仍由主 Agent 持有，并需要用户授权。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。优先提交可复现失败案例和紧凑测试。

## License

MIT，见 [LICENSE](LICENSE)。
