# copybook 实现说明

记录几个**容易算错**的地方。每一条都对应一个真实 bug 或一次真实的错误计算。

## 1. 字节数计算：三套完全不同的规则

| PIC | USAGE | 字节数 | 说明 |
|---|---|---|---|
| `X(n)` / `A(n)` | DISPLAY | n | 纯文本，1 字节 1 字符 |
| `9(n)` | DISPLAY | n | zoned decimal，1 位数字 1 字节 |
| `S9(n)` | DISPLAY | n | 符号**覆盖**最后一字节的高半字节，**不加字节** |
| `9(n)` | COMP | n≤4→2, n≤9→4, n≤18→8 | 二进制补码，大端 |
| `S9(n)` | COMP | 同 `9(n)` | 符号在补码里，不额外占位 |
| `9(n)` | COMP-3 | `ceil((n+1)/2)` | 每字节两个数字，末字节低半字节放符号 |
| `S9(n)V9(m)` | COMP-3 | `ceil((n+m+1)/2)` | 总位数 = 整数位 + 小数位 |
| `N(n)` | DISPLAY | n*2 | 国家字符（UTF-16BE），n 为码元数，填充 U+0020 |
| 任意 | `SIGN ... SEPARATE` | +1 | 唯一的"额外占用"情况 |

**最容易错的两个**：

`S9(4) COMP` 按 IBM 规则占 **2 字节**。1 至 4 位占 2 字节、5 至 9 位占 4 字节、10 至 18 位占 8 字节。`order.cpy` 的 `QTY` 占 2 字节，整条记录为 103 字节。

`S9(7)V99 COMP-3` 是 **5 字节**：`ceil((7+2+1)/2) = ceil(5.0) = 5`。不是 4（漏了符号位），也不是 6（多算了）。

## 2. REDEFINES 不能用「父组求和」

第一版实现里，`compile_field` 返回子项长度、父组累加 `inner += child_len`。`redefines.cpy` 立刻算出 **35** 而不是 29：

```
ACCT-NO     12
ACCT-TYPE    2
LIMIT-AMT    6
RAW-BYTE     6    ← 与 LIMIT-AMT 共享字节，不该累加
SSN          9
            --
            35    ← 错
```

**这是结构性的坑**：只要用「父组求和」，任何 REDEFINES 都会重复计算。

正确做法是**单一游标驱动**：

```
cursor = 0
对每个字段:
    if 是 REDEFINES:
        save = cursor
        cursor = 目标字段的 offset      // 挪回去
        计算字段（不影响 cursor）
        cursor = max(save, 目标 offset + 字段 span)
    else:
        offset = cursor
        cursor += span
```

## 3. 重定义组的 id 不能从 0 开始

用 `redefine_group == 0` 表示「不参与重定义」是个自然的直觉，但会导致：

- 第一个重定义组的 id 是 0 → 被当成普通字段 → 游标推进两次
- 被重定义的目标字段（`LIMIT-AMT`）也要拿到组 id，否则调用方用 `group != 0` 筛选"这段字节被复用"时会漏掉一半

解决：预扫描 `collect_redefine_groups`，一次性给整组分配 id，**从 1 开始**。支持 `A→B`、`C→B`、`D→A` 这样的链式重定义，且与定义顺序无关。

## 4. 重定义视图不能强校验

`redefines.cpy` 里 `ALT-VIEW.RAW-BYTE` 是 `X(6)`，但同一段字节实际是 packed 数值 `12 34 56 78 9C 0D`。`0x12` 和 `0x0D` 是不可打印的 EBCDIC 控制字符 → 文本校验必然失败。

如果对重定义视图强校验，**任何 REDEFINES 都会让整条记录解码失败**，与 COBOL 的实际用法矛盾——重定义本来就是"同一段字节的另一种解释"，其中一种解释可能不是合法文本。

拆成两个入口：

- `decode_record`（宽容）：主视图（`group == 0`）失败 → 整条报错；重定义视图失败 → 该键置 `Null`，键保留
- `decode_record_strict`（严格）：所有视图任一失败即报错，供 `verify` 用

## 5. COMP 没有负零

二进制补码不存在 `-0`。`Decimal{ coef: 0, negative: true }` 编码成全 0 字节，解码回来是 `negative: false`。

这不是 bug，是 COMP 与 zoned/packed 的本质差异——后两者有独立的符号半字节，可以表示 `-0`；COMP 不能。

往返测试显式排除了这个组合，并加了注释说明。

## 6. EBCDIC 的坑

`cp037` 是**全定义单射表**：256 个字节映射到 256 个互不相同的码点，**没有"未映射字节"**。`0x00`..`0x3F` 是 C0 控制符，`0xFF` → U+009F。

所以 `ebcdic_to_unicode` 对 0..255 恒返回真实码点，U+FFFD 只用于越界防御（< 0 或 > 255）。这意味着「非法 EBCDIC 字节」这个检查**用映射表查不出来**——需要额外提供 `ebcdic_is_printable` 供 decode 层判断。

关键映射（最容易记错的）：

```
'0'..'9'  →  0xF0..0xF9     （ASCII 是 0x30..0x39）
'A'..'I'  →  0xC1..0xC9
'J'..'R'  →  0xD1..0xD9     （不连续！）
'S'..'Z'  →  0xE2..0xE9     （不连续！）
'a'..'i'  →  0x81..0x89
'j'..'r'  →  0x91..0x99
's'..'z'  →  0xA2..0xA9
空格      →  0x40           （不是 0x20）
```

数字位置差异意味着：如果用 ASCII 的 `0x30` 去解析 EBCDIC 数据，会得到乱码而不是报错。

## 7. 固定列格式必须整文件判定

COBOL 传统格式是列敏感的：1-6 序号区、7 指示符（`*` 表示注释）、8-72 代码区。

但如果**逐行**判断「前 6 列是不是数字」，会把这一行误判：

```
    05  LINES OCCURS 5 TIMES.
```

前 6 列是「4 个空格 + `05`」——看起来像序号区，会把级别号 `05` 的十位切掉。

必须**整文件**判定：只要有任意一行第 7 列是 `*`，或者任意一行前 6 列是全数字且第 7 列是空格，就按固定格式解析；否则按自由格式。

## 8. 验证方法与结果

布局和三份 copybook 的权威答案（用 Python 独立计算，不与 MoonBit 实现共享代码）：

```
customer.cpy   →  54 字节
order.cpy      → 103 字节
redefines.cpy  →  29 字节
```

EBCDIC 测试数据由 `scripts/gen_copybook_data.py` 独立生成——它自己实现了 cp037 表、zoned decimal、COMP-3 打包，**与 MoonBit 侧没有任何共享代码**。因此两边一致是真正的证据，而不是同一份逻辑跑两遍。

实测覆盖：
- `123456789` cents → `1234567.89`（正数）
- `-9876543` cents → `-98765.43`（COMP-3 负号 `0xD`）
- `-1` cents → `-0.01`（最小非零负值边界）
- `0` cents → `0.00`
- 名字尾部 0x40 填充被正确 trim
- `verify` 报告 5 条记录字节级往返一致

## 9. COMP 的十进制容量：decode 与 encode 必须对称强制

`PIC S9(4) COMP` 占 **2 字节**，二进制容器能表示 `-32768..32767`。但能装下不等于允许装下：COBOL 字段的语义是「**最多 4 位十进制数**」，范围 `-9999..9999`。

这条约束是**双向**的，两侧都必须强制：

| 方向 | 依据 | 越界行为 |
|---|---|---|
| encode | PIC 声明的 `storage_digits` | 报 `InvalidNumeric`，绝不截断 |
| decode | 同一个 `storage_digits` | 报 `InvalidNumeric`，绝不"读出来再说" |

历史教训：issue #28 修了 encode 一侧（`src/encode.mbt` 的 `dec_limit`），decode 一侧（`src/decode.mbt` 的 `decode_binary`）当时只校验宽度 1..8 与无符号符号位。结果同一份 `7F FF`：

```
copybook decode  → 成功，32767
copybook verify  → 失败：value 32767 exceeds 4 decimal digits (field holds at most 9999)
```

`verify` 走的是 decode→encode，encode 拒绝才暴露了问题；**decode 单独看是错的**。两个方向对同一段字节给出互相矛盾的结论，就是单边修补的信号。

现在 `decode_binary` 用与 `encode_binary` 相同的上限判定（`10^storage_digits`），错误消息带绝对偏移并说明「超出 PIC 声明的十进制位数、字段最多能装多少」。回归测试在 `src/comp_decode_capacity_test.mbt`：

- 拒绝：`S9(4)` 的 `7F FF` / `80 00`、`9(4)` 的 `FF FF`、`S9(9)` 的 `7F FF FF FF`
- 接受并逐字节往返：`S9(4)` 的 `270F`（9999）/ `D8F1`（-9999）、`S9(9)` 的 `3B9AC9FF`（999999999）、`S9(18)` 的 `0DE0B6B3A763FFFF`（18 位边界）

`PIC S9(18) COMP` 是这条规则最容易含糊的地方：8 字节补码能到 `2^63-1`（19 位），但声明容量只有 `10^18-1`，所以 `7FFFFFFFFFFFFFFF` 同样是**解码错误**而不是"一个很大的数"。
