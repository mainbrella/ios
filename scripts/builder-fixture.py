#!/usr/bin/env python3
"""Local, deterministic builder fixture for opt-in simulator UI tests.

Run on a free port: python3 scripts/builder-fixture.py --port 8790
No inference, cloud machines, or outbound network requests are made.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_ID = '11111111-1111-4111-8111-111111111111'
PREVIEW_HOST = 'a' * 48 + '.localhost'
PORT = 8787
USER = {'id': 'ios-builder-fixture', 'email': 'builder@example.test', 'name': 'Builder QA'}
STATE = {'app': None, 'started': 0, 'keys': {}, 'balanceCents': 492}
LOCK = threading.Lock()


def app_snapshot():
    with LOCK:
        if STATE['app'] is None:
            return None
        app = json.loads(json.dumps(STATE['app']))
        elapsed = time.monotonic() - STATE['started']
    turn = app['turns'][-1]
    finished = elapsed > 14
    turn['status'] = 'succeeded' if finished else 'running'
    turn['stage'] = 'Preview ready' if finished else 'Writing website' if elapsed > 5 else 'Planning website'
    turn['activity'] = [{'id': 'thought', 'type': 'message', 'text': 'I’ll build a frog field guide with species profiles and pond photography.' if elapsed > 3 else 'I’ll build a frog field guide', 'status': 'succeeded'}]
    if elapsed > 5:
        turn['activity'].append({'id': 'write', 'type': 'tool', 'text': 'Write src/App.tsx', 'status': 'succeeded' if finished else 'running'})
    if finished:
        turn['summary'] = 'Your frog website is ready. Try the preview, then tell me what to change.'
        app['activeTurnId'] = None
        app['preview'] = {'id': 'preview-' + str(app['revision']), 'url': f'http://{PREVIEW_HOST}:{PORT}/preview/', 'expiresAt': (time.time() + 900) * 1000}
    return app


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
            app = app_snapshot()
            return self.send_json({'apps': [app] if app else []})
        if self.path == f'/build/apps/{APP_ID}':
            return self.send_json({'app': app_snapshot()})
        if self.path == f'/build/apps/{APP_ID}/events':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                while True:
                    app = app_snapshot()
                    self.wfile.write(('event: app\ndata: ' + json.dumps({'app': app}) + '\n\n').encode())
                    self.wfile.flush()
                    if not app['activeTurnId']:
                        break
                    time.sleep(0.75)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        if self.path == '/preview/':
            body = b'''<!doctype html><html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Frog Field Guide</title><style>body{margin:0;background:#eef2dc;color:#173d27;font:18px Georgia,serif}main{padding:48px 28px;max-width:720px;margin:auto}h1{font-size:46px;font-weight:normal}p{line-height:1.6}button{background:#173d27;color:white;border:0;padding:16px;border-radius:6px;font-size:16px}</style><main><p>THE POND JOURNAL</p><h1>Frog Field Guide</h1><p>Meet the small creatures making a big splash. Discover pond life, frog calls, and the habitats they call home.</p><button onclick="this.textContent='Spring peeper, tree frog, bullfrog'">Meet the frogs</button></main></html>'''
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_json({'error': 'not_found'}, 404)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        body = json.loads(raw) if raw else {}
        if self.path == '/auth/email':
            with LOCK:
                STATE.update(app=None, started=0, keys={}, balanceCents=0 if body.get('email') == 'zero@example.test' else 492)
            return self.send_json({'user': USER}, headers={'Set-Cookie': 'mainbrella_session=' + 'a' * 64 + '; Path=/; HttpOnly; Secure; Max-Age=2592000'})
        if self.path == '/auth/logout':
            return self.send_json({'ok': True})
        if self.path not in ['/build/apps', f'/build/apps/{APP_ID}/turns']:
            return self.send_json({'error': 'not_found'}, 404)
        if self.headers.get('Origin') != 'https://mainbrella.com' or not self.headers.get('Cookie', '').startswith('mainbrella_session='):
            return self.send_json({'error': 'not_authenticated'}, 401)
        key = self.headers.get('Idempotency-Key')
        if not key:
            return self.send_json({'error': 'invalid_request'}, 400)
        previous = app_snapshot()
        with LOCK:
            if key in STATE['keys']:
                return self.send_json({'app': STATE['keys'][key]})
            revision = previous['revision'] + 1 if previous else 1
            turn = {'id': f'turn-{revision}', 'prompt': body.get('prompt', ''), 'mode': body.get('mode', 'build'), 'status': 'running', 'stage': 'Planning website', 'summary': None, 'error': None, 'model': body.get('model', '@cf/fixture'), 'activity': []}
            STATE['app'] = {'id': APP_ID, 'name': 'Frog Field Guide', 'prompt': 'Make me a website about frogs', 'revision': revision, 'activeTurnId': turn['id'], 'preview': None, 'turns': (previous['turns'] if previous else []) + [turn]}
            STATE['started'] = time.monotonic()
            STATE['keys'][key] = STATE['app']
        self.send_json({'app': app_snapshot()}, 201)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    PORT = parser.parse_args().port
    if not 1024 <= PORT <= 65535:
        parser.error('--port must be between 1024 and 65535')
    print(f'Builder fixture listening at http://localhost:{PORT}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
