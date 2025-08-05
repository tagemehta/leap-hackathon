# Verification Flow (TrafficEye → LLM)

This document describes the **view-aware, cost-aware vehicle verification pipeline** introduced in August 2025.

## Overview
The system combines two verification engines:

| Engine | Latency | Cost | Strengths |
|--------|---------|------|-----------|
| **TrafficEye MMR API** | ~50 ms | High | Precise make-model-rear/front detection. Provides *view angle* metadata. |
| **LLM Verifier** | 3-10 s | Low | Handles side/partial views; good at fuzzy semantic reasoning. |

Goal: maximise accuracy while *minimising paid MMR calls* and *avoiding LLM latency* whenever a clean front/rear shot is available.

## Key Data Added
* `Candidate.VehicleView` – `.front`, `.rear`, `.side`, `.unknown`  
  stores the **best observed angle** + `viewScore`.
* `lastMMRTime` – last timestamp this candidate hit the MMR API.
* `waitingUntil` – when a side/unknown view may fall back to LLM.
* `VerificationConfig`
  * `perCandidateMMRInterval` (default 2 s)
  * `sideViewWait` (default 0.8 s)

## Processing Steps
1. **Initial detection**  
   *Every new candidate* immediately triggers **one** MMR call, giving both
   – a quick match decision, and  
   – the first `vehicleView` assessment.

2. **Fast path** – *front / rear*  
   If that angle is `.front` or `.rear`:
   * Accept / reject using the **MMR result only**.  
   * Do **not** call the LLM.  
   * Further MMR calls for this candidate are suppressed for
     `perCandidateMMRInterval` seconds.

3. **Slow path** – *side / unknown*
   * Set `waitingUntil = now + sideViewWait`.
   * Delay and keep scanning frames.
   * When the per-candidate MMR throttle expires:
     * If a *new* MMR returns front/rear → go to Fast path.
     * Else if `now ≥ waitingUntil` → fire **one** LLM call and cache its result.  
       (LLM results are cheap but slow; we only pay when truly necessary.)

4. **Book-keeping after every verification**
   * `updateView()` keeps the best angle and score.
   * `lastMMRTime` stamped for MMR responses.
   * `waitingUntil` reset/cleared as appropriate.

## Throttling Summary
* **Global** – `minVerifyInterval` (3 s) prevents frame-rate MMR floods.
* **Per Candidate** – `perCandidateMMRInterval` (2 s) caps paid hits per car.
* **Side-view Timeout** – `sideViewWait` (0.8 s) before allowing an LLM fallback.

Together these rules mean:
* Every car costs **≥1** MMR call (cannot know angle otherwise).
* Subsequent MMR calls are rare, LLM calls are rarer.
* User receives quick confirmation for good angles; slower but still timely feedback when only side views are visible.

## Future Enhancements
* **Multi-frame vote** – require 2 agreeing positives within 1 s before full match.
* Adaptive timing based on real-world cost data.
* Dynamic change of `sideViewWait` if vehicle remains side-only for extended periods.

---
_Last updated: 2025-08-01_
