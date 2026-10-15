#!/usr/bin/env python3
"""Local, deterministic multi-session builder fixture for opt-in simulator tests.

Run on a free port: python3 scripts/builder-fixture.py --port 8790
No inference, cloud machines, or outbound network requests are made.
"""
import argparse
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_ID = '11111111-1111-4111-8111-111111111111'
PREVIEW_HOST = 'a' * 48 + '.localhost'
PORT = 8787
BUILD_SECONDS = 14
USER = {'id': 'ios-builder-fixture', 'email': 'builder@example.test', 'name': 'Builder QA'}
STATE = {'apps': {}, 'started': {}, 'startedEpoch': {}, 'keys': {}, 'balanceCents': 492}
LOCK = threading.RLock()


def app_snapshot(app_id):
    with LOCK:
        source = STATE['apps'].get(app_id)
        if source is None:
            return None
        app = json.loads(json.dumps(source))
        elapsed = time.monotonic() - STATE['started'].get(app_id, 0)
    turn = app['turns'][-1]
    finished = elapsed >= BUILD_SECONDS
    turn['status'] = 'succeeded' if finished else 'running'
    turn['stage'] = 'Preview ready' if finished else 'Writing website' if elapsed > 5 else 'Planning website'
    subject = 'birds' if 'bird' in app['prompt'].lower() else 'frogs'
    turn['activity'] = [{'id': 'thought', 'type': 'message', 'text': f'I’ll build a {subject} field guide with species profiles and habitat photography.' if elapsed > 3 else f'I’ll build a {subject} field guide', 'status': 'succeeded'}]
    if elapsed > 5:
        turn['activity'].append({'id': 'write', 'type': 'tool', 'text': 'Write src/App.tsx', 'status': 'succeeded' if finished else 'running'})
    if finished:
        turn['summary'] = f'Your {subject} website is ready. Try the preview, then tell me what to change.'
        app['activeTurnId'] = None
        with LOCK:
            expires_at = (STATE['startedEpoch'].get(app_id, time.time()) + BUILD_SECONDS + 900) * 1000
        app['preview'] = {'id': 'preview-' + str(app['revision']), 'url': f'http://{PREVIEW_HOST}:{PORT}/preview/', 'expiresAt': expires_at}
    return app


def app_summaries():
    with LOCK:
        ids = list(STATE['apps'])
    return [app_snapshot(app_id) for app_id in ids]


def app_name(prompt):
    if 'bird' in prompt.lower():
        return 'Bird Field Guide'
    return 'Frog Field Guide'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def send_json(self, value, status=200, headers=None):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_sse(self, event, value):
        self.wfile.write((f'event: {event}\ndata: ' + json.dumps(value) + '\n\n').encode())
        self.wfile.flush()

    def do_GET(self):
        self.path = self.path.split('?', 1)[0]
        if self.path == '/auth/me':
            return self.send_json({'user': USER})
        if self.path == '/capabilities':
            return self.send_json({'observability': {'activityWebSocket': False}})
        if self.path == '/containers':
            return self.send_json({'containers': []})
        if self.path == '/billing/balance':
            with LOCK:
                cents = STATE['balanceCents']
            return self.send_json({'balance': {'balanceCents': cents, 'availableBalanceCents': cents, 'currency': 'usd'}})
        if self.path == '/billing/apple/config':
            return self.send_json({'productId': 'MAINBRELLA_FIVE', 'appAccountToken': APP_ID, 'creditCents': 349, 'currency': 'usd'})
        if self.path == '/build/config':
            return self.send_json({'available': True, 'model': '@cf/fixture', 'models': [{'id': '@cf/fixture', 'name': 'Cloudflare model', 'efforts': ['low', 'high'], 'defaultEffort': 'low'}], 'maxApps': 50, 'aiBilling': 'prepaid'})
        if self.path == '/build/apps':
            return self.send_json({'apps': app_summaries()})
        if self.path == '/build/events':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'close')
            self.end_headers()
            deadline = time.monotonic() + 55
            previous = None
            previous_apps = {}
            try:
                while time.monotonic() < deadline:
                    apps = app_summaries()
                    current = json.dumps(apps, sort_keys=True)
                    if current != previous:
                        self.send_sse('apps', {'apps': apps})
                        current_apps = {app['id']: app for app in apps}
                        for app in apps:
                            prior = previous_apps.get(app['id'])
                            if app['activeTurnId'] or (prior is not None and prior['activeTurnId'] and not app['activeTurnId']):
                                self.send_sse('app', {'app': app})
                        previous_apps = current_apps
                        previous = current
                    time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            self.close_connection = True
            return
        if self.path == f'/build/apps/{APP_ID}/events':
            return self.serve_app_events(APP_ID)
        if self.path.startswith('/build/apps/') and self.path.endswith('/events'):
            app_id = self.path[len('/build/apps/'):-len('/events')].rstrip('/')
            return self.serve_app_events(app_id)
        if self.path.startswith('/build/apps/'):
            app_id = self.path.rsplit('/', 1)[-1]
            app = app_snapshot(app_id)
            return self.send_json({'app': app}, 200 if app else 404)
        if self.path == '/preview/':
            body = b'''<!doctype html><html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Frog Field Guide</title><style>body{margin:0;background:#eef2dc;color:#173d27;font:18px Georgia,serif}main{padding:48px 28px;max-width:720px;margin:auto}h1{font-size:46px;font-weight:normal}p{line-height:1.6}button{background:#173d27;color:white;border:0;padding:16px;border-radius:6px;font-size:16px}</style><main><p>THE POND JOURNAL</p><h1>Frog Field Guide</h1><p>Meet the small creatures making a big splash. Discover pond life, frog calls, and the habitats they call home.</p><button onclick="this.textContent='Spring peeper, tree frog, bullfrog'">Meet the frogs</button></main></html>'''
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_json({'error': 'not_found'}, 404)

    def serve_app_events(self, app_id):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            while True:
                app = app_snapshot(app_id)
                if app is None:
                    break
                self.send_sse('app', {'app': app})
                if not app['activeTurnId']:
                    break
                time.sleep(0.75)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw) if raw else {}
        if self.path == '/auth/email':
            with LOCK:
                STATE.update(apps={}, started={}, startedEpoch={}, keys={}, balanceCents=0 if body.get('email') == 'zero@example.test' else 492)
            return self.send_json({'user': USER}, headers={'Set-Cookie': 'mainbrella_session=' + 'a' * 64 + '; Path=/; HttpOnly; Secure; Max-Age=2592000'})
        if self.path == '/auth/logout':
            return self.send_json({'ok': True})
        if self.path != '/build/apps' and not (self.path.startswith('/build/apps/') and self.path.endswith('/turns')):
            return self.send_json({'error': 'not_found'}, 404)
        if self.headers.get('Origin') != 'https://mainbrella.com' or not self.headers.get('Cookie', '').startswith('mainbrella_session='):
            return self.send_json({'error': 'not_authenticated'}, 401)
        key = self.headers.get('Idempotency-Key')
        if not key:
            return self.send_json({'error': 'invalid_request'}, 400)
        prompt = body.get('prompt', '')
        with LOCK:
            if self.path == '/build/apps':
                idempotency_scope = ('create', key)
                if idempotency_scope in STATE['keys']:
                    return self.send_json(STATE['keys'][idempotency_scope]['response'])
                app_id = APP_ID if not STATE['apps'] else str(uuid.uuid4())
                revision = 1
                turns = []
                title_prompt = prompt or 'Make me a website about frogs'
                app = {'id': app_id, 'name': app_name(title_prompt), 'prompt': title_prompt, 'revision': revision, 'activeTurnId': None, 'preview': None, 'turns': turns}
            else:
                app_id = self.path[len('/build/apps/'):-len('/turns')].rstrip('/')
                idempotency_scope = ('turn', app_id, key)
                if idempotency_scope in STATE['keys']:
                    return self.send_json(STATE['keys'][idempotency_scope]['response'])
                app = STATE['apps'].get(app_id)
                if app is None:
                    return self.send_json({'error': 'not_found'}, 404)
                previous = app_snapshot(app_id)
                if previous['activeTurnId']:
                    return self.send_json({'error': 'build_busy'}, 409)
                revision = previous['revision'] + 1
                turns = previous['turns']
                app = previous
            turn = {'id': f'turn-{revision}', 'prompt': prompt, 'mode': body.get('mode', 'build'), 'status': 'running', 'stage': 'Planning website', 'summary': None, 'error': None, 'model': body.get('model', '@cf/fixture'), 'activity': []}
            app.update(revision=revision, activeTurnId=turn['id'], preview=None, turns=turns + [turn])
            STATE['apps'][app_id] = app
            STATE['started'][app_id] = time.monotonic()
            STATE['startedEpoch'][app_id] = time.time()
            response = {'app': app_snapshot(app_id)}
            STATE['keys'][idempotency_scope] = {'appID': app_id, 'response': response}
        self.send_json(response, 201)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--build-seconds', type=float, default=14, help='seconds before a build completes')
    args = parser.parse_args()
    PORT = args.port
    BUILD_SECONDS = args.build_seconds
    if not 1024 <= PORT <= 65535:
        parser.error('--port must be between 1024 and 65535')
    if BUILD_SECONDS <= 0:
        parser.error('--build-seconds must be positive')
    print(f'Builder fixture listening at http://localhost:{PORT}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
