// 公开手工布局：五条入口同一份边界判据（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `check_layout_encode_bounds` 是公开布局（`RecordLayout` / `FieldLayout` 都是
// `pub(all)`，库用户可手建）唯一的区间 / OCCURS 跨度不变量守卫。C1 把它接到
// `decode_record_impl`（→ `decode_record` / `decode_record_strict`）与
// `encode_record`，`roundtrip_check` 走 decode+encode 自然也接上；但
// `decode_record_ordered`（`pub`，给需要稳定列序的调用方/表格类用法）漏了：
//
//   occurs=3、byte_length=2、total_length=0 的布局
//   decode_record          → Err field ... out of bounds
//   decode_record_strict   → Err
//   encode_record          → Err
//   roundtrip_check        → Err
//   decode_record_ordered  → **Ok 3 个值**（读的是 6 字节，跨度声明说 0）
//
// 同一份布局，第五条入口给出与另外四条相反的结论。`occurs=0`、负
// `total_length`、负 `byte_length` 这类形态同理。
//
// 修法：`decode_record_ordered` 入口先跑同一个 `check_layout_encode_bounds`；
// 一致性由下面的矩阵锁死。

///|
fn entry_layout(
  byte_length : Int32,
  offset : Int32,
  elem_len : Int32,
  occurs : Int32,
  total_length : Int32,
) -> RecordLayout raise ParseError {
  let base = compile_layout(parse_copybook("01 R.\n    05 A PIC X(2).\n"))
  let f = base.fields[0]
  {
    ..base,
    byte_length,
    fields: [{ ..f, offset, byte_length: elem_len, occurs, total_length, }],
  }
}

///|
/// 五条入口对同一布局的结论必须一致：要么全 Ok，要么全 Err。
fn assert_all_entries_reject(
  label : String,
  layout : RecordLayout,
  record : Bytes,
) -> Unit raise Failure {
  match decode_record(layout, record) {
    Ok(_) => fail("\{label}: decode_record accepted a layout it must reject")
    Err(_) => ()
  }
  match decode_record_strict(layout, record) {
    Ok(_) => fail("\{label}: decode_record_strict accepted")
    Err(_) => ()
  }
  match decode_record_ordered(layout, record) {
    Ok(_) => fail("\{label}: decode_record_ordered accepted")
    Err(_) => ()
  }
  let row : Map[String, CellValue] = Map([])
  match encode_record(layout, row) {
    Ok(_) => fail("\{label}: encode_record accepted")
    Err(_) => ()
  }
  match roundtrip_check(layout, record) {
    Ok(_) => fail("\{label}: roundtrip_check accepted")
    Err(_) => ()
  }
}

///|
test "layout invariant: all five entries accept a consistent layout" {
  let layout = entry_layout(6, 0, 2, 3, 6)
  let record = b"\xC1\xC2\xC3\xC4\xC5\xC6"
  let row = decode_record(layout, record).unwrap()
  let strict = decode_record_strict(layout, record).unwrap()
  let ordered = decode_record_ordered(layout, record).unwrap()
  assert_eq(ordered.length(), 3)
  assert_eq(row.get("R.A(1)").unwrap().to_display(), "AB")
  assert_eq(strict.get("R.A(2)").unwrap().to_display(), "CD")
  assert_eq(ordered[2].to_display(), "EF")
  let back = encode_record(layout, row).unwrap()
  assert_eq(back.length(), 6)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(at)) => fail("good layout: roundtrip mismatch at \{at}")
    Err(e) => fail("good layout: roundtrip error \{e.to_display()}")
  }
}

///|
test "layout invariant: total_length disagreeing with occurs is rejected everywhere" {
  // occurs=3 * byte_length=2 应为 6，跨度声明 0
  assert_all_entries_reject(
    "span=0",
    entry_layout(6, 0, 2, 3, 0),
    b"\xC1\xC2\xC3\xC4\xC5\xC6",
  )
}

///|
test "layout invariant: occurs=0 is rejected everywhere" {
  assert_all_entries_reject(
    "occurs=0",
    entry_layout(4, 0, 4, 0, 0),
    b"\xC1\xC2\xC3\xC4",
  )
}

///|
test "layout invariant: negative total_length is rejected everywhere" {
  assert_all_entries_reject(
    "total=-4",
    entry_layout(4, 0, 4, 1, -4),
    b"\xC1\xC2\xC3\xC4",
  )
}

///|
test "layout invariant: negative byte_length is rejected everywhere" {
  assert_all_entries_reject("neg layout len", entry_layout(-1, 0, 0, 1, 0), b"")
}

///|
test "layout invariant: element span beyond byte_length is rejected everywhere" {
  // offset 4 + 2*2 = 8 > byte_length 6
  assert_all_entries_reject(
    "span past end",
    entry_layout(6, 4, 2, 2, 4),
    b"\xC1\xC2\xC3\xC4\xC5\xC6",
  )
}

///|
test "layout invariant: numeric PIC width must match the slot in ordered decode too" {
  // 手工把 byte_length 改成 3，而 PIC S9(4) COMP 的写入宽度是 2 —— 数据面
  // （decode_field）与区间守卫都拒绝这种槽位/宽度不一致；ordered 入口同源。
  let base = compile_layout(parse_copybook("01 R.\n    05 A PIC S9(4) COMP.\n"))
  let f = base.fields[0]
  let layout : RecordLayout = {
    ..base,
    byte_length: 3,
    fields: [{ ..f, byte_length: 3, total_length: 3, }],
  }
  assert_all_entries_reject("slot 3 vs pic 2", layout, b"\x00\x00\x00")
}
