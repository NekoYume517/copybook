# 字节保真（Byte Fidelity）

这份文档回答一个问题：**`decode → encode` 凭什么说"逐字节无损"？原始表示里哪些信息必须被保留，哪些必然会丢？**

审阅意见里那条「逐字节无损往返也缺少原始表示的信息保留说明」指向的正是这里。结论放在最前面：

> **数值对了不等于字节对了。** 同一个 COBOL 数值在存储层有多种合法字节写法。
> 若解码时不把「原始字节长什么样」带出来，编码就只能按自己的偏好重写，
> 于是往返从「逐字节无损」退化成「数值无损」——而后者对主機数据交换是不够的：
> 校验和、`MEMCMP` 比对、增量同步、原样回写都依赖字节一致。

---

## 1. 保真的定义

本项目承诺的往返性质分两级，**测试分别覆盖**：

| 级别 | 性质 | 保证 |
|---|---|---|
| **L1 字节级** | `encode(decode(bytes)) == bytes` | 对**本项目支持的所有字段类型**成立，`verify` 子命令与 `fidelity_test.mbt` 逐条锁定 |
| **L2 数值级** | `decode(encode(v)) 的数值 == v` | 对**新建值**（无字节来源）成立；符号写法按文档默认规则 |

不追求字节级的唯一例外写在下面第 5 节（`COMP-2` 尾数超出 `Double` 精度），且**只在 HFP↔Double 这一跨界上发生**，不涉及原始记录字节。

---

## 2. 同一个数值，多种合法字节

这是「同值不同符号字节」的核心事实，也是审阅意见要求给案例的地方。

### 2.1 packed decimal（COMP-3）

符号半字节（末字节低 4 位）有三个合法取值，其中两个表示正号：

| 符号半字节 | 含义 | 谁写的 |
|---|---|---|
| `0xC` | 正 | 最常见的 COBOL 编译器输出 |
| `0xF` | 正 | IBM 对**无符号**字段的约定写法 |
| `0xD` | 负 | 唯一负号写法 |

于是 `PIC 9(4) COMP-3`（3 字节）里的数值 **1234** 有两种合法字节：

```
01 23 4C    填充半字节 0 + 正号 C
01 23 4F    填充半字节 0 + 正号 F
```

**两种写法数值都是 1234**，字节互不相同。若解码只记下「1234，正」，编码时按默认规则写 `01 23 4C`，那么使用另一正号的输入往返后就**变了字节**。

本项目用 `Decimal.sign_nibble` 保存实际读到的 C/F 正号，编码时原样写回。偶数位字段的 `pad_nibble` 固定为最左半字节零；`F` 或其他非零填充不属于受支持的 IBM 格式，解码时拒绝。测试 `fidelity_test.mbt` 验证两种正号各自往返，`packed_standard_test.mbt` 验证标准对齐与非法填充。

### 2.2 zoned decimal（DISPLAY 数值）

`PIC S9(3)` 的符号覆盖末字节**高**半字节（`SIGN IS TRAILING`，默认）或首字节高半字节（`SIGN IS LEADING`）：

```
F1 F2 C3    123，末位符号 C（最常见）
F1 F2 F3    123，末位符号 F（未符号化写法，同样合法）
F1 F2 D3    -123，末位符号 D
```

同样是「数值相同、字节不同」。`SIGN IS SEPARATE` 则完全换一种布局：符号独占一字节（EBCDIC `0x4E` 是 `+`、`0x60` 是 `-`），数字字节一律 F 区：

```
F1 F2 F3 4E    123，符号字节 +
F1 F2 F3 60    -123，符号字节 -
```

三种符号布局（内嵌 TRAILING / 内嵌 LEADING / SEPARATE）各有测试。

### 2.3 浮点：HFP 的符号位与 ±0

IBM HFP 没有 IEEE 那种「负零是特殊值」的语义，但**符号位仍然存在**，所以 `+0` 与 `-0` 字节不同：

```
00 00 00 00    +0.0（COMP-1）
80 00 00 00    -0.0（COMP-1）
```

本项目保留符号位，让这两者各自往返（否则 `-0` 会被改成 `+0`）。COBOL 在比较语义上区分 `+0` 与 `-0` 的场合（例如某些 `IF` 条件），这个区别是可观察的。

### 2.4 浮点：HFP 与 IEEE 的字节完全不同

同一个 `1.5`：

```
41 18 00 00    IBM HFP（COMP-1，4 字节）
3F C0 00 00    IEEE 754 binary32
```

这不是"精度差异"，是**两种格式**。所以 `--float-mode` 必须显式声明（见 README「目标标准与兼容范围」）。误读不报错、只给错值——`41 18 00 00` 按 IEEE 读是 `9.5`，测试里有这条交叉误读的断言。

---

## 3. 哪些信息必须被保留

| 信息 | 载体 | 不保留会怎样 |
|---|---|---|
| 符号半字节（`C` / `F` / `D`） | `Decimal.sign_nibble` | `F` 正号被改写成 `C`，字节不一致 |
| **数值的负零**（zoned / packed） | `Decimal.negative` + `__nibbles.sign` | `-0` 变 `+0`：`F0 F0 D0` → `F0 F0 F0`、`00 0D` → `00 0C` |
| packed 前导填充零 | `Decimal.pad_nibble` | 偶数位字段必须在最左补零；非零填充拒绝 |
| 浮点符号位（含 ±0） | `Decimal` / `Float` 的符号 | `-0.0` 变 `+0.0` |
| 浮点格式（HFP / IEEE） | `RecordLayout.float_mode` | 数值完全错误 |
| 字段宽度与偏移 | `FieldLayout`（布局层算出） | 记录错位 |
| `FILLER` 占位 | 布局层推进游标，但不进输出 | 后续字段全部偏移错 |
| **REDEFINES 尾部空洞**（只有重定义视图覆盖、且该视图解不出的字节） | `__tail_hex`（JSONL 旁路）/ `__record_bytes`（内存路径） | `FF EE` 被静默改写成 `40 40` |
| **FILLER 中部空洞**（FILLER 区与叶子字段之间的裂缝） | `__filler_hex`（JSONL 旁路）/ `__record_bytes`（内存路径） | `C3 C4` 被静默改写成 `40 40` |

**负零为什么单独列一行**：整数型的 `0` 与 `-0` 数值相等，但 zoned / packed 的符号半字节不同，字节也就不同。走 `decode → JSONL → encode` 时，文本这一环靠不住——JSON 的数字是 double，`-0` 经核心 JSON 词法后原文不保留，放手写的 `-0` 也可能被折叠成 `0`。所以 **JSONL 里的 `__nibbles.sign` 是符号的权威来源**：`0xD` 就是负号，系数为 0 时同样生效。修复前这条旁路只被当作"写回哪个半字节"的提示，`decode` 出 `-0`、`encode` 回 `+0`，而 `verify`（内存路径，`Decimal.negative` 没丢）还报 `byte-identical roundtrip` —— 两条路径互相矛盾。回归测试在 `src/negative_zero_test.mbt`，同时锁定文本链路与 `verify` 两条路径的结论一致。

`FILLER` 那条值得单独说：它**占字节但不产值**，所以解码结果里没有它。字节保真由两条旁路承载（P1-2 修复后）：`verify`（内存路径）通过宽容解码附带的 `__record_bytes` 把 FILLER 区原样写回；`decode → JSONL → encode` 路径通过 `__filler_hex`（中部 FILLER 区，与 `__tail_hex` 同一手法，全 `0x40` 空格填充不携带）把这段字节带回编码器。JSONL 输出里仍然**不出现** FILLER 字段——旁路键是保留键，不是字段。

---

## 4. 默认写法（无字节来源时）

调用方自己构造的 `Decimal`（`Decimal::from_parts`）没有原始字节信息，编码按**文档化的默认规则**写。这是契约，有测试锁定：

| 场景 | 默认符号 |
|---|---|
| packed，有符号（`PIC S9(n) COMP-3`），正 | `0xC` |
| packed，有符号，负 | `0xD` |
| packed，**无符号**（`PIC 9(n) COMP-3`），正 | `0xF`（IBM 标准约定，不是 `0xC`） |
| zoned，正 | `0xF` |
| zoned，负 | `0xD` |
| packed 填充半字节 | `0x0` |
| 文本不足宽度 | 补空格 `0x40` |

注意「无符号 packed 用 `0xF`」这条：**默认写 `0xF`，但读到 `0xC` 时原样保留**。两者不矛盾——默认值是"我造值时的选择"，保真是"我照抄记录里的字节"。

---

## 5. 已知的信息丢失边界

诚实列出**做不到**字节级往返的地方。这些不涉及原始记录字节，只在跨类型转换时发生：

### 5.1 `COMP-2` 的 56 位尾数 → `Double` 的 53 位

IBM HFP 的 `COMP-2` 尾数是 **56 位**，比 IEEE `double` 的 53 位多 3 位。所以：

- **`Double` → HFP `COMP-2` 编码：精确**（`S << w` 是移位，无舍入）
- **HFP `COMP-2` → `Double` 解码：若原始尾数低 3 位非零，按最近偶数舍入丢掉**

例：某个 `COMP-2` 值在主机上能区分 `1.0000000000000002` 与 `1.0000000000000004`，转成 `Double` 后可能合并。这是 `Double` 类型本身的表达能力所限，不是实现缺陷。

**影响范围**：只影响「主机 `COMP-2` 值读进 `Double`」这一跨界。原始记录字节不受影响——`verify`（内存内 decode→encode）在这类记录上**会报告字节差异**并返回退出码 1，而不是假装一致。

### 5.2 `COMP-1` 的 24 位尾数

`COMP-1` 尾数 24 位 < 53 位，**双向都精确**，无丢失。

### 5.3 HFP 的范围边界

| 边界 | 值 | 处理 |
|---|---|---|
| 最小可表示 | `2^-260`（`16^-64 × 2^-4`） | 更小则下溢，**报错**（不静默截断） |
| 最大可表示 | 约 `2^308` | 更大则上溢，**报错** |
| `NaN` / `±Infinity` | 不存在 | 编码时**报错**，不写垃圾字节 |

### 5.4 严格性选择

`decode_record`（宽容版）对 **REDEFINES 视图**解码失败只填 `Null` 不报错；`decode_record_strict`（严格版）任何视图失败都报错。**`verify`（roundtrip_check）用的是宽容版**——主视图失败照样报错（数据真坏了），重定义视图失败置 Null、由尾部字节旁路（`__tail_hex`）保住超出主视图的字节；这与本文件第 3 节的保真机制配套。`decode_record_strict` 留给想证明「每个视图都自洽」的调用方。

### 5.5 REDEFINES 尾部空洞

重定义视图可以比主视图长（布局层把记录延长到 `max(主视图, 视图)`）。超出主视图的字节只有重定义视图覆盖；当该视图解不出（置 `Null`）时，这些字节由 `__tail_hex` 旁路携带：`render_jsonl` 以小写十六进制写出（全 `0x40` 空格填充除外——那是「未赋值工作存储区」惯例），`parse_jsonl_row` / `encode_record` 按空洞区间原样回填。主视图字段之间的**中部**空洞（FILLER、手工布局裂缝）由 `__filler_hex` 旁路按同一规则携带（P1-2），见第 3 节 FILLER 说明。

---

## 6. 怎么自己验证

```bash
# L1：内存内 decode→encode 逐字节比对（严格版，覆盖 REDEFINES 全部视图）
copybook verify --copybook app.cpy --data app.dat

# L1：经过 JSON 文本的真实工作流（FILLER 非空格字节经 __filler_hex 旁路保真）
copybook decode --copybook app.cpy --data app.dat --format jsonl > out.jsonl
copybook encode --copybook app.cpy --json out.jsonl --out roundtrip.dat
cmp app.dat roundtrip.dat

# 浮点数据要声明格式，否则 verify 会给出错误的字节差异
copybook verify --copybook app.cpy --data app.dat --float-mode ieee
```

代码层面：`src/fidelity_test.mbt` 是这一节所有断言的实现，`moon test` 直接覆盖。
