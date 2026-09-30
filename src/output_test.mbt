// output 单元测试：逐字符比对，尤其是 render_layout 的列宽。

///|
fn o_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n    05  CUST-NAME      PIC X(30).\n    05  BALANCE        PIC S9(7)V99 COMP-3.\n    05  OPEN-DATE      PIC 9(8).\n    05  FLAGS.\n        10  ACTIVE     PIC X(1).\n        10  TIER       PIC 9(2).\n",
    ),
  )
}

///|
/// 构造一行示例数据
fn o_row() -> Map[String, CellValue] {
  let m : Map[String, CellValue] = Map([])
  m["CUSTOMER-RECORD.CUST-ID"] = Int(42L)
  m["CUSTOMER-RECORD.CUST-NAME"] = Text("ALICE")
  m["CUSTOMER-RECORD.BALANCE"] = Decimal(
    Decimal::from_parts(123456789L, 2, false),
  )
  m["CUSTOMER-RECORD.OPEN-DATE"] = Int(20260930L)
  m["CUSTOMER-RECORD.FLAGS.ACTIVE"] = Text("Y")
  m["CUSTOMER-RECORD.FLAGS.TIER"] = Int(7L)
  m
}

///|
/// render_layout 必须与 API.md 的样例**逐字符一致**。
test "render_layout 与 API.md 样例逐字符一致" {
  let layout = o_layout()
  let expected = "RECORD: CUSTOMER-RECORD                          LENGTH: 54 bytes\n\nOFFSET  LENGTH  OCCURS  TYPE              NAME\n     0       8       1  9(8) DISPLAY      CUSTOMER-RECORD.CUST-ID\n     8      30       1  X(30) DISPLAY     CUSTOMER-RECORD.CUST-NAME\n    38       5       1  S9(7)V99 COMP-3   CUSTOMER-RECORD.BALANCE\n    43       8       1  9(8) DISPLAY      CUSTOMER-RECORD.OPEN-DATE\n    51       1       1  X(1) DISPLAY      CUSTOMER-RECORD.FLAGS.ACTIVE\n    52       2       1  9(2) DISPLAY      CUSTOMER-RECORD.FLAGS.TIER"
  let actual = render_layout(layout)
  if actual != expected {
    abort(
      "render_layout mismatch:\n--- expected ---\n\{expected}\n--- actual ---\n\{actual}",
    )
  }
}

///|
test "render_layout 行数 = 2 + 表头 + 字段数" {
  let layout = o_layout()
  let out = render_layout(layout)
  let lines = out.split("\n").collect()
  // 标题 + 空行 + 表头 + 6 个字段行
  inspect(lines.length(), content="9")
}

///|
test "render_layout 不列组项" {
  let layout = o_layout()
  let out = render_layout(layout)
  assert_true(!out.contains("FLAGS  "))
  assert_true(out.contains("FLAGS.ACTIVE"))
}

///|
test "render_layout 记录名超长时 LENGTH 仍对齐到 49 列" {
  let long_name = "A-VERY-LONG-RECORD-NAME-THAT-EXCEEDS-THE-COLUMN"
  let layout = compile_layout(
    parse_copybook("01 \{long_name}.\n  05 F PIC X(1).\n"),
  )
  let out = render_layout(layout)
  let first_line = out.split("\n").collect()[0].to_owned()
  // LENGTH: 必须在第 49 列之后（索引 49）
  let idx = first_line.find("LENGTH:")
  match idx {
    Some(i) => assert_true(i >= 49)
    None => fail("LENGTH: missing")
  }
}

///|
test "render_jsonl 单行单对象" {
  let layout = o_layout()
  let rows = [o_row()]
  let out = render_jsonl(layout, rows)
  // 恰好一行
  inspect(out.split("\n").collect().length(), content="2")
  // 键按 layout 顺序，值正确
  let expected = "{\"CUSTOMER-RECORD.CUST-ID\":42,\"CUSTOMER-RECORD.CUST-NAME\":\"ALICE\",\"CUSTOMER-RECORD.BALANCE\":1234567.89,\"CUSTOMER-RECORD.OPEN-DATE\":20260930,\"CUSTOMER-RECORD.FLAGS.ACTIVE\":\"Y\",\"CUSTOMER-RECORD.FLAGS.TIER\":7}\n"
  if out != expected {
    abort(
      "jsonl mismatch:\n--- expected ---\n\{expected}\n--- actual ---\n\{out}",
    )
  }
}

///|
test "render_jsonl 多条记录" {
  let layout = o_layout()
  let rows = [o_row(), o_row()]
  let out = render_jsonl(layout, rows)
  let lines = out.split("\n").collect()
  inspect(lines.length(), content="3")
  assert_true(lines[0] == lines[1])
}

///|
test "render_jsonl 转义引号与反斜杠" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC X(4).\n"))
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Text("a\"b\\")
  let out = render_jsonl(layout, [m])
  // 必须正确转义成 \" 与 \\
  inspect(out, content="{\"R.A\":\"a\\\"b\\\\\"}\n")
}

///|
test "render_jsonl 空文本与 null" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(4).\n  05 B PIC 9(2).\n"),
  )
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Text("")
  // B 缺失 → Null → json null
  let out = render_jsonl(layout, [m])
  inspect(out, content="{\"R.A\":\"\",\"R.B\":null}\n")
}

///|
test "render_jsonl Int64 大数不丢精度" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(18).\n"))
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Int(123456789012345678L)
  let out = render_jsonl(layout, [m])
  // repr 传原文，不能变成 1.2345678901234568e17
  inspect(out, content="{\"R.A\":123456789012345678}\n")
}

///|
test "render_jsonl Bytes 转十六进制" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  let m : Map[String, CellValue] = Map([])
  let arr : Array[Byte] = []
  let v1 = 0x01
  let v2 = 0xAB
  arr.push(v1.to_byte())
  arr.push(v2.to_byte())
  m["R.A"] = Bytes(Bytes::from_array(arr))
  let out = render_jsonl(layout, [m])
  inspect(out, content="{\"R.A\":\"01ab\"}\n")
}

///|
test "render_table 对齐" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 ID PIC 9(4).\n  05 NAME PIC X(6).\n"),
  )
  let m1 : Map[String, CellValue] = Map([])
  m1["R.ID"] = Int(1L)
  m1["R.NAME"] = Text("AB")
  let m2 : Map[String, CellValue] = Map([])
  m2["R.ID"] = Int(9999L)
  m2["R.NAME"] = Text("LONGER")
  let out = render_table(layout, [m1, m2])
  let expected = "ID    NAME  \n----  ------\n   1  AB    \n9999  LONGER\n"
  if out != expected {
    abort(
      "table mismatch:\n--- expected ---\n\{expected}\n--- actual ---\n\{out}",
    )
  }
}

///|
test "render_table 空行集只有表头" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  let out = render_table(layout, [])
  let lines = out.split("\n").collect()
  inspect(lines.length(), content="3")
  inspect(lines[0].to_owned(), content="A")
  inspect(lines[1].to_owned(), content="-")
}

///|
test "render_table 无字段返回空串" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 G.\n    10 A PIC X(1).\n"),
  )
  // 去掉叶子之外没有组 —— 这里仍有 1 个叶子，故非空
  let out = render_table(layout, [])
  assert_true(out.length() > 0)
}

///|
test "render_jsonl 空行集返回空串" {
  let layout = o_layout()
  let rows : Array[Map[String, CellValue]] = []
  inspect(render_jsonl(layout, rows), content="")
}
