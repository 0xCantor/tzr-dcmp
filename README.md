# Tessera propAMM (Base) reconstruction

## Architecture

```
trader ─► TesseraSwap (router) ─► TesseraEngine ─► book proxy ─► TesseraBook (logic)
              │                    (manager + factory)    │
              └─ moves tokens ◄── treasury (inventory)    └─ prices only, never moves tokens
```

- **Router (`TesseraSwap`)**: pays output from the treasury and pulls input from the caller. Forwards its `msg.sender` as `sender`.
- **Engine**: book manager, book factory and proxy admin of every book. Maps a pair to a book (direct, else via `hub`). Calls `sell` (exact in) or `buy` (exact out). Holds the kill switch, address labels, level-exclusion deadline and priority-fee reference. Roles: multisig (hardcoded), `owner` (router), `killer`, `exclusionSetter`.
- **Book proxy (`TesseraBookProxy`)**: one per pair, created by `createBook`. Holds the quote update path. An allowed updater (one of 10 immutables) sends a raw 32-byte word that is stored in slot 0 if the tag advanced by 1 to 15 (~27k gas). Any other call is delegated to the implementation.
- **Book (`TesseraBook`)**: shared implementation. State:
  - `Quote`: tag, refBlock, priceAnchor, spreadPpm.
  - Two sides of the clob (bids, asks), ≤19 levels + terminator. Level price = top-of-book price * multiplier. Replaced wholesale by `updateBook`.
  - Two flow accumulators. They reset on each book update and opposite flow nets against own flow at the anchor.
- **Swap**: walk the book side (skip excluded levels and depth already consumed by net flow) -> gross output -> `out = gross × (1 − fee)`. Previews carry no mode fee.
- **Fee (ppm, capped at 1e6)**: mode + age + base + default + priority + address. Age = grace, then quadratic, then no fill at expiry. Address = blacklist, penalized or fingerprint helper. Default fee is flipped within blocks by the operator.

## Open questions

- Flow accumulator unit (input vs output) and `factor` semantics are inferred. Verify via the storage diff of the accumulator slots in a swap tx and the on-chain `factor`.
- `Swap` event argument types are guessed.
- `BookParams` middle fields (`baseFee` ... `priorityFee`) are mapped from types and range checks only.
- `setDefaultFee` on a wrong block: revert or no-op is unverified.
- Engine constructor values, the pair-key hash encoding and the two-hop condition are inferred.
- Helper contracts (fingerprint, mode fee) are not decompiled. Selectors `0x1ed58fc8` and `0x4a89bec0` are raw `staticcall`s.
- Rounding: ceil is marked `TODO: round UP` in exact-out and the fee gross-up. Use libs for that.
- The paper does not specify the age curve, priority threshold, `factor`, accumulator reset or exact-out handling. Those come from the decompilation alone.

## References

- Paper: "Active Liquidity On Chain", arXiv 2609.38056 — https://arxiv.org/html/2609.38056v1
- TesseraSwap: 0x55555522005BcAE1c2424D474BfD5ed477749E3e
- TesseraEngine: 0x31e99e05fee3dce580af777c3fd63ee1b3b40c17
- TesseraBook (implementation): 0x6d9dd143e42b6338f4f6a7c0c26d124658f641cb
- TesseraBookProxy (example): 0x4B963fB4A26f082D94f964FA3c2764821Cc06Bd4
