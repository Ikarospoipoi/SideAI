"""Local deterministic HTTP fixture; never uses or logs a real credential."""
import json, sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        data = json.dumps({'data': [{'id': 'fixture-vision'}]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if '/redirect/' in self.path:
            self.send_response(307); self.send_header('Location', '/must-not-follow'); self.end_headers(); return
        if '/unauthorized/' in self.path:
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error":{"message":"invalid fixture-key"}}'); return
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        if '/slow/' in self.path: time.sleep(3)
        if body.get('model') != 'fixture-vision':
            events = [{'error': {'message': 'model was not routed'}}]
        elif self.path.endswith('/responses'):
            events = [{'type': 'response.output_text.delta', 'delta': '你好🌿'}, {'type': 'response.completed', 'response': {'output': [{'content': [{'text': '你好🌿'}]}]}}]
        elif self.path.endswith('/messages'):
            if not self.headers.get('anthropic-version') or self.headers.get('x-api-key') != 'fixture-key':
                events = [{'type': 'error', 'error': {'message': 'missing auth or version'}}]
            else:
                events = [{'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': '你好🌿'}}, {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}}, {'type': 'message_stop'}]
        else:
            events = [{'choices': [{'delta': {'content': '你好🌿'}, 'finish_reason': None}]}, {'choices': [{'delta': {}, 'finish_reason': 'stop'}]}]
        if '/truncated/' in self.path: events = events[:1]
        try:
            for event in events:
                data = ('data: ' + json.dumps(event, ensure_ascii=False) + '\r\n\r\n').encode()
                for i in range(0, len(data), 3): self.wfile.write(data[i:i+3]); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
