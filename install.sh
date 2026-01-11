#!/bin/bash

# ============================================================
# Script d'installation automatique du Dashboard VM Control
# Pour PC principal (192.168.1.6)
# ============================================================

set -e

echo "============================================================"
echo "🚀 Installation Dashboard Kick Viewbot VM Control"
echo "============================================================"
echo ""

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Variables
INSTALL_DIR="$HOME/kick-vm-control"
VENV_DIR="$INSTALL_DIR/venv"

# Fonction pour afficher les messages
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Vérification Python
echo "Vérification des prérequis..."
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 n'est pas installé !"
    echo "Installe Python 3 avec : sudo apt install python3 python3-pip python3-venv"
    exit 1
fi
print_status "Python 3 trouvé : $(python3 --version)"

# Création du dossier
echo ""
echo "Création du dossier d'installation..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
print_status "Dossier créé : $INSTALL_DIR"

# Création du venv
echo ""
echo "Création de l'environnement virtuel Python..."
if [ -d "$VENV_DIR" ]; then
    print_warning "Venv existe déjà, suppression..."
    rm -rf "$VENV_DIR"
fi

python3 -m venv venv
source venv/bin/activate
print_status "Environnement virtuel créé"

# Installation des dépendances
echo ""
echo "Installation des dépendances Python..."
pip install --upgrade pip > /dev/null 2>&1
pip install flask flask-cors paramiko > /dev/null 2>&1
print_status "Dépendances installées : flask, flask-cors, paramiko"

# Création du fichier server.py
echo ""
echo "Création du serveur API..."

cat > server.py << 'EOFSERVER'
#!/usr/bin/env python3
"""
Serveur API pour contrôler les VMs Kali - Kick Viewbot
À exécuter sur ton PC principal (192.168.1.6)
"""

from flask import Flask, request, jsonify
from flask_cors import CORS
import paramiko
import threading
import time
import os
import re

app = Flask(__name__)
CORS(app)

# Configuration
VMS = [
    '192.168.1.101',
    '192.168.1.84',
    '192.168.1.4',
    '192.168.1.11',
    '192.168.1.182'
]

SSH_USER = 'kali'
SSH_PASS = 'kali'
SSH_PORT = 22

REMOTE_PROJECT_DIR = '/home/kali/Desktop/kick-viewbot-main'
LOCAL_KICK_SCRIPT = './kick.py'

vm_status = {}
vm_stats = {}

def ssh_connect(vm_ip):
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            vm_ip,
            port=SSH_PORT,
            username=SSH_USER,
            password=SSH_PASS,
            timeout=10,
            allow_agent=False,
            look_for_keys=False
        )
        return client
    except Exception as e:
        print(f"[ERROR] Connexion SSH à {vm_ip}: {e}")
        return None

def execute_ssh_command(vm_ip, command, timeout=30):
    client = ssh_connect(vm_ip)
    if not client:
        return None, f"Impossible de se connecter à {vm_ip}"
    
    try:
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
        output = stdout.read().decode('utf-8')
        error = stderr.read().decode('utf-8')
        return output, error
    except Exception as e:
        return None, str(e)
    finally:
        client.close()

def deploy_script_to_vm(vm_ip):
    try:
        client = ssh_connect(vm_ip)
        if not client:
            return False, f"Connexion impossible à {vm_ip}"
        
        sftp = client.open_sftp()
        
        try:
            sftp.stat(REMOTE_PROJECT_DIR)
        except:
            execute_ssh_command(vm_ip, f'mkdir -p {REMOTE_PROJECT_DIR}')
        
        if os.path.exists(LOCAL_KICK_SCRIPT):
            remote_kick = f'{REMOTE_PROJECT_DIR}/kick.py'
            sftp.put(LOCAL_KICK_SCRIPT, remote_kick)
            execute_ssh_command(vm_ip, f'chmod +x {remote_kick}')
        
        ensure_venv_content = '''#!/bin/bash
PROJECT="$HOME/Desktop/kick-viewbot-main"
VENV="$PROJECT/venv"
PY="$VENV/bin/python"
cd "$PROJECT" || exit 1
if [ -x "$PY" ] && "$PY" -c "import fake_useragent" >/dev/null 2>&1; then
    exit 0
fi
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install fake_useragent tls_client typing_extensions websockets
'''
        
        with open('/tmp/ensure_venv_tmp.sh', 'w') as f:
            f.write(ensure_venv_content)
        
        ensure_venv_path = f'{REMOTE_PROJECT_DIR}/ensure_venv.sh'
        sftp.put('/tmp/ensure_venv_tmp.sh', ensure_venv_path)
        execute_ssh_command(vm_ip, f'chmod +x {ensure_venv_path}')
        
        output, error = execute_ssh_command(vm_ip, f'cd {REMOTE_PROJECT_DIR} && bash ensure_venv.sh', timeout=120)
        
        sftp.close()
        client.close()
        
        return True, "Déploiement réussi"
    except Exception as e:
        return False, f"Erreur déploiement: {e}"

def start_script_on_vm(vm_ip, channel, viewers):
    try:
        execute_ssh_command(vm_ip, f'pkill -f "python.*kick.py"')
        time.sleep(1)
        
        input_script = f'''#!/bin/bash
cd {REMOTE_PROJECT_DIR}
source venv/bin/activate
echo -e "{channel}\\n{viewers}" | python kick.py > kick.log 2>&1 &
'''
        
        client = ssh_connect(vm_ip)
        if not client:
            return False, "Connexion impossible"
        
        sftp = client.open_sftp()
        start_script_path = f'{REMOTE_PROJECT_DIR}/start_kick.sh'
        
        with sftp.open(start_script_path, 'w') as f:
            f.write(input_script)
        
        execute_ssh_command(vm_ip, f'chmod +x {start_script_path}')
        output, error = execute_ssh_command(vm_ip, f'bash {start_script_path}')
        
        sftp.close()
        client.close()
        
        time.sleep(2)
        
        output, _ = execute_ssh_command(vm_ip, 'pgrep -f "python.*kick.py"')
        if output and output.strip():
            return True, "Script démarré avec succès"
        else:
            return False, f"Le script n'a pas démarré. Error: {error}"
    except Exception as e:
        return False, f"Erreur démarrage: {e}"

def stop_script_on_vm(vm_ip):
    try:
        output, error = execute_ssh_command(vm_ip, 'pkill -f "python.*kick.py"')
        time.sleep(1)
        
        check, _ = execute_ssh_command(vm_ip, 'pgrep -f "python.*kick.py"')
        if not check or not check.strip():
            return True, "Script arrêté"
        else:
            return False, "Le script tourne encore"
    except Exception as e:
        return False, f"Erreur arrêt: {e}"

def check_vm_status(vm_ip):
    try:
        output, _ = execute_ssh_command(vm_ip, 'pgrep -f "python.*kick.py"', timeout=5)
        
        if output and output.strip():
            status = 'running'
            log_output, _ = execute_ssh_command(vm_ip, f'tail -20 {REMOTE_PROJECT_DIR}/kick.log', timeout=5)
            stats = parse_stats_from_log(log_output)
            vm_stats[vm_ip] = stats
        else:
            status = 'stopped'
            vm_stats[vm_ip] = None
        
        vm_status[vm_ip] = status
        return status
    except:
        vm_status[vm_ip] = 'offline'
        return 'offline'

def parse_stats_from_log(log_text):
    if not log_text:
        return None
    
    stats = {
        'connections': 0,
        'viewers': 0,
        'pings': 0,
        'heartbeats': 0
    }
    
    try:
        connections_match = re.search(r'Connections:\s*(\d+)', log_text)
        viewers_match = re.search(r'Viewers:\s*(\d+)', log_text)
        pings_match = re.search(r'Pings:\s*(\d+)', log_text)
        heartbeats_match = re.search(r'Heartbeats:\s*(\d+)', log_text)
        
        if connections_match:
            stats['connections'] = int(connections_match.group(1))
        if viewers_match:
            stats['viewers'] = int(viewers_match.group(1))
        if pings_match:
            stats['pings'] = int(pings_match.group(1))
        if heartbeats_match:
            stats['heartbeats'] = int(heartbeats_match.group(1))
        
        return stats
    except:
        return stats

def status_monitor_thread():
    while True:
        for vm_ip in VMS:
            check_vm_status(vm_ip)
        time.sleep(10)

@app.route('/status', methods=['GET'])
def get_status():
    result = {}
    for vm_ip in VMS:
        result[vm_ip] = {
            'status': vm_status.get(vm_ip, 'unknown'),
            'stats': vm_stats.get(vm_ip)
        }
    return jsonify(result)

@app.route('/execute', methods=['POST'])
def execute_action():
    data = request.json
    action = data.get('action')
    vm_ip = data.get('vm_ip')
    channel = data.get('channel', '')
    viewers = data.get('viewers', 100)
    
    if action == 'deploy':
        results = []
        for ip in VMS:
            success, msg = deploy_script_to_vm(ip)
            results.append(f"{ip}: {msg}")
        return jsonify({
            'success': True,
            'message': 'Déploiement terminé\n' + '\n'.join(results)
        })
    
    elif action == 'start_all':
        results = []
        for ip in VMS:
            success, msg = start_script_on_vm(ip, channel, viewers)
            results.append(f"{ip}: {msg}")
        return jsonify({
            'success': True,
            'message': 'Démarrage sur toutes les VMs\n' + '\n'.join(results)
        })
    
    elif action == 'stop_all':
        results = []
        for ip in VMS:
            success, msg = stop_script_on_vm(ip)
            results.append(f"{ip}: {msg}")
        return jsonify({
            'success': True,
            'message': 'Arrêt sur toutes les VMs\n' + '\n'.join(results)
        })
    
    elif action == 'start' and vm_ip:
        success, msg = start_script_on_vm(vm_ip, channel, viewers)
        return jsonify({'success': success, 'message': msg})
    
    elif action == 'stop' and vm_ip:
        success, msg = stop_script_on_vm(vm_ip)
        return jsonify({'success': success, 'message': msg})
    
    else:
        return jsonify({'success': False, 'message': 'Action invalide'})

@app.route('/logs/<vm_ip>', methods=['GET'])
def get_logs(vm_ip):
    if vm_ip not in VMS:
        return jsonify({'error': 'VM invalide'}), 404
    
    output, error = execute_ssh_command(vm_ip, f'tail -100 {REMOTE_PROJECT_DIR}/kick.log')
    
    if output:
        logs = output.strip().split('\n')
        return jsonify({'logs': logs})
    else:
        return jsonify({'logs': [], 'error': error})

if __name__ == '__main__':
    print("=" * 60)
    print("🚀 Serveur API Kick Viewbot Control")
    print("=" * 60)
    print(f"Démarrage sur http://192.168.1.6:5000")
    print(f"VMs configurées: {len(VMS)}")
    print("=" * 60)
    
    monitor = threading.Thread(target=status_monitor_thread, daemon=True)
    monitor.start()
    
    app.run(host='0.0.0.0', port=5000, debug=False)
EOFSERVER

chmod +x server.py
print_status "Serveur créé : server.py"

# Création du script de démarrage
echo ""
echo "Création du script de démarrage..."

cat > start.sh << 'EOFSTART'
#!/bin/bash
cd ~/kick-vm-control
source venv/bin/activate
python server.py
EOFSTART

chmod +x start.sh
print_status "Script de démarrage créé : start.sh"

# Création d'un README
cat > README.md << 'EOFREADME'
# Kick Viewbot VM Control

## Démarrage rapide

1. Place ton fichier `kick.py` dans ce dossier
2. Lance le serveur : `./start.sh`
3. Utilise l'API sur http://192.168.1.6:5000

## Commandes utiles

```bash
# Vérifier le statut des VMs
curl http://192.168.1.6:5000/status

# Déployer le script
curl -X POST http://192.168.1.6:5000/execute \
  -H "Content-Type: application/json" \
  -d '{"action": "deploy"}'

# Démarrer toutes les VMs
curl -X POST http://192.168.1.6:5000/execute \
  -H "Content-Type: application/json" \
  -d '{"action": "start_all", "channel": "xqc", "viewers": 100}'

# Arrêter toutes les VMs
curl -X POST http://192.168.1.6:5000/execute \
  -H "Content-Type: application/json" \
  -d '{"action": "stop_all"}'
```

## VMs configurées

- 192.168.1.101
- 192.168.1.84
- 192.168.1.4
- 192.168.1.11
- 192.168.1.182
EOFREADME

print_status "README créé"

# Résumé final
echo ""
echo "============================================================"
echo -e "${GREEN}✓ Installation terminée avec succès !${NC}"
echo "============================================================"
echo ""
echo "📁 Dossier d'installation : $INSTALL_DIR"
echo ""
echo "Prochaines étapes :"
echo ""
echo "1. Copie ton fichier kick.py :"
echo "   ${YELLOW}cp /chemin/vers/kick.py $INSTALL_DIR/kick.py${NC}"
echo ""
echo "2. Lance le serveur :"
echo "   ${YELLOW}cd $INSTALL_DIR && ./start.sh${NC}"
echo ""
echo "3. Test le serveur :"
echo "   ${YELLOW}curl http://192.168.1.6:5000/status${NC}"
echo ""
echo "============================================================"
echo ""