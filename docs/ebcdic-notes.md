# EBCDIC cp037 — the details that actually cause wrong output

Three facts about cp037 that produce silently incorrect results when assumed
to work like ASCII. Each one has its own regression test.

## 1. There are no unmapped bytes

cp037 is a **fully defined, injective** table: all 256 byte values map to 256
distinct Unicode code points. `0x00`..`0x3F` are C0 control characters,
`0xFF` maps to U+009F.

This matters because it means **"invalid EBCDIC byte" cannot be detected by
table lookup**. `ebcdic_to_unicode` returns a real code point for every input
in `0..255`; U+FFFD only appears for out-of-range arguments, which is a
programming error rather than a data error.

Detecting data that is *not printable text* requires a separate check —
`ebcdic_is_printable` — which asks whether the resulting code point is a
printable character. `ebcdic_has_mapping` is useless here because it is
always true.

## 2. Digits live at 0xF0..0xF9, not 0x30..0x39

```
ASCII:   '0' = 0x30   '1' = 0x31   ...  '9' = 0x39
EBCDIC:  '0' = 0xF0   '1' = 0xF1   ...  '9' = 0xF9
```

Applying ASCII digit arithmetic (`b - 0x30`) to EBCDIC data produces values
around `0xC0`, not `0..9`. It will not raise an error; it will produce a
wrong number.

The project's digit decoding therefore uses the low nibble:

```moonbit
let digit = b & 0x0F          // 0xF5 -> 5
let is_digit = (b & 0xF0) == 0xF0
```

## 3. The letter ranges are not contiguous

```
'A'..'I'  ->  0xC1..0xC9
'J'..'R'  ->  0xD1..0xD9      <- gap at 0xCA..0xD0
'S'..'Z'  ->  0xE2..0xE9      <- gap at 0xDA..0xE1

'a'..'i'  ->  0x81..0x89
'j'..'r'  ->  0x91..0x99
's'..'z'  ->  0xA2..0xA9
```

Assuming `c - 'A'` gives alphabetic index works for `A..I` and then breaks.
Any case-folding or letter-range logic must consult the table.

## Space is 0x40

Not `0x20`. Trailing padding on `PIC X(n)` fields is `0x40` repeated, so
trimming with ASCII whitespace logic leaves the padding in place.

## Signs are overpunched, not appended

Zoned decimal puts the sign in the **high nibble of the last byte**, replacing
what would otherwise be `0xF`:

```
+123  ->  F1 F2 F3        (last byte unchanged, high nibble F = positive)
-123  ->  F1 F2 D3        (high nibble becomes D)
```

There is no extra sign byte. A decoder that expects a separate sign position
will be off by one byte for the rest of the record.

## Verification

`src/ebcdic_test.mbt` checks:

- all 256 inputs round-trip
- the specific mappings above, one assertion per range
- `ebcdic_is_printable` rejects control bytes that `ebcdic_to_unicode`
  happily maps
