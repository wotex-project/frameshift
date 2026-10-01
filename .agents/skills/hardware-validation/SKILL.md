---
name: hardware-validation
description: Plan or assess incoming inspection, assembly, electrical or thermal measurements, display tests, and fault recovery for an exact panel, controller, power path, enclosure, or complete frame. Apply when source-based candidates must be checked against received hardware or a physical build.
user-invocable: false
---

# Hardware validation

**Inputs:** exact component/build revision, selected frame requirements, primary
limits and drawings, available equipment, and the observations or measurements
to evaluate.

**Output:** an executable measurement plan or a result scoped to the recorded
configuration, with pass/stop conditions, observations, failed or missing checks,
and reproducible evidence. Use the existing build-record format only when the
task calls for a maintained record; otherwise return the assessment in chat.

## Establish the configuration

1. Read the relevant tests and record format in the
   [hardware validation plan](../../../docs/hardware/validation-plan.md) and the
   selected [frame requirements](../../../docs/README.md#reference-frames).
   Use the shared tests and frame-specific tests that apply to this build.
2. Inspect received markings, part/board revisions, firmware and controller,
   connectors, cable, waveform/scan mode, and visible defects. Compare them with
   primary documents; a drawing revision alone cannot identify the received
   component. Resolve source or sourcing gaps using decision research.
3. Record the reproducible operating configuration: host/protocol/render
   revisions, artwork, brightness and refresh settings; PSU/protection,
   grounding and wiring; arrangement, surface treatment, passe-partout,
   ventilation, mounting, bend radii, and service access.
4. Record instruments and their material range/accuracy, probe locations,
   ambient and lighting conditions, sample interval, warm-up, and test duration.

## Plan and interpret measurements

1. Define pass and stop conditions from the owning requirement, derated
   component limits, and instrument limits before testing. Do not invent
   universal depth, current, temperature, or duration thresholds. Use a
   qualified setup for tests involving hazardous energy or destructive faults.
2. Measure the complete installed stack and power path. Select relevant
   operating cases: retained artwork, refresh/scan, worst valid brightness,
   voltage drop/inrush, and thermal stabilization. Name each measurement point
   and distinguish vendor limits, calculations, and measurements.
3. Exercise applicable digest/profile refusal, partial transfer, host/network
   loss, power interruption, firmware recovery, and last-valid-artwork behavior.
   Physical display success needs physical observation; a transfer
   acknowledgement or simulated panel cannot establish it.
4. Compare observations with the predefined conditions. Preserve failures,
   incomplete checks, configuration changes, and measurement uncertainty.
   Stop at the declared electrical, thermal, mechanical, or instrument boundary;
   do not infer product certification or unattended-use safety from bring-up.
5. If a maintained result is requested, bind logs, photos, measurements, and
   immutable firmware/configuration identifiers to the exact build. Update
   shared constraints or a frame's qualification only to the extent those
   results support it. Keep private account data and credentials out of records.
