#!/usr/bin/env python3
"""Find non-prime entries in CSEE4280PrimesBad.txt."""

import math

def is_prime(n):
    if n < 2:
        return False
    if n < 4:
        return True
    if n % 2 == 0 or n % 3 == 0:
        return False
    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0:
            return False
        i += 6
    return True

with open("CSEE4280PrimesBad.txt") as f:
    for line_num, line in enumerate(f, 1):
        val = int(line.strip())
        if not is_prime(val):
            print(f"Line {line_num}: {val} is NOT prime")

print("Done.")
