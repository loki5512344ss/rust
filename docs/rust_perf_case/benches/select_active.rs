use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use rust_perf_case::{make_rows, select_active_after, select_active_before};

fn bench_select(c: &mut Criterion) {
    let mut group = c.benchmark_group("select_active");
    for &n in &[64usize, 4_096, 262_144] {
        for &percent in &[1u8, 50, 99] {
            let rows = make_rows(n, percent); // Not timed.
            let scenario = format!("n={n}/active={percent}%");
            group.throughput(Throughput::Elements(n as u64));
            group.bench_with_input(BenchmarkId::new("before", &scenario), &rows, |b, input| {
                b.iter(|| black_box(select_active_before(black_box(input))));
            });
            group.bench_with_input(BenchmarkId::new("after", &scenario), &rows, |b, input| {
                b.iter(|| black_box(select_active_after(black_box(input))));
            });
        }
    }
    group.finish();
}

criterion_group!(benches, bench_select);
criterion_main!(benches);
