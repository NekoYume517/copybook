# 报名复审补充说明

> 本文件是**第二轮复审**（2026-10-30）提交的材料，逐条回应初审驳回意见。
> 仓库：<https://github.com/NekoYume517/copybook> · 发布包：<https://mooncakes.io/docs/NekoYume517/copybook>
> 当前 HEAD：`869de1e` · 测试 **367 / 367** · CI 四门全绿

---

## 〇、对初审两条意见的结论

| 初审意见 | 是否成立 | 处理方式 |
|---|---|---|
| 「COMP-3 关键案例不符合 IBM 布局语义」 | **成立** | 申报书案例写错，已按实测更正（实现本来就是对的） |
| 「'所有支持类型逐字节往返' 与 COMP-2 转 Double 丢精度相矛盾」 | **成立** | **修实现**：新增 `FloatRaw` + `__float_hex` 旁路，L1 真正覆盖 COMP-2 |

第二条不是文字问题而是实现缺口，所以本轮**先改代码、后改文档**。

---

## 一、意见 1：COMP-3 案例更正

**IBM 布局规则**：n 位数字 + 1 符号半字节 = n+1 半字节，向上取整到整字节；奇数位时**最左半字节补 0**；符号半字节在**最右**低 4 位。

`PIC 9(4) COMP-3` = 4 位数字 + 符号 = 5 半字节 → **3 字节**。

### 初版申报书的错误案例（已废弃）

```
12 34 0C     ← 前导半字节是 1，不是填充 0
12 34 FC
12 34 0F
```

这三个字节**不符合 IBM 布局**：`9(4)` 只有 4 位数字，塞进 7 个半字节不合语义。实测该实现直接拒收：

```
$ copybook decode --copybook v.cpy --data 12340c.dat --format jsonl
decode: invalid numeric at offset 0: packed leading pad nibble must be zero
exit=1
```

### 更正后的正确案例（实测）

```
$ printf '\x01\x23\x4c' > v.dat && copybook decode --copybook v.cpy --data v.dat --format jsonl
{"R.V":1234,"__nibbles":{"R.V":{"sign":12,"pad":0}}}

$ printf '\x01\x23\x4f' > v.dat && copybook decode --copybook v.cpy --data v.dat --format jsonl
{"R.V":1234,"__nibbles":{"R.V":{"sign":15,"pad":0}}}
```

两条合法写法数值都是 1234、字节不同，各自往返保真。**只有 5 位数字的字段**（如 `PIC S9(5)V99 COMP-3`，4 字节）才会出现"数字占满、无填充"的形态 `01 23 45 6C`。

### 符号半字节三值

| 半字节 | 含义 | 谁写的 |
|---|---|---|
| `0xC` | 正 | 最常见的编译器输出 |
| `0xF` | 正 | IBM 对**无符号**字段的约定写法 |
| `0xD` | 负 | 唯一负号写法 |

`Decimal` 携带 `sign_nibble` / `pad_nibble` 保存 decode 实际读到的半字节，encode 优先原样写回，JSONL 经 `__nibbles` 旁路键携带。

---

## 二、意见 2：COMP-2 字节保真缺口（已修实现）

### 问题复现

`COMP-2` 尾数 **56 位**，`Double` **53 位**：

```
$ printf '\x41\x80\x00\x00\x00\x00\x00\x01' > d.dat     # F = 2^55 + 1
$ copybook verify --copybook d.cpy --data d.dat
verify: record 0: byte mismatch at offset 7
exit=1
```

decode 得 `8.0`（低 3 位被舍入），重编码写回 `41 80 00 00 00 00 00 00` —— **L1 在 COMP-2 上确实不成立**，而文档却写"所有字段类型"。初审这条意见指得准确。

### 修复：原始字节旁路

与既有 `__nibbles` / `__tail_hex` / `__filler_hex` 完全同构：

```moonbit
pub(all) enum CellValue {
  ...
  Float(Double)                    // 尾数低 3 位全零：Double 能精确承载
  FloatRaw(Double, Bytes)          // 尾数低 3 位非零：额外挂原始 8 字节
}
```

| 环节 | 行为 |
|---|---|
| decode | 尾数低 3 位非零 → `FloatRaw(近似值, 原始字节)`；全零 → 普通 `Float` |
| encode | `FloatRaw` + `Hfp` 模式 → **原样写回**，不重新计算；`Ieee754` 模式 → 按数值重编码 |
| JSONL | 保留键 `__float_hex`：`{"R.D":"4180000000000001"}`，`parse_jsonl_row` 还原 |

### 修复后实测

```
$ copybook decode --copybook d.cpy --data d.dat --format jsonl
{"R.D":8,"__float_hex":{"R.D":"4180000000000001"}}

$ copybook verify --copybook d.cpy --data d.dat
verify: 1 record(s) OK, byte-identical roundtrip
exit=0
```

端到端（走真实文件 + JSONL）同样恒等：

```
原始:    41 80 00 00 00 00 00 01
JSONL:   {"R.D":8,"__float_hex":{"R.D":"4180000000000001"}}
往返后:  41 80 00 00 00 00 00 01
```

**可精确表示的 COMP-2 不写 `__float_hex`**，真实数据的绝大多数输出保持不变。

### 回归测试有效性

`src/comp2_precision_test.mbt` 4 条：超精度往返恒等、可精确表示不挂旁路、JSONL 旁路、可精确表示不写键。

**临时回退 encode 分支后其中 3 条实测变红**（`Some(7) != None`、`0 != 1`），恢复即转绿 —— 覆盖有效性经反向验证，不是只写在文档里的承诺。

---

## 三、保真的准确定义（矛盾已消除）

`FIDELITY.md` 第 1 节：

| 级别 | 性质 | 保证范围 |
|---|---|---|
| **L1 字节级** | `encode(decode(bytes)) == bytes` | **全部支持字段类型**，含 COMP-1/COMP-2。凡 `Double` / 文本表达不出的原始字节都由旁路携带 |
| **L2 数值级** | 新建值按文档化默认规则编码 | 有测试锁定的契约 |

四条旁路键一览：

| 旁路键 | 承载什么 | 不保留会怎样 |
|---|---|---|
| `__nibbles` | 符号半字节 / packed 填充半字节 | `01 23 4F` → `01 23 4C`；`-0` → `+0` |
| `__tail_hex` | REDEFINES 视图独占的尾部字节 | `FF EE` → `40 40` |
| `__filler_hex` | FILLER 中部空洞字节 | `C3 C4` → `40 40` |
| `__float_hex` | 超 `Double` 精度的 COMP-2 尾数 | `...01` → `...00`（CB-21） |

### 仍然存在的边界（如实说明，不影响 L1）

- **数值精度**：两个只差尾数低 3 位的 COMP-2 值，读成 `Double` 后数值会合并。`.f` 字段是近似值，**精确值以 `__float_hex` 为准**。这是 `Double` 类型表达能力所限。
- **HFP 范围**：最小 `2^-260`、最大约 `2^308`；新建值超界报错不静默截断；NaN / ±Infinity 不存在，写入报错。
- **非法输入一律拒收**：非规格化尾数、非法符号半字节、packed 前导填充非零 —— 报错并给绝对字节偏移，不猜着解。

---

## 四、验证

```
moon check                  0 error（42 warnings 为既有 deprecation 提示）
moon fmt --check            通过
moon test                   367 / 367 passed
moon test --release         367 / 367 passed
moon build --target wasm   通过
```

- CI（GitHub Actions，Linux runner）：check → fmt → test --release → build wasm，HEAD `869de1e` **success**
- **远端干净克隆复跑四门通过**（367/367），确认无漏传文件
- README / `docs/DEMO.md` 全部命令逐条实测
- mooncakes 发布 `NekoYume517/copybook@0.1.0`，独立消费者工程 `moon add` + 真实调用三包核心 API 验证可用

本轮新增/修改：

- 新增 `src/comp2_precision_test.mbt`（4 条回归）
- 修改 `src/decode.mbt`（`FloatRaw` 判定）、`src/encode.mbt`（原字节优先写回）、`src/jsonl.mbt`（`__float_hex` 解析）、`src/output.mbt`（`__float_hex` 输出）
- 修改 `src/hfp_denormal_test.mbt`（CB-19 测试前提随修复变更，改为验证新契约）
- 文档：`FIDELITY.md` 第 5 节改写、`README.md` 浮点保真段、`PLAN.md`、`docs/DEMO.md`

---

## 五、可直接粘进报名表的一段话

> **目标**：IBM 大型机（z/OS）定长记录。EBCDIC cp037、COMP-3 打包十进制、COMP 二进制补码、IBM HFP 十六进制浮点；COBOL-85 数据描述子集 + IBM Enterprise COBOL 扩展，不含过程部语义。
>
> **COMP-3 布局语义**：n 位数字 + 1 符号半字节，奇数位时最左半字节补 0。`PIC 9(4) COMP-3` 占 3 字节，数值 1234 的合法写法是 `01 23 4C` / `01 23 4F`（前导半字节必须为 0）；不合布局的字节如 `12 34 0C` 被明确拒收并报偏移，不猜着解。实测输出见上文。
>
> **字节保真**：承诺 `encode(decode(bytes)) == bytes` 覆盖全部支持字段类型。凡 `Double` 或 JSON 文本表达不出的原始字节，都由旁路键携带——`__nibbles`（符号/填充半字节）、`__tail_hex`（REDEFINES 尾部）、`__filler_hex`（FILLER 空洞）、`__float_hex`（超 `Double` 精度的 COMP-2 尾数）。
>
> **COMP-2 精度**：主机尾数 56 位 > `Double` 53 位。decode 对低 3 位非零的值产出 `FloatRaw(数值, 原始字节)`，encode 原样写回，实测 `41 80 00 00 00 00 00 01` 经 `decode → JSONL → encode` 逐字节恒等，`verify` 报告 `byte-identical`。`.f` 字段数值为近似值，精确值以 `__float_hex` 为准。这一条原先是实现缺口，本轮已修。
>
> **验证**：367 / 367 测试（debug 与 release 双模式）、四门 CI 全绿、远端干净克隆复跑通过、mooncakes 已发布并用独立消费者工程验证可用。回归测试有效性经"回退实现即变红"反向验证。