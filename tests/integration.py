#!/usr/bin/env python3
"""Integration tests for vw-autofill against a live Vaultwarden + bw.

Self-contained: starts an in-process TLS terminator in front of the
HTTP Vaultwarden test instance (bw refuses http:// servers), logs in
to grab a session token, then drives two daemon lifetimes:

    A) start with BW_SESSION env  → eager rule load
    B) start with no session      → locked state → UnlockWith over D-Bus

Run with:
    nimble integration

Prerequisites (system state, not bootstrapped here):
    - Vaultwarden listening at 127.0.0.1:8765
    - cert.pem + key.pem in /tmp/vw-test-data (server's data folder)
    - `bw` CLI, `dbus-run-session`, python-dbus, python-gobject
    - The daemon built at ../bin/vw_autofill

If DBUS_SESSION_BUS_ADDRESS isn't set, we re-exec ourselves under
`dbus-run-session` so the test always runs against an isolated bus.
"""

import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path

# --- hardcoded test fixtures -------------------------------------------------
# These are throwaway test credentials for a local Vaultwarden test
# server that holds nothing real and isn't reachable from the
# internet. They live with the test code on purpose; the runner needs
# them and there's nothing here worth protecting.
EMAIL = 'dev@example.test'
PASS  = 'CorrectHorseBatteryStaple-1234!'

BACKEND_ADDR = ('127.0.0.1', 8765)
PROXY_ADDR   = ('127.0.0.1', 8766)
PROXY_URL    = f'https://{PROXY_ADDR[0]}:{PROXY_ADDR[1]}'

CERT_DIR = Path(os.environ.get('VW_TEST_CERT_DIR', '/tmp/vw-test-data'))
CERT = CERT_DIR / 'cert.pem'
KEY  = CERT_DIR / 'key.pem'

ROOT = Path(__file__).resolve().parent.parent
BIN  = ROOT / 'bin' / 'vw_autofill'
LOG  = Path('/tmp/vw-int-daemon.log')

# --- isolated session bus ----------------------------------------------------
if 'DBUS_SESSION_BUS_ADDRESS' not in os.environ:
	os.execvp('dbus-run-session',
	          ['dbus-run-session', '--', sys.executable, __file__, *sys.argv[1:]])

# dbus only imports cleanly under a bus; defer until after the re-exec
import dbus  # noqa: E402
import dbus.exceptions  # noqa: E402


# --- TLS terminator (background thread) --------------------------------------
def _relay(src, dst):
	try:
		while True:
			data = src.recv(65536)
			if not data: break
			dst.sendall(data)
	except OSError:
		pass
	finally:
		for s in (src, dst):
			try: s.shutdown(socket.SHUT_RDWR)
			except OSError: pass
			try: s.close()
			except OSError: pass


def _accept_loop(srv, ctx):
	while True:
		raw, _ = srv.accept()
		try:
			tls = ctx.wrap_socket(raw, server_side=True)
		except (ssl.SSLError, OSError):
			try: raw.close()
			except OSError: pass
			continue
		try:
			up = socket.create_connection(BACKEND_ADDR)
		except OSError:
			tls.close(); continue
		threading.Thread(target=_relay, args=(tls, up), daemon=True).start()
		threading.Thread(target=_relay, args=(up, tls), daemon=True).start()


def start_proxy():
	# Bind in the main thread so a port-in-use error can't get swallowed
	# in a worker — we'd otherwise silently piggyback on a stale proxy
	# left over from a previous run.
	ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
	ctx.load_cert_chain(CERT, KEY)
	srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	try:
		srv.bind(PROXY_ADDR)
	except OSError as e:
		raise RuntimeError(
			f'cannot bind {PROXY_URL}: {e}. '
			f'Is another instance of these tests already running?') from e
	srv.listen(32)
	threading.Thread(target=_accept_loop, args=(srv, ctx), daemon=True).start()


# --- bw -----------------------------------------------------------------------
def bw_env(extra=None):
	env = {**os.environ, 'NODE_TLS_REJECT_UNAUTHORIZED': '0'}
	if extra: env.update(extra)
	return env


def bw_login() -> str:
	subprocess.run(['bw', 'config', 'server', PROXY_URL],
	               env=bw_env(), capture_output=True, check=False)
	# Always start clean: `bw login` errors if we're already authed and
	# there's no other way to recover a session token from existing state.
	subprocess.run(['bw', 'logout'], env=bw_env(), capture_output=True, check=False)
	r = subprocess.run(['bw', 'login', EMAIL, PASS, '--raw'],
	                   env=bw_env(), capture_output=True, text=True)
	token = r.stdout.strip()
	if r.returncode != 0 or len(token) < 60:
		raise RuntimeError(f'bw login failed (rc={r.returncode}, len={len(token)})\n'
		                   f'stderr: {r.stderr}')
	return token


# --- daemon lifecycle ---------------------------------------------------------
BUS_NAME  = 'org.vwautofill.Daemon'
OBJ_PATH  = '/org/vwautofill/Daemon'
IFACE     = 'org.vwautofill.Daemon1'


def wait_for_bus_name(timeout=10.0):
	bus = dbus.SessionBus()
	dbus_proxy = bus.get_object('org.freedesktop.DBus', '/org/freedesktop/DBus')
	deadline = time.time() + timeout
	while time.time() < deadline:
		try:
			names = list(dbus_proxy.ListNames(dbus_interface='org.freedesktop.DBus') or [])
			if BUS_NAME in names:
				return True
		except dbus.exceptions.DBusException:
			pass
		time.sleep(0.25)
	return False


def start_daemon(session: str | None):
	LOG.write_text('')
	env = bw_env({
		'BW_SESSION':       session or '',
		'VW_AUTOFILL_LOG':  str(LOG),
		'YDOTOOL_SOCKET':   '/tmp/.fake_ydotool',
		'TERMINAL':         '/bin/false',
	})
	p = subprocess.Popen([str(BIN), 'daemon'], env=env,
	                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
	if not wait_for_bus_name():
		try: p.terminate()
		except OSError: pass
		out = p.stdout.read().decode(errors='replace') if p.stdout else ''
		raise RuntimeError(f'daemon never claimed bus name.\n{out}')
	return p


def stop_daemon(p):
	if p and p.poll() is None:
		p.terminate()
		try: p.wait(timeout=5)
		except subprocess.TimeoutExpired:
			p.kill(); p.wait()


# --- D-Bus helpers ------------------------------------------------------------
def iface():
	bus = dbus.SessionBus()
	obj = bus.get_object(BUS_NAME, OBJ_PATH)
	return dbus.Interface(obj, IFACE)


def cli(*args):
	"""Run a vw-autofill subcommand; return CompletedProcess."""
	return subprocess.run([str(BIN), *args], env=bw_env(),
	                      capture_output=True, text=True)


def status_json():
	r = cli('status')
	assert r.returncode == 0, f'status exit {r.returncode}: {r.stderr}'
	return json.loads(r.stdout)


def assert_dbus_error(method, *args, contains: str):
	try:
		getattr(iface(), method)(*args)
	except dbus.exceptions.DBusException as e:
		msg = (e.get_dbus_message() or str(e)).lower()
		assert contains.lower() in msg, f'{method} raised {msg!r}, want {contains!r}'
		return
	raise AssertionError(f'{method} did not raise — expected error containing {contains!r}')


# --- test runner -------------------------------------------------------------
class Suite:
	def __init__(self, name: str):
		self.name = name
		self.passed = 0
		self.failed: list[str] = []
		print(f'===== {name} =====')

	def case(self, desc: str, fn):
		try:
			fn()
		except (AssertionError, dbus.exceptions.DBusException) as e:
			self.failed.append(desc)
			print(f'  FAIL: {desc} ({type(e).__name__}: {e})')
		except Exception as e:
			self.failed.append(desc)
			print(f'  FAIL: {desc} ({type(e).__name__}: {e})')
		else:
			self.passed += 1
			print(f'  PASS: {desc}')


# --- cases: Lifetime A (env-unlocked) -----------------------------------------
def run_lifetime_a(session: str, suite: Suite, daemon):
	def t_introspect():
		assert cli('introspect').returncode == 0

	def t_unlock_method_in_xml():
		assert 'UnlockWith' in cli('introspect').stdout

	def t_every_method_in_xml():
		xml = cli('introspect').stdout
		for m in ['WindowActivated', 'Fill', 'LastWindow', 'Reload',
		         'ListItems', 'AddUriToItem', 'ListRules', 'Status',
		         'UnlockWith', 'Log', 'Introspect']:
			assert f'name="{m}"' in xml, f'missing {m}'

	def t_status_shape():
		d = status_json()
		assert d['rules'] >= 2, d
		assert d['vault']['status'] == 'unlocked', d

	def t_list_shows_rules():
		out = cli('list').stdout
		assert 'linapp://firefox' in out
		assert 'linapp://openconnect' in out
		assert 'app://' in out

	def t_reload():
		assert 'reloaded' in cli('reload').stdout

	def t_match_banking():
		iface().WindowActivated('/usr/bin/firefox', 'Online Banking', 'X')
		time.sleep(0.2)
		d = status_json()
		assert d['last_window']['exe'] == '/usr/bin/firefox', d
		assert d['last_match'] == 'Banking', d

	def t_fill_no_crash():
		try: iface().Fill()
		except dbus.exceptions.DBusException: pass
		time.sleep(0.2)
		assert daemon.poll() is None, 'daemon died on Fill'

	def t_no_match():
		iface().WindowActivated('/usr/bin/no-such', 'whatever', 'X')
		time.sleep(0.2)
		assert status_json()['last_match'] is None

	def t_f5_auto_mode():
		iface().WindowActivated('/usr/bin/openconnect', 'F5 VPN connecting', 'X')
		time.sleep(0.2)
		assert status_json()['last_match'] == 'F5 VPN'

	suite.case('introspect succeeds', t_introspect)
	suite.case('introspect lists UnlockWith (NEW)', t_unlock_method_in_xml)
	suite.case('introspect lists every dispatched method', t_every_method_in_xml)
	suite.case('Status JSON has rules + vault.status unlocked', t_status_shape)
	suite.case('list shows 3 rule URIs from the test vault', t_list_shows_rules)
	suite.case('reload returns rule count', t_reload)
	suite.case('WindowActivated(Online Banking) matches Banking rule', t_match_banking)
	suite.case('Fill on matched window does not crash daemon', t_fill_no_crash)
	suite.case('no-match window leaves last_match null', t_no_match)
	suite.case('F5 auto-mode rule matches openconnect+F5 VPN title', t_f5_auto_mode)


# --- cases: Lifetime B (locked → UnlockWith) ----------------------------------
def run_lifetime_b(session: str, suite: Suite, daemon):
	def t_locked_status():
		d = status_json()
		assert d['vault'] == 'locked', d
		assert d['rules'] == 0, d

	def t_locked_reload():
		assert 'vault is locked' in cli('reload').stderr.lower() + cli('reload').stdout.lower()

	def t_locked_list_items():
		assert_dbus_error('ListItems', contains='vault is locked')

	def t_locked_add_uri():
		assert_dbus_error('AddUriToItem', 'deadbeef', 'linapp://x',
		                  contains='vault is locked')

	def t_window_activated_while_locked():
		iface().WindowActivated('/usr/bin/firefox', 'Sign in', 'X')
		time.sleep(0.2)
		d = status_json()
		assert d['last_window']['exe'] == '/usr/bin/firefox', d
		assert d['last_match'] is None, d

	def t_unlock_empty():
		assert_dbus_error('UnlockWith', '', contains='empty token')

	def t_unlock_bogus():
		assert_dbus_error('UnlockWith', 'not-a-real-session',
		                  contains='unlockwith failed')

	def t_unlock_valid():
		n = int(iface().UnlockWith(session))
		assert n >= 2, n
		d = status_json()
		assert d['rules'] >= 2, d
		assert d['vault']['status'] == 'unlocked', d

	def t_post_unlock_reload():
		assert 'reloaded' in cli('reload').stdout

	def t_post_unlock_match():
		iface().WindowActivated('/usr/bin/firefox', 'Online Banking', 'X')
		time.sleep(0.2)
		assert status_json()['last_match'] == 'Banking'

	suite.case('locked Status JSON has vault=locked + rules=0', t_locked_status)
	suite.case('locked Reload returns D-Bus error', t_locked_reload)
	suite.case('locked ListItems returns D-Bus error', t_locked_list_items)
	suite.case('locked AddUriToItem returns D-Bus error', t_locked_add_uri)
	suite.case('WindowActivated works while locked (no match)', t_window_activated_while_locked)
	suite.case('UnlockWith empty token returns error', t_unlock_empty)
	suite.case('UnlockWith bogus token returns error', t_unlock_bogus)
	suite.case('UnlockWith valid token populates rules + unlocks', t_unlock_valid)
	suite.case('post-unlock Reload now works', t_post_unlock_reload)
	suite.case('post-unlock WindowActivated re-matches', t_post_unlock_match)


# --- main --------------------------------------------------------------------
def main() -> int:
	if not BIN.exists():
		print(f"missing {BIN} — run 'nimble build' first", file=sys.stderr)
		return 2
	for p in (CERT, KEY):
		if not p.is_file():
			print(f'missing {p} — Vaultwarden cert/key not where tests expect them.\n'
			      f'Override with VW_TEST_CERT_DIR.', file=sys.stderr)
			return 2

	start_proxy()
	session = bw_login()

	a = Suite('Lifetime A: unlocked-from-env')
	daemon = start_daemon(session)
	try: run_lifetime_a(session, a, daemon)
	finally: stop_daemon(daemon)

	print()
	b = Suite('Lifetime B: locked → UnlockWith')
	daemon = start_daemon(None)
	try: run_lifetime_b(session, b, daemon)
	finally: stop_daemon(daemon)

	total_pass = a.passed + b.passed
	total_fail = len(a.failed) + len(b.failed)
	print()
	print(f'===== {total_pass} passed, {total_fail} failed =====')
	if total_fail:
		for d in a.failed + b.failed:
			print(f'  - {d}')
		print()
		print('===== daemon log tail =====')
		try: print('\n'.join(LOG.read_text().splitlines()[-40:]))
		except OSError: pass
		return 1
	return 0


if __name__ == '__main__':
	sys.exit(main())
