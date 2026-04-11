#!/usr/bin/env python3
"""
gen_prime_bitmap.py

Generates a ~1 MB hex file representing prime bitmaps for the 6k-1 and
6k+1 candidate threads. Each row is exactly 8 hex characters (32 bits).

Row format (alternating):
  Even rows (0, 2, 4, ...): 6k-1 thread
  Odd  rows (1, 3, 5, ...): 6k+1 thread

Within each 32-bit row:
  LSB (bit 0)  = is_prime(6*k_base     +/- 1)   k_base = row_pair*32 + 1
  bit 1        = is_prime(6*(k_base+1) +/- 1)
  ...
  MSB (bit 31) = is_prime(6*(k_base+31)+/- 1)

Total output: 262144 rows * 4 bytes = 1,048,576 bytes = 1 MB
Covers k = 1 .. 4,194,304  =>  candidates up to 25,165,825

Output: scripts/prime_bitmap.hex  (one 8-char hex value per line)
"""

import os
import sys


def sieve(limit):
    """Return a bytearray where sieve[i]=1 if i is prime, 0 otherwise."""
    s = bytearray([1]) * (limit + 1)
    s[0] = s[1] = 0
    i = 2
    while i * i <= limit:
        if s[i]:
            s[i*i::i] = bytearray(len(s[i*i::i]))
        i += 1
    return s


def main():
    # -----------------------------------------------------------------------
    # Sizing
    # -----------------------------------------------------------------------
    TARGET_BYTES  = 1 * 1024 * 1024       # 1 MB
    ROWS          = TARGET_BYTES // 4      # 262144 rows (4 bytes each)
    K_WORDS       = ROWS // 2             # 131072 words per thread (rows alternate)
    K_MAX         = K_WORDS * 32          # 4,194,304 — highest k value covered
    N_MAX         = 6 * K_MAX + 1         # 25,165,825 — highest candidate checked

    print(f"Sieving primes up to {N_MAX:,} ...", flush=True)
    is_prime = sieve(N_MAX)
    print("Sieve complete.", flush=True)

    output_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "prime_bitmap.hex"
    )

    rows_written = 0
    with open(output_path, "w", newline="\n") as f:
        for word_idx in range(K_WORDS):
            k_base = word_idx * 32 + 1    # first k value in this 32-k block

            # --- 6k-1 row (even) ---
            word_minus = 0
            for bit in range(32):
                k = k_base + bit
                n = 6 * k - 1
                if n <= N_MAX and is_prime[n]:
                    word_minus |= (1 << bit)
            f.write(f"{word_minus:08X}\n")
            rows_written += 1

            # --- 6k+1 row (odd) ---
            word_plus = 0
            for bit in range(32):
                k = k_base + bit
                n = 6 * k + 1
                if n <= N_MAX and is_prime[n]:
                    word_plus |= (1 << bit)
            f.write(f"{word_plus:08X}\n")
            rows_written += 1

    file_bytes = rows_written * 4
    print(f"Wrote {rows_written:,} rows ({file_bytes:,} bytes = {file_bytes/1024:.1f} KB)")
    print(f"Coverage: k = 1 .. {K_MAX:,}  =>  candidates up to {N_MAX:,}")
    print(f"Output: {output_path}")


if __name__ == "__main__":
    main()
