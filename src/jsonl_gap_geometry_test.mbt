// 审计回归（2026-11-12 遗留项 B1）：空洞的位置几何必须随 JSONL 携带。
//
// ## 缺陷形态
//
// `render_jsonl` 只写出空洞的**字节**（`__tail_hex` / `__filler_hex`），不写
// 这些字节原来在记录的哪个位置。encode 端的长度匹配只能证明「字节数对」，
// 证明不了「位置对」，于是三类形态出问题：
//
// 1. **报错**（N4 只修了「当前空洞为空」这一档）：decode 时部分视图解出，
//    快照比「全视图不写」的超集短；用户编辑某个视图后，当前空洞数既不等于
//    快照长度、也不等于超集长度 → `__tail_hex must be exactly N byte(s)`。
// 2. **静默错位**（比报错更糟）：快照长度恰好等于超集长度时，encode 走
//    `restore_from_superset`，把快照按超集起点顺序摊开 —— 快照字节被写到
//    错误的位置上，exit 0、无提示。
// 3. 中部 FILLER 空洞同族：视图编辑让 FILLER 洞收缩到中间长度，同样报错。
//
// ## 通解
//
// 渲染端同时写出空洞的**区间**：`"__tail_gap":[[6,10]]` /
// `"__filler_gap":[[2,4]]`。encode 端按绝对位置映射：每个区间里的字节只在
// 「该位置此刻仍是空洞」时写回（编辑优先），已由字段值覆盖的位置丢弃。
// 旧 JSONL（没有这两个键）行为完全不变 —— 这是迁移的前提。

///|
fn gg_hole_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 M PIC X(2).\n  05 V2 REDEFINES M PIC X(4).\n  05 V3 REDEFINES M PIC X(6).\n  05 V4 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
fn gg_hole_record() -> Bytes {
  bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE, 0xF7, 0xF8])
}

///|
fn gg_short_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(4).\n  05 V2 REDEFINES M PIC X(6).\n  05 V3 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
fn gg_filler_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(2).\n  05 FILLER PIC X(2).\n  05 B PIC X(2).\n  05 V REDEFINES M PIC X(3).\n",
    ),
  )
}

///|
fn gg_encode(layout : RecordLayout, line : String) -> Bytes {
  let row = match parse_jsonl_row(layout, line) {
    Ok(r) => r
    Err(e) => abort("expected a valid JSONL row, got: \{e}")
  }
  match encode_record(layout, row) {
    Ok(b) => b
    Err(e) => abort("expected the row to encode, got: \{e.to_display()}")
  }
}

///|
fn gg_expect_bytes(b : Bytes, want : Array[Int32]) -> Unit {
  if b.length() != want.length() {
    abort("byte length mismatch: got \{b.length()}, want \{want.length()}")
  }
  for i = 0; i < want.length(); i = i + 1 {
    if b[i].to_int() != want[i] {
      abort("byte mismatch at \{i}: got \{b[i].to_int()}, want \{want[i]}")
    }
  }
}

///|
test "gap geometry: decode writes the tail gap intervals next to the bytes" {
  let layout = gg_hole_layout()
  let row = decode_record(layout, gg_hole_record()).unwrap()
  // A=AB, M=CD, V2=CDEF 解出；V3/V4 含 FF → null。
  // 尾部空洞 = [6,10)（4 字节），字节序列 ffeef7f8。
  inspect(
    render_jsonl(layout, [row]),
    content="{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,10]]}\n",
  )
}

///|
test "gap geometry: editing a view no longer hits a length error (shape 1)" {
  // 快照 4 字节（[6,10)），编辑 V3 后当前空洞 = [8,10) = 2 字节 ——
  // 旧实现：2 既不等于快照 4、也不等于超集 6 → exit 1。
  // 修后：按区间 [6,10) 绝对映射，[6,8) 已被 V3 覆盖（丢弃），[8,10) 写回。
  //
  // 走的是真实链路：decode → render_jsonl → parse_jsonl_row → 改 V3 → encode。
  let layout = gg_hole_layout()
  let row = parse_jsonl_row(
    layout,
    render_jsonl(layout, [decode_record(layout, gg_hole_record()).unwrap()])
    .trim_end()
    .to_string(),
  ).unwrap()
  row["R.V3"] = Text("CDEFGH")
  match encode_record(layout, row) {
    Err(e) => abort("editing a view must encode, got: \{e.to_display()}")
    Ok(b) =>
      // A B C D E F G H 之后是原始 [8,10) = F7 F8
      gg_expect_bytes(b, [
        0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xF7, 0xF8,
      ])
  }
}

///|
test "gap geometry: the snapshot is restored at its own offset, not the superset start (shape 2)" {
  // decode 时 M、V2 解出、V3 含不可打印字节 → 快照只覆盖 [6,8)。
  // 用户把 V2 改成 null：当前空洞变成 [4,8)，长度 4 == 超集长度 ——
  // 旧实现按超集起点摊开，把 ff ee 静默写到 [4,6)（错位、exit 0）。
  // 修后按 __tail_gap 的绝对位置写回 [6,8)，[4,6) 保持空白。
  let layout = gg_short_layout()
  let row = parse_jsonl_row(
    layout,
    render_jsonl(layout, [
      decode_record(
        layout,
        bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE]),
      ).unwrap(),
    ])
    .trim_end()
    .to_string(),
  ).unwrap()
  row["R.V2"] = Null
  match encode_record(layout, row) {
    Err(e) => abort("editing a view must encode, got: \{e.to_display()}")
    Ok(b) =>
      gg_expect_bytes(b, [0xC1, 0xC2, 0xC3, 0xC4, 0x40, 0x40, 0xFF, 0xEE])
  }
}

///|
test "gap geometry: FILLER holes carry their own intervals (shape 3)" {
  let layout = gg_filler_layout()
  // M=AB（[0,2)）、B=EF（[4,6)）、V 覆盖 [0,3) 且解出 → FILLER 洞只剩 [3,4)，
  // 快照 1 字节 `c4`；而「V 不写」的超集是 [2,4)，2 字节。
  let row = parse_jsonl_row(
    layout,
    render_jsonl(layout, [
      decode_record(layout, bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6])).unwrap(),
    ])
    .trim_end()
    .to_string(),
  ).unwrap()
  // 把 V 改成 null：FILLER 洞扩张成 [2,4)（2 字节），快照仍是 1 字节 ——
  // 旧实现：1 既不是当前空洞数 2、也不是别的合法长度 → exit 1。
  // 修后按 `__filler_gap:[[3,4]]` 绝对映射：只写 [3,4)，[2,3) 保持空白。
  row["R.V"] = Null
  match encode_record(layout, row) {
    Err(e) => abort("editing a view must encode, got: \{e.to_display()}")
    Ok(b) => gg_expect_bytes(b, [0xC1, 0xC2, 0x40, 0xC4, 0xC5, 0xC6])
  }
}

///|
test "gap geometry: an unedited row still round-trips byte for byte" {
  let layout = gg_hole_layout()
  let line = render_jsonl(layout, [
      decode_record(layout, gg_hole_record()).unwrap(),
    ])
    .trim_end()
    .to_string()
  let b = gg_encode(layout, line)
  gg_expect_bytes(b, [
    0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE, 0xF7, 0xF8,
  ])
}

///|
test "gap geometry: old JSONL without gap keys keeps the previous behaviour" {
  // 没有 __tail_gap 时，长度既非当前空洞数也非超集数的快照仍按 CB-A2 报错 ——
  // 迁移的前提是旧文件一字不改地保持原行为（不做「猜位置」的静默修补）。
  let layout = gg_hole_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":\"CDEFGH\",\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\"}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("__tail_hex"))
    Ok(_) =>
      fail("legacy JSONL without __tail_gap must keep the strict behaviour")
  }
}

///|
test "gap geometry: corrupt or inconsistent gap specs are rejected" {
  let layout = gg_hole_layout()
  // 区间总长 2 与 4 字节快照不符
  let cases : Array[String] = [
    "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,8]]}",
    // 区间越过记录末尾
     "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,12]]}",
    // 区间落在主视图区（不属于尾部空洞的超集）
     "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[0,4]]}",
    // 有几何、没有字节
     "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_gap\":[[6,10]]}",
  ]
  for line in cases {
    match parse_jsonl_row(layout, line) {
      Err(_) => ()
      Ok(row) =>
        match encode_record(layout, row) {
          Err(_) => ()
          Ok(_) => fail("corrupt gap spec must be rejected: \{line}")
        }
    }
  }
}
