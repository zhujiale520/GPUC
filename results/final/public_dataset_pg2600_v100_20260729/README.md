# Project Gutenberg #2600 benchmark

Five-run real-text experiment using the official UTF-8 artifact for *War and
Peace*. `dataset_metadata.txt` records URL, catalog/license pages, byte count
and the exact required SHA-256. Cold means `POSIX_FADV_DONTNEED` before one
logical read; warm means a full pre-read followed by time-based fio.

SGLZ retained RAW because it did not meet the 85% threshold. LZ4 compressed to
68.76% allocated bytes. This is a positive space result, not a read-speed win.
