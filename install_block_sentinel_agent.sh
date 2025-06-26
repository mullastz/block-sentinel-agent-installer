#!/bin/bash

echo "[*] Installing Block Sentinel Agent..."

# 1. Make sure Python and pip are installed
if ! command -v python3 &> /dev/null; then
    echo "[!] Python3 is not installed. Please install it first."
    exit 1
fi

if ! command -v pip3 &> /dev/null; then
    echo "[!] pip3 is not installed. Please install it first."
    exit 1
fi

# 2. Install required Python packages
echo "[*] Installing required Python packages..."
pip3 install requests pymongo psycopg2-binary mysql-connector-python

# 3. Clone or copy agent code
echo "[*] Setting up agent code..."
AGENT_DIR="block_sentinel_agent"
mkdir -p "$AGENT_DIR"

# Assume you have monitoring_engine.py and hook_agent_middleware.py ready
# You can also host these in a GitHub repo and use `git clone`

cat <<EOF > $AGENT_DIR/monitoring_engine.py
import psycopg2
import mysql.connector
from pymongo import MongoClient
import threading
import time
import logging
import requests
from datetime import datetime

logging.basicConfig(
    format='[%(asctime)s] %(levelname)s - %(message)s',
    level=logging.INFO
)

class MongoDBConnector:
    def __init__(self, config):
        self.config = config
        self.client = MongoClient(**config)
        self.db = self.client[config['database']]

    def list_tables(self, db_name):
        return self.db.list_collection_names()

    def list_users(self):
        admin_db = self.client['admin']
        users_info = admin_db.command("usersInfo")
        return [user['user'] for user in users_info.get('users', [])]

class PostgresConnector:
    def __init__(self, config):
        self.config = config
        self.conn = psycopg2.connect(**config)

    def list_tables(self, db_name):
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'public'
            """)
            return [row[0] for row in cur.fetchall()]

    def list_users(self):
        with self.conn.cursor() as cur:
            cur.execute("SELECT usename FROM pg_user")
            return [row[0] for row in cur.fetchall()]

class MySQLConnector:
    def __init__(self, config):
        self.config = config
        self.conn = mysql.connector.connect(**config)

    def list_tables(self, db_name):
        with self.conn.cursor() as cur:
            cur.execute("SHOW TABLES")
            return [row[0] for row in cur.fetchall()]

    def list_users(self):
        with self.conn.cursor() as cur:
            cur.execute("SELECT User FROM mysql.user")
            return [row[0] for row in cur.fetchall()]

class MonitoringAgent:
    def __init__(self, system_id, backend_url, db_configs: dict, poll_interval=60):
        self.system_id = system_id
        self.backend_url = backend_url.rstrip('/')
        self.db_configs = db_configs
        self.poll_interval = poll_interval
        self.running = True

        self.db_connectors = {}
        for db_type, cfg in db_configs.items():
            if db_type == 'PostgreSQL':
                self.db_connectors[db_type] = PostgresConnector(cfg)
            elif db_type == 'MySQL':
                self.db_connectors[db_type] = MySQLConnector(cfg)
            elif db_type == 'MongoDB':
                self.db_connectors[db_type] = MongoDBConnector(cfg)
            elif db_type == 'MSSQL':
                self.db_connectors[db_type] = MySQLConnector(cfg)  # or create MSSQLConnector

        self.known_tables = {}
        self.known_users = {}

    def _send_events(self, events):
        if not events:
            return
        headers = {
            'Content-Type': 'application/json',
        }
        try:
            # Send to anomaly analysis endpoint
            url = f"{self.backend_url}/auditlog/analyze/"
            resp = requests.post(url, headers=headers, json=events, timeout=10)
            resp.raise_for_status()
            logging.info(f"Sent {len(events)} events for anomaly analysis successfully")
        except Exception as e:
            logging.error(f"Failed to send events for anomaly analysis: {e}")

    def _build_event(self, event_type, description, user=None, severity='INFO', metadata=None, db_type=None, table=None):
        event = {
            'system_id': self.system_id,
            'user': user,
            'event_type': event_type,
            'description': description,
            'source': 'MONITOR_AGENT',
            'severity': severity,
            'timestamp': datetime.utcnow().isoformat(),
            'metadata': metadata or {},
        }
        if db_type:
            event['metadata']['db_type'] = db_type
        if table:
            event['metadata']['table'] = table
        return event

    def _monitor_db(self, db_type, connector):
        target_db = self.db_configs[db_type].get('database')
        self.known_tables[db_type] = set()
        self.known_users[db_type] = set()

        while self.running:
            try:
                current_tables = set(connector.list_tables(target_db))
                known_tables = self.known_tables[db_type]
                added_tables = current_tables - known_tables
                removed_tables = known_tables - current_tables

                events = []

                for tbl in added_tables:
                    events.append(self._build_event('NewTableCreated', f"Table '{tbl}' created in database '{target_db}'", db_type=db_type, table=tbl))
                for tbl in removed_tables:
                    events.append(self._build_event('TableDeleted', f"Table '{tbl}' deleted from database '{target_db}'", db_type=db_type, table=tbl))

                current_users = set(connector.list_users())
                known_users = self.known_users[db_type]
                added_users = current_users - known_users
                removed_users = known_users - current_users

                for user in added_users:
                    events.append(self._build_event('DBUserCreated', f"Database user '{user}' created", db_type=db_type))
                for user in removed_users:
                    events.append(self._build_event('DBUserDeleted', f"Database user '{user}' deleted", db_type=db_type))

                self.known_tables[db_type] = current_tables
                self.known_users[db_type] = current_users

                if events:
                    self._send_events(events)

            except Exception as e:
                logging.error(f"Error monitoring {db_type} DB: {e}")

            time.sleep(self.poll_interval)

    def _run_monitor_db(self):
        threads = []
        for db_type, connector in self.db_connectors.items():
            t = threading.Thread(target=self._monitor_db, args=(db_type, connector), daemon=True)
            t.start()
            threads.append(t)

        for t in threads:
            t.join()

    def run(self):
        logging.info(f"Starting MonitoringAgent for system {self.system_id}")
        threading.Thread(target=self._run_monitor_db, daemon=True).start()

        while self.running:
            try:
                resp = requests.get(f"{self.backend_url}/health-check/{self.system_id}/", timeout=5)
                if resp.status_code == 200:
                    logging.info(f"System {self.system_id} is alive")
                else:
                    logging.warning(f"Health check returned {resp.status_code}")
            except Exception as e:
                logging.error(f"Health check failed: {e}")
            time.sleep(300)

def start_monitoring_agent(system_id, backend_url, db_configs, poll_interval=60):
    agent = MonitoringAgent(system_id, backend_url, db_configs, poll_interval)
    thread = threading.Thread(target=agent.run, daemon=True)
    thread.start()
    return agent

EOF

cat <<EOF > $AGENT_DIR/hook_agent_middleware.py
import json
import threading
import requests
from django.utils.deprecation import MiddlewareMixin
from datetime import datetime

ANOMALY_ENGINE_URL = 'http://12.0.0.1:8000/auditlog/analyze/'  # Endpoint for anomaly analysis
SAFE_EVENT_URL = 'http://12.0.0.1:8000/auditlog/monitoring/events/'  # Endpoint to log safe events
REGISTERED_SYSTEM_ID = 'SYS-XXXXXX'  # Inject dynamically in production

class HookAgentMiddleware(MiddlewareMixin):
    def process_request(self, request):
        try:
            request_data = {
                "system_id": REGISTERED_SYSTEM_ID,
                "timestamp": datetime.utcnow().isoformat(),
                "method": request.method,
                "path": request.path,
                "user_agent": request.META.get('HTTP_USER_AGENT', ''),
                "ip_address": self._get_client_ip(request),
                "query_params": request.GET.dict(),
                "post_data": request.POST.dict(),
                "raw_body": self._get_raw_body(request),
            }

            threading.Thread(target=self._handle_event, args=(request_data,), daemon=True).start()
        except Exception as e:
            print(f"[HookAgentMiddleware] Error processing request: {e}")

    def _handle_event(self, data):
        try:
            # Reformat to standard MonitoredEvent structure
            event_payload = {
                "system_id": data["system_id"],
                "user": None,
                "event_type": "HTTP_REQUEST",
                "description": f"Request to {data['path']}",
                "source": "AGENT",
                "severity": "INFO",
                "timestamp": data["timestamp"],
                "metadata": {
                    "method": data["method"],
                    "path": data["path"],
                    "user_agent": data["user_agent"],
                    "ip": data["ip_address"],
                    "query_params": data["query_params"],
                    "post_data": data["post_data"],
                    "raw_body": data["raw_body"]
                }
            }

            headers = {'Content-Type': 'application/json'}
            resp = requests.post(ANOMALY_ENGINE_URL, headers=headers, json=event_payload, timeout=5)

            if resp.status_code == 200:
                result = resp.json()
                if result.get("anomaly", False):
                    print(f"[HookAgent] 🚨 Anomaly detected: {result.get('message', '')}")
                else:
                    self._save_safe_event(event_payload)
            else:
                print(f"[HookAgent] Unexpected analyzer response code: {resp.status_code}")
        except Exception as e:
            print(f"[HookAgent] Analyzer communication failed: {e}")

    def _save_safe_event(self, data):
        safe_event = {
            "system_id": data["system_id"],
            "user": None,
            "event_type": "HTTP_REQUEST",
            "description": f"Safe request to {data['path']} from {data['ip_address']}",
            "source": "AGENT",
            "severity": "INFO",
            "timestamp": data["timestamp"],
            "metadata": {
                "method": data["method"],
                "user_agent": data["user_agent"],
                "query_params": data["query_params"],
                "post_data": data["post_data"],
                "raw_body": data["raw_body"],
            }
        }

        try:
            headers = {'Content-Type': 'application/json'}
            requests.post(SAFE_EVENT_URL, headers=headers, data=json.dumps(safe_event), timeout=5)
        except Exception as e:
            print(f"[HookAgent] Failed to save safe event: {e}")

    def _get_client_ip(self, request):
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0]
        return request.META.get('REMOTE_ADDR')

    def _get_raw_body(self, request):
        try:
            if request.body:
                body = request.body.decode('utf-8')
                return body if len(body) < 1000 else '[TRUNCATED]'
        except Exception:
            return '[UNREADABLE]'
        return ''

EOF

# 4. Copy middleware to Django middleware directory (adjust path as needed)
echo "[*] Copying agent files to Django project..."
DJANGO_PROJECT_PATH="./"  # Update to actual project root if needed
cp $AGENT_DIR/hook_agent_middleware.py $DJANGO_PROJECT_PATH

# 5. Add middleware to Django settings.py automatically (if not added)
MIDDLEWARE_LINE="    'hook_agent_middleware.HookAgentMiddleware',"
SETTINGS_FILE="$DJANGO_PROJECT_PATH/settings.py"

if grep -q "HookAgentMiddleware" "$SETTINGS_FILE"; then
    echo "[✓] Middleware already added to settings.py"
else
    echo "[*] Adding HookAgentMiddleware to settings.py"
    sed -i "/MIDDLEWARE = \[/a $MIDDLEWARE_LINE" "$SETTINGS_FILE"
fi

# 6. Restart Django (development server)
echo "[*] Restarting Django dev server (you may need to restart manually if using gunicorn/uwsgi)..."

echo "[✓] Block Sentinel Agent installed successfully."
