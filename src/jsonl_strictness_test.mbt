// JSONL 输入侧的「静默降级」回归（2026-11-04 对抗性审计 NEW-5 / NEW-6）。
//
// ## 两条缺陷的共同形态
//
// 都是「输入里有错，但工具装作没看见，产出一份看起来正常的输出」——
// 正是项目自己的「绝不静默修正」原则明确要拒绝的东西。
//
// ### NEW-5：已知字段收到对象/数组时静默跳过
//
// `jsonl.mbt` 的值匹配分支末梢是 `Some(_) => ()`，于是
// `{"R.NAME":{"evil":1}}` 让该字段从 map 里消失，`encode` 按「未赋值
// 存储」写一整片 0x40 空格，exit 0、零提示。手写 JSON 的嵌套错误变成
// 整字段空白。
//
// ### NEW-6：旁路键内容损坏时静默降级
//
// `__tail_hex` / `__filler_hex` / `__float_hex` 的解析失败走 `None => ()`，
// 于是把 `__filler_hex` 改成奇数长度的 `"e"` 之后 encode 仍 exit 0，
// 对应字节被写成 0x40（`...4C EE...` → `...4C 40...`）。文件截断或传输
// 损坏之后，「无损往返」变成静默改字节，用户毫无信号。
//
// **这两类键报错没有误伤面**：它们都以 `__` 开头，只可能来自 decode 的
// 输出或蓄意构造，不像未知字段那样需要容忍手写 JSON 的额外键。

///|
fn filler_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  A  PIC X(2).\n    05  FILLER PIC X(2).\n    05  B  PIC X(2).\n",
    ),
  )
}

///|
test "NEW-5: 已知字段收到对象时报错，不静默跳过" {
  let layout = filler_layout()
  let line = "{\"R.A\":\"AB\",\"R.B\":{\"evil\":1}}"
  let r = parse_jsonl_row(layout, line)
  match r {
    Ok(_) => fail("object value for a known field must be rejected")
    Err(msg) => {
      assert_true(msg.contains("R.B"))
      assert_true(msg.contains("an object"))
    }
  }
}

///|
test "NEW-5: 已知字段收到数组时报错" {
  let layout = filler_layout()
  let line = "{\"R.A\":[1,2]}"
  match parse_jsonl_row(layout, line) {
    Ok(_) => fail("array value for a known field must be rejected")
    Err(msg) => assert_true(msg.contains("an array"))
  }
}

///|
test "NEW-5: 合法的标量类型仍然接受（不误伤）" {
  let layout = filler_layout()
  // 字符串 / 数字 / null / true 都是合法输入形态（`is_ok` 已从新工具链移除，
  // 用模式匹配判定）
  for
    line in [
      "{\"R.A\":\"AB\"}", "{\"R.A\":42}", "{\"R.A\":null}", "{\"R.A\":true}", "{}",
    ] {
    match parse_jsonl_row(layout, line) {
      Ok(_) => ()
      Err(msg) => fail("legal scalar value rejected: \{msg}")
    }
  }
}

///|
test "NEW-6: __filler_hex 奇数长度报错，不再静默写 0x40" {
  let layout = filler_layout()
  let r = parse_jsonl_row(layout, "{\"__filler_hex\":\"e\"}")
  match r {
    Ok(_) => fail("odd-length __filler_hex must be rejected")
    Err(msg) => assert_true(msg.contains("__filler_hex"))
  }
}

///|
test "NEW-6: __filler_hex 含非十六进制字符报错" {
  let layout = filler_layout()
  let r = parse_jsonl_row(layout, "{\"__filler_hex\":\"zz\"}")
  match r {
    Ok(_) => fail("non-hex __filler_hex must be rejected")
    Err(msg) => assert_true(msg.contains("__filler_hex"))
  }
}

///|
test "NEW-6: __tail_hex 损坏同样报错" {
  let layout = filler_layout()
  let r = parse_jsonl_row(layout, "{\"__tail_hex\":\"abc\"}")
  match r {
    Ok(_) => fail("odd-length __tail_hex must be rejected")
    Err(msg) => assert_true(msg.contains("__tail_hex"))
  }
}

///|
test "NEW-6: 合法的旁路键仍然生效（不误伤）" {
  let layout = filler_layout()
  let line = "{\"R.A\":\"AB\",\"R.B\":\"YZ\",\"__filler_hex\":\"c3c4\"}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  // A=AB, FILLER 回填 c3c4, B=YZ
  assert_eq(out[0].to_int(), 0xC1)
  assert_eq(out[2].to_int(), 0xC3)
  assert_eq(out[3].to_int(), 0xC4)
  assert_eq(out[4].to_int(), 0xE8)
}
