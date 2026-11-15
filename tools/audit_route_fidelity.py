#!/usr/bin/env python3
"""Route fidelity audit: sample points along A* routes, measure distance from
each sample to the real pedestrian network (OSM ways + Mapbox tile paths).
Reports median/p90/p99 distance and fraction of samples within thresholds.
"""
import json, math, random, sys, time
sys.path.insert(0, ".")
from router import Router

MPLAT = 111320.0
MPLNG = 111320.0 * math.cos(math.radians(43.07))
BUCK = 0.0008

def pt_seg_m(px, py, ax, ay, bx, by):
    px*=MPLAT; py*=MPLNG; ax*=MPLAT; ay*=MPLNG; bx*=MPLAT; by*=MPLNG
    dx, dy = bx-ax, by-ay
    L2 = dx*dx+dy*dy
    if L2 == 0: return math.hypot(px-ax, py-ay)
    t = max(0.0, min(1.0, ((px-ax)*dx+(py-ay)*dy)/L2))
    return math.hypot(px-(ax+t*dx), py-(ay+t*dy))

def load_network():
    lines = []
    for cand in ("/tmp/uw_ways.json", "/tmp/uw_roads.json"):
        try:
            for e in json.load(open(cand)).get("elements", []):
                g = e.get("geometry")
                if g: lines.append([[p["lat"], p["lon"]] for p in g])
        except (OSError, ValueError): pass
    try:
        for ln in json.load(open("/tmp/uw_mapbox_paths.json"))["lines"]:
            lines.append(ln["coords"])
    except (OSError, ValueError): pass
    idx = {}
    for li, cs in enumerate(lines):
        for k in range(len(cs)-1):
            clat, clng = (cs[k][0]+cs[k+1][0])/2, (cs[k][1]+cs[k+1][1])/2
            idx.setdefault((int((clat-43)/BUCK), int((clng+90)/BUCK)), []).append((li, k))
    return lines, idx

def min_dist(pt, lines, idx):
    pr, pc = int((pt[0]-43)/BUCK), int((pt[1]+90)/BUCK)
    best = float("inf"); seen = set()
    R = 6  # ~536m radius
    for dr in range(-R, R+1):
        for dc in range(-R, R+1):
            for (li, k) in idx.get((pr+dr, pc+dc), ()):
                if li in seen: continue
                seen.add(li)
                cs = lines[li]
                d = pt_seg_m(pt[0], pt[1], cs[k][0], cs[k][1], cs[k+1][0], cs[k+1][1])
                if d < best: best = d
    return best

def main(n_pairs=120, seed=7, sample_m=15.0):
    buildings = json.load(open("configs/buildings.json"))["buildings"]
    all_b = buildings
    used = [b for b in buildings if b.get("type") != "housing"]
    R = Router(all_b)  # FULL grid like generator — corridor file matches this grid
    lines, idx = load_network()
    print(f"network: {len(lines)} lines, {sum(len(c)-1 for c in lines)} segments")
    rng = random.Random(seed)
    pairs = [(a, b) for a in range(len(used)) for b in range(len(used)) if a < b]
    rng.shuffle(pairs); pairs = pairs[:n_pairs]
    t0 = time.time()
    ds = []
    for i, (ai, bi) in enumerate(pairs):
        route = R.route(R.door_of(used[ai]), R.door_of(used[bi]))
        if not route: continue
        # walk the polyline, sample every sample_m meters
        acc = 0.0
        pts = [route[0]]
        for p, q in zip(route, route[1:]):
            seg = math.hypot((q[0]-p[0])*MPLAT, (q[1]-p[1])*MPLNG)
            while acc + seg >= sample_m:
                t = (sample_m - acc) / seg
                pts.append([p[0]+t*(q[0]-p[0]), p[1]+t*(q[1]-p[1])])
                seg -= (sample_m - acc); acc = 0.0
            acc += seg
        for p in pts:
            ds.append(min_dist(p, lines, idx))
        if (i+1) % 20 == 0:
            print(f"  {i+1}/{len(pairs)} pairs, {len(ds)} samples ({time.time()-t0:.0f}s)")
    ds.sort()
    n = len(ds)
    frac = lambda t: sum(1 for d in ds if d <= t)/n*100
    print(f"\nsamples: {n}")
    print(f"median {ds[n//2]:.1f}m  p90 {ds[int(n*0.9)]:.1f}m  p99 {ds[int(n*0.99)]:.1f}m  max {ds[-1]:.1f}m")
    for t in (5, 10, 12, 15, 25):
        print(f"  within {t:>2}m: {frac(t):.1f}%")

if __name__ == "__main__":
    main()
