# 报名表补充说明（提交用）

> 用途：填写「修改报名表格并提交最新信息」时的补充材料栏。
> 对应提交：`52e6edb`（https://github.com/NekoYume517/copybook/commit/52e6edb）

---

## 一、目标标准与兼容范围

**首要目标平台：IBM 大型机（z/OS）落地的定长记录。**

这决定了项目里每一个默认值：

| 维度 | 本项目采用 | 依据 |
|---|---|---|
| 字符编码 | EBCDIC cp037（US/Canada） | 主机记录的实际编码，ASCII 不是候选 |
| 记录形态 | 定长，无 RDW/BDW，记录间无填充 | 主机批量文件标准形态 |
| 数值表示 | zoned decimal / COMP-3 打包十进制 / COMP 二进制补码 | COBOL 主机端标准数值格式 |
| 浮点表示 | IBM HFP 十六进制浮点（base-16 指数） | z/OS 的 COMP-1 / COMP-2 原生格式 |
| 语言子集 | COBOL-85 数据描述子集 + IBM Enterprise COBOL 常用扩展 | 见下 |

**语言标准**：数据描述层面遵循 ISO/IEC 1989（COBOL-85）的 `PIC` / `USAGE` /
`OCCURS` / `REDEFINES` / `SIGN` 子句语义；扩展采纳 IBM Enterprise COBOL 的
`COMP-1` / `COMP-2` / `COMP-4` / `FLOAT-SHORT` / `FLOAT-LONG` 写法。

**明确不涉及**：过程部（`PROCEDURE DIVISION`）语义、`MOVE` 的隐式转换规则、
运行时算术。本项目只做**数据布局与字节编解码**，不做 COBOL 解释器。

**兼容范围速查**（已写入 README）：

| 数据来源 | 能否用 | 需要的选项 |
|---|---|---|
| IBM z/OS 批量导出（EBCDIC + COMP-3 + HFP） | ✅ 完整支持 | 默认 |
| 同上但含 IEEE 浮点字段 | ⚠️ 浮点需声明 | `--float-mode ieee` |
| GnuCOBOL / Micro Focus 生成的数据 | ⚠️ 浮点需声明 | `--float-mode ieee` |
| ASCII 编码的 COBOL 文件 | ❌ 不支持 | 只解 EBCDIC |
| 变长记录（RDW/BDW 头） | ❌ 不支持 | 需先剥离头部 |
| 多个 `01` 层级混排的记录型态 | ⚠️ 有简化 | 详见 README「已声明的简化」 |

---

## 二、浮点处理与 IBM 主机表示：已改为原生 HFP

### 原问题（审阅意见指出的冲突，确实成立）

此前 `API.md` 写的是「COMP-1 / COMP-2：IEEE 754 浮点」。这与 IBM 主机的实际
表示冲突——z/OS 的 `COMP-1` / `COMP-2` 是 **HFP（十六进制浮点，base-16 指数）**，
与 IEEE 754 的字节布局完全互不兼容。

### 现在的做法：Host-native first，IEEE 作为显式可选项

新增 `src/hfp.mbt` 实现原生 HFP：

```
COMP-1（短）：1 位符号 | 7 位指数 | 24 位尾数  = 4 字节
COMP-2（长）：1 位符号 | 7 位指数 | 56 位尾数  = 8 字节

值 = (-1)^sign × (F / 2^frac_bits) × 16^(exp7 - 64)
```

指数是 **base-16 的 excess-64**（不是 IEEE 的 base-2 excess-1023）；尾数规格化
时最高十六进制位非零。HFP 与 IEEE 的差异不是"精度不同"，而是**格式不同**：

| 属性 | IBM HFP | IEEE 754 |
|---|---|---|
| 指数基数 | **16** | 2 |
| 指数偏置 | 64（7 位） | 127 / 1023（8 / 11 位） |
| COMP-1 尾数 | 24 位（6 个十六进制数字） | 24 位（隐含前导 1） |
| COMP-2 尾数 | 56 位（14 个十六进制数字） | 53 位（隐含前导 1） |
| NaN / ±Infinity | **没有** | 有 |
| 渐进下溢 | **没有** | 有非规格化数 |
| ±0 | 尾数为 0，符号位保留 | 有专门编码 |

**因此浮点表示必须显式声明，不提供"猜"的模式**：新增 `FloatMode`
（`Hfp` / `Ieee754`）挂在 `RecordLayout` 上——浮点表示是**数据源属性**，
不是字段属性。CLI 提供 `--float-mode hfp|ieee`，**默认 `hfp`，有回归测试
锁定，不允许悄悄改回 IEEE**。

实现细节：解码用逐次乘除 2 的精确缩放（不用 `pow`，避免极端指数上 1 ulp 误差）；
编码对 COMP-2 **无舍入**（56 位尾数 > double 的 53 位，是精确左移），COMP-1 按
最近偶数舍入；NaN / ±Infinity / 上溢 / 下溢一律**显式报错**，不写主机读不懂的字节。

---

## 三、数值正确性与字节保真：输入输出案例

### 案例 1：同一数值 1.5，HFP 与 IEEE 的字节完全不同

```
数值 1.5
  IBM HFP（COMP-1）   → 41 18 00 00      F=0x180000, exp7=65(0x41)
                         1.5 = (0x180000/2^24) × 16^1
  IEEE 754 binary32   → 3F C0 00 00      sign=0, exp=127, mantissa=0x400000
```

**交叉误读的后果**（这是为什么必须显式声明）：

```
41 18 00 00  按 HFP 读 → 1.5       ✅
41 18 00 00  按 IEEE 读 → 9.5      ❌ 不报错，只给错值
```

已实跑验证（`copybook decode --float-mode hfp|ieee` 对同一份 4 字节数据）：

```
-- HFP 模式  → {"R.A":1.5}
-- IEEE 模式 → {"R.A":9.5}
```

这条已写成回归测试 `audit_test.mbt`「同一数值 1.5 在 HFP 与 IEEE 下字节完全不同」，
双向交叉误读都有断言。

### 案例 2：同值不同符号字节——COMP-3 一个数值三种合法写法

符号半字节有**三个**合法取值，其中两个表示正号：

| 符号半字节 | 含义 | 谁写的 |
|---|---|---|
| `0xC` | 正 | 最常见的编译器输出 |
| `0xF` | 正 | IBM 对**无符号**字段的约定写法 |
| `0xD` | 负 | 唯一负号写法 |

`PIC 9(4) COMP-3`（3 字节）里的数值 **1234** 因此有三种合法字节：

```
12 34 0C     填充半字节 0 + 正号 C
12 34 FC     填充半字节 F + 正号 C
12 34 0F     填充半字节 0 + 正号 F
```

三种写法**数值都是 1234**，字节互不相同。实跑验证（三条都解出 1234）：

```
12 34 0C -> {"R.V":1234}
12 34 FC -> {"R.V":1234}
12 34 0F -> {"R.V":1234}
```

**这就是"信息保留"要求的具体内容**：若解码只记下「1234，正」，编码时按默认规则
写 `12 34 0C`，那么后两种输入往返后就**变了字节**——数值对了，字节不对。

### 修复：原始表示信息随值携带

`Decimal` 新增两个可选字段：

```moonbit
pub(all) struct Decimal {
  coefficient : Int64
  scale : Int32
  negative : Bool
  sign_nibble : Int?       // decode 读到的符号半字节（C/D/F）
  pad_nibble : Int?        // decode 读到的 packed 填充半字节（0/F）
}
```

decode 把**实际读到的**半字节带出来，encode 优先原样写回。`align_scale`
（JSON 往返的 scale 对齐）也传递而非丢弃这两个字段。

JSONL 路径同样保真——通过旁路键 `__nibbles` 携带：

```json
{"R.PK":1234,"R.ZN":123,
 "__nibbles":{"R.PK":{"sign":12,"pad":15},"R.ZN":{"sign":15}}}
```

**端到端实测**（24 字节记录，含 HFP/COMP-2/COMP-3/zoned 各两路）：

```
原始:    41 18 00 00 41 18 00 00 00 00 00 00 12 34 0C 12 34 FC F1 F2 C3 F1 F2 F3
往返后:  41 18 00 00 41 18 00 00 00 00 00 00 12 34 0C 12 34 FC F1 F2 C3 F1 F2 F3
字节完全相同: True        （decode → JSONL → encode 三个步骤之后）
```

注意 `12 34 FC`（填充 F）与 `F1 F2 C3`（zoned 正号 C）都保持了非默认写法——
这正是修复前会丢失的两个字节。

### 案例 3：zoned 的三种符号布局

```
F1 F2 C3    123，末位符号 C（SIGN IS TRAILING，默认）
F1 F2 F3    123，末位符号 F（未符号化写法，同样合法）
F1 F2 D3    -123，末位符号 D
F1 F2 F3 4E 123，SIGN IS SEPARATE，符号独占一字节（EBCDIC '+'）
F1 F2 F3 60 -123，SIGN IS SEPARATE（EBCDIC '-'）
```

三种布局各自往返，`sign_nibble` 分别记录 `C` / `F` / `D`。

### 案例 4：±0 的字节区分

COBOL 在比较语义上区分 `+0` 与 `-0`，存储上靠符号半字节 / 符号位：

```
COMP-3:  00 0C 是 +0     00 0D 是 -0
HFP:     00 00 00 00 是 +0.0     80 00 00 00 是 -0.0
```

全部保留符号位/符号半字节，各自往返。

---

## 四、保真的边界（诚实说明）

`FIDELITY.md` 把承诺分成两级并列出做不到的地方：

- **L1 字节级**：`encode(decode(bytes)) == bytes`，对所有支持字段类型成立，
  `verify` 子命令与 `fidelity_test.mbt` 逐条锁定。
- **L2 数值级**：新建值（无字节来源）按文档化默认规则编码，有测试锁定。

**已知丢失边界（不涉及原始记录字节）**：

- **COMP-2 的 56 位尾数 → Double 的 53 位**：主机 `COMP-2` 尾数比 `double` 多
  3 位，转成 `Double` 时按最近偶数丢掉低 3 位。这是 `Double` 类型表达能力所限，
  不是实现缺陷。反方向（`Double` → HFP COMP-2）**精确无舍入**。
  `verify`（内存内 decode→encode）在这类记录上**会如实报告字节差异**并返回
  退出码 1，而不是假装通过。
- **COMP-1 的 24 位尾数**：小于 53 位，双向都精确，无丢失。
- **HFP 范围边界**：最小 `2^-260`、最大约 `2^308`，超出报错不静默截断。

另外说明 `FILLER` 的行为：它占字节但不进解码输出，编码时必须原样写回那段字节。
`verify`（内存内往返）覆盖这条；而 `decode → JSONL → encode` 路径对**含 FILLER
且原值非空格**的记录不保证字节一致，`verify` 会如实报告差异。

---

## 五、验证

```
moon test          276 / 276 passed（原 259，新增 17 条 HFP + 保真回归）
moon fmt --check   通过
moon build --target wasm   通过
CI（GitHub Actions）  52e6edb success
```

新增文件：
- `src/hfp.mbt` — IBM HFP 编解码（287 行）
- `src/fidelity_test.mbt` — 字节保真回归（441 行）
- `FIDELITY.md` — 保真说明（177 行）

修改：`README.md`（新增「目标标准与兼容范围」章节）、`API.md`（修正浮点描述、
补充 `FloatMode` 与 `Decimal` 字段）、`src/decode.mbt`、`src/encode.mbt`、
`src/layout.mbt`、`src/output.mbt`、`src/jsonl.mbt`、`cmd/copybook/main.mbt`
（新增 `--float-mode`）。

---

## 六、可以直接粘进报名表的一段话

> 本项目首要目标平台为 IBM 大型机（z/OS）定长记录，采用 EBCDIC cp037、
> COMP-3 打包十进制、COMP 二进制补码与 IBM HFP 十六进制浮点；数据描述遵循
> COBOL-85 数据描述子集加 IBM Enterprise COBOL 扩展，不含过程部语义。
>
> 浮点处理已从原 IEEE 754 改为**默认按主机 HFP 解释**（新增 `src/hfp.mbt`），
> 并新增 `FloatMode`（挂 `RecordLayout`）与 CLI `--float-mode {hfp|ieee}`
> 显式声明数据源格式，不再有任何"猜"的路径。同一数值 1.5 在 HFP 下是
> `41 18 00 00`、在 IEEE 下是 `3F C0 00 00`，交叉误读会得到 9.5 而不是 1.5，
> 因此格式必须由数据源决定——这条差异与双向误读都写成了回归测试。
>
> 字节保真方面，`Decimal` 现携带 `sign_nibble` / `pad_nibble`，保存 decode
> 实际读到的符号与填充半字节，encode 优先原样写回，JSONL 通过 `__nibbles`
> 旁路键携带，使 `decode → JSONL → encode` 也逐字节还原。实测：`9(4) COMP-3`
> 的同一数值 1234 有三种合法写法 `12 34 0C` / `12 34 FC` / `12 34 0F`，
> 三者各自往返字节不变；24 字节混合记录经三步往返后字节完全相同。
> 保真的边界（`COMP-2` 的 56 位尾数转 `double` 会按最近偶数丢低 3 位）已在
> `FIDELITY.md` 中明确列出，`verify` 在该情形下如实报差异而非假装通过。
>
> 测试 276/276 通过，`moon fmt --check` 与 wasm 构建通过，CI success。
