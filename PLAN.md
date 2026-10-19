# 项目计划书 — copybook：MoonBit 的 COBOL copybook 编解码器

> 仓库：<https://github.com/NekoYume517/copybook>
> 赛事：MoonBit Hackathon 2026
> 状态：已交付（`moon check` 0 错误 · 250 测试全绿 · CI 全绿 · wasm 构建通过）

---

## 1. 背景与动机

主机（mainframe）系统至今承载着银行核心账务、保险保单、航空订座与政府批处理。这些系统的数据交换格式是 **COBOL copybook**：用 `PIC` 子句描述定长记录的字节布局，用 EBCDIC 编码、zoned decimal / COMP-3 存数。只要主机还在，这些数据就要被导出、转换、喂进现代系统。

MoonBit 生态里没有任何处理这个格式的工具（以 mooncakes 注册表检索为证，关键词 `copybook / ebcdic / comp-3 / cobol` 零命中）。现实中的替代方案要么是商业 ETL（IBM InfoSphere、Syncsort，昂贵且不开放），要么是每个工程师手写的 `struct.unpack` 脚本——后者在四个地方**反复出错**：

1. zoned decimal 的末字节符号覆盖（`F1 F2 D3` 是 -123）
2. COMP-3 的半字节对齐与填充（`ceil((n+1)/2)` 字节，偶数位补 0）
3. `OCCURS` 展开（布局层算对总长、数据面漏掉第 2..n 份）
4. `REDEFINES` 联合体（同一段字节的两种读法，不能累加长度）

## 2. 目标

**做**：一份 copybook → 一套字节布局 → 双向编解码（EBCDIC 记录 ↔ JSONL/表格），带字节级布局报告与逐字节往返自检。

**不做**（范围控制，防止做成半成品 ETL）：

- 不做完整 COBOL 语言（只覆盖数据描述项：PIC / USAGE / OCCURS / REDEFINES / SIGN / VALUE / 88 / 66）
- 不做多记录型态文件（多个 `01` 按并列拼接处理，README 已声明）
- 不做字符集转换（EBCDIC ↔ Unicode 单向映射 cp037，足够 US/Canada 数据）

## 3. 技术方案

五层单向依赖，每层可独立测试：

```
lexer → parser → layout → decode/encode → output
                                  ↘ verify（往返自检）
```

三个决定成败的设计决策：

**布局层是唯一的摊平权威。** `OCCURS`（组级与叶子级）在 `compile_field` 构造期展开成带下标的独立叶子（`PATH(1)..PATH(n)`）。第一版在 decode 运行时展开叶子级，导致 decode 写 `R.A(1)` 而 render 查 `R.A`、输出 `{"R.A":null}`——两套展开机制两套键空间。修复后数据面四条路径（decode/render/jsonl/encode）只见过摊平后条目，一致性靠构造保证而不是靠约定。

**数值永远携带 (coefficient, scale)。** JSON 没有定点类型，`5.00` 序列化成 `5`，读回来 scale=0。如果编码器直接采用，scale=2 的字段会把 500 分写成 5 分——静默 100 倍损坏。所有数值输入（Decimal/Int/Text）统一过 `align_scale` 对齐到 PIC 声明的 scale；放不下就报错，绝不截断。

**错误带绝对偏移。** `InvalidNumeric(offset, ...)` 指到记录内的字节位置，不是"第几条记录第几个字段"。二进制数据没有行号，偏移是唯一能定位的坐标。

## 4. 实施里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| M1 词法与语法 | 固定列 + 自由格式 tokenizer，PIC 语义解析 | cp037 全 256 项往返；三份真实 copybook 解析通过 |
| M2 布局计算 | 偏移/长度/摊平，REDEFINES 单游标 | 布局字节数与 Python 独立实现一致（54/98/29） |
| M3 编解码 | zoned / packed / COMP / COMP-1/2 / 编辑型 | 500 条随机记录字节级往返；JSONL 路径往返 |
| M4 CLI 与自检 | layout/decode/encode/verify，退出码 0/1/2 | README 每条命令实测；示例数据可审计 |

里程碑之间发生的真实返工（都值得记录）：M2 的 REDEFINES 父组求和算出 35（应 29）；M3 的 JSON scale 对齐缺失造成 100 倍损坏；M4 发现 `verify` 的内存往返掩盖了文本往返的缺陷——由此衍生出 `json_roundtrip_test.mbt` 专项。

## 5. 质量保障

- **250 个测试**，其中对抗性审查贡献 18 个回归测试（`review_test.mbt` + `audit_test.mbt`），每条对应一个真实复现路径
- **独立实现交叉验证**：`scripts/gen_copybook_data.py` 用 Python 独立实现 cp037 / zoned / COMP-3，与 MoonBit 零共享代码——两边一致是证据，不是同义反复
- **两轮审查**：第一轮子代理对抗审计修复 13 个缺陷；第二轮外部复验确认 18 条修复、抓到 1 个回归并已修复
- **CI**：Linux runner 上 check / fmt / test --release / build wasm 四道门，依赖解析前显式 `moon update`

## 6. 差异化

- **MoonBit 原生**：wasm 目标可跑在浏览器/边缘侧，传统主机工具链做不到
- **往返是硬承诺**：`verify` 逐字节比对，README 声称的能力矩阵每项都有测试背书
- **审查驱动**：开发过程本身包含两轮对抗性审查的完整记录（Issues、commits、修复纪律），可审计

## 7. 后续路线

1. `OCCURS DEPENDING ON` 动态展开（当前按上界固定展开，字段已预留 `occurs_depending_on`）
2. RDW/BDW 记录头（变长记录流）
3. 更多码表（cp273、cp500）与 ASCII 模式
4. 布局差异比较工具（两个 copybook 版本间的字段级 diff）

## 8. 提交信息

- 仓库：<https://github.com/NekoYume517/copybook>
- 许可：Apache-2.0
- 演示：`docs/DEMO.md` 十步走完全部成果，每条命令与预期输出均实测
- 技术细节：`docs/implementation.md`（8 个算术陷阱）与 `docs/ebcdic-notes.md`（cp037 三坑）
