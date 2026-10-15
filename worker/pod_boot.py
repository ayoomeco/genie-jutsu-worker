#!/usr/bin/env python3
"""Genie Jutsu pod boot helper (stdlib only, runs inside the RunPod pod; NEVER prints keys).

  pod_boot.py plan     --manifest M --slate S [--root /workspace]   # which files are missing/present (no network)
  pod_boot.py sync     --manifest M --slate S [--root /workspace] [--verify sha256|size] [--dry-run]
  pod_boot.py health   --url http://127.0.0.1:8188 [--timeout 900]
  pod_boot.py queue    --url ... --slate S --graphs DIR [--dry-run]
  pod_boot.py watchdog --url ... [--idle 900] [--max-usd 2.80] [--rate 2.49] [--max-seconds N] [--dry-run]

sync = idempotent: a file whose size matches AND whose sha256 is recorded in <root>/models/.jutsu-verified.json (or
recomputes equal) is skipped; mismatches are re-downloaded via bootstrap_volume.fetch (resume, hf_transfer).
watchdog = terminate THIS pod (RUNPOD_POD_ID, pod-scoped RUNPOD_API_KEY injected by RunPod) when ComfyUI's queue has been
empty for --idle seconds after at least one job ran, or when elapsed*rate >= max-usd, or elapsed >= max-seconds."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, sys, time, urllib.request

HERE = pathlib.Path(__file__).resolve().parent


def slate_models(manifest: dict, slate: dict) -> list[dict]:
    want = set(slate['quote']['models'])
    by = {m['target'].rsplit('/', 1)[-1]: m for m in manifest['models']}
    missing = sorted(want - set(by))
    if missing:
        raise SystemExit(f'[boot] FATAL slate models not in manifest: {missing}')
    for name in want:
        if by[name]['size_bytes'] != slate['quote']['models'][name]:
            raise SystemExit(f'[boot] FATAL size drift manifest vs slate for {name}')
        if not by[name].get('sha256'):
            raise SystemExit(f'[boot] FATAL no sha256 pinned for {name}')
    return [by[n] for n in sorted(want)]


def _sha(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(64 << 20), b''):
            h.update(b)
    return h.hexdigest()


def status(models: list[dict], root: pathlib.Path, verify: str) -> list[tuple[dict, str]]:
    ledger_p = root / 'models/.jutsu-verified.json'
    ledger = json.loads(ledger_p.read_text()) if ledger_p.exists() else {}
    out = []
    for m in models:
        p = root / m['target']
        if not p.exists():
            out.append((m, 'missing')); continue
        st = p.stat()
        if st.st_size != m['size_bytes']:
            out.append((m, 'bad_size')); continue
        key = m['target']; rec = ledger.get(key)
        if rec and rec.get('sha256') == m['sha256'] and rec.get('size') == st.st_size and rec.get('mtime') == int(st.st_mtime):
            out.append((m, 'ok')); continue
        if verify == 'size':
            out.append((m, 'ok_size')); continue
        if _sha(p) == m['sha256']:
            ledger[key] = {'sha256': m['sha256'], 'size': st.st_size, 'mtime': int(st.st_mtime)}
            ledger_p.parent.mkdir(parents=True, exist_ok=True); ledger_p.write_text(json.dumps(ledger, indent=1))
            out.append((m, 'ok'))
        else:
            out.append((m, 'bad_sha'))
    return out


def order_by_first_use(models: list[dict], slate: dict, graphs: pathlib.Path | None) -> list[dict]:
    """Files needed by the first queued run come first (so render can start while the rest downloads)."""
    if not graphs:
        return models
    rank = {}
    for i, r in enumerate(slate['runs']):
        g = graphs / f"{r['id']}.api.json"
        if not g.exists():
            continue
        for n in json.loads(g.read_text()).values():
            for v in n['inputs'].values():
                if isinstance(v, str):
                    rank.setdefault(v, i)
    return sorted(models, key=lambda m: rank.get(m['target'].rsplit('/', 1)[-1], 10 ** 6))


def preflight(graph: dict, object_info: dict) -> list[str]:
    """worker-comfyui 5.11-style pre-flight: every combo-valued string input must be an allowed option on the server
    (catches missing model files / input images before the GPU spends minutes on a doomed prompt)."""
    bad = []
    for nid, n in graph.items():
        spec = object_info.get(n['class_type'])
        if spec is None:
            bad.append(f'{nid}: unknown node {n["class_type"]}'); continue
        req = {**spec.get('input', {}).get('required', {}), **spec.get('input', {}).get('optional', {})}
        for k, v in n['inputs'].items():
            opt = req.get(k)
            if isinstance(v, str) and opt and isinstance(opt[0], list) and opt[0] and v not in opt[0]:
                bad.append(f'{nid}.{k}: {v!r} not on server')
    return bad


def cmd_sync(a) -> int:
    root = pathlib.Path(a.root)
    models = slate_models(json.load(open(a.manifest)), json.load(open(a.slate)))
    st = status(models, root, 'size' if a.dry_run else a.verify)
    todo = [m for m, s in st if not s.startswith('ok')]
    gb = sum(m['size_bytes'] for m in todo) / 1e9
    print(f'[boot] slate models {len(models)} ({sum(m["size_bytes"] for m in models)/1e9:.1f} GB); to fetch {len(todo)} ({gb:.1f} GB)')
    for m, s in st:
        print(f'  {s:8s} {m["target"]}')
    if a.dry_run or not todo:
        return 0
    sys.path.insert(0, str(HERE)); import bootstrap_volume as bv
    import concurrent.futures as cf
    os.environ.setdefault('HF_XET_HIGH_PERFORMANCE', '1')
    tok = os.environ.get('HF_TOKEN')
    todo = order_by_first_use(todo, json.load(open(a.slate)), pathlib.Path(a.graphs) if getattr(a, 'graphs', None) else None)
    for m in todo:
        p = root / m['target']
        if p.exists():
            p.unlink()                      # wrong size / wrong sha -> refetch
    with cf.ThreadPoolExecutor(max(1, a.workers)) as ex:
        for r in ex.map(lambda m: bv.fetch(m, root, True, tok, True), todo):
            print(f"[boot]   {r.get('status')} {r.get('id')} {r.get('seconds', '')}s", flush=True)
    bad = [m['target'] for m, s in status(models, root, a.verify) if not s.startswith('ok')]
    if bad:
        print(f'[boot] FATAL still bad after sync: {bad}'); return 2
    print('[boot] sync OK'); return 0


def _get(url: str, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read() or b'{}')


def cmd_health(a) -> int:
    t0 = time.time()
    while time.time() - t0 < a.timeout:
        try:
            s = _get(a.url + '/system_stats'); _get(a.url + '/object_info/KSampler')
            print(f'[boot] ComfyUI healthy after {time.time()-t0:.0f}s: {s.get("system", {}).get("comfyui_version")}')
            return 0
        except Exception:
            time.sleep(3)
    print('[boot] FATAL ComfyUI not healthy'); return 1


def queue_plan(slate: dict, graphs: pathlib.Path) -> tuple[list[tuple[str, pathlib.Path]], list[str]]:
    """(queueable runs, skipped run ids with no materialized API graph)."""
    out, skipped = [], []
    for r in slate['runs']:
        g = graphs / f"{r['id']}.api.json"
        (out.append((r['id'], g)) if g.exists() else skipped.append(r['id']))
    return out, skipped


def cmd_queue(a) -> int:
    plan, skipped = queue_plan(json.load(open(a.slate)), pathlib.Path(a.graphs))
    for rid in skipped:
        print(f'[boot] WARN skip {rid}: no API graph in {a.graphs}')
    if not plan:
        print('[boot] FATAL nothing to queue'); return 1
    if not a.dry_run and not a.no_preflight:
        oi = _get(a.url + '/object_info', timeout=60)
        for rid, g in plan:
            bad = preflight(json.load(open(g)), oi)
            if bad:
                print(f'[boot] FATAL preflight {rid}: {bad[:5]}'); return 3
    for rid, g in plan:
        if a.dry_run:
            print(f'[boot] would queue {rid}'); continue
        body = json.dumps({'prompt': json.load(open(g)), 'client_id': 'jutsu-autoqueue', 'extra_data': {'jutsu_run': rid}}).encode()
        req = urllib.request.Request(a.url + '/prompt', body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f'[boot] queued {rid}: {json.loads(r.read()).get("prompt_id")}')
    return 0


def should_stop(now: float, t0: float, last_busy: float | None, ran_any: bool, idle: int, max_usd: float, rate: float,
                max_seconds: int | None, down_since: float | None = None, down_grace: int = 300) -> str | None:
    el = now - t0
    if down_since is not None and now - down_since >= down_grace:
        return f'ComfyUI unreachable {down_grace}s after it was healthy (crash/OOM)'
    if max_seconds and el >= max_seconds:
        return f'max_seconds {max_seconds}'
    if el / 3600 * rate >= max_usd:
        return f'cost cap ${max_usd:.2f} at ${rate}/hr'
    if ran_any and last_busy is not None and now - last_busy >= idle:
        return f'idle {idle}s after last job'
    if not ran_any and el >= 2 * idle:   # never got work (e.g. bundle/queue failed): do not sit forever
        return 'no work received'
    return None


def terminate(dry: bool) -> None:
    pod = os.environ.get('RUNPOD_POD_ID')
    print(f'[boot] TERMINATE pod {pod} (dry={dry})', flush=True)
    if dry or not pod:
        return
    if os.system(f'command -v runpodctl >/dev/null && runpodctl remove pod {pod}') == 0:
        return
    req = urllib.request.Request(f'https://rest.runpod.io/v1/pods/{pod}', method='DELETE',
                                 headers={'Authorization': 'Bearer ' + os.environ.get('RUNPOD_API_KEY', '')})
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception as e:
        print(f'[boot] terminate REST failed: {type(e).__name__}')


def cmd_watchdog(a) -> int:
    t0 = float(os.environ.get('JUTSU_BOOT_T0', time.time())); last_busy = None; ran_any = False
    seen_up = False; down_since = None
    while True:
        now = time.time()
        try:
            q = _get(a.url + '/queue')
            busy = bool(q.get('queue_running') or q.get('queue_pending')); seen_up = True; down_since = None
        except Exception:
            busy = False
            if seen_up and down_since is None:
                down_since = now
        if busy:
            ran_any = True; last_busy = now
        why = should_stop(now, t0, last_busy, ran_any, a.idle, a.max_usd, a.rate, a.max_seconds, down_since)
        if why:
            print(f'[boot] watchdog: {why}'); terminate(a.dry_run); return 0
        time.sleep(a.poll)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest='cmd', required=True)
    for n in ('plan', 'sync'):
        p = sp.add_parser(n); p.add_argument('--manifest', required=True); p.add_argument('--slate', required=True)
        p.add_argument('--root', default='/workspace'); p.add_argument('--verify', default='sha256', choices=['sha256', 'size'])
        p.add_argument('--dry-run', action='store_true', default=(n == 'plan'))
        p.add_argument('--graphs'); p.add_argument('--workers', type=int, default=int(os.environ.get('JUTSU_DL_WORKERS', 4)))
    p = sp.add_parser('health'); p.add_argument('--url', default='http://127.0.0.1:8188'); p.add_argument('--timeout', type=int, default=900)
    p = sp.add_parser('queue'); p.add_argument('--url', default='http://127.0.0.1:8188'); p.add_argument('--slate', required=True)
    p.add_argument('--graphs', required=True); p.add_argument('--dry-run', action='store_true')
    p.add_argument('--no-preflight', action='store_true')
    p = sp.add_parser('watchdog'); p.add_argument('--url', default='http://127.0.0.1:8188'); p.add_argument('--idle', type=int, default=900)
    p.add_argument('--max-usd', type=float, default=2.80); p.add_argument('--rate', type=float, default=2.49)
    p.add_argument('--max-seconds', type=int); p.add_argument('--poll', type=int, default=15); p.add_argument('--dry-run', action='store_true')
    a = ap.parse_args(argv)
    return {'plan': cmd_sync, 'sync': cmd_sync, 'health': cmd_health, 'queue': cmd_queue, 'watchdog': cmd_watchdog}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
