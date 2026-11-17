// 2026-11-17 审计 C13：`roundtrip_check` 对「记录长于布局」的输入给出自相矛盾
// 的结论。
//
// ## 缺陷形态
//
// `decode_record` **接受**长于布局的输入（只查过短，`decode.mbt` 的
// `record.length() < layout.byte_length`），因为真实文件里每条记录可能带
// RDW/BDW 头或自定义尾部填充（API.md §7 的 `--record-length` 语义）。
// 但 `roundtrip_check` 逐字节比到 `record.length()`，然后发现
// `reencoded.length() != n`（encode 恒写 `byte_length` 字节）就返回
// `Some(n)` —— 被读成「第一个不同字节在 N」，而实际是「布局之外的字节没被看过」。
//
// CLI 早就发现这个坑：`cmd_verify` 自己按 `check_len = min(rec_len, byte_length)`
// 切片再喂进来（`main.mbt` 的注释写得很清楚）。也就是说「必须由调用方先切片」
// 是**只在 main.mbt 里成立**的隐含前提，库级调用方一脚就踩进去。
//
// 裁决（本轮 Lead 拍板）：`roundtrip_check` 只比较布局覆盖的前 `byte_length`
// 字节，与 `decode_record` 接受长输入的行为对齐；API.md 写明「超出布局长度的
// 尾部字节不参与往返比较，调用方需自行切片」。

///|
fn c13_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC X(10).\n"))
}

///|
test "C13: trailing bytes outside the layout are not compared" {
  let layout = c13_layout()
  inspect(layout.byte_length, content="10")
  // 10 字节记录 + 2 字节布局外的尾部（RDW/自定义填充的形态）
  let rec = bs([
    0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD1, 0x00, 0x01,
  ])
  match roundtrip_check(layout, rec) {
    Ok(None) => ()
    Ok(Some(off)) =>
      fail(
        "trailing bytes outside the layout must not be compared, got mismatch at \{off}",
      )
    Err(e) => fail("roundtrip must not error: \{e.to_display()}")
  }
}

///|
test "C13: a real difference inside the layout is still reported" {
  // 反向锁：布局内的差异必须照旧定位到第一个不同字节。
  let layout = c13_layout()
  let rec = bs([
    0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD1, 0x00, 0x01,
  ])
  // 先写一条内容不同的 JSONL，再比字节：用 decode→encode 的结果对照
  let row = decode_record(layout, rec).unwrap()
  match encode_record(layout, row) {
    Ok(b) => assert_eq(b.length(), layout.byte_length)
    Err(e) => fail("encode must succeed: \{e.to_display()}")
  }
  // 布局内改一个字节：第 3 字节换成不可打印 → decode 先失败（数据真坏）
  let bad = bs([0xC1, 0xC2, 0x00, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD1])
  match roundtrip_check(layout, bad) {
    Err(_) => ()
    Ok(_) => fail("broken data inside the layout must be reported")
  }
}
