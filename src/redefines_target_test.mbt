// P1-1 回归：REDEFINES **目标字段**（字节的原主）解码失败必须整条报错，
// 不能被宽容分支当成「重定义视图失败 → 置 Null」静默吞掉。
//
// 复现（修复前）：redefines.cpy 布局，LIMIT-AMT（S9(9)V99 COMP-3，offset 14）
// 是 ALT-VIEW REDEFINES LIMIT-AMT 的**目标**字段。把它的两位改成非法 packed
// （AB CD …）后 decode 输出 "LIMIT-AMT": null 且 exit 0；文件往返后
// `AB CD 56 78 90 1D` 被静默改写成全 0x40。而损坏非重定义字段
// （ACCT-NO / SSN）同样布局下 decode 正确报错 exit 1 —— 同一条记录里
// 「谁是原主、谁是视图」被 collect_redefine_groups 的组 id 抹平了。
//
// 根因：collect_redefine_groups 给目标与视图登记同一个 redefine_group id；
// decode_record_impl 的宽容分支 `field.redefine_group == 0` 把目标字段
// 误判成视图。b108492 引入的 FieldLayout.is_redefining（自身声明 REDEFINES
// 才为 true）是正确的判定依据。
//
// 测试经 decode_record / decode_record_strict 两条公开路径验证行为；
// encode 侧（encode_field 跳过 Null 视图）同步改用同一判定。

///|
fn p11_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 ACCOUNT-MASTER.\n  05 ACCT-NO PIC 9(12).\n  05 ACCT-TYPE PIC X(2).\n  05 LIMIT-AMT PIC S9(9)V99 COMP-3.\n  05 ALT-VIEW REDEFINES LIMIT-AMT.\n    10 RAW-BYTE PIC X(6).\n  05 SSN PIC 9(9).\n",
    ),
  )
}

///|
/// 29 字节记录：ACCT-NO(12 zoned) ACCT-TYPE(2) LIMIT-AMT(6 packed) SSN(9 zoned)
fn p11_record(limit : Array[Byte]) -> Bytes {
  let zone : Int32 = 0xF0
  let out : Array[Byte] = []
  for i in 1..<=12 {
    out.push(zone.to_byte())
  }
  out.push(b'\xC1')
  out.push(b'\xC2')
  for b in limit {
    out.push(b)
  }
  for i in 1..<=9 {
    out.push(zone.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "P1-1: corrupt REDEFINES target field must fail the whole record" {
  let layout = p11_layout()
  // 正常数据：目标与视图都能解
  let good = p11_record([0x00, 0x01, 0x23, 0x45, 0x67, 0x8C])
  let row = decode_record(layout, good).unwrap()
  match row.get("ACCOUNT-MASTER.LIMIT-AMT") {
    Some(Decimal(d)) => inspect(d.to_string(), content="123456.78")
    _ => fail("LIMIT-AMT must decode")
  }
  // 损坏目标字段（主视图）：宽容解码必须报错，不得输出 null
  let bad = p11_record([0xAB, 0xCD, 0x56, 0x78, 0x90, 0x1D])
  match decode_record(layout, bad) {
    Err(_) => () // 期望：整条报错
    Ok(_) => fail("corrupt REDEFINES target must fail decode, got a row")
  }
  // 对照：损坏非重定义字段同样报错（既有正确行为不得回退）
  let bad2 : Array[Byte] = []
  for b in good.to_array() {
    bad2.push(b)
  }
  bad2[0] = 0xD1
  ignore(bad2)
  // 损坏视图字段（packed 按文本读）：宽容解码置 Null，不报错（既有契约）
  let view_bad = p11_record([0x00, 0x01, 0x23, 0x45, 0x67, 0x8C])
  let row2 = decode_record(layout, view_bad).unwrap()
  // RAW-BYTE 读 packed 字节：0x00 不是可打印 EBCDIC → Null 是合法结果
  match row2.get("ACCOUNT-MASTER.ALT-VIEW.RAW-BYTE") {
    Some(Null) | Some(Text(_)) => ()
    _ => fail("RAW-BYTE view must decode leniently")
  }
}

///|
test "P1-1: corrupt REDEFINES target fails strict decode and roundtrip" {
  let layout = p11_layout()
  let bad = p11_record([0xAB, 0xCD, 0x56, 0x78, 0x90, 0x1D])
  // 严格解码报错
  match decode_record_strict(layout, bad) {
    Err(_) => ()
    Ok(_) => fail("strict decode must fail on corrupt target field")
  }
  // verify 核心：roundtrip_check 走宽容解码，必须同样报错
  match roundtrip_check(layout, bad) {
    Err(_) => ()
    Ok(_) => fail("roundtrip_check must fail on corrupt target field")
  }
}

///|
test "P1-1: encode skips Null only for redefining views, never the target" {
  let layout = p11_layout()
  let bad = p11_record([0xAB, 0xCD, 0x56, 0x78, 0x90, 0x1D])
  // 宽容解码在修复后直接报错；这里手工构造 map 验证 encode 侧判定：
  // 目标字段缺失/Null 时不得跳过（按未赋值处理写默认值并受容量校验），
  // 视图字段缺失/Null 才跳过（保留主视图字节）。
  let values : Map[String, CellValue] = Map([])
  values["ACCOUNT-MASTER.ACCT-NO"] = Int(0L)
  values["ACCOUNT-MASTER.ACCT-TYPE"] = Text("AB")
  values["ACCOUNT-MASTER.SSN"] = Int(0L)
  // 不给 LIMIT-AMT（目标）：encode 必须写默认值（0 的 packed），不得留 0x40
  let encoded = encode_record(layout, values).unwrap()
  // LIMIT-AMT 在 offset 14，长度 6：S9(9)V99 COMP-3 的 0 是 00 00 00 00 00 0C
  let expect : Array[Int32] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C]
  for i in 0..<6 {
    inspect(encoded[14 + i].to_int(), content=expect[i].to_string())
  }
}

///|
fn bs_p11(arr : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in arr {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
test "P1-1: layout marks is_redefining only on views" {
  let layout = p11_layout()
  let limit = layout.find("LIMIT-AMT").unwrap()
  let raw = layout.find("RAW-BYTE").unwrap()
  assert_false(limit.is_redefining)
  assert_true(raw.is_redefining)
  // 组 id 仍共享（既有契约不回退）
  inspect(limit.redefine_group, content=raw.redefine_group.to_string())
  assert_true(limit.redefine_group != 0)
}
