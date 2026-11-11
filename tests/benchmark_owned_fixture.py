#!/usr/bin/env python3
"""Benchmark completed background layouts using three owned synthetic windows.

Creates three ordinary windows and one floating panel in an inactive Space. Never opens
user documents or controls other apps. Build/fixture launch are separate from the
cold API/start and completed-layout measurements. Requires the same permissions
and compatible macOS private API as Workspace Layout itself.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / 'scripts/workspacectl.py'
BUNDLE = 'io.vioano.workspace-layout.fixture'


def distribution(values):
    values = sorted(values)
    return {'samples': len(values), 'min_ms': min(values), 'median_ms': statistics.median(values),
            'p95_ms': values[min(len(values)-1, int(len(values)*.95))], 'max_ms': max(values)}


def latest_metadata(path):
    with path.open('rb') as source:
        source.seek(0, 2)
        source.seek(max(0, source.tell()-65536))
        data=source.read()
    lines=data.splitlines()
    if data and not data.endswith(b'\n'): lines=lines[:-1]
    return json.loads(lines[-1]) if lines else None


def run_benchmark(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='wlf-', dir='/tmp') as runtime:
        socket_path = Path(runtime) / 'api.sock'
        def invoke(arguments, cwd=ROOT):
            began = time.monotonic_ns()
            process = subprocess.run([sys.executable, str(CLIENT), '--socket', str(socket_path), *arguments],
                                     cwd=cwd, capture_output=True, text=True, timeout=20)
            elapsed = round((time.monotonic_ns()-began)/1e6, 3)
            try:
                result = json.loads(process.stdout or process.stderr)
            except ValueError:
                result = {'ok': False, 'error': process.stdout + process.stderr}
            return {'external_elapsed_ms': elapsed, 'returncode': process.returncode, 'result': result}

        fixture = None
        monitor = None
        trace = None
        stop = output/'monitor.stop'
        source_paths = [CLIENT, ROOT/'scripts/workspace_service.py', ROOT/'scripts/windowbridge.m',
                        ROOT/'tests/workspace_fixture.m', ROOT/'tests/watch_fixture_metadata.m', Path(__file__)]
        source_hashes = {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in source_paths}
        try:
            app = output/'WorkspaceLayoutFixture.app'
            executable = app/'Contents/MacOS/fixture'
            executable.parent.mkdir(parents=True)
            info = {'CFBundleIdentifier': BUNDLE, 'CFBundleName': 'Workspace Layout Fixture',
                    'CFBundleDisplayName': 'Workspace Layout Fixture',
                    'CFBundleExecutable': 'fixture', 'CFBundlePackageType': 'APPL',
                    'CFBundleVersion': '1', 'LSUIElement': True, 'NSHighResolutionCapable': True}
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            monitor_binary = output/'watch-fixtures'
            for source, destination in [('workspace_fixture.m', executable), ('watch_fixture_metadata.m', monitor_binary)]:
                subprocess.run(['clang', '-O2', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'ApplicationServices',
                                str(ROOT/'tests'/source), '-o', str(destination)], check=True)
            # Native compilation/permission readiness belongs to setup, not API cold-start latency.
            from_import = "import sys;sys.path.insert(0,sys.argv[1]);import workspace_layout;workspace_layout.native({'command':'snapshot'})"
            subprocess.run([sys.executable, '-c', from_import, str(ROOT/'scripts')], check=True,
                           capture_output=True, text=True)
            cold = invoke(['start'])
            if not cold['result'].get('ready'):
                raise RuntimeError(cold)
            reserved = invoke(['reserve', '--workspace', args.workspace, '--task', 'fixture-'+uuid.uuid4().hex])
            if not reserved['result'].get('ok'):
                raise RuntimeError(reserved)
            target = reserved['result']['workspace']
            manifest_path = output/'fixture-manifest.json'
            fixture = subprocess.Popen([str(executable), str(target['id']), str(manifest_path)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic()+10
            while not manifest_path.exists() and time.monotonic()<deadline and fixture.poll() is None:
                time.sleep(.025)
            if not manifest_path.exists():
                raise RuntimeError('Owned fixture did not establish prebound windows')
            manifest = json.loads(manifest_path.read_text())
            ids = [window['id'] for window in manifest.get('records', [])]
            owned = manifest.get('records', []) + manifest.get('popups', [])
            owned_ids = {window['id'] for window in owned}
            if not (manifest.get('ok') and manifest.get('bundle_id')==BUNDLE and len(ids)==3
                    and manifest.get('binding_verified_before_reveal') and len(owned)==4
                    and all(w['pid']==fixture.pid and w['spaces']==[target['id']] for w in owned)
                    and all(manifest[key]['frontPID']!=fixture.pid and target['id'] not in manifest[key]['activeSpaces']
                            for key in ['context_before','context_after'])):
                raise RuntimeError('Owned fixture creation proof failed: '+json.dumps(manifest))
            initial = invoke(['state', '--fresh', '--windows', ','.join(map(str, ids))])
            if not initial['result'].get('ok') or not all(w['pid']==fixture.pid and w['app']==BUNDLE
                    for w in initial['result']['windows']) or len(initial['result']['windows'])!=3:
                raise RuntimeError('Fixture identity could not be verified')
            before = invoke(['status'])['result']
            time.sleep(args.idle_seconds)
            after = invoke(['status'])['result']
            idle_wall = after['uptime_seconds']-before['uptime_seconds']
            idle_cpu = sum(after[k]-before[k] for k in ['cpu_self_seconds','cpu_children_seconds'])
            idle = {'seconds': idle_wall, 'self_and_child_cpu_seconds': idle_cpu,
                    'one_core_percent': 100*idle_cpu/idle_wall, 'max_rss_bytes': after['max_rss_bytes']}
            cwd_cases = [ROOT, Path(runtime)/'project-a', Path(runtime)/'project-b']
            for path in cwd_cases[1:]: path.mkdir()
            trace_path = output/'metadata.jsonl'
            trace = trace_path.open('w')
            monitor = subprocess.Popen([str(monitor_binary), str(manifest_path), str(stop)],
                                       stdout=trace, stderr=subprocess.PIPE, text=True)
            samples = []
            stopped_early = None
            for index in range(args.samples):
                arguments = ['arrange', '--workspace', str(target['index']), '--windows', ','.join(map(str,ids)),
                             '--layout', 'main-left' if index%2==0 else 'main-right',
                             '--main', str(ids[(index//4)%3]), '--ratio', '.39' if index%2==0 else '.61', '--gap', '4']
                record = invoke(arguments, cwd_cases[index%3])
                record.update(index=index, cwd_case=index%3, arguments=arguments)
                record['within_one_second'] = bool(record['returncode']==0 and record['result'].get('ok')
                                                   and record['result'].get('deadline_met') and record['external_elapsed_ms']<=1000)
                samples.append(record)
                if (index+1)%20==0: print(f'completed {index+1}/{args.samples}', flush=True)
                observed=latest_metadata(trace_path)
                interference=observed and (observed['context']['frontPID']==fixture.pid
                                           or target['id'] in observed['context']['activeSpaces'])
                if not record['within_one_second'] or record['result'].get('context_unchanged') is False or interference:
                    stopped_early={'index':index,'reason':'deadline, action, or foreground/Space verification failed'}
                    break
            stop.write_text('stop')
            monitor.wait(timeout=5)
            trace.close()
            monitor = trace = None
            traces = [json.loads(line) for line in trace_path.read_text().splitlines() if line.strip()]
            wrong = [i for i,row in enumerate(traces) if {w['id'] for w in row['windows']}!=owned_ids
                     or any(w['spaces'] != [target['id']] for w in row['windows'])]
            foreground = [i for i,row in enumerate(traces) if row['context']['frontPID']==fixture.pid]
            activated = [i for i,row in enumerate(traces) if target['id'] in row['context']['activeSpaces']]
            intervals = [(b['uptime']-a['uptime'])*1000 for a,b in zip(traces,traces[1:])]
            states = [invoke(['state']) for _ in range(30)]
            final = invoke(['state', '--fresh', '--windows', ','.join(map(str,ids))])
            event_path=Path(str(manifest_path)+'.events.jsonl')
            fixture_events=[json.loads(line) for line in event_path.read_text().splitlines() if line.strip()]
            failures = [s for s in samples if not s['within_one_second']]
            sources_unchanged = all(hashlib.sha256(path.read_bytes()).hexdigest()==source_hashes[str(path.relative_to(ROOT))]
                                    for path in source_paths)
            monitored = {'samples':len(traces), 'interval_ms':distribution(intervals) if intervals else None,
                         'wrong_space_samples':wrong, 'fixture_foreground_samples':foreground,
                         'task_space_active_samples':activated}
            report = {'scope':'Three owned synthetic AppKit windows plus one floating panel only. No user application/document loading guarantee.',
                      'popup_scope':'Standalone NSPanel; an application-modal event loop is not exercised.',
                      'cold_scope':'New isolated API service; compiled native helper already available; fixture not yet launched.',
                      'source_sha256':source_hashes, 'sources_unchanged_during_test':sources_unchanged,
                      'cold_service_start':cold, 'reservation':reserved, 'fixture':manifest, 'idle_profile':idle,
                      'allocation_mode':'confirmed_empty_auto' if args.workspace=='auto' else 'explicit_inactive_workspace',
                      'actions':samples, 'latency':distribution([s['external_elapsed_ms'] for s in samples]),
                      'stopped_early':stopped_early,'fixture_events':fixture_events,
                      'state_queries':states, 'state_latency':distribution([s['external_elapsed_ms'] for s in states]),
                      'monitor':monitored, 'final_readback':final, 'failed_or_over_deadline':failures,
                      'passed':len(samples)==args.samples and bool(traces) and sources_unchanged and final['result'].get('ok')
                               and not failures and not wrong and not foreground and not activated}
            (output/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
            print(json.dumps({key:report[key] for key in ['passed','latency','state_latency','idle_profile','monitor']}, indent=2))
            print(output/'report.json')
            return 0 if report['passed'] else 1
        except Exception as error:
            (output/'failure.json').write_text(json.dumps({'passed':False,'error':str(error)},indent=2)+'\n')
            raise
        finally:
            stop.write_text('stop')
            if monitor is not None:
                monitor.wait(timeout=5)
            if trace is not None: trace.close()
            # This Popen object is the only process this runner is allowed to terminate.
            if fixture is not None and fixture.poll() is None:
                fixture.terminate()
                fixture.wait(timeout=5)
            invoke(['stop'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--idle-seconds', type=float, default=5)
    parser.add_argument('--workspace', default='auto', help='Default: confirmed empty inactive Space; or an explicitly authorized Desktop index')
    parser.add_argument('--output', type=Path,
                        default=ROOT/'.local/benchmarks'/time.strftime('%Y%m%d-%H%M%S'))
    args = parser.parse_args()
    if args.samples<1 or args.idle_seconds<=0: parser.error('samples and idle-seconds must be positive')
    return run_benchmark(args)


if __name__=='__main__':
    raise SystemExit(main())
