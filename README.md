🔐 Block Sentinel Agent Installer

This script installs the Monitoring Agent and Hook Agent Middleware required to connect an external system to the Block Sentinel security platform. These agents monitor database activity, detect system anomalies, and report events to the central backend.
📦 What It Does

    Installs Python dependencies (e.g. requests, psycopg2, mysql-connector-python, pymongo)

    Sets up monitoring_engine.py and starts it as a background agent

    Injects HookAgentMiddleware into the external Django system

    Configures system ID and backend URLs

    Starts automatic communication with Block Sentinel backend

⚙️ Requirements

    Python 3.8+

    pip

    curl or wget

    A Django project (for the Hook Agent)

    Internet access (to fetch this installer and Python packages)

🚀 Installation (One-time Step)

On the external system (Ubuntu/Debian recommended):

bash <(curl -sSL https://raw.githubusercontent.com/<your-username>/block-sentinel-agent-installer/main/install_agent.sh)

Or using wget:

bash <(wget -qO- https://raw.githubusercontent.com/<your-username>/block-sentinel-agent-installer/main/install_agent.sh)

🔁 After Installation

Once the script finishes:

    The external system will be ready to register with Block Sentinel

    You can now visit the Block Sentinel frontend and begin the registration process

    The backend will automatically recognize and control the monitoring agents

🧪 Testing It Locally (Optional)

To test before using on real external systems:

git clone https://github.com/<your-username>/block-sentinel-agent-installer.git
cd block-sentinel-agent-installer
chmod +x install_agent.sh
./install_agent.sh

📁 File Structure

block-sentinel-agent-installer/
│
├── install_agent.sh           # 🔧 Main agent installer
├── monitoring_engine.py       # 📡 DB and system monitoring agent
├── hook_agent_middleware.py   # 🛡️ Django middleware for HTTP monitoring
└── README.md                  # 📖 You're reading this!

📞 Support

For questions, contact the Block Sentinel team or open an issue on this GitHub repository.
