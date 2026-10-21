///|
test "examples/customer.cpy 端到端布局" {
  let src = "\n01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n    05  CUST-NAME      PIC X(30).\n    05  BALANCE        PIC S9(7)V99 COMP-3.\n    05  OPEN-DATE      PIC 9(8).\n    05  FLAGS.\n        10  ACTIVE     PIC X(1).\n        10  TIER       PIC 9(2).\n"
  let specs = parse_copybook(src)
  let layout = compile_layout(specs)
  inspect(layout.name, content="CUSTOMER-RECORD")
  inspect(layout.byte_length, content="54")
  let expected : Array[(String, Int32, Int32)] = [
    ("CUST-ID", 0, 8),
    ("CUST-NAME", 8, 30),
    ("BALANCE", 38, 5),
    ("OPEN-DATE", 43, 8),
    ("ACTIVE", 51, 1),
    ("TIER", 52, 2),
  ]
  for e in expected {
    let (n, off, len) = e
    let f = layout.find(n).unwrap()
    inspect(f.offset, content=off.to_string())
    inspect(f.byte_length, content=len.to_string())
  }
}

///|
test "examples/order.cpy 端到端布局" {
  let src = "\n01  ORDER-LINES.\n    05  ORDER-ID       PIC 9(10).\n    05  LINE-COUNT     PIC 9(3).\n    05  LINES OCCURS 5 TIMES.\n        10  SKU        PIC X(12).\n        10  QTY        PIC S9(4) COMP.\n        10  PRICE      PIC S9(5)V99 COMP-3.\n"
  let layout = compile_layout(parse_copybook(src))
  inspect(layout.name, content="ORDER-LINES")
  inspect(layout.byte_length, content="103")
  let lines = layout.find("LINES").unwrap()
  inspect(lines.byte_length, content="18")
  inspect(lines.occurs, content="5")
  inspect(lines.total_length, content="90")
}

///|
test "examples/redefines.cpy 端到端布局" {
  let src = "\n01  ACCOUNT-MASTER.\n    05  ACCT-NO        PIC 9(12).\n    05  ACCT-TYPE      PIC X(2).\n    05  LIMIT-AMT      PIC S9(9)V99 COMP-3.\n    05  ALT-VIEW REDEFINES LIMIT-AMT.\n        10  RAW-BYTE   PIC X(6).\n    05  SSN            PIC 9(9).\n"
  let layout = compile_layout(parse_copybook(src))
  inspect(layout.name, content="ACCOUNT-MASTER")
  inspect(layout.byte_length, content="29")
  inspect(layout.find("LIMIT-AMT").unwrap().offset, content="14")
  inspect(layout.find("RAW-BYTE").unwrap().offset, content="14")
  inspect(layout.find("SSN").unwrap().offset, content="20")
  // 两者同属一个重定义组
  let a = layout.find("LIMIT-AMT").unwrap()
  let b = layout.find("RAW-BYTE").unwrap()
  assert_true(a.redefine_group != 0)
  inspect(a.redefine_group, content=b.redefine_group.to_string())
}
