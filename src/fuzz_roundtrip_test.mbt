// 确定性随机字节往返（2026-11-11 审计新增）。
//
// 目的：把「decode → encode 逐字节相同」这条 L1 承诺从手写样例扩展到
// 数千条随机记录。生成器按字段的 PIC 选择**该类型合法的字节空间**
// （zoned 的 F 区号与 C/D/F 符号、COMP-3 的 0..9 数字半字节与符号、
// NATIONAL 的非代理项码元、文本的可打印 EBCDIC），否则均匀随机字节在
// zoned / packed 上几乎全部解码失败，测不到任何东西。
//
// 固定 LCG 种子，失败时打印 copybook、轮次与输入/输出字节，保证可复现。
// 已知且**已声明**的规范化不在此列：
//   - `JUSTIFIED RIGHT` 生成的数据保证右侧非空格（左对齐的非规范输入
//     会被右对齐改写，这是编码契约，不是字节保真缺陷）；
//   - HFP 非规格化尾数在 decode 侧按 CB-19 拒收，随机字节被跳过。

///|
fn fz_next(st : Array[Int32]) -> Int32 {
  let s = (st[0].to_int64() * 1103515245L + 12345L) & 2147483647L
  st[0] = s.to_int()
  st[0]
}

///|
fn fz_below(st : Array[Int32], n : Int32) -> Int32 {
  fz_next(st) % n
}

///|
fn fz_hex(bs : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 0; i < bs.length(); i = i + 1 {
    let v = bs[i].to_int()
    sb.write_char(digits.get_char((v >> 4) & 0xF).unwrap())
    sb.write_char(digits.get_char(v & 0xF).unwrap())
  }
  sb.to_string()
}

///|
fn fz_fill_random(
  st : Array[Int32],
  arr : Array[Byte],
  start : Int32,
  n : Int32,
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    arr[start + i] = fz_below(st, 256).to_byte()
  }
}

///|
fn fz_fill_text(
  st : Array[Int32],
  arr : Array[Byte],
  start : Int32,
  n : Int32,
  justified_right : Bool,
) -> Unit {
  // 全部是 cp037 可表示的可打印 ASCII；编辑型/字符型都适用。
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,-/$*+Z"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let idx = fz_below(st, alphabet.length())
    chars.push(alphabet.get_char(idx).unwrap())
  }
  if justified_right && n > 0 && chars[n - 1] == ' ' {
    chars[n - 1] = 'A'
  }
  let bs = ebcdic_encode(String::from_array(chars))
  for i = 0; i < n; i = i + 1 {
    arr[start + i] = bs[i]
  }
}

///|
fn fz_fill_zoned(
  st : Array[Int32],
  arr : Array[Byte],
  start : Int32,
  pic : PicClause,
  field_len : Int32,
) -> Unit {
  if pic.blank_when_zero && fz_below(st, 8) == 0 {
    // BWZ 唯一的合法零形态是整项全空格（IBM：item is set to all spaces）。
    for i = 0; i < field_len; i = i + 1 {
      arr[start + i] = 0x40
    }
    return
  }
  let width = pic.storage_digits
  let negative = fz_below(st, 2) == 0
  if pic.sign_separate {
    let digit_start = if pic.sign_leading { start + 1 } else { start }
    for i = 0; i < width; i = i + 1 {
      arr[digit_start + i] = (0xF0 | fz_below(st, 10)).to_byte()
    }
    let sign_at = if pic.sign_leading { start } else { start + width }
    arr[sign_at] = (if negative { 0x60 } else { 0x4E }).to_byte()
  } else {
    for i = 0; i < width; i = i + 1 {
      arr[start + i] = (0xF0 | fz_below(st, 10)).to_byte()
    }
    let sign_at = if pic.sign_leading { start } else { start + width - 1 }
    let digit = arr[sign_at].to_int() & 0xF
    let zone = if pic.signed {
      // C/F 正、D 负
      match fz_below(st, 3) {
        0 => 0xD
        1 => 0xC
        _ => 0xF
      }
      // 无符号字段出现 D 会被 decode 拒绝（数据错误），只取正号区
    } else if fz_below(st, 2) == 0 {
      0xC
    } else {
      0xF
    }
    arr[sign_at] = ((zone << 4) | digit).to_byte()
  }
}

///|
fn fz_fill_packed(
  st : Array[Int32],
  arr : Array[Byte],
  start : Int32,
  pic : PicClause,
) -> Unit {
  let total = pic.storage_digits
  let nbytes = (total + 2) / 2
  let has_pad = total % 2 == 0
  let nibs : Array[Int32] = []
  for i = 0; i < nbytes * 2; i = i + 1 {
    nibs.push(0)
  }
  let off = if has_pad { 1 } else { 0 }
  for i = 0; i < total; i = i + 1 {
    nibs[off + i] = fz_below(st, 10)
  }
  let sign = if pic.signed && fz_below(st, 2) == 0 {
    0xD
  } else if fz_below(st, 2) == 0 {
    0xC
  } else {
    0xF
  }
  nibs[nbytes * 2 - 1] = sign
  for b = 0; b < nbytes; b = b + 1 {
    arr[start + b] = ((nibs[b * 2] << 4) | nibs[b * 2 + 1]).to_byte()
  }
}

///|
fn fz_fill_national(
  st : Array[Int32],
  arr : Array[Byte],
  start : Int32,
  units : Int32,
) -> Unit {
  for i = 0; i < units; i = i + 1 {
    let mut unit = fz_below(st, 0xD7FF)
    // 避开代理项区，避免生成 decode 必然拒绝的字节
    if unit >= 0xD800 && unit <= 0xDFFF {
      unit = 0x20
    }
    arr[start + i * 2] = (unit >> 8).to_byte()
    arr[start + i * 2 + 1] = (unit & 0xFF).to_byte()
  }
}

///|
fn fz_generate(st : Array[Int32], layout : RecordLayout) -> Bytes {
  let arr : Array[Byte] = []
  for i = 0; i < layout.byte_length; i = i + 1 {
    arr.push(0x40)
  }
  for field in layout.fields {
    if field.is_redefining {
      // 视图由主视图的字节承载；随机生成它会与主视图互相覆盖。
      continue
    }
    let pic = field.pic
    let start = field.offset
    match pic.category {
      Numeric =>
        match pic.usage {
          Display => fz_fill_zoned(st, arr, start, pic, field.byte_length)
          Comp3 => fz_fill_packed(st, arr, start, pic)
          _ => fz_fill_random(st, arr, start, field.byte_length)
        }
      National => fz_fill_national(st, arr, start, pic.digits)
      Edited | Alphanumeric | Alphabetic =>
        fz_fill_text(st, arr, start, field.byte_length, pic.justified_right)
    }
  }
  Bytes::from_array(arr)
}

///|
fn fz_run_case(
  cb : String,
  rounds : Int32,
  ok_count : Array[Int32],
) -> Unit raise {
  let layout = compile_layout(parse_copybook(cb))
  let st : Array[Int32] = [20261111]
  for r = 0; r < rounds; r = r + 1 {
    let rec = fz_generate(st, layout)
    match decode_record(layout, rec) {
      Ok(row) =>
        match encode_record(layout, row) {
          Ok(bs) => {
            ok_count[0] = ok_count[0] + 1
            if bs != rec {
              fail(
                "fuzz roundtrip mismatch\ncopybook:\n\{cb}\nround=\{r}\nin =\{fz_hex(rec)}\nout=\{fz_hex(bs)}",
              )
            }
          }
          Err(e) =>
            fail(
              "fuzz encode failed after successful decode\ncopybook:\n\{cb}\nround=\{r}\nin =\{fz_hex(rec)}\nerr=\{e.to_display()}",
            )
        }
      // 随机字节落在该 PIC 的非法空间（例如 COMP 超出声明容量、
      // HFP 非规格化尾数）时 decode 报错是契约要求，跳过。
      Err(_) => ()
    }
  }
}

///|
test "fuzz: deterministic random-byte decode → encode roundtrip" {
  let cases : Array[String] = [
    "01 R.\n  05 A PIC S9(3).\n", "01 R.\n  05 A PIC 9(3).\n", "01 R.\n  05 A PIC S9(3) SIGN LEADING.\n",
    "01 R.\n  05 A PIC S9(3) SIGN SEPARATE.\n", "01 R.\n  05 A PIC S9(3) SIGN LEADING SEPARATE.\n",
    "01 R.\n  05 A PIC S9(3) BLANK WHEN ZERO.\n", "01 R.\n  05 A PIC S9(3) SIGN SEPARATE BLANK WHEN ZERO.\n",
    "01 R.\n  05 A PIC 9(3)PP.\n", "01 R.\n  05 A PIC PP9(3)V99.\n", "01 R.\n  05 A PIC S9(4) COMP.\n",
    "01 R.\n  05 A PIC S9(9) COMP.\n", "01 R.\n  05 A PIC S9(18) COMP.\n", "01 R.\n  05 A PIC S9(4) COMP-3.\n",
    "01 R.\n  05 A PIC 9(5) COMP-3.\n", "01 R.\n  05 A PIC S9(9)V99 COMP-3.\n", "01 R.\n  05 A PIC S9(4) COMP-1.\n",
    "01 R.\n  05 A PIC S9(9) COMP-2.\n", "01 R.\n  05 A PIC X(6).\n", "01 R.\n  05 A PIC X(5) JUSTIFIED RIGHT.\n",
    "01 R.\n  05 A PIC N(3).\n", "01 R.\n  05 A PIC $9,999.99.\n", "01 R.\n  05 A PIC ZZ9V99.\n",
    "01 R.\n  05 A PIC ZZ9.99.\n", "01 R.\n  05 A PIC 9(5)CR.\n", "01 R.\n  05 G OCCURS 3 TIMES.\n    10 A PIC X(2).\n",
    "01 R.\n  05 M PIC S9(3) COMP-3.\n  05 V REDEFINES M.\n    10 RAW PIC X(2).\n  05 Z PIC X(1).\n",
    "01 R.\n  05 M PIC X(4).\n  05 V REDEFINES M.\n    10 A PIC X(2) OCCURS 2 TIMES.\n",
    "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(2).\n  05 B PIC X(2).\n", "01 R.\n  05 ID PIC 9(4).\n  05 NAME PIC X(6).\n  05 AMT PIC S9(5)V99 COMP-3.\n  05 TAG PIC X(2) JUSTIFIED RIGHT.\n",
    "01 R.\n  05 G1.\n    10 A PIC S9(3).\n  05 G2.\n    10 A PIC X(2).\n  05 V REDEFINES G2.\n    10 B PIC X(2).\n",
  ]
  let ok : Array[Int32] = [0]
  for cb in cases {
    fz_run_case(cb, 300, ok)
  }
  // 至少要有足够多的样本真的解出来了，否则这个测试是空转。
  assert_true(ok[0] > 3000)
}
