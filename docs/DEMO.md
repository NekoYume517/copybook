# 演示与复现

评审可以直接按顺序跑下面每一步。所有命令都在仓库根目录执行，不需要网络、不需要额外数据。

## 环境

```bash
# MoonBit 工具链
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
moon version   # 期望 0.1.20261012 或更新
```

Windows：

```powershell
# 安装后
$env:MOON_HOME="$env:USERPROFILE\.moon"
$env:Path="$env:MOON_HOME\bin;"+$env:Path
moon version
```

## 一、clone 后立刻能跑的三条命令

```bash
moon check     # 类型检查，0 error
moon test      # 229 个测试，全绿
moon build --target wasm
```

预期输出（`moon test`）：

```
Total tests: 229, passed: 229, failed: 0.
```

## 二、看字节布局（这是项目最有说服力的输出）

```bash
moon run cmd/copybook -- layout --copybook examples/customer.cpy
```

预期：

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

**可以验证的点**：`S9(7)V99 COMP-3` 占 5 字节（`ceil((7+2+1)/2)`），`FLAGS` 组的两个子字段在 offset 51 和 52，总计正好 54。

## 三、解码真实 EBCDIC 数据

```bash
moon run cmd/copybook -- decode --copybook examples/customer.cpy --data examples/customer.dat --format table
```

预期：

```
CUST-ID  CUST-NAME      BALANCE     OPEN-DATE  ACTIVE  TIER
-------  -------------  ----------  ---------  ------  ----
   1001  ADA LOVELACE   1234567.89   20240115  Y          3
   1002  ALAN TURING     -98765.43   20230602  Y          1
   1003  GRACE HOPPER         5.00   19920101  N          5
   1004  K JOHNSON            0.00   20201231  Y          2
   1005  J VON NEUMANN       -0.01   19550608  N          4
```

**可以验证的点**：
- 负数通过 COMP-3 的符号半字节（`0xD`）正确解出
- `-0.01` 是最小非零负值，边界正确
- 名字尾部有 EBCDIC 空格填充（`0x40`），被正确 trim

## 四、往返自检

```bash
moon run cmd/copybook -- verify --copybook examples/customer.cpy --data examples/customer.dat
```

预期：

```
verify: 5 record(s) OK, byte-identical roundtrip
```

## 五、完整工作流（decode → JSON → encode）

```bash
moon run cmd/copybook -- decode --copybook examples/customer.cpy --data examples/customer.dat --format jsonl > out.jsonl
moon run cmd/copybook -- encode --copybook examples/customer.cpy --json out.jsonl --out roundtrip.dat
```

然后比较两个文件：

```bash
cmp examples/customer.dat roundtrip.dat && echo "byte identical"
```

Windows：

```powershell
(Get-FileHash examples/customer.dat).Hash -eq (Get-FileHash roundtrip.dat).Hash
```

**这是本项目最容易被忽略、但最容易出错的一条路径**：JSON 没有定点小数类型，`5.00` 会序列化成 `5`。编码器按 PIC 声明的 scale 还原，所以仍然写回 500 分而不是 5 分。这条路径有专门的回归测试（`src/json_roundtrip_test.mbt`），因为早期版本在这里有过 100 倍的数据损坏。

## 六、数据的来源可以审计

`examples/customer.dat` 不是手搓的，也不是 MoonBit 代码生成的：

```bash
python3 scripts/gen_copybook_data.py
```

这个脚本自己实现了 cp037 码表、zoned decimal、COMP-3 打包，**与 MoonBit 实现零共享代码**。所以两边结果一致是真正的交叉验证，而不是同一份逻辑跑两遍。

## 七、错误处理演示

```bash
# 空数据文件
moon run cmd/copybook -- decode --copybook examples/customer.cpy --data empty.dat
# → decode: data file 'empty.dat' is empty (expected 54-byte records)   exit 1

# 记录长度不匹配
moon run cmd/copybook -- decode --copybook examples/customer.cpy --data short.dat
# → decode: record too short: expected 54 bytes, got 20   exit 1

# 文件不存在
moon run cmd/copybook -- layout --copybook nope.cpy
# → cannot read copybook 'nope.cpy'   exit 1

# 参数缺失（用法错误）
moon run cmd/copybook -- decode --data examples/customer.dat
# → decode: --copybook is required   exit 2

# 参数拼错（用法错误）
moon run cmd/copybook -- decode --copybook examples/customer.cpy --data examples/customer.dat --format json
# → decode: unknown --format 'json' (expected jsonl or table)   exit 2
```

退出码约定：`0` 成功 / `1` 数据错误（含文件不存在、内容不合法）/ `2` 用法错误（参数缺失或拼错）。

**空文件返回 1 而不是 0** 是有意的：解码 0 条记录不是成功，而是「没有数据可解」。静默返回 0 会让脚本误以为文件正常。

## 八、其他两份 copybook

```bash
# OCCURS 展开：98 字节 = 10 + 3 + 5 × 17
moon run cmd/copybook -- layout --copybook examples/order.cpy

# REDEFINES：29 字节，两个字段共享 offset 14
moon run cmd/copybook -- layout --copybook examples/redefines.cpy
```

`order.cpy` 的关键验证点：`QTY PIC S9(4) COMP` 是 **1 字节**（n≤4 → 1），如果算成 2 字节，整条记录会变成 103 而不是 98。

`redefines.cpy` 的关键验证点：`LIMIT-AMT` 和 `ALT-VIEW.RAW-BYTE` 都在 offset 14、各 6 字节，**不累加**。用「父组求和」的朴素实现会算出 35 而不是 29。

## 九、测试覆盖了哪些边界

```bash
moon test
```

值得单独看的几个测试文件：

| 文件 | 覆盖内容 |
|---|---|
| `src/ebcdic_test.mbt` | cp037 全 256 项往返 |
| `src/layout_test.mbt` | 每种 PIC / USAGE 组合的字节数 |
| `src/layout_examples_test.mbt` | 三份 examples 的布局逐字符比对 |
| `src/decode_test.mbt` | zoned / packed / COMP 的正负数与边界 |
| `src/encode_test.mbt` | 500 条随机记录字节级往返 |
| `src/json_roundtrip_test.mbt` | 经过 JSON 文本的往返（含 5.00 回归） |
| `src/output_test.mbt` | JSONL / 表格 / 布局报告的格式 |

## 十、看到这里还没被说服？

`docs/implementation.md` 记录了 8 个实现过程中真实踩到的算术陷阱，每一条都对应一个曾经算错的具体数字（比如 REDEFINES 算出 35、`S9(4) COMP` 算成 2 字节）。这些不是假设性问题，是实际发生并被测试锁住的。
