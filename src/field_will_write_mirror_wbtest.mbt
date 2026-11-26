// 白盒：空洞判定（`field_will_write`）必须与编码器用**同一个**取值函数
// （C4，2026-11-17 审计）。
//
// 历史两次 P2 都出在这一侧：
//   - A2 的 `"" ≡ null`（2026-11-15 `d394f87`）——`encode_field` 跳过写入，
//     空洞判定却把该视图当"已写"，`__tail_hex` 快照被静默丢弃；
//   - `occurs` 逐元素镜像（2026-11-16 `8c1c8a7`）——空洞判定只看裸路径。
// 所以「裸路径后备」这条新语义必须同时落在两处：`encode_field` 说会写的地方，
// `field_will_write` 也必须说会写，否则回填会覆盖刚写好的值、或者快照被丢掉。

///|
fn c4w_field(layout : RecordLayout, path : String) -> FieldLayout {
  for f in layout.fields {
    if f.path == path {
      return f
    }
  }
  abort("no field \{path}")
}

///|
test "field_will_write honours the bare path for the first element only" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M OCCURS 2 PIC X(2).\n",
    ),
  )
  let v1 = c4w_field(layout, "R.V(1)")
  let v2 = c4w_field(layout, "R.V(2)")
  assert_true(v1.is_redefining)
  assert_true(v2.is_redefining)
  let row : Map[String, CellValue] = Map([])
  row["R.V"] = Text("CD")
  // 编码器会给 V(1) 写 "CD"（field_value 的裸路径后备）→ 空洞判定必须同答
  assert_true(field_will_write(v1, Some(row)))
  // 裸路径不服务第 2 个元素 → V(2) 不写，它那段仍是空洞
  assert_false(field_will_write(v2, Some(row)))
  row["R.V(2)"] = Text("EF")
  assert_true(field_will_write(v2, Some(row)))
}

///|
test "field_will_write and encode_field agree on a bare-path-fed view" {
  // 端到端一致性：视图经裸路径拿到值后，encode 写出的字节就是它，且尾部
  // 空洞收缩到视图末端之后（快照不会把它当空洞回填成 0x40）。
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M OCCURS 2 PIC X(2).\n",
    ),
  )
  let row = parse_jsonl_row(layout, "{\"R.M\":\"AB\",\"R.V\":\"CD\"}").unwrap()
  // **CB-20-3（2026-11-28 第二十轮审计）**：第 2 个元素（[2,4)）没有值、
  // 也没有快照 —— 旧写法在这里静默写出 0x40，现在必须报 `InvalidBypass`。
  // 想得到「未赋值存储 0x40」就显式给空快照（`__tail_hex:""` +
  // `__tail_gap:[]`），那是调用方在声明「这段确实没有字节」。
  match encode_record(layout, row) {
    Err(InvalidBypass(detail)) => assert_true(detail.contains("no carrier"))
    Ok(_) =>
      fail("没有值也没有快照的第 2 个元素不得静默写成 0x40")
    Err(e) => fail("应当是 InvalidBypass，实际 \{e.to_display()}")
  }
  let explicit = parse_jsonl_row(
    layout, "{\"R.M\":\"AB\",\"R.V\":\"CD\",\"__tail_hex\":\"\",\"__tail_gap\":[]}",
  ).unwrap()
  let out = encode_record(layout, explicit).unwrap()
  inspect(out[0].to_int(), content="195") // C1 'C'
  inspect(out[1].to_int(), content="196") // C2 'D'
  // 显式声明「无快照」→ 未赋值存储 0x40
  inspect(out[2].to_int(), content="64")
  inspect(out[3].to_int(), content="64")
}
