01  CUSTOMER-RECORD.
    05  CUST-ID        PIC 9(8).
    05  CUST-NAME      PIC X(30).
    05  BALANCE        PIC S9(7)V99 COMP-3.
    05  OPEN-DATE      PIC 9(8).
    05  FLAGS.
        10  ACTIVE     PIC X(1).
        10  TIER       PIC 9(2).
