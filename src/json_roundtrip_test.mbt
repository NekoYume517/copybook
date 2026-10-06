// JSON 往返保真测试。
//
// 这里覆盖一个曾经真实存在的缺陷，而 `verify` 子命令**掩盖了它**：
//
//   `verify` 在内存里做 decode → encode，不经过 JSON，所以 `Decimal` 保持
//   完整的 coefficient/scale，往返当然成立。
//
//   但真实工作流是 `decode --format jsonl > out.jsonl` 然后
//   `encode --json out.jsonl`。JSON 没有定点小数类型，`5.00` 序列化成 `5`，
//   读回来变成 `scale=0, coef=5`。如果编码器直接用这个 scale，字段要求
//   scale=2 时就会把 500 分写成 5 分 —— 100 倍的数据损坏，且静默成功。
//
// 因此需要专门测「经过 JSON 文本」这一条路径，而不是只在内存里往返。

///|
/// 走完整链路：记录 → JSONL 文本 → 解析回 CellValue → 记录。
fn json_roundtrip(
  layout : RecordLayout,
  record : Bytes,
) -> Result[Bytes, String] {
  let values = match decode_record(layout, record.exact_view()) {
    Ok(v) => v
    Err(e) => return Err("decode failed: " + e.to_display())
  }
  let rows : Array[Map[String, CellValue]] = [values]
  let jsonl = render_jsonl(layout, rows)
  let lines = jsonl.split("\n").collect()
  if lines.length() == 0 {
    return Err("render_jsonl produced no line")
  }
  let line = lines[0].to_owned()
  let parsed = match parse_jsonl_row(layout, line) {
    Ok(m) => m
    Err(msg) => return Err("parse_jsonl_row failed: " + msg)
  }
  match encode_record(layout, parsed) {
    Ok(b) => Ok(b)
    Err(e) => Err("encode failed: " + e.to_display())
  }
}

///|
/// 单字段 copybook 的布局，`AMT PIC S9(7)V99 COMP-3`（5 字节）。
fn amount_layout() -> RecordLayout raise {
  compile_layout(parse_copybook("01 R.\n  05 AMT PIC S9(7)V99 COMP-3.\n"))
}

///|
/// 逐字节比较两个 Bytes，返回第一个不同的偏移（相同则 None）。
fn first_diff(a : Bytes, b : Bytes) -> Int32? {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    if a[i].to_int() != b[i].to_int() {
      return Some(i)
    }
  }
  if a.length() != b.length() {
    return Some(n)
  }
  None
}

///|
test "JSON 往返：5.00 序列化成 5 之后仍还原成 500 分（历史缺陷回归）" {
  // 这是核心回归点。修复前，`as_decimal` 直接用 JSON 文本解析出的
  // scale=0，把 500 分写成 5 分 —— 100 倍损坏且不报错。
  let layout = amount_layout()
  // packed: 00 00 00 50 0C  => coefficient 500, scale 2, 正号
  let rec : Bytes = b"\x00\x00\x00\x50\x0C"
  match json_roundtrip(layout, rec) {
    Ok(b) => {
      inspect(b.length(), content="5")
      match first_diff(rec, b) {
        None => inspect(true, content="true")
        Some(off) => {
          println("mismatch at offset \{off}")
          inspect(false, content="true")
        }
      }
    }
    Err(msg) => {
      println("unexpected error: \{msg}")
      inspect(false, content="true")
    }
  }
}

///|
test "JSON 往返：小数位非零的值不受影响" {
  let layout = amount_layout()
  // 12 34 56 78 9C => coefficient 123456789, scale 2 => 1234567.89
  let rec : Bytes = b"\x12\x34\x56\x78\x9C"
  match json_roundtrip(layout, rec) {
    Ok(b) =>
      match first_diff(rec, b) {
        None => inspect(true, content="true")
        Some(off) => {
          println("mismatch at offset \{off}")
          inspect(false, content="true")
        }
      }
    Err(msg) => {
      println("unexpected error: \{msg}")
      inspect(false, content="true")
    }
  }
}

///|
test "JSON 往返：整数部分为零的小数" {
  let layout = amount_layout()
  // 00 00 00 00 5C => coefficient 5, scale 2 => 0.05
  let rec : Bytes = b"\x00\x00\x00\x00\x5C"
  match json_roundtrip(layout, rec) {
    Ok(b) =>
      match first_diff(rec, b) {
        None => inspect(true, content="true")
        Some(off) => {
          println("mismatch at offset \{off}")
          inspect(false, content="true")
        }
      }
    Err(msg) => {
      println("unexpected error: \{msg}")
      inspect(false, content="true")
    }
  }
}

///|
test "align_scale：scale 放大时系数乘以 10 的幂" {
  let d = Decimal::from_parts(5L, 0, false)
  match align_scale(d, 2, 0) {
    Ok(aligned) => {
      inspect(aligned.coefficient, content="500")
      inspect(aligned.scale, content="2")
      inspect(aligned.negative, content="false")
    }
    Err(_) => inspect(false, content="true")
  }
}

///|
test "align_scale：放大时保留负号" {
  let d = Decimal::from_parts(-7L, 0, true)
  match align_scale(d, 3, 0) {
    Ok(aligned) => {
      inspect(aligned.coefficient, content="-7000")
      inspect(aligned.scale, content="3")
      inspect(aligned.negative, content="true")
    }
    Err(_) => inspect(false, content="true")
  }
}

///|
test "align_scale：缩小且低位为零时成功" {
  let d = Decimal::from_parts(12300L, 4, false)
  match align_scale(d, 2, 0) {
    Ok(aligned) => {
      inspect(aligned.coefficient, content="123")
      inspect(aligned.scale, content="2")
    }
    Err(_) => inspect(false, content="true")
  }
}

///|
test "align_scale：缩小遇到非零小数位时报精度损失而不是静默截断" {
  // 1.234 塞不进 scale=2 的字段
  let d = Decimal::from_parts(1234L, 3, false)
  match align_scale(d, 2, 0) {
    Ok(_) => inspect(false, content="should have failed")
    Err(InvalidNumeric(_, _)) => inspect(true, content="true")
    Err(_) => inspect(false, content="wrong error kind")
  }
}

///|
test "align_scale：scale 相同时原样返回" {
  let d = Decimal::from_parts(12345L, 2, false)
  match align_scale(d, 2, 0) {
    Ok(aligned) => {
      inspect(aligned.coefficient, content="12345")
      inspect(aligned.scale, content="2")
    }
    Err(_) => inspect(false, content="true")
  }
}
