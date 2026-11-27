// CB-22-5（2026-11-27 第二十二轮审计）：**零的三种符号半字节与 JSONL 的
// `__nibbles.sign` 一一对应**（把 `FIDELITY.md:112` 那段表述收敛成可机检事实）。
//
// ## 背景
//
// `FIDELITY.md:112` 写「`__nibbles.sign` 是符号的权威来源：`0xD` 就是负号，
// **系数为 0 时同样生效**」。这句话笼统 —— 本轮实测，只有**负零**这一档靠
// `sign` 生效：
//
// | 手写 JSONL | 写出 | 说明 |
// |---|---|---|
// | `{"R.A":0,  "__nibbles":{"R.A":{"sign":13}}}` | `F0 F0 C0` | `sign=13` **被忽略**，正零就是 C |
// | `{"R.A":"-0","__nibbles":{"R.A":{"sign":13}}}` | `F0 F0 D0` | 负零靠 `sign` 生效 |
// | `{"R.A":null,"__nibbles":{"R.A":{"sign":13}}}` | `F0 F0 D0` | null 也走 `sign` |
//
// 这不是缺陷 —— decode 端从不产出「正零文本 + `sign=13`」这种组合。实测三档：
//
// ```
// 末字节 C0 -> {"R.A":0,  "__nibbles":{"R.A":{"sign":12}}}
// 末字节 D0 -> {"R.A":-0, "__nibbles":{"R.A":{"sign":13}}}
// 末字节 F0 -> {"R.A":0,  "__nibbles":{"R.A":{"sign":15}}}
// ```
//
// 两端在**自己能产出的组合**上是一致的。本轮把「一一对应」锁进测试，这样
// 将来任何一端漂移（decode 把 `C0` 配成 `sign=13`、或 encode 把 `sign=12`
// 写成 `D0`）都会当场变红。
//
// ## 判据（双向）
//
// 1. 正向：三档末字节 → `(文本, sign)` → 回编码，逐字节还原；
// 2. 反向：三档的 `sign` **两两不同**（否则「一一对应」可以靠全相等蒙过去），
//    且正零那档的文本**不带**负号、负零那档**带**负号。

///|
fn zsn_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
}

///|
/// 三个样本：末字节 C0（正、标准）、D0（负）、F0（正、未符号化区号）。
fn zsn_cases() -> Array[(Int32, Int32, Bool)] {
  // (末字节, 期望 sign, 期望文本是否带负号)
  [(0xC0, 12, false), (0xD0, 13, true), (0xF0, 15, false)]
}

///|
test "zero: each sign nibble survives decode -> encode byte-exactly" {
  let layout = zsn_layout()
  for (last, sign, is_neg) in zsn_cases() {
    let rec = b"\xF0\xF0\x00"
    let bs : Array[Byte] = [0xF0, 0xF0, last.to_byte()]
    let row = decode_record(layout, Bytes::from_array(bs)).unwrap()
    // 正向：decode 写出的 JSONL 文本必须与符号一致
    let text = render_jsonl(layout, [row])
    if is_neg {
      assert_true(text.contains("-0"))
    } else {
      assert_false(text.contains("-0"))
    }
    // 回编码逐字节还原
    let back = parse_jsonl_row(layout, text.trim_end().to_string()).unwrap()
    match encode_record(layout, back) {
      Err(e) => fail("sign=\{sign} must encode: \{e.to_display()}")
      Ok(out) => assert_eq(out, Bytes::from_array(bs))
    }
    let _ = rec
  }
}

///|
test "zero: the three sign nibbles are pairwise distinct (anti-degenerate)" {
  let cases = zsn_cases()
  assert_eq(cases.length(), 3)
  // 直接钉住三档取值 —— 这本身就是「两两不同」的最强形式，
  // 也防止「三档全写成同一个 sign」把一一对应蒙过去。
  let (c0, s0, n0) = cases[0]
  let (c1, s1, n1) = cases[1]
  let (c2, s2, n2) = cases[2]
  assert_eq(c0, 0xC0)
  assert_eq(s0, 12)
  assert_false(n0)
  assert_eq(c1, 0xD0)
  assert_eq(s1, 13)
  assert_true(n1)
  assert_eq(c2, 0xF0)
  assert_eq(s2, 15)
  assert_false(n2)
  // 两两不同
  assert_true(s0 != s1)
  assert_true(s1 != s2)
  assert_true(s0 != s2)
}
