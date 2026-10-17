// layout 单元测试：手写的 FieldSpec 树，不依赖 parser。

///|
fn pic_numeric(
  digits : Int32,
  scale : Int32,
  signed : Bool,
  usage : Usage,
) -> PicClause {
  {
    category: Numeric,
    digits,
    scale,
    signed,
    usage,
    sign_separate: false,
    sign_leading: false,
    pic_text: "",
  }
}

///|
fn pic_x(n : Int32) -> PicClause {
  {
    category: Alphanumeric,
    digits: n,
    scale: 0,
    signed: false,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    pic_text: "",
  }
}

///|
fn leaf(level : Int32, name : String, pic : PicClause) -> FieldSpec {
  {
    level,
    name,
    pic: Some(pic),
    redefines: None,
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children: [],
    line: 1,
    group_usage: None,
  }
}

///|
fn group(
  level : Int32,
  name : String,
  children : Array[FieldSpec],
) -> FieldSpec {
  {
    level,
    name,
    pic: None,
    redefines: None,
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children,
    line: 1,
    group_usage: None,
  }
}

///|
/// customer.cpy 的等价树
fn customer_specs() -> Array[FieldSpec] {
  let flags = group(5, "FLAGS", [
    leaf(10, "ACTIVE", pic_x(1)),
    leaf(10, "TIER", pic_numeric(2, 0, false, Display)),
  ])
  [
    group(1, "CUSTOMER-RECORD", [
      leaf(5, "CUST-ID", pic_numeric(8, 0, false, Display)),
      leaf(5, "CUST-NAME", pic_x(30)),
      leaf(5, "BALANCE", pic_numeric(7, 2, true, Comp3)),
      leaf(5, "OPEN-DATE", pic_numeric(8, 0, false, Display)),
      flags,
    ]),
  ]
}

///|
test "customer.cpy 总长 54" {
  let layout = compile_layout(customer_specs())
  inspect(layout.name, content="CUSTOMER-RECORD")
  inspect(layout.byte_length, content="54")
}

///|
test "customer.cpy 逐字段偏移与长度" {
  let layout = compile_layout(customer_specs())
  let cases : Array[(String, Int32, Int32)] = [
    ("CUSTOMER-RECORD.CUST-ID", 0, 8),
    ("CUSTOMER-RECORD.CUST-NAME", 8, 30),
    ("CUSTOMER-RECORD.BALANCE", 38, 5),
    ("CUSTOMER-RECORD.OPEN-DATE", 43, 8),
    ("CUSTOMER-RECORD.FLAGS.ACTIVE", 51, 1),
    ("CUSTOMER-RECORD.FLAGS.TIER", 52, 2),
  ]
  for c in cases {
    let (name, offset, len) = c
    match layout.find(name) {
      Some(f) => {
        inspect(f.offset, content=offset.to_string())
        inspect(f.byte_length, content=len.to_string())
      }
      None => fail("not found: " + name)
    }
  }
}

///|
test "fields 只含叶子，按 offset 排序" {
  let layout = compile_layout(customer_specs())
  inspect(layout.fields.length(), content="6")
  inspect(layout.fields[0].name, content="CUST-ID")
  inspect(layout.fields[5].name, content="TIER")
  // 单调不减
  let mut prev = -1
  for f in layout.fields {
    assert_true(f.offset >= prev)
    prev = f.offset
  }
}

///|
test "all_fields 含中间层" {
  let layout = compile_layout(customer_specs())
  // 6 叶子 + FLAGS 组 + 根 01 组 = 8
  inspect(layout.all_fields.length(), content="8")
}

///|
test "covered_bytes 覆盖整条记录" {
  let layout = compile_layout(customer_specs())
  inspect(layout.covered_bytes(), content="54")
}

///|
test "COMP 字节数表" {
  let cases : Array[(Int32, Int32)] = [
    (1, 1),
    (4, 1),
    (5, 2),
    (9, 2),
    (10, 4),
    (18, 4),
  ]
  for c in cases {
    let (digits, expected) = c
    let specs = [
      group(1, "R", [leaf(5, "F", pic_numeric(digits, 0, false, Comp))]),
    ]
    let layout = compile_layout(specs)
    inspect(layout.byte_length, content=expected.to_string())
  }
}

///|
test "COMP 带小数位按总位数算" {
  // S9(5)V99 → 总 7 位 → 2 字节
  let specs = [group(1, "R", [leaf(5, "F", pic_numeric(5, 2, true, Comp))])]
  inspect(compile_layout(specs).byte_length, content="2")
}

///|
test "COMP-3 字节数表" {
  let cases : Array[(Int32, Int32, Int32)] = [
    (7, 2, 5),
    (5, 2, 4),
    (9, 2, 6),
    (3, 0, 2),
    (1, 0, 1),
    (10, 0, 6),
  ]
  for c in cases {
    let (digits, scale, expected) = c
    let specs = [
      group(1, "R", [leaf(5, "F", pic_numeric(digits, scale, true, Comp3))]),
    ]
    inspect(compile_layout(specs).byte_length, content=expected.to_string())
  }
}

///|
test "zoned 长度 = 整数位 + 小数位，符号不加字节" {
  let specs = [group(1, "R", [leaf(5, "A", pic_numeric(7, 2, true, Display))])]
  inspect(compile_layout(specs).byte_length, content="9")
}

///|
test "SIGN SEPARATE 加一字节" {
  let mut pic = pic_numeric(5, 0, true, Display)
  pic = { ..pic, sign_separate: true, }
  let specs = [group(1, "R", [leaf(5, "A", pic)])]
  inspect(compile_layout(specs).byte_length, content="6")
}

///|
test "N(n) 双字节" {
  let pic : PicClause = {
    category: National,
    digits: 5,
    scale: 0,
    signed: false,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    pic_text: "",
  }
  let specs = [group(1, "R", [leaf(5, "A", pic)])]
  inspect(compile_layout(specs).byte_length, content="10")
}

///|
test "OCCURS 组：total_length = 单元素 * occurs" {
  let lines : FieldSpec = {
    level: 5,
    name: "LINES",
    pic: None,
    redefines: None,
    occurs: 5,
    occurs_min: 5,
    occurs_depending_on: None,
    value_literal: None,
    children: [
      leaf(10, "SKU", pic_x(12)),
      leaf(10, "QTY", pic_numeric(4, 0, true, Comp)),
      leaf(10, "PRICE", pic_numeric(5, 2, true, Comp3)),
    ],
    line: 1,
    group_usage: None,
  }
  let specs = [
    group(1, "ORDER-LINES", [
      leaf(5, "ORDER-ID", pic_numeric(10, 0, false, Display)),
      leaf(5, "LINE-COUNT", pic_numeric(3, 0, false, Display)),
      lines,
    ]),
  ]
  let layout = compile_layout(specs)
  // 单元素 = 12 + 1 + 4 = 17，× 5 = 85；10 + 3 + 85 = 98
  inspect(layout.byte_length, content="98")
  let lines_layout = layout.find("LINES").unwrap()
  inspect(lines_layout.byte_length, content="17")
  inspect(lines_layout.occurs, content="5")
  inspect(lines_layout.total_length, content="85")
  // 子项偏移相对组首
  let sku = layout.find("ORDER-LINES.LINES.SKU").unwrap()
  inspect(sku.offset, content="13")
  let qty = layout.find("ORDER-LINES.LINES.QTY").unwrap()
  inspect(qty.offset, content="25")
  let price = layout.find("ORDER-LINES.LINES.PRICE").unwrap()
  inspect(price.offset, content="26")
}

///|
test "OCCURS 在最外层叶子上" {
  let f : FieldSpec = {
    level: 5,
    name: "TAGS",
    pic: Some(pic_x(4)),
    redefines: None,
    occurs: 3,
    occurs_min: 3,
    occurs_depending_on: None,
    value_literal: None,
    children: [],
    line: 1,
    group_usage: None,
  }
  let layout = compile_layout([group(1, "R", [f])])
  inspect(layout.byte_length, content="12")
  let tags = layout.find("TAGS").unwrap()
  inspect(tags.byte_length, content="4")
  inspect(tags.total_length, content="12")
}

///|
test "REDEFINES 共享偏移且不累加长度" {
  let alt : FieldSpec = {
    level: 5,
    name: "ALT-VIEW",
    pic: None,
    redefines: Some("LIMIT-AMT"),
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children: [leaf(10, "RAW-BYTE", pic_x(6))],
    line: 1,
    group_usage: None,
  }
  let specs = [
    group(1, "ACCOUNT-MASTER", [
      leaf(5, "ACCT-NO", pic_numeric(12, 0, false, Display)),
      leaf(5, "ACCT-TYPE", pic_x(2)),
      leaf(5, "LIMIT-AMT", pic_numeric(9, 2, true, Comp3)),
      alt,
      leaf(5, "SSN", pic_numeric(9, 0, false, Display)),
    ]),
  ]
  let layout = compile_layout(specs)
  // 12 + 2 + 6 + 9 = 29（ALT-VIEW 的 6 字节不叠加）
  inspect(layout.byte_length, content="29")
  let limit = layout.find("LIMIT-AMT").unwrap()
  inspect(limit.offset, content="14")
  let raw = layout.find("RAW-BYTE").unwrap()
  inspect(raw.offset, content="14")
  let ssn = layout.find("SSN").unwrap()
  inspect(ssn.offset, content="20")
  // 重定义组 id 相同且非 0
  assert_true(limit.redefine_group != 0)
  inspect(limit.redefine_group, content=raw.redefine_group.to_string())
}

///|
test "REDEFINES 目标不存在报错" {
  let bad : FieldSpec = {
    level: 5,
    name: "X",
    pic: Some(pic_x(2)),
    redefines: Some("NOPE"),
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children: [],
    line: 7,
    group_usage: None,
  }
  let specs = [group(1, "R", [bad])]
  let r = try {
    let _ = compile_layout(specs)
    "ok"
  } catch {
    InvalidLayout(msg) => "err:" + msg
    _ => "other"
  } noraise {
    v => v
  }
  assert_true(r.has_prefix("err:"))
}

///|
test "空 copybook 报错" {
  let specs : Array[FieldSpec] = []
  let r = try {
    let _ = compile_layout(specs)
    "ok"
  } catch {
    InvalidLayout(_) => "err"
    _ => "other"
  } noraise {
    v => v
  }
  inspect(r, content="err")
}

///|
test "pic_type_name 渲染" {
  inspect(
    pic_type_name(pic_numeric(8, 0, false, Display)),
    content="9(8) DISPLAY",
  )
  inspect(pic_type_name(pic_x(30)), content="X(30) DISPLAY")
  inspect(
    pic_type_name(pic_numeric(7, 2, true, Comp3)),
    content="S9(7)V99 COMP-3",
  )
  inspect(pic_type_name(pic_numeric(7, 2, true, Comp)), content="S9(7)V99 COMP")
  inspect(pic_type_name(pic_numeric(4, 0, true, Comp1)), content="S9(4) COMP-1")
}

///|
test "find 大小写不敏感 + 后缀匹配" {
  let layout = compile_layout(customer_specs())
  assert_true(layout.find("cust-id") is Some(_))
  assert_true(layout.find("CUSTOMER-RECORD.cust-name") is Some(_))
  assert_true(layout.find("CUST-ID") is Some(_))
  assert_true(layout.find("NOPE") is None)
}

///|
test "多个 01 并列拼接" {
  let specs = [
    group(1, "R1", [leaf(5, "A", pic_x(3))]),
    group(1, "R2", [leaf(5, "B", pic_x(4))]),
  ]
  let layout = compile_layout(specs)
  inspect(layout.name, content="R1")
  inspect(layout.byte_length, content="7")
}

///|
test "嵌套多层组偏移" {
  let inner = group(10, "INNER", [leaf(15, "DEEP", pic_x(2))])
  let mid = group(5, "MID", [
    leaf(10, "BEFORE", pic_x(3)),
    inner,
    leaf(10, "AFTER", pic_x(1)),
  ])
  let layout = compile_layout([group(1, "R", [mid])])
  inspect(layout.byte_length, content="6")
  inspect(layout.find("R.MID.BEFORE").unwrap().offset, content="0")
  inspect(layout.find("R.MID.INNER.DEEP").unwrap().offset, content="3")
  inspect(layout.find("R.MID.AFTER").unwrap().offset, content="5")
}
