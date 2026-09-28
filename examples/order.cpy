01  ORDER-LINES.
    05  ORDER-ID       PIC 9(10).
    05  LINE-COUNT     PIC 9(3).
    05  LINES OCCURS 5 TIMES.
        10  SKU        PIC X(12).
        10  QTY        PIC S9(4) COMP.
        10  PRICE      PIC S9(5)V99 COMP-3.
