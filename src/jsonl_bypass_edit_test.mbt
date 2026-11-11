// 审计回归（2026-11-11）：编辑 REDEFINES 视图时，decode 写出的
// `__tail_hex` / `__filler_hex` 快照会反过来把编辑卡死。
//
// 场景（tail）：
//
//     01 R.  05 A PIC X(4).  05 V REDEFINES A PIC X(6).
//
// 记录 `F1F2F3F4 FF EE`：A 解成 "1234"，V 因 FF/EE 不是可打印 EBCDIC
// 而置 Null；超出 A 的两字节由 `__tail_hex:"ffee"` 承载。
// 用户在 JSONL 里把 V 改成 `"ABCDEF"`（合法的编辑工作流），`__tail_hex`
// 作为行尾快照原样留着。修复前 encode 报：
//
//     __tail_hex must be exactly 0 byte(s) for this record's tail gap(s), got 2
//
// —— 与 CB-16 / RJ-3 同族：**旁路快照压过用户编辑**。`__filler_hex`
// 在视图覆盖 FILLER 区时同样。
//
// 正确语义：快照的有效长度是「把所有视图当成不写」时的空洞集（超集）；
// 用户把某个视图写成非 Null 后，空洞集收缩，快照中对应位置的字节应当
// 被丢弃，而不是让整条记录失败。长度既不等于当前空洞、也不等于超集
// 空洞时，仍按 CB-A2 报损坏。

///|
fn jbe_encode(
  line : String,
  cb : String,
) -> Result[Bytes, String] raise ParseError {
  let layout = compile_layout(parse_copybook(cb))
  match parse_jsonl_row(layout, line) {
    Err(e) => Err(e)
    Ok(row) =>
      match encode_record(layout, row) {
        Err(e) => Err(e.to_display())
        Ok(b) => Ok(b)
      }
  }
}

///|
fn jbe_bs(a : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in a {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "editing a Null view over a tail gap must not be blocked by __tail_hex" {
  let cb = "01 R.\n  05 A PIC X(4).\n  05 V REDEFINES A PIC X(6).\n"
  let layout = compile_layout(parse_copybook(cb))
  let rec = jbe_bs([0xF1, 0xF2, 0xF3, 0xF4, 0xFF, 0xEE])
  let row = decode_record(layout, rec).unwrap()
  let line = render_jsonl(layout, [row]).trim_end().to_string()
  assert_true(line.contains("__tail_hex"))
  let edited = line.replace(old="\"R.V\":null", new="\"R.V\":\"ABCDEF\"")
  match jbe_encode(edited, cb) {
    Ok(bs) => {
      // V 是 X(6)：写 "ABCDEF" 会覆盖 0..6 全部字节（视图后写）
      let want6 = jbe_bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6])
      assert_eq(bs, want6)
    }
    Err(e) => fail("editing the view must encode, got: \{e}")
  }
}

///|
test "editing a Null view over a FILLER gap must not be blocked by __filler_hex" {
  let cb = "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(2).\n  05 V REDEFINES A PIC X(4).\n  05 B PIC X(2).\n"
  let layout = compile_layout(parse_copybook(cb))
  let rec = jbe_bs([0xC1, 0xC2, 0x00, 0x01, 0xC5, 0xC6])
  let row = decode_record(layout, rec).unwrap()
  let line = render_jsonl(layout, [row]).trim_end().to_string()
  assert_true(line.contains("__filler_hex"))
  let edited = line.replace(old="\"R.V\":null", new="\"R.V\":\"ABCD\"")
  match jbe_encode(edited, cb) {
    Ok(bs) => assert_eq(bs, jbe_bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6]))
    Err(e) => fail("editing the view must encode, got: \{e}")
  }
}

///|
test "a corrupt bypass length is still rejected (CB-A2 stays)" {
  let cb = "01 R.\n  05 A PIC X(4).\n  05 V REDEFINES A PIC X(6).\n"
  // V=null 时当前空洞 2 字节、超集也 2 字节；3 字节既不是当前也不是超集
  match
    jbe_encode("{\"R.A\":\"1234\",\"R.V\":null,\"__tail_hex\":\"ffee00\"}", cb) {
    Err(e) => assert_true(e.contains("exactly 2 byte(s)"))
    Ok(_) => fail("a 3-byte tail bypass for a 2-byte gap must be rejected")
  }
}
