# Version 2

New required input `qrs-ms` (integer, ms, 40 to 300, must be less than `qt-ms`). A QRS of 120 ms or more now shortens the QT before correction: QTa = QT - (QRS - 100). Requests without `qrs-ms` are rejected.
