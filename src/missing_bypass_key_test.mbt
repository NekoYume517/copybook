// CB-20-3（2026-11-28 第二十轮审计）：**删除旁路键 → 空洞字节被静默写成 0x40**。
//
// ## 缺陷形态（修复前实测，native 二进制）
//
//     copybook:  01 R. 05 M PIC S9(4) COMP-3. 05 A REDEFINES M. 10 RAW PIC X(4).
//     记录:      01 23 4C 99        主视图 M 占 0..3，尾部空洞 [3,4)
//
//     $ copybook decode --copybook n.cpy --data n.dat
//     {"R.M":1234,"R.A.RAW":null,"__nibbles":{...},"__tail_hex":"99","__tail_gap":[[3,4]]}
//     $ copybook encode --copybook n.cpy --json <删掉 __tail_hex / __tail_gap 之后的行>
//     encoded 1 record(s), 4 bytes -> bare.dat      exit 0
//     bare.dat = 01-23-4C-40     ← 第 4 字节 0x99 被改成 0x40，**零提示**
//
// 同一份布局上，`__tail_gap` 单独存在（缺字节）是会报错的；反过来「字节
// 整块缺席」没有任何对账。这是 NEW-5 / NEW-6「静默降级」家族的第三个入口：
// 前两个是「键内容损坏」与「已知字段收到对象」，这个是「键整块缺席」。
//
// ## 为什么不能简单地对「有空洞却没载体」报错
//
// decode 有一条**合法**路径完全不发旁路键：空洞字节全是 0x40（「未赋值
// 工作存储区」惯例）。`redefines_tail_test.mbt` / `filler_fidelity_test.mbt`
// 锁的就是它 —— 那种行缺少载体是对的，写回 0x40 与原记录逐字节相同。
//
// 真正能区分两者的信号是**视图解出的值**：`aws 01 R. 05 M COMP-3(4). 05 A
// REDEFINES M. 10 RAW X(4).` 这类布局里，尾部空洞正是靠视图读出内容才会
// 让 decode 认为「这里有数据」。所以判据收紧到：
//
//   **行里有视图值指向某段空洞，而这段空洞没有任何字节载体** → 报错。
//
// 「视图值指向」的定义与 `field_will_write` 同源（不另立口径）：视图值为
// `Null`、或数值类字段上的空串 → 视图不写、也不构成「有值」，此时空洞
// 字节确实没被解出来，缺载体就是数据缺失。反之视图有值而快照缺席，说明
// 这份 JSONL 被人动过（手写、过滤 `__` 键、或只保留了另一半），必须拒绝。

///|
fn cb203_tail_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n    05 M PIC S9(4) COMP-3.\n    05 A REDEFINES M.\n       10 RAW PIC X(4).\n",
    ),
  )
}

///|
test "CB-20-3: 删掉 __tail_hex 之后 encode 必须报错，不许静默写 0x40" {
  let layout = cb203_tail_layout()
  inspect(layout.byte_length, content="4")
  // 1) 完整快照：逐字节往返（基线，不能被这条收紧打破）
  let full = parse_jsonl_row(
    layout, "{\"R.M\":1234,\"R.A.RAW\":null,\"__nibbles\":{\"R.M\":{\"sign\":12,\"pad\":0}},\"__tail_hex\":\"99\",\"__tail_gap\":[[3,4]]}",
  ).unwrap()
  let encoded = encode_record(layout, full).unwrap()
  inspect(encoded[3].to_int(), content="153")
  // 2) 唯一承载 0x99 的键被摘掉 → 修复前 exit 0、第 4 字节变 0x40
  let bare = parse_jsonl_row(
    layout, "{\"R.M\":1234,\"R.A.RAW\":null,\"__nibbles\":{\"R.M\":{\"sign\":12,\"pad\":0}}}",
  ).unwrap()
  match encode_record(layout, bare) {
    Ok(bytes) =>
      fail(
        "缺少 __tail_hex 时不得静默写 0x40；实际写出 \{bytes[3].to_int()}（应为报错）",
      )
    Err(InvalidBypass(detail)) => {
      assert_true(detail.contains("__tail_hex"))
      // 报错要能定位：点名是**尾部空洞**的字节
      assert_true(detail.contains("tail"))
    }
    Err(other) => fail("应当是 InvalidBypass，实际 \{other.to_display()}")
  }
}

///|
test "CB-20-3: 中部 FILLER 洞缺 __filler_hex 同样报错" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n    05 A PIC X(2).\n    05 FILLER PIC X(2).\n    05 B PIC X(1).\n",
    ),
  )
  let ok = parse_jsonl_row(
    layout, "{\"R.A\":\"AB\",\"R.B\":\"C\",\"__filler_hex\":\"f1f2\",\"__filler_gap\":[[2,4]]}",
  ).unwrap()
  let b = encode_record(layout, ok).unwrap()
  inspect(b[2].to_int(), content="241")
  let bare = parse_jsonl_row(layout, "{\"R.A\":\"AB\",\"R.B\":\"C\"}").unwrap()
  match encode_record(layout, bare) {
    Ok(_) => fail("缺少 __filler_hex 时不得静默写 0x40")
    Err(InvalidBypass(detail)) => assert_true(detail.contains("__filler_hex"))
    Err(other) => fail("应当是 InvalidBypass，实际 \{other.to_display()}")
  }
}

///|
test "CB-20-3: 不误伤 —— 视图被编辑成有值后缺载体不报错" {
  // 视图从 Null 改成 "WXYZ" → 空洞被字段值覆盖，字节由字段生成，
  // 旁路键本来就该缺席（decode 也不会给被值覆盖的位置发快照）。
  let layout = cb203_tail_layout()
  let row = parse_jsonl_row(layout, "{\"R.M\":1234,\"R.A.RAW\":\"WXYZ\"}").unwrap()
  let b = encode_record(layout, row).unwrap()
  // "WXYZ" = 0xE6 E7 E9 E8，第 3 字节是 'Z'
  inspect(b[3].to_int(), content="233")
}

///|
test "CB-20-3: 不误伤 —— 空洞被字段值覆盖的那一段缺载体不报错" {
  // 同一份布局上做两个对照，证明判据看的是**每一个字节**而不是「整条行有没有
  // 快照」：
  //   - V2 有值（覆盖整段 0..4）→ 空洞集为空，缺快照合法；
  //   - 只给 V（覆盖 0..2）且 V2 为 null → [2,4) 没有任何值解释，必须报错。
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n    05 M PIC S9(3) COMP-3.\n    05 V REDEFINES M PIC X(2).\n    05 V2 REDEFINES M PIC X(4).\n",
    ),
  )
  // 1) 覆盖整段：不报错
  let covered = parse_jsonl_row(layout, "{\"R.M\":123,\"R.V2\":\"ABCD\"}").unwrap()
  match encode_record(layout, covered) {
    Ok(b) => inspect(b[3].to_int(), content="196")
    Err(e) =>
      fail(
        "视图覆盖了整段空洞，不该报缺载体: \{e.to_display()}",
      )
  }
  // 2) 只覆盖前半：后半 [2,4) 无人解释 → 必须报错
  let half = parse_jsonl_row(layout, "{\"R.M\":123,\"R.V\":\"AB\"}").unwrap()
  match encode_record(layout, half) {
    Ok(_) =>
      fail("V2 为 null 时 [2,4) 没有字节来源，不得静默补 0x40")
    Err(InvalidBypass(detail)) => assert_true(detail.contains("no carrier"))
    Err(e) => fail("应当是 InvalidBypass，实际 \{e.to_display()}")
  }
}
