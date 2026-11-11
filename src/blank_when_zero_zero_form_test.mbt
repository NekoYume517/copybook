// 审计回归（2026-11-11）：BLANK WHEN ZERO 字段收到**非空格写法的零**时，
// decode 接受、encode 却把它改写成全空格 —— 与 L1「decode → encode 逐字节
// 相同」冲突，且 verify（内存路径）会报 mismatch 而 JSONL 路径静默改字节。
//
// IBM 的 BLANK WHEN ZERO 描述的是「值为 0 时**写出**全空格」；zoned 零的
// 普通写法 `F0 F0 F0`（符号区 C/F）仍是可解码的数值 0。既然 decode 接受它，
// encode 就必须能原样还回去 —— 与 CB-2（负零）、RJ-1（HFP 非规范零）同族。
//
// 修复前行为（本文件锁定）：
//   9(3) BWZ          F0F0F0 -> 40 40 40      (false)
//   9(3) BWZ          F0F0C0 -> 40 40 40      (false)
//   S9(3) BWZ         F0F0F0 -> 40 40 40      (false)
//   S9(3) SEP BWZ     F0F0F04E -> 40404040    (false)
//   （负数零 F0F0D0 / F0F0F060 本来就 byte-identical）

///|
fn bzz_bs(a : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in a {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
fn bzz_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
test "BWZ: non-blank zero forms must roundtrip byte-identically" {
  let cases : Array[(String, Array[Bytes])] = [
    (
      "01 R.\n  05 A PIC 9(3) BLANK WHEN ZERO.\n",
      [bzz_bs([0xF0, 0xF0, 0xF0]), bzz_bs([0xF0, 0xF0, 0xC0])],
    ),
    (
      "01 R.\n  05 A PIC S9(3) BLANK WHEN ZERO.\n",
      [
        bzz_bs([0xF0, 0xF0, 0xF0]),
        bzz_bs([0xF0, 0xF0, 0xC0]),
        bzz_bs([0xF0, 0xF0, 0xD0]),
      ],
    ),
    (
      "01 R.\n  05 A PIC S9(3) SIGN SEPARATE BLANK WHEN ZERO.\n",
      [bzz_bs([0xF0, 0xF0, 0xF0, 0x4E]), bzz_bs([0xF0, 0xF0, 0xF0, 0x60])],
    ),
  ]
  for (cb, records) in cases {
    let layout = bzz_layout(cb)
    for rec in records {
      let row = decode_record(layout, rec).unwrap()
      match encode_record(layout, row) {
        Ok(bs) =>
          if bs != rec {
            fail(
              "BWZ zero form must roundtrip\ncopybook:\n\{cb}\nin =\{rec}\nout=\{bs}",
            )
          }
        Err(e) => fail("re-encode must succeed: \{e.to_display()}")
      }
      // JSONL 路径同样必须逐字节一致（旁路键承载非空格零的字节身份）
      let text = render_jsonl(layout, [row])
      let back = parse_jsonl_row(layout, text).unwrap()
      match encode_record(layout, back) {
        Ok(bs) =>
          if bs != rec {
            fail(
              "BWZ zero form must survive JSONL\ncopybook:\n\{cb}\njsonl=\{text}\nin =\{rec}\nout=\{bs}",
            )
          }
        Err(e) => fail("JSONL re-encode must succeed: \{e.to_display()}")
      }
    }
  }
}

///|
test "BWZ: all-blank zero still encodes as all blanks" {
  let layout = bzz_layout("01 R.\n  05 A PIC 9(3) BLANK WHEN ZERO.\n")
  let rec = bzz_bs([0x40, 0x40, 0x40])
  let row = decode_record(layout, rec).unwrap()
  assert_eq(encode_record(layout, row).unwrap(), rec)
  let sep = bzz_layout(
    "01 R.\n  05 A PIC S9(3) SIGN SEPARATE BLANK WHEN ZERO.\n",
  )
  let rec4 = bzz_bs([0x40, 0x40, 0x40, 0x40])
  let row4 = decode_record(sep, rec4).unwrap()
  assert_eq(encode_record(sep, row4).unwrap(), rec4)
}

///|
test "BWZ: nonzero values are still decoded as Int and unchanged" {
  let layout = bzz_layout("01 R.\n  05 A PIC 9(3) BLANK WHEN ZERO.\n")
  let row = decode_record(layout, bzz_bs([0xF1, 0xF2, 0xF3])).unwrap()
  match row.get("R.A") {
    Some(Int(i)) => assert_eq(i, 123L)
    _ => fail("nonzero BWZ value must stay Int")
  }
}
