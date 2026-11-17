// 2026-11-17-b 审计（已声明的限制，锁定形态）：`COMP-5` / `COMPUTATIONAL-5`
// 目前按 `COMP` 处理 —— 而 IBM 的 COMP-5 **不受 PIC 位数约束**：容器满量程都
// 合法（`9(4) COMP-5` 是 2 字节无符号，最大 65535；`S9(4) COMP-5` 最大 32767）。
// 本工具对 COMP 族一律强制「十进制容量 = PIC 声明位数」，于是这类**合法主机
// 数据**被解成数据错（`InvalidNumeric`）。
//
// 这与 CB-B12 / 字符项 SIGN 那两条不同：那两条是「照收后原地丢弃」，本条是
// 「照收后按另一套语义执行」。改语义要动 `Usage` 枚举的公开面（新增 Comp5
// 变体 + 全入口分派），不在本轮范围内；按「绝不静默修正」的最低要求，把它
// 写成**已声明的限制**：API.md §3 已注明，回归锁住当前形态，将来要改就是
// 有意识的决定，而不是悄悄漂移。
//
// 锁住的两件事：
//   1. 落在 PIC 位数内的 COMP-5 值与 COMP 完全一致（所以多数 copybook 照旧能用）；
//   2. 超出 PIC 位数但落在容器满量程内的值被拒（与 IBM 的行为**不同**，故声明）。

///|
fn comp5_layout(pic : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic}.\n"))
}

///|
fn comp5_decode(layout : RecordLayout, bytes : Array[Int32]) -> String {
  let bs : Array[Byte] = []
  for v in bytes {
    bs.push(v.to_byte())
  }
  match decode_record(layout, Bytes::from_array(bs)) {
    Ok(m) =>
      match m.get("R.A") {
        Some(v) => "OK \{v.to_display()}"
        None => "OK (no key)"
      }
    Err(e) => "ERR " + e.to_display()
  }
}

///|
test "COMP-5: values inside the PIC digit capacity behave exactly like COMP" {
  let signed = comp5_layout("S9(4) COMP-5")
  assert_eq(comp5_decode(signed, [0x27, 0x0F]), "OK 9999")
  assert_eq(comp5_decode(signed, [0xD8, 0xF1]), "OK -9999")
  let unsigned = comp5_layout("9(4) COMP-5")
  assert_eq(comp5_decode(unsigned, [0x27, 0x0F]), "OK 9999")
}

///|
test "COMP-5: declared limitation — full container range is rejected" {
  // IBM 上这两个值都合法（COMP-5 用容器满量程）；本工具按 COMP 语义拒收。
  // 这一条被拒是**已声明的限制**，不是这次要修的缺陷：要修必须给 Usage
  // 增加 Comp5 变体并让 decode_binary / encode_binary 跳过十进制容量校验。
  let signed = comp5_layout("S9(4) COMP-5")
  let msg = comp5_decode(signed, [0x7F, 0xFF])
  assert_true(msg.contains("exceeds 4 decimal digits"))
  let unsigned = comp5_layout("9(4) COMP-5")
  let umsg = comp5_decode(unsigned, [0xFF, 0xFF])
  assert_true(umsg.contains("exceeds 4 decimal digits"))
}
