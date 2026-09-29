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

```bash
# 需要 MoonBit 工具链：https://www.moonbitlang.com/download
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

# 编码回去（往返验证）
copybook encode --copybook examples/customer.cpy --json out.jsonl --out roundtrip.dat

# 自检：解码再编码，逐字节比对
copybook verify --copybook examples/customer.cpy --data examples/customer.dat
```

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

## 支持的 COBOL 子集

| 特性 | 状态 |
|---|---|
| `PIC 9(n)` 数字（zoned decimal） | ✅ |
| `PIC S9(n)` 带符号 | ✅ |
| `PIC X(n)` / `A(n)` 字符 | ✅ |
| `PIC N(n)` 国家字符 | ✅ |
| `PIC S9(n)V9(m)` 隐含小数 | ✅ |
| `COMP` / `COMP-4` 二进制 | ✅ |
| `COMP-3` 打包十进制 | ✅ |
| `COMP-1` / `COMP-2` 浮点 | ✅ |
| `OCCURS n TIMES` | ✅ |
| `REDEFINES` | ✅ |
| `SIGN ... SEPARATE` | ✅ |
| `PIC 66 RENAMES` / `88` 条件名 | 忽略（记录在 AST） |

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
  decode.mbt       记录 → 类型化值
  encode.mbt       类型化值 → 记录
  output.mbt       JSONL / 表格 / 布局报告
cmd/copybook/
  main.mbt         CLI
```

详细 API 见 [API.md](API.md)，MoonBit 语法要点见 [MOONBIT-GUIDE.md](MOONBIT-GUIDE.md)。

## 背景资料

- IBM Enterprise COBOL Language Reference — `PIC` 子句、`USAGE` 子句
- ISO/IEC 1989（COBOL 标准）
- EBCDIC cp037 码表 — IBM CDRA

## License

Apache-2.0，见 [LICENSE](LICENSE)。
