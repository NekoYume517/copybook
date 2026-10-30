# copybook

**COBOL copybook 编译器：把大型机定长记录解码成类型化数据。**

[![MoonBit](https://img.shields.io/badge/MoonBit-0.1.20261012-blueviolet)](https://www.moonbitlang.com/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

## 为什么

每天仍有海量业务数据以 **EBCDIC 定长记录 + COBOL copybook** 的形式在主機之间流转：银行日终对账、保险保单批处理、社保与税务申报、航空订票（SABRE 系）、医院 HIS 系统。

这些文件的 schema 不是 JSON Schema，而是一份 `PIC` 子句组成的 copybook：

```cobol
01  CUSTOMER-RECORD.
    05  CUST-ID        PIC 9(8).
    05  CUST-NAME      PIC X(30).
    05  BALANCE        PIC S9(7)V99 COMP-3.
    05  OPEN-DATE      PIC 9(8).
```

`S9(7)V99 COMP-3` 的意思是：**带符号、7 位整数 + 2 位小数、打包十进制，占 5 个字节**。金额绝不用浮点——这就是它能几十年不出分毫误差的原因。

现有处理方式要么是商业软件（IBM InfoSphere、Syncsort、Precisely），要么是大量手写 `struct.unpack` 脚本，后者经常在以下地方出错：zoned decimal 的末位符号覆盖、`COMP-3` 的半字节对齐、`OCCURS` 展开、`REDEFINES` 联合体、层级号决定的隐式填充。

`copybook` 把这件事做成一个**可测试、可复现**的编译器：解析 copybook → 计算精确字节布局 → 双向编解码。

## 安装与运行

**作为库依赖**（已发布到 [mooncakes.io](https://mooncakes.io/docs/NekoYume517/copybook)）：

```bash
moon add NekoYume517/copybook
```

```moonbit
// 解析 copybook → 编译布局 → 解码 EBCDIC 记录
let specs = @copybook.parse_copybook(cpy_text)
let layout = @copybook.compile_layout(specs)
let row = @copybook.decode_record(layout, record_bytes)
```

**作为命令行工具**（源码运行，需要 MoonBit 工具链：https://www.moonbitlang.com/download ）：

```bash
moon check
moon test
moon run cmd/copybook -- layout --copybook examples/customer.cpy
```

## 用法

```bash
# 看字节布局（最容易出错的地方，先看这个）
copybook layout --copybook examples/customer.cpy

# 解码成 JSONL
copybook decode --copybook examples/customer.cpy --data examples/customer.dat --format jsonl

# 解码成定宽文本表格
copybook decode --copybook examples/customer.cpy --data examples/customer.dat --format table

# 自检：解码再编码，逐字节比对（纯内存路径）
copybook verify --copybook examples/customer.cpy --data examples/customer.dat

# 完整的「解码 → 编辑 → 编码」工作流（经过 JSON 文本）
copybook decode --copybook examples/customer.cpy --data examples/customer.dat --format jsonl > out.jsonl
copybook encode --copybook examples/customer.cpy --json out.jsonl --out roundtrip.dat
# roundtrip.dat 与 examples/customer.dat 逐字节相同

# 数据源是 GnuCOBOL / Micro Focus 时，浮点要显式声明为 IEEE 754
copybook decode --copybook app.cpy --data app.dat --float-mode ieee
```

> `verify` 走的是内存内 decode→encode，不经过 JSON。要验证「导出成 JSON 再导回」
> 这条真实工作流，用上面最后两条命令，然后比较文件。这两条路径不同，都测过。

> 注意 `decode --format jsonl` 把定点小数写成 JSON 数字（`1234567.89`）。
> JSON 没有定点类型，`5.00` 会序列化成 `5`；编码器按字段声明的 scale
> （`PIC S9(7)V99` → 2 位小数）还原，因此 `5` 仍被正确写成 `500` 分。
> 这一点有专门的回归测试（`src/json_roundtrip_test.mbt`）。

`layout` 输出：

```
RECORD: CUSTOMER-RECORD                          LENGTH: 54 bytes

OFFSET  LENGTH  OCCURS  TYPE              NAME
     0       8       1  9(8) DISPLAY      CUSTOMER-RECORD.CUST-ID
     8      30       1  X(30) DISPLAY     CUSTOMER-RECORD.CUST-NAME
    38       5       1  S9(7)V99 COMP-3   CUSTOMER-RECORD.BALANCE
    43       8       1  9(8) DISPLAY      CUSTOMER-RECORD.OPEN-DATE
    51       1       1  X(1) DISPLAY      CUSTOMER-RECORD.FLAGS.ACTIVE
    52       2       1  9(2) DISPLAY      CUSTOMER-RECORD.FLAGS.TIER
```

## 目标标准与兼容范围

这一节回答「你实现的到底是哪个 COBOL」——**去掉这一段，任何字节级声明都站不住**。

### 目标平台

本项目的首要目标是** IBM 大型机（z/OS）落地的定长记录**。这决定了下面每个默认值：

| 维度 | 本项目采用 | 依据 |
|---|---|---|
| 字符编码 | **EBCDIC cp037**（US/Canada） | 主機记录的实际编码；ASCII 不是候选 |
| 记录形态 | **定长**，无 RDW/BDW，记录间无填充 | 主机批量文件的标准形态 |
| 数值表示 | zoned decimal / **COMP-3 打包十进制** / COMP 二进制补码 | COBOL 主机端标准数值格式 |
| **浮点表示** | **IBM HFP 十六进制浮点**（base-16 指数） | z/OS 的 `COMP-1` / `COMP-2` 原生格式 |
| 语言子集 | COBOL-85 数据描述子集 + IBM Enterprise COBOL 常用扩展 | 见下方「支持的 COBOL 子集」 |

### 语言标准

- **数据描述**：ISO/IEC 1989（COBOL-85）的 `PIC` / `USAGE` / `OCCURS` / `REDEFINES` / `SIGN` 子句语义
- **扩展**：IBM Enterprise COBOL 的 `COMP-1` / `COMP-2` / `COMP-4` / `FLOAT-SHORT` / `FLOAT-LONG` 写法
- **不涉及**：过程部（`PROCEDURE DIVISION`）语义、`MOVE` 的隐式转换规则、运行时算术——本项目只做**数据布局与字节编解码**，不做 COBOL 解释器

### 浮点：两种互不兼容的表示

这是本项目最容易出错、也最需要显式声明的一点。**同一个数值 `1.5`，在不同 COBOL 实现的 `COMP-1` 里字节完全不同**：

| 实现 | `COMP-1` 存 1.5 的字节 | 格式 | 指数 |
|---|---|---|---|
| **IBM z/OS 主机** | `41 18 00 00` | **HFP**（十六进制浮点） | base-16，excess-64 |
| GnuCOBOL / Micro Focus / x86 | `3F C0 00 00` | IEEE 754 binary32 | base-2，excess-127 |

两者的差异不是"精度不同"，而是**格式不同**：

| 属性 | IBM HFP | IEEE 754 |
|---|---|---|
| 指数基数 | **16** | 2 |
| 指数偏置 | 64（7 位） | 127 / 1023（8 / 11 位） |
| `COMP-1` 尾数 | 24 位（6 个十六进制数字） | 24 位（隐含前导 1） |
| `COMP-2` 尾数 | 56 位（14 个十六进制数字） | 53 位（隐含前导 1） |
| NaN / ±Infinity | **没有** | 有 |
| 渐进下溢 | **没有**（小于 2^-260 直接下溢） | 有非规格化数 |
| ±0 | 尾数为 0，符号位保留 | 有专门的 ±0 编码 |

**因此本项目要求显式声明浮点表示，不提供"猜"的模式：**

```bash
# 默认：IBM 主机 HFP（本项目目标平台）
copybook decode --copybook app.cpy --data app.dat

# GnuCOBOL / Micro Focus 产生的数据：显式指定 IEEE 754
copybook decode --copybook app.cpy --data app.dat --float-mode ieee
```

选错的后果是**数值完全错误但不会报错**——`41 18 00 00` 按 IEEE 读出来是 9.5。这是把 HFP 的 `41 18 00 00` 当成 IEEE 754 解释后的结果；反过来把 IEEE 的 `3F C0 00 00` 当成 HFP 解释，也会得到无意义的值。所以 `layout` / `decode` / `encode` / `verify` 四个子命令都接受 `--float-mode`，且默认值写死为 `hfp`（有回归测试锁定，不允许悄悄改回 IEEE）。

浮点字节保真：`COMP-2` 的 56 位尾数比 `Double` 多 3 位，`Double` 存不下低 3 位非零的值。本项目**不因此放弃字节保真**——decode 对这类值产出带原始字节的 `FloatRaw`，encode 原样写回，JSONL 用保留键 `__float_hex` 携带；因此 `decode → JSONL → encode` 仍然逐字节恒等（详见 [FIDELITY.md](FIDELITY.md) 第 5.1 节）。`.f` 字段里的数值本身是近似值，精确值以 `__float_hex` 为准。

### 兼容范围速查

| 数据来源 | 能否用本项目 | 需要的选项 |
|---|---|---|
| IBM z/OS 批量导出（EBCDIC + COMP-3 + HFP） | ✅ 完整支持 | 默认 |
| 同上但含 IEEE 浮点字段（`ARITH(IEEE)` 编译） | ⚠️ 浮点需声明 | `--float-mode ieee` |
| GnuCOBOL 生成的测试数据 | ⚠️ 浮点需声明 | `--float-mode ieee` |
| Micro Focus 生成的数据 | ⚠️ 浮点需声明 | `--float-mode ieee` |
| ASCII 编码的 COBOL 文件 | ❌ 不支持 | 本项目只解 EBCDIC |
| 变长记录（RDW/BDW 头） | ❌ 不支持 | 需先剥离头部再喂进来 |
| 多个 `01` 层级混排的记录型态 | ⚠️ 有简化 | 见「已声明的简化」 |



| 特性 | 状态 |
|---|---|
| `PIC 9(n)` 数字（zoned decimal） | ✅ |
| `PIC S9(n)` 带符号 | ✅ |
| `PIC X(n)` / `A(n)` 字符 | ✅ |
| `PIC N(n)` 国家字符 | ✅ UTF-16BE；**n 是 UTF-16 码元数**（不是字符数），空位补 U+0020 |
| `PIC S9(n)V9(m)` 隐含小数 | ✅ |
| `COMP` / `COMP-4` 二进制 | ✅ |
| `COMP-3` 打包十进制 | ✅ |
| `COMP-1` / `COMP-2` 浮点 | ✅ 默认 IBM HFP；`--float-mode ieee` 切 IEEE 754 |
| `OCCURS n TIMES` | ✅ |
| `REDEFINES` | ✅ |
| `SIGN ... SEPARATE` | ✅ |
| 固定格式列 7 `-` 续行（`PIC` / `VALUE` 跨行） | ✅ 仅固定格式；自由格式没有续行符，行首 `-` 报错 |
| 列 73-80 标识区 | ✅ 固定格式下忽略（行长必须真的写到第 73 列） |
| `PIC 66 RENAMES` / `88` 条件名 | 忽略（记录在 AST） |
| `OCCURS DEPENDING ON` | 按上界展开（固定长度存储），`occurs_depending_on` 字段记录依赖名 |
| 多个 `01` 层级 | **并列拼接为一条记录**（见下方说明） |
| 组级 `USAGE` | ✅ 子项继承 |

**`PIC N(n)` 的容量单位是 UTF-16 码元，不是「字符个数」**：`N(n)` 占 `2n` 字节，
每个码元 2 字节，不足补 `00 20`（U+0020）。基本平面（BMP）字符占 1 码元，
补充平面字符（emoji、少数字形复杂的汉字）在 UTF-16 里是**代理对，占 2 码元**：

```cobol
05  EMOJI    PIC N(1).   * 只有 2 码元容量 → 存 emoji 报错（不截断、不替换）
05  EMOJI    PIC N(2).   * 4 字节，emoji 写成 D8 3D DE 00（U+1F600）
```

放不下时返回带偏移的 `InvalidNumeric`（`text exceeds NATIONAL code-unit capacity`），
绝不截断成半个代理对。回归测试：`src/national_capacity_test.mbt`。

### 已声明的简化

**多个 `01` 层级**：COBOL 语义里每个 `01` 是一条独立记录（一个文件里可以
有多种记录型态）。本实现把后续 `01` **并列拼接**成一条更长的记录——
`compile_layout` 的契约是「一份 copybook 一条记录布局」。如果文件里的数据
真的是多种记录型态混排，需要按记录类型拆分 copybook 分别处理。这个行为
写进测试（多 01 偏移连续）而不是悄悄偏离。

**重复的字段路径是编译错误。** 解码结果以字段路径为键（`R.G1.A`），所以
两个可解码叶子拿到同一个路径时它们在数据面上不可区分：`decode` 会静默丢
其中一个，`encode` 把同一个值写进两个偏移。`compile_layout` 因此在布局
阶段显式报 `duplicate field path '<path>'`（对齐「绝不静默修正」，而不是
运行期加后缀去重）。触发它的两类输入是**同名 `01`**（上一条的并列拼接
形态）与**同名兄弟组**；`G1.A` / `G2.A` 这类不同组下的同名字段、以及
`OCCURS` 展开出的 `A(1)` / `A(2)` 路径互不相同，不受影响。

EBCDIC 使用 **cp037**（US/Canada）。ASCII 与 EBCDIC 的数字位置完全不同——`'0'` 在 ASCII 是 `0x30`，在 EBCDIC 是 `0xF0`。

## 设计要点

**绝不静默修正。** 遇到非法 EBCDIC 字节、越界字段、长度不匹配，返回带偏移量的显式错误，而不是猜一个值。

**布局可审计。** `compile_layout` 是纯函数，输入 copybook、输出每个字段的字节偏移。可以先 `layout` 肉眼核对，再解码数据。

**往返是测试基准。** `decode → encode` 必须逐字节还原原始记录。随机生成的 500 条记录全部往返一致，是 CI 的硬性要求。

## 项目结构

```
src/
  ebcdic.mbt       cp037 编码表与转换
  lexer.mbt        copybook 词法
  parser.mbt       copybook 语法（层级树、PIC 子句）
  layout.mbt       字节布局计算
  hfp.mbt          IBM 十六进制浮点（COMP-1 / COMP-2 主机格式）
  decode.mbt       记录 → 类型化值
  encode.mbt       类型化值 → 记录
  output.mbt       JSONL / 表格 / 布局报告
  fidelity_test.mbt  字节保真回归（同值不同符号字节）
  audit_test.mbt   对抗性审计回归测试
cmd/copybook/
  main.mbt         CLI
```

详细 API 见 [API.md](API.md)，字节保真的完整说明见 [FIDELITY.md](FIDELITY.md)，
MoonBit 语法要点见 [MOONBIT-GUIDE.md](MOONBIT-GUIDE.md)。

## 背景资料

- IBM Enterprise COBOL Language Reference — `PIC` 子句、`USAGE` 子句
- ISO/IEC 1989（COBOL 标准）
- EBCDIC cp037 码表 — IBM CDRA

## License

Apache-2.0，见 [LICENSE](LICENSE)。



