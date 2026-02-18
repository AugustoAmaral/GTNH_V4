from time import sleep
import os
import subprocess
from datetime import datetime
import logging
import sys
import signal

# Configurações do backup
CONFIG = {
    'backup_interval': 3600,  # 1 hora em segundos
    'log_file': 'backup.log',
    'last_update_file': 'lastUpdate.txt',
    'max_retries': 3,
    'retry_delay': 30
}

# Configurar o logging
logging.basicConfig(
    filename=CONFIG['log_file'],
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# Adicionar handler para console também
console = logging.StreamHandler()
console.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
console.setFormatter(formatter)
logging.getLogger('').addHandler(console)

def setup_gitignore():
    """Configura o arquivo .gitignore para ignorar logs de backup"""
    gitignore_entries = ['backup.log', '*.pyc', '__pycache__/']

    if not os.path.exists('.gitignore'):
        with open('.gitignore', 'w') as f:
            for entry in gitignore_entries:
                f.write(f'{entry}\n')
        logging.info(".gitignore criado com entradas de backup")
    else:
        with open('.gitignore', 'r') as f:
            content = f.read()

        missing_entries = [entry for entry in gitignore_entries if entry not in content]
        if missing_entries:
            with open('.gitignore', 'a') as f:
                f.write('\n')
                for entry in missing_entries:
                    f.write(f'{entry}\n')
            logging.info(f"Adicionadas entradas ao .gitignore: {missing_entries}")

def check_git_repository():
    """Verifica se estamos em um repositório git válido"""
    try:
        result = subprocess.run(["git", "rev-parse", "--git-dir"],
                              capture_output=True, text=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def check_git_remote():
    """Verifica se existe um remote configurado"""
    try:
        result = subprocess.run(["git", "remote"],
                              capture_output=True, text=True, check=True)
        return bool(result.stdout.strip())
    except subprocess.CalledProcessError:
        return False

def has_changes():
    """Verifica se há alterações para commit no repositório"""
    try:
        # Adiciona todos os arquivos ao staging
        result = subprocess.run(["git", "add", "-A"],
                              capture_output=True, text=True, check=True)

        # Verifica se há alterações no staging usando git status
        result = subprocess.run(["git", "status", "--porcelain"],
                              capture_output=True, text=True, check=True)
        return bool(result.stdout.strip())
    except subprocess.CalledProcessError as e:
        logging.error(f"Erro ao verificar alterações: {e.stderr}")
        return False

def perform_backup(time_str):
    """Realiza o backup com retry e tratamento de erros"""
    for attempt in range(CONFIG['max_retries']):
        try:
            logging.info(f"Tentativa {attempt + 1} de backup")

            # Atualiza lastUpdate.txt
            with open(CONFIG['last_update_file'], "a") as f:
                f.write(f"Last update {time_str}\n")

            # Adiciona novamente (para incluir o lastUpdate.txt)
            subprocess.run(["git", "add", "-A"], check=True)

            # Commit das alterações
            commit_message = f'Auto backup - {time_str}'
            result = subprocess.run(
                ["git", "commit", "-m", commit_message],
                capture_output=True, text=True, check=True
            )
            logging.info(f"Commit realizado: {result.stdout.strip()}")

            # Push para o repositório remoto (se existir)
            if check_git_remote():
                push_result = subprocess.run(
                    ["git", "push"],
                    capture_output=True, text=True, check=True
                )
                logging.info(f"Push realizado: {push_result.stdout.strip()}")
            else:
                logging.warning("Nenhum remote configurado, apenas commit local realizado")

            logging.info("Backup realizado com sucesso")
            return True

        except subprocess.CalledProcessError as e:
            logging.error(f"Erro no backup (tentativa {attempt + 1}): {e.stderr}")
            if attempt < CONFIG['max_retries'] - 1:
                logging.info(f"Aguardando {CONFIG['retry_delay']}s antes da próxima tentativa")
                sleep(CONFIG['retry_delay'])
            else:
                logging.error("Máximo de tentativas excedido")
                return False
        except Exception as e:
            logging.error(f"Erro inesperado no backup: {str(e)}")
            return False

    return False

def signal_handler(signum, frame):
    """Handler para sinais de interrupção"""
    logging.info(f"Sinal {signum} recebido, encerrando script graciosamente")
    sys.exit(0)

def main():
    # Configurar handlers de sinal
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    logging.info("Script de backup iniciado")
    logging.info(f"Configurações: {CONFIG}")

    # Verificações iniciais
    if not check_git_repository():
        logging.error("Não é um repositório git válido")
        sys.exit(1)

    logging.info("Repositório git válido detectado")

    if not check_git_remote():
        logging.warning("Nenhum remote git configurado - apenas commits locais serão realizados")

    # Configurar .gitignore
    setup_gitignore()

    # Loop principal
    while True:
        try:
            my_date = datetime.now()
            time_str = my_date.strftime('%Y-%m-%dT%H:%M')

            logging.info(f"Verificando alterações em {time_str}")

            if has_changes():
                logging.info("Alterações detectadas, realizando backup")

                success = perform_backup(time_str)
                if not success:
                    logging.error("Falha ao realizar backup")
            else:
                logging.info("Nenhuma alteração detectada, pulando backup")
                print(f"[{time_str}] Nenhuma alteração detectada")

            # Espera antes da próxima verificação
            logging.info(f"Aguardando {CONFIG['backup_interval']}s até a próxima verificação")
            sleep(CONFIG['backup_interval'])

        except Exception as e:
            logging.error(f"Erro inesperado no loop principal: {str(e)}")
            sleep(60)  # Espera 1 minuto antes de tentar novamente

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logging.info("Script de backup encerrado pelo usuário (Ctrl+C)")
        sys.exit(0)
    except Exception as e:
        logging.error(f"Erro fatal no script de backup: {str(e)}")
        sys.exit(1)
