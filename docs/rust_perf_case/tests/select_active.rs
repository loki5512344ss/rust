use rust_perf_case::{make_rows, select_active_after, select_active_before};

#[test]
fn edge_cases_preserve_output_and_order() {
    let cases: &[&[(u64, u8)]] = &[
        &[],
        &[(9, 0)],
        &[(9, 1)],
        &[(9, 2), (3, 0), (1, 7)],
        &[(5, 1), (5, 1), (2, 0)],
    ];
    for &rows in cases {
        assert_eq!(select_active_before(rows), select_active_after(rows));
    }
    assert_eq!(select_active_after(&[(8, 1), (7, 0), (6, 2)]), vec![8, 6]);
}

#[test]
fn deterministic_matrix_preserves_behavior() {
    for &size in &[0, 1, 2, 3, 31, 32, 33, 1_024, 10_000] {
        for &percent in &[0, 1, 10, 50, 90, 99, 100] {
            let rows = make_rows(size, percent);
            assert_eq!(select_active_before(&rows), select_active_after(&rows),
                       "size={size}, active_percent={percent}");
        }
    }
}
