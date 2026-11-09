//! Educational candidate optimization: allocation strategy for a filtered Vec.
//! No runtime speedup is assumed; compare several sizes and selectivities.

/// Baseline: output buffer grows as necessary.
pub fn select_active_before(rows: &[(u64, u8)]) -> Vec<u64> {
    let mut result = Vec::new();
    for &(id, active) in rows {
        if active != 0 {
            result.push(id);
        }
    }
    result
}

/// Candidate: reserve the upper bound. May use more memory for sparse outputs.
pub fn select_active_after(rows: &[(u64, u8)]) -> Vec<u64> {
    let mut result = Vec::with_capacity(rows.len());
    for &(id, active) in rows {
        if active != 0 {
            result.push(id);
        }
    }
    result
}

/// Deterministic, varied input. Generated outside the measured closure.
pub fn make_rows(count: usize, active_percent: u8) -> Vec<(u64, u8)> {
    assert!(active_percent <= 100);
    let mut seed = 0x0123_4567_89ab_cdef_u64;
    let mut rows = Vec::with_capacity(count);
    for i in 0..count {
        seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let active = u8::from(((seed >> 32) % 100) < u64::from(active_percent));
        rows.push((i as u64, active));
    }
    rows
}
