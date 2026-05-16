# 18 — Fixed-point math

> **Languages / 语言**: **English** · [简体中文](./zh/18-fixed-point.md)

## 1. Scope

R11 adds a small, pure-OCaml fixed-point math surface for Solana/DeFi examples.
It does **not** add a new runtime representation, new wire nodes, floats, or
128-bit arithmetic. All values are plain `int` values in the existing OCaml
subset and therefore work through the interpreter, native Zig, and BPF backends.

## 2. Representation

`Fixed.t` is an erased alias of `int` with six decimal places:

```ocaml
module Fixed : sig
  type t = int
  val scale : int        (* 1_000_000, written as 1000000 in the subset *)
end
```

A raw value of `1000000` represents `1.0`; `1500000` represents `1.5`.
The API intentionally exposes `of_scaled` / `to_scaled` so callers can persist
or log the deterministic integer representation.

## 3. Public API

Core constructors and conversions:

- `Fixed.zero`, `Fixed.one`
- `Fixed.of_scaled : int -> Fixed.t`
- `Fixed.to_scaled : Fixed.t -> int`
- `Fixed.of_int : int -> Fixed.t`
- `Fixed.to_int_trunc`, `to_int_floor`, `to_int_ceil`, `to_int_round`

Arithmetic and comparison:

- `Fixed.add`, `sub`, `neg`, `mul`, `div`
- `Fixed.mul_int`, `div_int`
- `Fixed.ratio : int -> int -> Fixed.t`
- `Fixed.bps : int -> Fixed.t`
- `Fixed.apply : int -> Fixed.t -> int`
- `Fixed.compare`, `equal`, `min`, `max`

Amount helpers:

- `Amount.fee_bps : int -> int -> int`
- `Amount.discount_bps : int -> int -> int`
- `Amount.premium_bps : int -> int -> int`
- `Amount.apply_rate : int -> Fixed.t -> int`

## 4. Constraints

- Multiplication is still `int * int`; callers must keep operands inside the
  existing signed-64-bit safety envelope for BPF output.
- Division by zero is not masked; it follows the compiler/runtime's existing
  integer division behavior.
- The first API targets deterministic DeFi-style quote/fee math, not arbitrary
  precision decimal accounting.

## 5. Coverage

- `stdlib/core_tests.ml` checks upstream OCaml behavior.
- `examples/tests/fixed_test.ml` covers `omlz test` discovery and execution.
- `examples/fixed_amm_quote.ml` is a BPF-friendly AMM quote smoke example.
