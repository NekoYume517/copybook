// CB-19 回归：HFP 非规格化尾数必须拒收，且 roundtrip_check 必须区分
// 「解码失败」与「编码失败」两个来源。
//
// (a) 量级下溢的字节必须在 decode 侧拒收。
//   HFP 的规格化尾数要求最高十六进制位非零：COMP-1 的 F ∈ [2^20, 2^24)、
//   COMP-2 的 F ∈ [2^52, 2^56)。`exp7 == 0` 且 F 低于该下界时，
//   值 = F/2^frac × 16^-64 < 2^-260 —— 正是 encode 报 underflow 的那一档。
//   修复前这种字节 decode 会成功（`00 00 00 01` → 5.147557589468029e-85），
//   encode 再把它拒掉，于是 verify 报错而 decode 说"没事"。
//
// (b) `roundtrip_check` 内部先 decode 再 encode，两者都可能失败，旧实现把
//   两者都归成同一个 DecodeError，CLI 因此把 encode 失败说成
//   "decode failed"（实测 COMP-2 `7F FF FF FF FF FF FF FF`：decode 成功、
//   encode 以 overflow 失败，却被报成 decode failed）。

///|
fn hfp_short(bytes : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in bytes {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "HFP COMP-1 denormalized tail below 2^-260 is rejected on decode (CB-19)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  // exp7 = 0 且 F = 1（远低于规格化下界 2^20）：值 < 2^-260，encode 会拒
  let rec = hfp_short([0x00, 0x00, 0x00, 0x01])
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.F") {
        Some(Float(f)) =>
          fail("decode must reject the underflowing HFP byte, got \{f}")
        _ => fail("decode must reject the underflowing HFP byte")
      }
    Err(e) => assert_true(e.to_display().contains("invalid numeric"))
  }
  // 同样的字节经 roundtrip_check 也必须失败，且**归因到 decode**
  match roundtrip_check(layout, rec) {
    Ok(_) => fail("roundtrip must reject it too")
    Err(_) => ()
  }
}

///|
test "HFP COMP-2 denormalized tail below 2^-260 is rejected on decode (CB-19)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  let rec = hfp_short([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
  match decode_record(layout, rec) {
    Ok(_) => fail("decode must reject the underflowing HFP long byte")
    Err(e) => assert_true(e.to_display().contains("invalid numeric"))
  }
}

///|
test "HFP zero and the smallest normalized magnitude still decode (CB-19)" {
  let short = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  // 尾数为 0 的 ±0 永远合法
  for arr in [[0x00, 0x00, 0x00, 0x00], [0x80, 0x00, 0x00, 0x00]] {
    match decode_record(short, hfp_short(arr)) {
      Ok(_) => ()
      Err(e) => fail("\{arr} must decode: \{e.to_display()}")
    }
  }
  // exp7=0 且 F = 2^20 恰好是 2^-260 的最小规格化值 —— 必须仍然可解且往返一致
  let min_norm = hfp_short([0x00, 0x10, 0x00, 0x00])
  match decode_record(short, min_norm) {
    Ok(m) =>
      match m.get("R.F") {
        Some(Float(f)) => assert_true(f > 0.0)
        _ => fail("R.F must be a Float")
      }
    Err(e) =>
      fail(
        "the smallest normalized COMP-1 value must decode: \{e.to_display()}",
      )
  }
  assert_eq(
    encode_record(short, decode_record(short, min_norm).unwrap()).unwrap(),
    min_norm,
  )
  // COMP-2 的对应下界 F = 2^52
  let long = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  let long_min = hfp_short([0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  match decode_record(long, long_min) {
    Ok(_) => ()
    Err(e) =>
      fail(
        "the smallest normalized COMP-2 value must decode: \{e.to_display()}",
      )
  }
}

///|
test "roundtrip_check reports an encode failure as such, not a decode failure (CB-19)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  // 这个字节 decode 得出来（数值有限），但超过 HFP 上界，encode 会 overflow
  let rec = hfp_short([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
  match decode_record(layout, rec) {
    Ok(_) => ()
    Err(e) => fail("decode of this byte must succeed: \{e.to_display()}")
  }
  match roundtrip_check(layout, rec) {
    Ok(_) => fail("roundtrip must fail (the value cannot be re-encoded)")
    Err(e) =>
      // 归因必须是「编码失败」，而不是含糊的 decode 失败
      match e {
        EncodeFailed(msg) =>
          assert_true(
            msg.contains("overflows") ||
            msg.contains("underflows") ||
            msg.contains("not representable"),
          )
        other =>
          fail(
            "roundtrip must attribute the failure to encode, got \{other.to_display()}",
          )
      }
  }
}
