#!/usr/bin/env python3
"""Run a task on this repository’s dedicated simulator in the shared pool."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'scripts' / 'simulator-policy.json'
POOL_PATH = Path.home() / '.local/lib/keinois-ios-pool/ios_pool.py'
DEFAULT_RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2'
DEFAULT_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro'
STANDARD_IPHONE_SPECS = (
    (DEFAULT_RUNTIME, DEFAULT_DEVICE_TYPE),
    ('com.apple.CoreSimulator.SimRuntime.iOS-26-5',
     'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max'),
)

def call(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def fixture_app_valid(app, guard):
    if app is None:
        return False
    try:
        app = Path(app)
        info = plistlib.loads((app/'Info.plist').read_bytes())
        executable = info['CFBundleExecutable']
        if Path(executable).name != executable:
            return False
        data = (app/executable).read_bytes()
        return (info.get('CFBundleIdentifier') == guard['fixture_bundle_id']
                and 'iPhoneSimulator' in info.get('CFBundleSupportedPlatforms', [])
                and all(marker.encode() in data for marker in guard['fixture_markers']))
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        return False

def choose_mode(requested, features, binary, config, fixture_app=None):
    if requested == 'stock':
        return 'stock', 'explicit stock requested'
    if not features:
        return 'stock', 'declare task features; ambiguous work uses stock'
    mapping = config.get('features', {})
    unknown = sorted(set(features) - set(mapping))
    if unknown:
        return 'stock', 'unmapped feature(s): ' + ','.join(unknown)
    guard = config.get('launch_guard')
    if guard and not (guard['fixture_feature'] in features and set(features) <= set(guard['allowed_fixture_features'])):
        return 'stock', guard['reason']
    if guard and not fixture_app_valid(fixture_app, guard):
        return 'stock', 'isolated UI requires --fixture-app pointing to a verified Debug simulator app'
    for name in features:
        if mapping[name]['tier'] == 'stock':
            return 'stock', name + ': ' + mapping[name].get('reason', 'stock required')
    # Explicit minimal never overrides a richer declared dependency.
    mode = 'app' if requested in ('app', 'slim') or any(mapping[f]['tier'] == 'app' for f in features) else 'minimal'
    if not pinned_binary_valid(binary, config):
        return 'stock', 'pinned SimSlim unavailable or checksum mismatch'
    profile = json.loads((ROOT / 'scripts' / config['profiles'][mode]).read_text())
    required = {c for f in features for c in mapping[f]['categories']}
    if not required.issubset(set(profile['except'])):
        return 'stock', 'profile does not preserve all declared feature dependencies'
    return mode, ('escalated to app-complete for declared feature dependencies' if mode == 'app' else 'declared local UI; minimal launch dependencies preserved')

def load_pool():
    if not POOL_PATH.is_file():
        raise RuntimeError('shared iOS simulator pool manager is not installed; no simulator changed')
    name = '_keinois_ios_pool'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, POOL_PATH)
        if spec is None or spec.loader is None:
            raise RuntimeError('shared iOS simulator pool manager could not be loaded')
        manager = importlib.util.module_from_spec(spec)
        sys.modules[name] = manager
        try:
            spec.loader.exec_module(manager)
        except Exception:
            del sys.modules[name]
            raise
    return sys.modules[name]


def validate_lease():
    lease = Path(os.environ['SIMSLIM_LEASE'])
    owner = json.loads((lease / 'owner.json').read_text())
    if (owner['udid'] != os.environ['SIMSLIM_UDID']
            or owner['mode'] != os.environ['SIMSLIM_MODE']
            or owner['repo'] != str(ROOT)):
        raise RuntimeError('lease ownership mismatch')
    os.kill(owner['pid'], 0)
    with (lease / 'lock').open('r') as check:
        try:
            fcntl.flock(check, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result = load_pool().Pool().validate_run(owner['task'], owner['token'], owner['udid'])
            if result is False:
                raise RuntimeError('shared simulator lease is not active')
            return
        raise RuntimeError('lease is not held by a running wrapper')


def pinned_binary_valid(binary, config):
    return binary.is_file() and hashlib.sha256(binary.read_bytes()).hexdigest() == config['binary_sha256']


def restore_stock(udid, binary, config, lease_dir, pass_fds=()):
    """A dirty/reused target must be observed as stock before stock work starts."""
    if not pinned_binary_valid(binary, config):
        raise RuntimeError('cannot restore stock without the pinned SimSlim binary')
    call([binary, 'off', udid], pass_fds=pass_fds)
    stock = lease_dir / 'stock.json'
    stock.write_text(json.dumps({'except': config['all_categories']}))
    call([binary, 'verify', udid, '--profile', stock], pass_fds=pass_fds)


def configure_mode(udid, mode, previous_profile, binary, config, profile_path, lease_dir, record_mode, pass_fds=()):
    desired_profile = ('stock' if mode == 'stock' else
                       mode + ':' + hashlib.sha256(profile_path.read_bytes()).hexdigest())
    if previous_profile == desired_profile:
        if mode == 'stock':
            return mode
        try:
            call([binary, 'verify', udid, '--profile', profile_path], pass_fds=pass_fds)
            return mode
        except subprocess.CalledProcessError:
            # Reconfirm a clean baseline rather than applying a profile over a dirty device.
            pass
    if previous_profile != 'stock':
        record_mode('dirty')
        restore_stock(udid, binary, config, lease_dir, pass_fds)
        record_mode('stock')
    if mode != 'stock':
        record_mode('dirty')
        try:
            call([binary, 'on', udid, '--profile', profile_path], pass_fds=pass_fds)
            call([binary, 'verify', udid, '--profile', profile_path], pass_fds=pass_fds)
        except subprocess.CalledProcessError:
            restore_stock(udid, binary, config, lease_dir, pass_fds)
            mode = desired_profile = 'stock'
            print('Slim failed; verified stock fallback', file=sys.stderr)
        record_mode(desired_profile)
    return mode


def child_environment(config, fixture_app, declared, udid, name, mode, lease, env, pass_fds=()):
    env.pop('SIMSLIM_FIXTURE_APP', None)
    guard = config.get('launch_guard')
    if guard:
        for key in [*guard['fixture_environment'], guard['fixture_run_id_environment']]:
            env.pop(key, None)
    if guard and guard['fixture_feature'] in declared and declared <= set(guard['allowed_fixture_features']) and fixture_app_valid(fixture_app, guard):
        # Install only the verified fixture binary on the leased device.
        call(['xcrun', 'simctl', 'install', udid, fixture_app.resolve()], pass_fds=pass_fds)
        env['SIMSLIM_FIXTURE_APP'] = str(fixture_app.resolve())
        env.update(guard['fixture_environment'])
        env[guard['fixture_run_id_environment']] = str(uuid.uuid4())
    env.update(SIMSLIM_UDID=udid, SIMSLIM_NAME=name, SIMSLIM_MODE=mode, SIMSLIM_LEASE=str(lease))
    return env


def run_in_pool(a, config, mode, reason, binary, profile_path, command):
    stopped = False

    def request_stop(*_):
        nonlocal stopped
        stopped = True

    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    old = [(signum, signal.signal(signum, request_stop)) for signum in signals]
    try:
        return run_with_lease(a, config, mode, reason, binary, profile_path, command, lambda: stopped)
    finally:
        for signum, handler in old:
            signal.signal(signum, handler)


def run_with_lease(a, config, mode, reason, binary, profile_path, command, cancelled):
    pool = load_pool().Pool()
    with tempfile.TemporaryDirectory(prefix='simulator-lease-') as lease_name:
        lease = Path(lease_name)
        with (lease / 'lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

            def prepare(run, env):
                uuid.UUID(run.udid)
                pass_fds = (run.lease_fd, lock.fileno())
                active_mode = configure_mode(run.udid, mode, run.profile, binary, config,
                                             profile_path, lease, run.mark_profile, pass_fds)
                actual_reason = reason if active_mode == mode else 'SimSlim failed; verified stock fallback'
                record = {'udid': run.udid, 'name': run.name, 'pid': os.getpid(), 'repo': str(ROOT),
                          'runtime': run.runtime, 'deviceType': run.device_type, 'mode': active_mode,
                          'features': a.features, 'reason': actual_reason, 'task': run.task, 'token': run.token}
                (lease / 'owner.json').write_text(json.dumps(record, indent=2) + '\n')
                print(f'Ownership record: {lease}/owner.json\nDedicated simulator: {run.udid}',
                      file=sys.stderr, flush=True)
                declared = {f.strip() for f in a.features.split(',') if f.strip()}
                child_environment(config, a.fixture_app, declared, run.udid, run.name,
                                  active_mode, lease, env, pass_fds)
                run.observe_mode(active_mode)
                summary = 'Stock' if active_mode == 'stock' else f'Slim verified ({active_mode})'
                print(f'Simulator mode actual: {summary}: {actual_reason}', file=sys.stderr, flush=True)
                # The shared lock and the compatibility lock both outlive the wrapper
                # if the child is still holding its inherited file descriptors.
                run.pass_fds.append(lock.fileno())

            return pool.run(a.task_id, command, runtime=a.runtime,
                            device_type=a.device_type, wait=a.wait, cancelled=cancelled, prepare=prepare,
                            eligible_specs=a.eligible_specs)


def constrain_xcodebuild(command):
    """Pin direct simulator Xcode work to this lease; disable XCTest cloning."""
    if not command:
        return command
    exe = Path(command[0]).name
    if exe == 'xcodebuild':
        start = 1
    elif exe == 'xcrun':
        indexes = [i for i, arg in enumerate(command[1:], 1) if Path(arg).name == 'xcodebuild']
        if not indexes:
            return command
        start = indexes[0] + 1
    else:
        return command

    args = command[start:]
    test_actions = {'test', 'test-without-building', 'build-for-testing'}
    is_test = bool(test_actions.intersection(args))
    canonical_destination = 'platform=iOS Simulator,id={udid}'
    exact_destinations = {canonical_destination, 'id={udid}'}
    single_worker = {'-parallel-testing-worker-count', '-maximum-parallel-testing-workers',
                     '-maximum-concurrent-test-simulator-destinations'}
    inspect = {'-destination', '-parallel-testing-enabled'} | single_worker
    flags = {}
    output = list(command[:start])
    i = 0
    while i < len(args):
        flag, equals, value = args[i].partition('=')
        i += 1
        if flag not in inspect:
            output.append(args[i-1])
            continue
        if flag in flags:
            raise RuntimeError(f'pass {flag} at most once for a pooled simulator')
        if not equals:
            if i == len(args):
                raise RuntimeError(f'missing value for {flag}')
            value = args[i]
            i += 1
        if flag == '-destination':
            if value not in exact_destinations:
                raise RuntimeError('xcodebuild destination must use the leased {udid} (no name, generic or other simulator)')
            value = canonical_destination
        elif flag == '-parallel-testing-enabled':
            if value.upper() != 'NO':
                raise RuntimeError('xcodebuild parallel simulator testing must be disabled within a pool lease')
            value = 'NO'
        elif value != '1':
            raise RuntimeError(f'{flag} must be 1 within a pool lease')
        flags[flag] = value
        output.extend((flag, value))
    if is_test and '-destination' not in flags:
        output.extend(('-destination', canonical_destination))
    if is_test and '-parallel-testing-enabled' not in flags:
        output.extend(('-parallel-testing-enabled', 'NO'))
    return output

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mode', choices=['auto', 'minimal', 'app', 'stock', 'slim'], default='auto', help='auto chooses lightest sufficient tier; slim is a legacy alias for app')
    p.add_argument('--features', default='', help='required comma-separated task features; see simulator-policy.json; unknown/missing uses stock')
    p.add_argument('--task', '--task-id', dest='task_id', default=os.environ.get('KEINOIS_IOS_TASK_ID'), help='stable pool owner for this task (or KEINOIS_IOS_TASK_ID)')
    p.add_argument('--wait', type=float, default=900, help='seconds to wait for a pool slot and boot capacity')
    p.add_argument('--runtime', help='exact available iOS runtime identifier; omit both device flags for a standard pooled iPhone')
    p.add_argument('--device-type', help='exact iPhone/iPad device type identifier; omit both device flags for a standard pooled iPhone')
    p.add_argument('--simslim', type=Path, default=Path.home()/'.local/lib/simslim/0.12.2/simslim')
    p.add_argument('--fixture-app', type=Path, help='verified existing Debug simulator bundle for isolated UI; built without booting a device')
    p.add_argument('--plan', action='store_true', help='print selection without acquiring or changing a simulator')
    p.add_argument('command', nargs=argparse.REMAINDER, help='-- command; {udid} is replaced in each argument')
    a = p.parse_args()
    command = a.command[1:] if a.command[:1] == ['--'] else a.command
    if not command and not a.plan:
        p.error('a command is required')
    config = json.loads(POLICY.read_text())
    a.eligible_specs = STANDARD_IPHONE_SPECS if a.runtime is None and a.device_type is None else None
    if a.eligible_specs is None:
        a.runtime = a.runtime if a.runtime is not None else DEFAULT_RUNTIME
        a.device_type = a.device_type if a.device_type is not None else DEFAULT_DEVICE_TYPE
    if a.runtime is not None and not a.runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
        p.error('only an explicit iOS runtime is supported')
    if a.device_type is not None and not a.device_type.startswith(('com.apple.CoreSimulator.SimDeviceType.iPhone-', 'com.apple.CoreSimulator.SimDeviceType.iPad-')):
        p.error('only an explicit iPhone/iPad device type is supported')
    binary = a.simslim.expanduser().resolve()
    mode, reason = choose_mode(a.mode, [f.strip() for f in a.features.split(',') if f.strip()], binary, config, a.fixture_app)
    profile_path = ROOT / 'scripts' / config['profiles'].get(mode, 'simulator-profile.json')
    if a.plan:
        print(json.dumps({'mode': mode, 'reason': reason, 'profile': str(profile_path) if mode != 'stock' else None}, indent=2))
        return 0
    if not math.isfinite(a.wait) or a.wait < 0:
        p.error('--wait must be a finite, nonnegative number of seconds')
    if not a.task_id:
        p.error('--task or KEINOIS_IOS_TASK_ID is required for simulator work')
    print(f'Simulator mode: {mode}: {reason}', file=sys.stderr, flush=True)
    return run_in_pool(a, config, mode, reason, binary, profile_path, constrain_xcodebuild(command))

if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['validate-lease']:
            validate_lease()
        else:
            sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Simulator task stopped: {error}', file=sys.stderr)
        sys.exit(1)
