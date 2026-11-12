#!/usr/bin/env bash
# Runs every benchmark workload in its own process, for laffy and for taffy, and prints a
# comparison table (Markdown). Timings of a workload that runs after others in the same
# process are inflated on both sides, so the comparison uses isolated runs.
#
# Usage: benches/compare.sh [runs-per-workload]   (default 3; the best run is reported)
set -euo pipefail
cd "$(dirname "$0")/.."
runs="${1:-3}"

zig build bench -- flex-chain-100 >/dev/null
laffy_bin="$(ls -t .zig-cache/o/*/bench | head -1)"
(cd benches/taffy-compare && cargo build --release --quiet)
taffy_bin="benches/taffy-compare/target/release/taffy-compare"

workloads="$("$laffy_bin" --verify | awk '{print $1}')"
results="$(mktemp)"
trap 'rm -f "$results"' EXIT
for workload in $workloads; do
    for _ in $(seq "$runs"); do
        echo "laffy $("$laffy_bin" "$workload" | grep "^$workload ")" >>"$results"
        echo "taffy $("$taffy_bin" "$workload" | grep "^$workload ")" >>"$results"
    done
done

awk '
{
    side = $1; name = $2
    if (!(name in seen)) { seen[name] = 1; order[++count] = name; nodes[name] = $3 }
    key = side SUBSEP name
    if (!(key in full) || $4 < full[key]) full[key] = $4
    if (!(key in relayout) || $5 < relayout[key]) relayout[key] = $5
    kib[key] = $6; calls[key] = $8
}
END {
    print "| workload | nodes | laffy full | taffy full | ratio | laffy relayout | taffy relayout | ratio | alloc KiB, laffy / taffy | allocation calls, laffy / taffy |"
    print "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    for (i = 1; i <= count; i++) {
        name = order[i]; l = "laffy" SUBSEP name; t = "taffy" SUBSEP name
        printf "| %s | %d | %.0f | %.0f | %.2f | %.0f | %.0f | %.2f | %.0f / %.0f | %d / %d |\n", name, nodes[name], full[l], full[t], full[l] / full[t], relayout[l], relayout[t], relayout[l] / relayout[t], kib[l], kib[t], calls[l], calls[t]
    }
}' "$results"
