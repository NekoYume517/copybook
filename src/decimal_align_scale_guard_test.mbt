// 2026-11-19 对抗性回归：C11 只限制 PicClause.scale，公开 Decimal 仍能带着
// 任意 scale 进入 align_scale。零系数不会因逐位精度检查提前返回，巨大
// scale 因而形成差值循环挂死。入口域与 PIC 一致为 [-18, 18]。

///|
test "align_scale rejects a Decimal outside the supported scale domain" {
  // 19 是红灯阶段可快速运行的最小越界值；修复后补 MIN 与 2e9，二者都
  // 必须在进入 while 前返回，不能在旧实现上直接运行。
  for scale in [-2147483648, 19, 2000000000] {
    let value = Decimal::from_parts(0L, scale, false)
    match align_scale(value, 0, 0) {
      Err(e) => assert_true(e.to_display().contains("scale"))
      Ok(_) => fail("out-of-domain Decimal scale must not be aligned")
    }
  }
}

///|
test "zoned and COMP reject an out-of-domain Decimal before scale loops" {
  for scale in [-2147483648, 19, 2000000000] {
    for pic in ["S9(3)", "S9(4) COMP"] {
      let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic}.\n"))
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(0L, scale, false))
      match encode_record(layout, row) {
        Err(e) => assert_true(e.to_display().contains("scale"))
        Ok(_) => fail("PIC \{pic} accepted an out-of-domain Decimal scale")
      }
    }
  }
}
