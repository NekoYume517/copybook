// 2026-11-19 对抗性回归：公开 Decimal 的 scale 是合法 Int32 值域，不是
// PicClause 的 [-18,18] 子域。防挂死必须用恒等与零系数短路，不能拒绝合法值。

///|
test "align_scale returns legitimate equal scales unchanged" {
  for scale in [19, 309, -2147483648, 2000000000] {
    let value = Decimal::from_parts(1L, scale, false)
    match align_scale(value, scale, 0) {
      Ok(aligned) => {
        assert_eq(aligned.coefficient, 1L)
        assert_eq(aligned.scale, scale)
      }
      Err(e) => fail("equal scale \{scale} must be identity: \{e.to_display()}")
    }
  }
  // 超出 PicClause 域的非零值也能做正常的少量低位对齐。
  match align_scale(Decimal::from_parts(100L, 19, false), 17, 0) {
    Ok(aligned) => {
      assert_eq(aligned.coefficient, 1L)
      assert_eq(aligned.scale, 17)
    }
    Err(e) => fail("scale 19 to 17 must remain valid: \{e.to_display()}")
  }
}

///|
test "align_scale short-circuits zero at arbitrary input and expected scales" {
  for scale in [-2147483648, -309, 19, 309, 2000000000] {
    let value = Decimal::from_parts(0L, scale, true)
    match align_scale(value, 0, 0) {
      Ok(aligned) => {
        assert_eq(aligned.coefficient, 0L)
        assert_eq(aligned.scale, 0)
        assert_true(aligned.negative)
      }
      Err(e) => fail("zero scale \{scale} must align: \{e.to_display()}")
    }
  }
  for expected in [-2147483648, 2000000000] {
    match align_scale(Decimal::from_parts(0L, 0, false), expected, 0) {
      Ok(aligned) => {
        assert_eq(aligned.coefficient, 0L)
        assert_eq(aligned.scale, expected)
      }
      Err(e) =>
        fail("zero must reach expected scale \{expected}: \{e.to_display()}")
    }
  }
}

///|
test "align_scale nonzero extreme scales stop in the arithmetic guards" {
  // 乘法方向最多约 19 步即 Int64 溢出；除法方向遇到非零低位立即报精度
  // 错误。两条都不能进入数十亿次空转，也不能被 scale 域检查抢先拒绝。
  match align_scale(Decimal::from_parts(1L, -2147483648, false), 0, 0) {
    Err(e) => assert_true(e.to_display().contains("overflows Int64"))
    Ok(_) => fail("nonzero scale multiplication must overflow")
  }
  match align_scale(Decimal::from_parts(1L, 2000000000, false), 0, 0) {
    Err(e) => assert_true(e.to_display().contains("fractional digits"))
    Ok(_) => fail("nonzero scale division must report precision loss")
  }
}

///|
test "zoned and COMP preserve zero for extreme Decimal scales" {
  for scale in [-2147483648, 2000000000] {
    for pic in ["S9(3)", "S9(4) COMP"] {
      let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic}.\n"))
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(0L, scale, false))
      match encode_record(layout, row) {
        Ok(encoded) => {
          let expected = if pic == "S9(3)" { 0xF0 } else { 0 }
          for b in encoded {
            assert_eq(b.to_int(), expected)
          }
        }
        Err(e) =>
          fail("PIC \{pic} rejected zero scale \{scale}: \{e.to_display()}")
      }
    }
  }
}
