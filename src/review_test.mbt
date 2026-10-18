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
