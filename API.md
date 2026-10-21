# copybook — API 契约

> **这是实现依据，不得更改签名。** 内部实现自由，但这些公开 API 必须存在且签名一致。

模块名：`moonbit-hack/copybook`，库包：`src`，CLI 包：`cmd/copybook`。

## 1. 编码层 `src/ebcdic.mbt`

EBCDIC ↔ ASCII 映射。使用 **cp037（美国/加拿大）** 作为默认表。

```moonbit
/// EBCDIC 单字节 -> Unicode 码点
pub fn ebcdic_to_unicode(byte : Int) -> Int

/// Unicode 码点 -> EBCDIC 单字节（不可表示时返回 None）
pub fn unicode_to_ebcdic(cp : Int) -> Int?

/// 整块解码，跳过不可打印控制字符由调用方决定
pub fn ebcdic_decode(bytes : BytesView) -> String

/// 整块编码
pub fn ebcdic_encode(s : StringView) -> Bytes

/// 是否合法的 EBCDIC 数字（0xF0..0xF9）
pub fn is_ebcdic_digit(b : Int) -> Bool

/// EBCDIC 空格 0x40
pub fn is_ebcdic_space(b : Int) -> Bool
```

要求：
- 完整 cp037 表（256 项）。无映射的字节解码为 U+FFFD 或原样保留，必须在文档里说明选择。
- 必须写测试：`A`→0xC1、`0`→0xF0、空格→0x40、往返一致性对全部 256 项。

## 2. Copybook 词法与语法 `src/lexer.mbt` + `src/parser.mbt`

### 词法

```moonbit
pub(all) enum TokenKind {
  Identifier(String)   // CUST-ID
  Level(Int)           // 01, 05, 88
  PicString(String)    // PIC 9(8) 里的 9(8)，已剥离 PIC 关键字
  PicX
  PicN
  Number(Int)
  LParen
  RParen
  Dot
  Keyword(String)      // VALUE REDEFINES OCCURS TIMES COMP COMP-3 USAGE SIGN SEPARATE etc
  Eof
}

pub(all) struct Token {
  kind : TokenKind
  line : Int
  column : Int
}

pub fn tokenize(source : StringView) -> Array[Token] raise ParseError
```

### 语法树

```moonbit
pub(all) enum PicCategory {
  Numeric          // PIC 9(...)
  Alphabetic       // PIC A(...)
  Alphanumeric     // PIC X(...)
  National         // PIC N(...)
  Edited           // 含 Z , . $ 等编辑字符
}

pub(all) enum Usage {
  Display          // 默认
  Comp             // COMP / COMP-4 / BINARY
  Comp3            // COMP-3 / PACKED-DECIMAL
  Comp1            // COMP-1 单精度浮点
  Comp2            // COMP-2 双精度浮点
}

pub(all) struct PicClause {
  category : PicCategory
  digits : Int           // 9(7) -> 7（整数位数），X(30) -> 30
  scale : Int            // V99 -> 2；无 V 则为 0；尾随 P 为负（如 9(3)PP -> -2）
  storage_digits : Int   // 实际占存储的数字位数（P 不占存储）
  signed : Bool          // S 前缀
  usage : Usage
  sign_separate : Bool   // SIGN IS ... SEPARATE
  sign_leading : Bool    // SIGN SEPARATE 的位置：true = LEADING
  pic_text : String      // PIC 模式串原文（大写）
}

pub(all) struct FieldSpec {
  level : Int
  name : String
  pic : PicClause?
  redefines : String?
  occurs : Int           // 默认 1；OCCURS 1 TO 5 取上界 5
  occurs_min : Int       // OCCURS 1 TO 5 取下界 1；无 TO 时等于 occurs
  occurs_depending_on : String?
  value_literal : String?
  children : Array[FieldSpec]
  line : Int
  group_usage : Usage?   // 组项上写的 USAGE，供子项继承
}

pub fn parse_copybook(source : StringView) -> Array[FieldSpec] raise ParseError
```

要求：
- 支持 `OCCURS n TIMES`、`OCCURS n TO m TIMES`（后者取上界并记录）、`REDEFINES`、`VALUE`、`USAGE`/`COMP`/`COMP-3`。
- 层级号 `01` 到 `49` 建树；`66`（RENAMES）和 `88`（条件名）单独收集或忽略（文档说明）。
- 错误要带行列号。


> **记录模型**：`compile_layout` 把整份 copybook 编译为**单条**记录布局。
> 多个 `01` 层级按「并列拼接」处理（偏移连续），不是 COBOL 的多记录型态语义。
> `FieldSpec.occurs_depending_on` 记录 ODO 依赖名，存储按上界固定展开。

## 3. 布局计算 `src/layout.mbt`

```moonbit
pub(all) struct FieldLayout {
  name : String
  path : String          // "CUSTOMER-RECORD.CUST-NAME"
  offset : Int           // 字节偏移（相对于记录起点，已含 OCCURS 展开前的基址）
  byte_length : Int      // 单个元素字节数
  occurs : Int
  total_length : Int     // byte_length * occurs
  pic : PicClause
  level : Int
  redefine_group : Int   // 同一 REDEFINES 组的 id，0 表示不参与
}

pub(all) struct RecordLayout {
  name : String
  byte_length : Int
  fields : Array[FieldLayout]     // 仅叶子字段，按偏移排序
  all_fields : Array[FieldLayout> // 含中间层
}

pub fn compile_layout(specs : Array[FieldSpec]) -> RecordLayout raise ParseError

/// 按名字查字段（大小写不敏感，支持点分路径）
pub fn RecordLayout::find(self : RecordLayout, name : StringView) -> FieldLayout?

/// 可解码叶子的偏移区间并集字节数（测试与 verify 自检用；REDEFINES
/// 会重复计数共享字节，故按并集而不是逐字段求和）
pub fn RecordLayout::covered_bytes(self : RecordLayout) -> Int
```

字节数计算规则（**必须精确，这是全项目最容易错的地方**）：

| PIC | Usage | 字节数 |
|---|---|---|
| `X(n)` / `A(n)` | Display | n |
| `9(n)` | Display (zoned) | n |
| `S9(n)` | Display | n（符号覆盖末位，**不加字节**） |
| `9(n)` | COMP | n≤4 → 1；n≤9 → 2；n≤18 → 4 |
| `S9(n)` | COMP | 同上（**符号不额外占字节**） |
| `9(n)` | COMP-3 (无符号) | ceil((n + 1) / 2) |
| `S9(n)V9(m)` | COMP-3 | ceil((n + m + 1) / 2) |
| `N(n)` | Display | n * 2 |
| 任意 | `SIGN ... SEPARATE` | +1 |

**权威布局答案（已用 Python 交叉核对，测试必须匹配）：**

`customer.cpy` → **总长 54 字节**

```
CUST-ID         offset  0  len  8
CUST-NAME       offset  8  len 30
BALANCE         offset 38  len  5     (S9(7)V99 COMP-3 → ceil((7+2+1)/2)=5)
OPEN-DATE       offset 43  len  8
FLAGS.ACTIVE    offset 51  len  1
FLAGS.TIER      offset 52  len  2
```

`order.cpy` → **总长 98 字节**

```
ORDER-ID        offset  0  len 10
LINE-COUNT      offset 10  len  3
LINES × 5       offset 13  每条 17 字节 = 85
    SKU         len 12
    QTY         len  1     (S9(4) COMP → n≤4 → 1 字节，不是 2！)
    PRICE       len  4     (S9(5)V99 COMP-3 → ceil((5+2+1)/2)=4)
TOTAL = 10 + 3 + 85 = 98
```

`redefines.cpy` → `LIMIT-AMT` (S9(9)V99 COMP-3 = 6 字节) 与 `ALT-VIEW` 的 `RAW-BYTE` X(6)
**共享同一偏移**，不累加：
```
ACCT-NO         offset  0  len 12
ACCT-TYPE       offset 12  len  2
LIMIT-AMT       offset 14  len  6
RAW-BYTE        offset 14  len  6     ← REDEFINES，同偏移
SSN             offset 20  len  9
TOTAL = 12 + 2 + 6 + 9 = 29
```

## 4. 解码 `src/decode.mbt`

```moonbit
pub(all) enum CellValue {
  Null
  Text(String)
  Int(Int64)
  Decimal(Decimal)      // 定点小数，见下
  Bool(Bool)
  Bytes(Bytes)
  Float(Double)         // COMP-1 / COMP-2 的值（字节表示见 float_mode）
}

/// 浮点字节表示。挂在 RecordLayout 上（数据源属性，不是字段属性）。
pub(all) enum FloatMode {
  Hfp        // IBM z/OS 十六进制浮点（默认）
  Ieee754    // IEEE 754 binary32 / binary64
}

pub(all) struct Decimal {
  coefficient : Int64      // 去掉小数点的整数部分
  scale : Int              // 小数位数
  negative : Bool
  sign_nibble : Int?       // decode 读到的符号半字节（C/D/F），用于字节保真
  pad_nibble : Int?        // decode 读到的 packed 填充半字节（0/F）
}

pub fn Decimal::to_string(self : Decimal) -> String
pub fn Decimal::from_parts(coef : Int64, scale : Int, neg : Bool) -> Decimal

pub(all) enum DecodeError {
  RecordTooShort(expected : Int, actual : Int)
  InvalidNumeric(offset : Int, detail : String)
  InvalidEbcdic(offset : Int, byte : Int)
  FieldOutOfBounds(field : String, offset : Int, length : Int)
} derive(Debug)

/// 解码一条记录为 Map[字段路径, 值]
pub fn decode_record(layout : RecordLayout, record : BytesView) -> Result[Map[String, CellValue], DecodeError]

/// 解码为有序数组（顺序同 layout.fields）
pub fn decode_record_ordered(layout : RecordLayout, record : BytesView) -> Result[Array[CellValue], DecodeError]

/// 批量解码
pub fn decode_records(layout : RecordLayout, data : BytesView, record_length : Int) -> Result[Array[Map[String, CellValue]], DecodeError]

/// 严格版 decode_record：任何视图（含 REDEFINES 重定义视图）
/// 解码失败都报错；供 verify 与单元测试使用
pub fn decode_record_strict(layout : RecordLayout, record : BytesView) -> Result[Map[String, CellValue], DecodeError]
```

规则：
- zoned decimal：每个字节低 4 位是数字；**最后一个字节的高 4 位是符号**（`0xC`/`0xF` 正，`0xD` 负）。
- packed decimal（COMP-3）：每字节两半字节；最后一字节低 4 位是符号。
- COMP 二进制：按字节数用**大端**读取，有符号用补码。
- COMP-1 / COMP-2：**字节解释方式由 `RecordLayout.float_mode` 决定**，两种互不兼容：
  - `Hfp`（默认）：IBM z/OS 主机十六进制浮点，1 符号位 + 7 位 excess-64 指数（base-16）
    + 24/56 位尾数
  - `Ieee754`：IEEE 754 binary32 / binary64，1 符号位 + 8/11 位 excess-127/1023 指数

  同一个 `1.5` 在 HFP 下是 `41 18 00 00`、在 IEEE 下是 `3F C0 00 00`。
  解码为 `CellValue::Float`。用 `compile_layout_with_float_mode` 或 CLI `--float-mode`
  指定；默认 `Hfp`（有测试锁定），不允许"猜"。
- 文本字段：EBCDIC 解码后 `trim_end` 空格（0x40）。
- P 缩放位（`PIC PP9(3)` / `PIC 9(3)PP`）不占存储：存储宽度按
  `storage_digits`；数值语义折算进 `scale`（前导 P 增大 scale，
  尾随 P 使 scale 为负）。值 = coefficient × 10^(-scale)。
- **绝不静默修正非法数据**，返回 `DecodeError`。

## 5. 编码（往返）`src/encode.mbt`

```moonbit
pub fn encode_record(layout : RecordLayout, values : Map[String, CellValue]) -> Result[Bytes, DecodeError]
pub fn encode_records(layout : RecordLayout, rows : Array[Map[String, CellValue]]) -> Result[Bytes, DecodeError]
```

要求：`decode → encode` 必须逐字节还原（写往返测试，随机数据 500 条）。

## 6. 输出格式 `src/output.mbt`

```moonbit
/// JSONL：每行一个 JSON 对象
pub fn render_jsonl(layout : RecordLayout, rows : Array[Map[String, CellValue]]) -> String

/// 定宽文本表格（给人看）
pub fn render_table(layout : RecordLayout, rows : Array[Map[String, CellValue]]) -> String

/// 布局报告：字段名 / 偏移 / 长度 / 类型
pub fn render_layout(layout : RecordLayout) -> String
```

`render_jsonl` 的数值表示：`Int` / `Decimal` / 有限 `Float` 输出 JSON
number（带十进制 repr 原文）。**COMP-1 / COMP-2 的 ±Inf / NaN 不是合法
JSON 字面量**，按 IEEE 754 文本约定输出带引号字符串 `"Infinity"` /
`"-Infinity"` / `"NaN"`；`parse_jsonl_row` 能把这三个串解回
`CellValue::Float`。

`render_layout` 示例输出（**必须长这样，数字是权威答案**）：

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

## 7. CLI `cmd/copybook/main.mbt`

```
copybook layout --copybook <file.cpy>
copybook decode --copybook <file.cpy> --data <file.dat> [--format jsonl|table] [--record-length N]
copybook encode --copybook <file.cpy> --json <file.jsonl> --out <file.dat>
copybook verify --copybook <file.cpy> --data <file.dat>     # 往返自检
```

退出码：0 成功，1 数据错误，2 用法错误。

## 8. 测试要求

至少覆盖：
- EBCDIC 全 256 往返
- 每种 PIC/USAGE 组合的字节数（表驱动）
- zoned/packed 正负数解码
- OCCURS 展开
- REDEFINES
- 记录过短报错
- 随机数据 create→decode→encode→compare（属性测试）
