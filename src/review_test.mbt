// 外部审查发现的缺陷回归测试（review_test.mbt）
//
// 每个测试对应一条来自代码审查的复现路径，修复前全部失败。

///|
test "C3: SIGN SEPARATE LEADING 的数字是 [1..n)，不再丢末位" {
  // PIC S9(3) SIGN IS LEADING SEPARATE → 1 符号字节 + 3 数字 = 4 字节
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3) SIGN IS LEADING SEPARATE.\n"),
  )
  inspect(layout.byte_length, content="4")
  // 4E F1 F2 F3 = +123，修复前解出 12
  let rec : Bytes = b"\x4E\xF1\xF2\xF3"
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          inspect(d.coefficient, content="123")
          inspect(d.negative, content="false")
        }
        other => {
          println("unexpected cell (not a Decimal)")
          inspect(false, content="true")
        }
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 60 F1 F2 F3 = -123
  let neg : Bytes = b"\x60\xF1\xF2\xF3"
  match decode_record(layout, neg) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          inspect(d.coefficient, content="123")
          inspect(d.negative, content="true")
        }
        _ => inspect(false, content="true")
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 编码端对称：+123 → 4E F1 F2 F3
  match
    encode_record(
      layout,
      map_of([("A", Decimal(Decimal::from_parts(123L, 0, false)))]),
    ) {
    Ok(b) => {
      inspect(b[0].to_int(), content="78")
      inspect(b[1].to_int(), content="241")
      inspect(b[3].to_int(), content="243")
    }
    Err(e) => {
      println("encode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C4: 内嵌 SIGN IS LEADING 的负号在首字节高半字节" {
  // PIC S9(3) SIGN IS LEADING → 3 字节，首字节高半字节是符号
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3) SIGN IS LEADING.\n"),
  )
  inspect(layout.byte_length, content="3")
  // D1 F2 F3 = -123，修复后解出 -123（修复前 123）
  let rec : Bytes = b"\xD1\xF2\xF3"
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          inspect(d.coefficient, content="123")
          inspect(d.negative, content="true")
        }
        _ => inspect(false, content="true")
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 往返：encode(-123) → D1 F2 F3
  match
    encode_record(
      layout,
      map_of([("A", Decimal(Decimal::from_parts(123L, 0, true)))]),
    ) {
    Ok(b) => {
      inspect(b[0].to_int(), content="209")
      inspect(b[1].to_int(), content="242")
      inspect(b[2].to_int(), content="243")
    }
    Err(_) => inspect(false, content="true")
  }
  // 正数 +123 → F1 F2 F3。
  // zoned 的正 zone 是 0xF（decode 同时接受 0xC 作为宽容输入）；
  // 这与 packed 不同 —— packed 有符号正号写 0xC。
  match
    encode_record(
      layout,
      map_of([("A", Decimal(Decimal::from_parts(123L, 0, false)))]),
    ) {
    Ok(b) => {
      inspect(b[0].to_int(), content="241")
      inspect(b[1].to_int(), content="242")
      inspect(b[2].to_int(), content="243")
    }
    Err(_) => inspect(false, content="true")
  }
}

///|
test "C5: 组级 USAGE 继承改变存储形态" {
  // 05 G USAGE COMP-3 / 10 X PIC 9(3) → X 是 2 字节 packed
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 G USAGE COMP-3.\n    10 X PIC 9(3).\n"),
  )
  inspect(layout.byte_length, content="2")
  match layout.fields[0] {
    f => inspect(f.pic.usage.name(), content="COMP-3")
  }
  // packed 往返：00 12 3C = 123
  let rec : Bytes = b"\x12\x3C"
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.G.X") {
        Some(Decimal(d)) => inspect(d.coefficient, content="123")
        other => {
          println("unexpected cell (not a Decimal)")
          inspect(false, content="true")
        }
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C6: 无符号 COMP-3 的正号是 0xF，逐字节往返标准数据" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC 9(3) COMP-3.\n"),
  )
  // 标准工具生成的无符号正数是 12 3F
  let rec : Bytes = b"\x12\x3F"
  match roundtrip_check(layout, rec) {
    Ok(None) => inspect(true, content="true")
    Ok(Some(off)) => {
      println("byte mismatch at \{off}")
      inspect(false, content="true")
    }
    Err(e) => {
      println("roundtrip error: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C1: 组级 OCCURS 展开全部元素且逐字节往返" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G OCCURS 3 TIMES.\n    10 X PIC 9(2).\n    10 Y PIC S9(3) COMP-3.\n",
    ),
  )
  inspect(layout.byte_length, content="12") // 3 × (2 + 2)
  // 每元素：zoned 2B + packed 2B（4 数字 + 符号）
  // 元素 1: X=11, Y=111 → F1F1 01 11 1C
  // 元素 2: X=22, Y=222 → F2F2 02 22 2C
  // 元素 3: X=33, Y=333 → F3F3 03 33 3C
  // 每元素 4 字节：zoned X(2B) + packed Y(2B)
  //   elem1: F1 F1 | 11 1C   (X=11, Y=111)
  //   elem2: F2 F2 | 22 2C   (X=22, Y=222)
  //   elem3: F3 F3 | 33 3C   (X=33, Y=333)
  let rec : Bytes = b"\xF1\xF1\x11\x1C\xF2\xF2\x22\x2C\xF3\xF3\x33\x3C"
  match decode_record(layout, rec) {
    Ok(m) => {
      // 全部 6 个键都在
      inspect(m.contains("R.G.X(1)"), content="true")
      inspect(m.contains("R.G.Y(1)"), content="true")
      inspect(m.contains("R.G.X(2)"), content="true")
      inspect(m.contains("R.G.Y(2)"), content="true")
      inspect(m.contains("R.G.X(3)"), content="true")
      inspect(m.contains("R.G.Y(3)"), content="true")
      // 修复前只能看到第 0 组的 2 个键
      match m.get("R.G.Y(2)") {
        Some(Decimal(d)) => inspect(d.coefficient, content="222")
        other => {
          println("Y(2) missing or not Decimal")
          inspect(false, content="true")
        }
      }
    }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 逐字节往返
  match roundtrip_check(layout, rec) {
    Ok(None) => inspect(true, content="true")
    Ok(Some(off)) => {
      println("byte mismatch at \{off}")
      inspect(false, content="true")
    }
    Err(e) => {
      println("roundtrip error: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C2: 重定义视图为 Null 时不覆盖主视图字节" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC S9(3) COMP-3.\n  05 B REDEFINES A PIC X(2).\n  05 C PIC X(2).\n",
    ),
  )
  inspect(layout.byte_length, content="4")
  // A=123 → 12 3C；B 视图解不出（12 不是可打印 EBCDIC）；C=XY
  let rec : Bytes = b"\x12\x3C\xC5\xC8"
  match decode_record(layout, rec) {
    Ok(m) => {
      match m.get("R.A") {
        Some(Decimal(d)) => inspect(d.coefficient, content="123")
        _ => inspect(false, content="true")
      }
      // B 视图宽容置 Null
      match m.get("R.B") {
        Some(Null) => inspect(true, content="true")
        other => {
          println("B expected Null")
          inspect(false, content="true")
        }
      }
      // 关键断言：把这份 map 编码回去，A 的字节必须原样保留
      match encode_record(layout, m) {
        Ok(b) => {
          inspect(b[0].to_int(), content="18")
          inspect(b[1].to_int(), content="60")
          inspect(b[2].to_int(), content="197")
          inspect(b[3].to_int(), content="200")
        }
        Err(e) => {
          println("encode failed: \{e.to_display()}")
          inspect(false, content="true")
        }
      }
    }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "R1: 尾随 P 折算为负 scale，值语义 123 → 12300" {
  // PIC 9(3)PP：存储 3 位数字，P 是小数点右移 2 位的缩放位。
  // COBOL 语义：存储 123 表示值 12300（值 = 系数 × 10^2）。
  let pc = parse_pic_clause("9(3)PP", 1, 1)
  inspect(pc.storage_digits, content="3")
  inspect(pc.scale, content="-2")
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(3)PP.\n"))
  inspect(layout.byte_length, content="3")
  // F1 F2 F3 = 存储 123 → 值 12300
  let rec : Bytes = b"\xF1\xF2\xF3"
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          inspect(d.coefficient, content="123")
          inspect(d.scale, content="-2")
          inspect(d.to_string(), content="12300")
        }
        other => {
          println("unexpected cell (not a Decimal)")
          inspect(false, content="true")
        }
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "R1b: 前导 P 计入 scale，值语义 123 → 0.00123" {
  // PIC PP9(3) = VPP999：小数点在最左，P 是小数点后的隐含零位。
  // 值 = 系数 × 10^-(2+3)，存储 123 表示 0.00123。
  let pc = parse_pic_clause("PP9(3)", 1, 1)
  inspect(pc.storage_digits, content="3")
  inspect(pc.scale, content="5")
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC PP9(3).\n"))
  inspect(layout.byte_length, content="3")
  let rec : Bytes = b"\xF1\xF2\xF3"
  match decode_record(layout, rec) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          inspect(d.coefficient, content="123")
          inspect(d.scale, content="5")
          inspect(d.to_string(), content="0.00123")
        }
        other => {
          println("unexpected cell (not a Decimal)")
          inspect(false, content="true")
        }
      }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "R2: 嵌套 OCCURS 键名下标按外层→内层顺序" {
  // G1 OCCURS 2 { G2 OCCURS 2 { X } }：4 个元素的下标语义是
  // X(i)(j) = G1 第 i 次、G2 第 j 次。存储顺序按行展开：
  //   offset 0: G1=1,G2=1 → 11
  //   offset 2: G1=1,G2=2 → 12
  //   offset 4: G1=2,G2=1 → 21
  //   offset 6: G1=2,G2=2 → 22
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G1 OCCURS 2 TIMES.\n    10 G2 OCCURS 2 TIMES.\n      20 X PIC 9(2).\n",
    ),
  )
  inspect(layout.byte_length, content="8")
  let rec : Bytes =
    b"\xF1\xF1\xF1\xF2\xF2\xF1\xF2\xF2"
  match decode_record(layout, rec) {
    Ok(m) => {
      match m.get("R.G1.G2.X(1)(1)") {
        Some(Int(v)) => inspect(v, content="11")
        other => {
          println("X(1)(1) wrong: not Int")
          inspect(false, content="true")
        }
      }
      match m.get("R.G1.G2.X(1)(2)") {
        Some(Int(v)) => inspect(v, content="12")
        other => {
          println("X(1)(2) wrong: not Int")
          inspect(false, content="true")
        }
      }
      match m.get("R.G1.G2.X(2)(1)") {
        Some(Int(v)) => inspect(v, content="21")
        other => {
          println("X(2)(1) wrong: not Int")
          inspect(false, content="true")
        }
      }
      match m.get("R.G1.G2.X(2)(2)") {
        Some(Int(v)) => inspect(v, content="22")
        other => {
          println("X(2)(2) wrong: not Int")
          inspect(false, content="true")
        }
      }
    }
    Err(e) => {
      println("decode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 编码端按同样键名写回，逐字节还原
  let m2 : Map[String, CellValue] = Map([])
  m2["R.G1.G2.X(1)(1)"] = Int(11L)
  m2["R.G1.G2.X(1)(2)"] = Int(12L)
  m2["R.G1.G2.X(2)(1)"] = Int(21L)
  m2["R.G1.G2.X(2)(2)"] = Int(22L)
  match roundtrip_check(layout, rec) {
    Ok(None) => inspect(true, content="true")
    Ok(Some(off)) => {
      println("byte mismatch at \{off}")
      inspect(false, content="true")
    }
    Err(e) => {
      println("roundtrip error: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
  // 编码下标键 → 字节位置：X(2)(1)（G1=2,G2=1）必须写在 offset 4
  match encode_record(layout, m2) {
    Ok(b) => {
      inspect(b.length(), content="8")
      inspect(b[4].to_int(), content="242") // F2
      inspect(b[5].to_int(), content="241") // F1
    }
    Err(e) => {
      println("encode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "R3: COMP-1/2 的 Inf/NaN 输出合法 JSON 并可回读" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 F1 PIC 9 USAGE COMP-1.\n  05 F2 PIC 9 USAGE COMP-2.\n"),
  )
  // 构造 +Inf / -Inf / NaN 行
  let pos_inf = 1.0 / 0.0
  let neg_inf = -1.0 / 0.0
  let nan = 0.0 / 0.0
  let rows : Array[Map[String, CellValue]] = []
  let m1 : Map[String, CellValue] = Map([])
  m1["R.F1"] = Float(pos_inf)
  m1["R.F2"] = Float(neg_inf)
  let m2 : Map[String, CellValue] = Map([])
  m2["R.F1"] = Float(nan)
  m2["R.F2"] = Null
  rows.push(m1)
  rows.push(m2)
  let jsonl = render_jsonl(layout, rows)
  // 每行必须是合法 JSON：非有限值带引号输出
  inspect(jsonl.contains("\"Infinity\""), content="true")
  inspect(jsonl.contains("\"-Infinity\""), content="true")
  inspect(jsonl.contains("\"NaN\""), content="true")
  inspect(jsonl.contains("Infinity"), content="true")
  // 回读：字符串形式能解回 Float
  let lines = jsonl.split("\n").collect()
  match parse_jsonl_row(layout, lines[0].to_owned()) {
    Ok(m) =>
      match m.get("R.F1") {
        Some(Float(f)) => {
          // +Inf == +Inf 成立；用相等而不是减法（Inf-Inf = NaN）
          inspect(f == pos_inf, content="true")
        }
        other => {
          println("F1 expected Float(Inf)")
          inspect(false, content="true")
        }
      }
    Err(msg) => {
      println("parse row1 failed: \{msg}")
      inspect(false, content="true")
    }
  }
  match parse_jsonl_row(layout, lines[1].to_owned()) {
    Ok(m) =>
      match m.get("R.F1") {
        Some(Float(f)) => inspect(f != f, content="true") // NaN != NaN
        other => {
          println("F1 expected Float(NaN)")
          inspect(false, content="true")
        }
      }
    Err(msg) => {
      println("parse row2 failed: \{msg}")
      inspect(false, content="true")
    }
  }
}

///|
test "R5: 子项显式 USAGE 优先于组级 USAGE 继承" {
  // COBOL 标准：子项显式声明 USAGE 优先，组级 USAGE 只补缺省。
  // 05 G USAGE COMP-3. 10 A PIC 9(3) USAGE DISPLAY. → A 是 zoned 3 字节，
  // 不是 COMP-3 2 字节。
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G USAGE COMP-3.\n    10 A PIC 9(3) USAGE DISPLAY.\n",
    ),
  )
  inspect(layout.byte_length, content="3")
  match layout.fields[0] {
    f => inspect(f.pic.usage.name(), content="DISPLAY")
  }
  // 裸写 COMP 族也算显式声明
  let layout2 = compile_layout(
    parse_copybook(
      "01 R2.\n  05 G COMP-3.\n    10 A PIC 9(3) COMP.\n",
    ),
  )
  match layout2.fields[0] {
    f => inspect(f.pic.usage.name(), content="COMP")
  }
  // 对照组：子项未声明仍正常继承（既有 C5 行为不回归）
  let layout3 = compile_layout(
    parse_copybook("01 R3.\n  05 G USAGE COMP-3.\n    10 X PIC 9(3).\n"),
  )
  inspect(layout3.byte_length, content="2")
  match layout3.fields[0] {
    f => inspect(f.pic.usage.name(), content="COMP-3")
  }
}

///|
test "R6: Int64::MIN 系数的 abs 不回绕" {
  // coefficient == Int64::MIN 时 abs() 回绕仍为负：
  // to_string 输出 "--9223..."（双负号），encode 的 decimal_digits
  // 同样拿到负数串。
  let dmin = Decimal::from_parts(-9223372036854775808L, 0, true)
  let s = dmin.to_string()
  // 不得出现双负号；首位 '-' 后面是纯数字
  inspect(s.has_prefix("-"), content="true")
  inspect(s.has_prefix("--"), content="false")
  // 对称正侧：negative=false 且 coefficient 为正也可以表达同值
  let dmax = Decimal::from_parts(9223372036854775807L, 0, false)
  inspect(dmax.to_string(), content="9223372036854775807")
  // encode 路径：to_string 修复后 to_display 不再产出 "--"；encode 对
  // MIN 绝对值（19 位）超出 18 位字段容量，按「绝不静默修正」明确报错。
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(18) COMP-3.\n"),
  )
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Decimal(dmin)
  match encode_record(layout, m) {
    Ok(_) => inspect(false, content="19 digits must not fit S9(18)")
    Err(InvalidNumeric(_, msg)) => {
      // 错误消息里的值串也是修复后的 |MIN|（19 位），无 "--"
      inspect(msg.has_prefix("value -"), content="false")
      inspect(msg.contains("9223372036854775808"), content="true")
      inspect(msg.has_prefix("--"), content="false")
    }
    Err(_) => inspect(false, content="wrong error kind")
  }
}

// ============================================================
// 辅助
// ============================================================

///|
fn map_of(pairs : Array[(String, CellValue)]) -> Map[String, CellValue] {
  let m : Map[String, CellValue] = Map([])
  for pair in pairs {
    m[pair.0] = pair.1
  }
  m
}

///|
test "C8: COMP 拒绝超过十进制位数的值（与 DISPLAY 同规则）" {
  // PIC S9(2) COMP 只占 1 字节，二进制容量装得下 100，
  // 但字段语义是「2 位十进制」——100 超出，必须报错而不是静默接受。
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(2) COMP.\n"))
  inspect(layout.byte_length, content="1")
  match encode_record(layout, map_of([("A", Int(100L))])) {
    Ok(_) => inspect(false, content="100 into S9(2) COMP should fail")
    Err(InvalidNumeric(_, _)) => inspect(true, content="true")
    Err(_) => inspect(false, content="wrong error kind")
  }
  // 99 仍合法（二进制容量之内）
  match encode_record(layout, map_of([("A", Int(99L))])) {
    Ok(_) => inspect(true, content="true")
    Err(e) => {
      println("99 should fit: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C9: 布局偏移溢出报 InvalidLayout 而不是回绕" {
  // 10^10 超出 Int32；旧实现静默回绕成 1410065408
  // 溢出在布局层（compile_layout），不在语法层——必须显式调用
  let err = try {
    let specs = parse_copybook("01 BIG.\n  05 A PIC X(100000) OCCURS 100000.\n")
    let _ = compile_layout(specs)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
  // 实际消息形如 "field 'A': length 100000 x OCCURS 100000 exceeds Int32"
  // 旧实现这里静默回绕出 1410065408，根本不会进入错误路径
  let ok = err.contains("exceeds Int32") && err.contains("10000000000")
  if !ok {
    println("actual message: \{err}")
  }
  inspect(ok, content="true")
}

///|
test "C10: 前导 P 不占存储" {
  // PP9(3)：P 是缩放字符，存储只有 3 个数字位
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC PP9(3).\n"))
  inspect(layout.byte_length, content="3")
}

///|
test "C11: PIC N 的填充字节是 EBCDIC 空格，标准数据逐字节往返" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC N(2).\n"))
  // 标准工具生成的 N 字段填充是 0x40（旧实现写 0x00）
  let rec : Bytes = b"\xC1\x40\xC2\x40"
  match roundtrip_check(layout, rec) {
    Ok(None) => inspect(true, content="true")
    Ok(Some(off)) => {
      println("byte mismatch at \{off}")
      inspect(false, content="true")
    }
    Err(e) => {
      println("roundtrip error: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}

///|
test "C12: Int(-42) 写 COMP 的符号不再翻转" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(4) COMP.\n"))
  // 库 API 的 Int 输入路径：S9(4) COMP 占 1 字节，-42 = 0xD6（补码），
  // 不是 0x2A（+42）
  match encode_record(layout, map_of([("A", Int(-42L))])) {
    Ok(b) => {
      inspect(b.length(), content="1")
      inspect(b[0].to_int(), content="214")
    }
    Err(e) => {
      println("encode failed: \{e.to_display()}")
      inspect(false, content="true")
    }
  }
}
