#!/usr/bin/env python3
"""
gen_golden_primes.py
Generate tb/golden_primes.mem for use with Verilog $readmemb in prime_engine_tb.v.

Output format: one line per index (0..10007), each line is "1" (prime) or "0" (not prime).
Compatible with: $readmemb("tb/golden_primes.mem", golden) where golden is reg [0:10007]
"""

import os


def is_prime(n):
    """Return True if n is prime, False otherwise. Uses trial division."""
    if n < 2:
        return False
    if n == 2:
        return True
    if n % 2 == 0:
        return False
    if n == 3:
        return True
    if n % 3 == 0:
        return False
    k = 1
    while True:
        d1 = 6 * k - 1
        d2 = 6 * k + 1
        if d1 * d1 > n:
            break
        if n % d1 == 0:
            return False
        if d2 * d2 > n:
            break
        if n % d2 == 0:
            return False
        k += 1
    return True


def main():
    max_index = 10007
    output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb', 'golden_primes.mem')
    output_path = os.path.normpath(output_path)

    prime_count = 0
    lines = []
    for i in range(max_index + 1):
        if is_prime(i):
            lines.append('1')
            prime_count += 1
        else:
            lines.append('0')

    with open(output_path, 'w', newline='\n') as f:
        for line in lines:
            f.write(line + '\n')

    print(f"Generated golden_primes.mem: {prime_count} primes in range 0..{max_index}")


if __name__ == '__main__':
    main()
