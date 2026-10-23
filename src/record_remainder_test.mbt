// 残缺数据必须区分「记录太短」与「文件长度不是记录长度的整数倍」。
//
// 背景（CB-5）：`decode_records` 对 `total % record_length != 0` 抛
// `RecordTooShort(record_length, total % record_length)`，消息于是变成
// 「expected 4 bytes, got 1」—— 把一条 4 字节记录说成只有 1 字节。
// 真实原因完全不同：文件里有 5 字节，前 4 字节是一条完整记录，尾部多出 1 字节。
//
// 两种情形分开报：
//   - 文件连一条记录都装不满（total < record_length）→ RecordTooShort
//   - 文件够长但不是整数倍（尾部残留）→ RecordRemainder，说明尾随多少字节、
//     共多少字节、记录长度多少

///|
/// 4 字节单字段布局。
fn rem_layout() -> RecordLayout raise {
  compile_layout(parse_copybook("01 R.\n  05 A PIC X(4).\n"))
}

///|
test "尾部残留字节：报 RecordRemainder 并说明真实原因（CB-5）" {
  let layout = rem_layout()
  // 5 字节 = 1 条完整记录 + 1 字节尾巴
  match decode_records(layout, b"\xC1\xC2\xC3\xC4\xC5", 4) {
    Err(RecordRemainder(total, record_length, trailing)) => {
      assert_eq(total, 5)
      assert_eq(record_length, 4)
      assert_eq(trailing, 1)
    }
    Err(e) => fail("expected RecordRemainder, got " + e.to_display())
    Ok(_) => fail("5 bytes with record length 4 must fail")
  }
  // 文案必须能看出「尾随 1 字节 / 共 5 字节 / 记录长 4 字节」，而不是
  // 「expected 4 bytes, got 1」
  let msg = DecodeError::RecordRemainder(5, 4, 1).to_display()
  assert_true(msg.contains("5"))
  assert_true(msg.contains("4"))
  assert_true(msg.contains("1"))
  assert_true(msg.contains("trailing"))
  assert_false(msg.contains("record too short"))
}

///|
test "文件连一条记录都装不满：仍报 RecordTooShort（CB-5 对照）" {
  let layout = rem_layout()
  // 单条记录短：decode_record 直接给不足
  match decode_record(layout, b"\xC1") {
    Err(RecordTooShort(expected, actual)) => {
      assert_eq(expected, 4)
      assert_eq(actual, 1)
    }
    _ => fail("1 byte for a 4-byte layout must be RecordTooShort")
  }
  assert_eq(
    DecodeError::RecordTooShort(4, 1).to_display(),
    "record too short: expected 4 bytes, got 1",
  )
  // 批量路径：总量不足一条记录，同样是「太短」而不是「尾部残留」
  match decode_records(layout, b"\xC1", 4) {
    Err(RecordTooShort(expected, actual)) => {
      assert_eq(expected, 4)
      assert_eq(actual, 1)
    }
    Err(e) => fail("expected RecordTooShort, got " + e.to_display())
    Ok(_) => fail("1 byte with record length 4 must fail")
  }
}

///|
test "记录长度整数倍与空数据不受影响（CB-5 回归护栏）" {
  let layout = rem_layout()
  // 2 条完整记录
  let rows = decode_records(layout, b"\xC1\xC2\xC3\xC4\xC1\xC2\xC3\xC4", 4).unwrap()
  assert_eq(rows.length(), 2)
  // 空数据：0 条记录，不是错误（CLI 层另行拒绝空文件）
  let empty = decode_records(layout, b"", 4).unwrap()
  assert_eq(empty.length(), 0)
}
