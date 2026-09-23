#!/usr/bin/env python3
"""Compare two Potree 2.0 octrees node-by-node.

Usage: compare_octrees.py A_dir B_dir [--json out.json]

Reads hierarchy.bin exactly as potree's OctreeLoader.js:151-232 does (22 B/node,
proxy records point at the next hierarchy chunk), then for every node reads its
byte range from octree.bin and compares:

  N  node-name sets
  C  per-node point counts (from hierarchy numPoints AND from byteSize/bpp)
  M  per-node multiset of full 18-byte records (position+rgb)
  P  per-node multiset of positions only (first 12 bytes)
  G  global multiset of all records (is anything lost/duplicated overall?)

It never uses metadata.json's self-reported "points".
Self-test (--selftest A_dir): compares A with itself (must be 0 diffs) and with a
copy where one point was moved from one node's record to another's value -> must
report a diff. A comparer that cannot see a difference is not a comparer.
"""
import sys, os, json, struct, hashlib
import numpy as np


def load_tree(d):
    meta = json.load(open(os.path.join(d, 'metadata.json')))
    bpp = sum(a['size'] for a in meta['attributes'])
    H = open(os.path.join(d, 'hierarchy.bin'), 'rb').read()
    first = meta['hierarchy']['firstChunkSize']
    nodes = {}
    pending = [('r', 0, first)]
    while pending:
        name, off, size = pending.pop()
        assert size % 22 == 0, (name, size)
        order = [name]
        for i in range(size // 22):
            cur = order[i]
            t, cm, npts, bo, bs = struct.unpack_from('<BBIQQ', H, off + i * 22)
            if t == 2:
                # proxy: this record points at the hierarchy chunk rooted at `cur`
                pending.append((cur, bo, bs))
                continue
            assert cur not in nodes, ('duplicate node', cur)
            nodes[cur] = dict(type=t, mask=cm, n=npts, off=bo, size=bs)
            for c in range(8):
                if cm & (1 << c):
                    order.append(cur + str(c))
    return meta, bpp, nodes


def node_rows(octree, bpp, nd):
    raw = octree[nd['off']:nd['off'] + nd['size']]
    assert raw.size % bpp == 0
    return np.ascontiguousarray(raw).reshape(-1, bpp)


def sorted_view(rows, width):
    v = np.ascontiguousarray(rows[:, :width]).view(np.dtype((np.void, width))).ravel()
    return np.sort(v)


def multiset_diff(a, b):
    """number of records in the symmetric multiset difference of sorted void arrays"""
    if a.size == b.size and np.array_equal(a, b):
        return 0
    allv = np.concatenate([a, b])
    lab = np.concatenate([np.ones(a.size, np.int64), -np.ones(b.size, np.int64)])
    order = np.argsort(allv, kind='stable')
    allv, lab = allv[order], lab[order]
    starts = np.r_[0, np.flatnonzero(allv[1:] != allv[:-1]) + 1]
    net = np.add.reduceat(lab, starts)
    return int(np.abs(net).sum())


def compare(A, B):
    ma, bppa, na = load_tree(A)
    mb, bppb, nb = load_tree(B)
    assert bppa == bppb, (bppa, bppb)
    bpp = bppa
    oa = np.memmap(os.path.join(A, 'octree.bin'), dtype=np.uint8, mode='r')
    ob = np.memmap(os.path.join(B, 'octree.bin'), dtype=np.uint8, mode='r')
    rep = {}
    rep['scale_equal'] = ma['scale'] == mb['scale']
    rep['offset_equal'] = ma['offset'] == mb['offset']
    rep['nodes_A'] = len(na); rep['nodes_B'] = len(nb)
    onlyA = sorted(set(na) - set(nb)); onlyB = sorted(set(nb) - set(na))
    rep['nodes_only_A'] = len(onlyA); rep['nodes_only_B'] = len(onlyB)
    rep['nodes_only_A_list'] = onlyA[:20]; rep['nodes_only_B_list'] = onlyB[:20]
    common = sorted(set(na) & set(nb))
    cnt_diff = 0; full_diff_nodes = 0; pos_diff_nodes = 0
    full_diff_pts = 0; pos_diff_pts = 0
    bytesize_mismatch = 0
    worst = []
    tot_a = 0; tot_b = 0
    for name in common:
        x, y = na[name], nb[name]
        ra, rb = node_rows(oa, bpp, x), node_rows(ob, bpp, y)
        if ra.shape[0] != x['n'] or rb.shape[0] != y['n']:
            bytesize_mismatch += 1
        tot_a += ra.shape[0]; tot_b += rb.shape[0]
        if ra.shape[0] != rb.shape[0]:
            cnt_diff += 1
        fa, fb = sorted_view(ra, bpp), sorted_view(rb, bpp)
        d = multiset_diff(fa, fb)
        if d:
            full_diff_nodes += 1; full_diff_pts += d
            worst.append((d, name, ra.shape[0], rb.shape[0]))
            pa, pb = sorted_view(ra, 12), sorted_view(rb, 12)
            dp = multiset_diff(pa, pb)
            if dp:
                pos_diff_nodes += 1; pos_diff_pts += dp
    for name in onlyA:
        tot_a += node_rows(oa, bpp, na[name]).shape[0]
    for name in onlyB:
        tot_b += node_rows(ob, bpp, nb[name]).shape[0]
    rep.update(common_nodes=len(common), count_diff_nodes=cnt_diff,
               full_multiset_diff_nodes=full_diff_nodes, full_multiset_diff_points=full_diff_pts,
               pos_multiset_diff_nodes=pos_diff_nodes, pos_multiset_diff_points=pos_diff_pts,
               bytesize_vs_numPoints_mismatch=bytesize_mismatch,
               points_in_tree_A=tot_a, points_in_tree_B=tot_b,
               octree_bin_A=int(oa.size // bpp), octree_bin_B=int(ob.size // bpp))
    worst.sort(reverse=True)
    rep['worst_nodes'] = worst[:10]
    # global multiset: every record of every node, both trees
    ga = sorted_view(np.ascontiguousarray(oa).reshape(-1, bpp), bpp)
    gb = sorted_view(np.ascontiguousarray(ob).reshape(-1, bpp), bpp)
    rep['global_multiset_diff_points'] = multiset_diff(ga, gb)
    rep['global_sha_A'] = hashlib.sha256(ga.tobytes()).hexdigest()[:16]
    rep['global_sha_B'] = hashlib.sha256(gb.tobytes()).hexdigest()[:16]
    return rep


if __name__ == '__main__':
    if sys.argv[1] == '--selftest':
        import shutil, tempfile
        A = sys.argv[2]
        r0 = compare(A, A)
        assert r0['full_multiset_diff_points'] == 0 and r0['nodes_only_A'] == 0, r0
        tmp = tempfile.mkdtemp(prefix='cmp_selftest_')
        for f in ('metadata.json', 'hierarchy.bin', 'octree.bin'):
            shutil.copy(os.path.join(A, f), tmp)
        meta, bpp, nodes = load_tree(tmp)
        # overwrite point 0 of the largest node with point 0 of another node (count-preserving)
        big = sorted(nodes, key=lambda k: -nodes[k]['n'])
        a, b = nodes[big[0]], nodes[big[1]]
        with open(os.path.join(tmp, 'octree.bin'), 'r+b') as f:
            f.seek(b['off']); rec = f.read(bpp)
            f.seek(a['off']); f.write(rec)
        r1 = compare(A, tmp)
        shutil.rmtree(tmp)
        ok = r1['full_multiset_diff_points'] == 2 and r1['full_multiset_diff_nodes'] == 1 \
            and r1['global_multiset_diff_points'] == 2
        print(json.dumps(dict(self=r0['full_multiset_diff_points'], corrupted=r1['full_multiset_diff_points'],
                              corrupted_global=r1['global_multiset_diff_points'],
                              verdict='PASS - comparer sees a moved point' if ok else 'FAIL - comparer blind')))
        sys.exit(0 if ok else 1)
    rep = compare(sys.argv[1], sys.argv[2])
    out = json.dumps(rep, indent=1, default=str)
    print(out)
    if len(sys.argv) > 4 and sys.argv[3] == '--json':
        open(sys.argv[4], 'w').write(out)
