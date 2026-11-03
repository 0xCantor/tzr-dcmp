# Tessera propAMM (Base) reconstruction

## Architecture

```
trader ─► TesseraSwap (router) ─► TesseraEngine ─► pool proxy (TesseraBook logic)
              │                                          │
              └─ moves tokens ◄── treasury (inventory)   └─ prices only; never moves tokens
```

- **Router (`TesseraSwap`)**: pays output from the treasury, pulls input from the caller. Forwards its `msg.sender` as `sender`.
- **Engine / `poolManager`**: maps a pair to a pool proxy. Calls `sell` (exact in) or `buy` (exact out). Also holds the kill switch, address labels, level-exclusion deadline and priority-fee reference.
- **Pool (`TesseraBook`)**: one proxy per pair, shared implementation. State:
  - `Quote`: anchor price, spread, refBlock, tag. Updated by a separate raw-calldata path (~27k gas).
  - Two sides of the clob (bids, asks), ≤19 levels + terminator. Level price = top-of-book price * multiplier. Replaced wholesale by `updateBook`.
  - Two flow accumulators: since the last book update; opposite flow nets against own flow at the anchor.
- **Swap**: walk the ladder (skip excluded levels, skip depth already consumed by net flow) -> gross output -> `out = gross × (1 − fee)`.
- **Fee (ppm, capped at 1e6)**: mode + age + base + default + priority + address. Age = grace, then quadratic, then no fill at expiry. Address = blacklist / penalized / fingerprint helper. Default fee is flipped within blocks by the operator.

## Open questions

- Quote update (anchor / spread / refBlock / tag) is not decompiled. Only its layout is known (the nature of this function call is very ez tho).
- Flow accumulator unit (input vs output) and `factor` semantics are inferred. Verify via the storage diff of slots 3 and 4 in a swap tx and the on-chain `factor`.
- `Swap` event argument types are guessed.
- Rounding: ceil is marked `TODO: round UP` in exact-out and the fee gross-up (need to use libs for that).
- The paper does not specify the age curve, priority threshold, `factor`, accumulator reset or exact-out handling. Those come from the decompilation alone.

## References

- Paper: "Active Liquidity On Chain", arXiv 2609.38056 — https://arxiv.org/html/2609.38056v1
- TesseraSwap: 0x55555522005BcAE1c2424D474BfD5ed477749E3e
- TesseraEngine: 0x31e99e05fee3dce580af777c3fd63ee1b3b40c17
- Tessera(Pool): 0x6d9dd143e42b6338f4f6a7c0c26d124658f641cb
