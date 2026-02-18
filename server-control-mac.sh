#!/bin/bash

# Script de controle do servidor GTNH V4 para macOS
# Uso: ./server-control-mac.sh [start|stop|restart|status|logs]

# Obtém o diretório do script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCREEN_NAME="gtnh"
BACKUP_SCREEN_NAME="gtnh_backup"
RESTART_LOG="$SCRIPT_DIR/restart.log"
BACKUP_LOG="$SCRIPT_DIR/backup.log"
AUTOBACKUP_SCRIPT="$SCRIPT_DIR/autobackup.py"

# Verifica se o comando screen está instalado
check_screen() {
    if ! command -v screen &> /dev/null; then
        echo "Comando 'screen' não encontrado!"
        echo "Instale com: brew install screen"
        exit 1
    fi
}

case "$1" in
    start)
        check_screen
        echo "Iniciando servidor GTNH V4..."
        cd "$SCRIPT_DIR"
        screen -dmS "$SCREEN_NAME" ./run-mac.sh
        sleep 3
        echo "Servidor iniciado em screen session '$SCREEN_NAME'"
        echo "Use 'screen -r $SCREEN_NAME' para acessar o console"
        echo "Use Ctrl+A, D para desconectar sem parar o servidor"
        ;;

    stop)
        echo "Parando servidor..."
        screen -S "$SCREEN_NAME" -X stuff "stop$(printf '\r')"
        echo "Comando stop enviado. Aguardando encerramento..."
        sleep 10
        if screen -list | grep -q "$SCREEN_NAME"; then
            echo "Servidor ainda rodando. Forcando encerramento..."
            screen -S "$SCREEN_NAME" -X quit
        fi
        echo "Servidor parado."
        ;;

    restart)
        echo "Reiniciando servidor..."
        $0 stop
        sleep 5
        $0 start
        ;;

    status)
        if screen -list | grep -q "$SCREEN_NAME"; then
            echo "Servidor RODANDO (session: $SCREEN_NAME)"
            if lsof -i :25565 | grep -q LISTEN; then
                echo "Porta 25565 ABERTA"
            else
                echo "Porta 25565 FECHADA (servidor ainda iniciando?)"
            fi
        else
            echo "Servidor PARADO"
        fi

        if [ -f "$RESTART_LOG" ]; then
            echo ""
            echo "Ultimas entradas do log de restart:"
            tail -5 "$RESTART_LOG"
        fi
        ;;

    logs)
        if [ -f "$RESTART_LOG" ]; then
            echo "=== Log de Restart ==="
            tail -20 "$RESTART_LOG"
            echo ""
        fi

        echo "=== Log do Servidor ==="
        if [ -f "$SCRIPT_DIR/logs/latest.log" ]; then
            tail -20 "$SCRIPT_DIR/logs/latest.log"
        else
            echo "Log do servidor não encontrado"
        fi
        ;;

    console)
        if screen -list | grep -q "$SCREEN_NAME"; then
            echo "Conectando ao console do servidor..."
            echo "Use Ctrl+A, D para desconectar sem parar o servidor"
            screen -r "$SCREEN_NAME"
        else
            echo "Servidor não está rodando!"
        fi
        ;;

    clear-crashes)
        if [ -f "$RESTART_LOG" ]; then
            rm "$RESTART_LOG"
            echo "Log de crashes limpo. Contador reiniciado."
        else
            echo "Nenhum log de crashes encontrado."
        fi
        ;;

    backup-start)
        check_screen
        echo "Iniciando sistema de backup automatico..."
        cd "$SCRIPT_DIR"
        if screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup já está rodando!"
            exit 1
        fi

        if [ ! -f "$AUTOBACKUP_SCRIPT" ]; then
            echo "Script de backup não encontrado: $AUTOBACKUP_SCRIPT"
            exit 1
        fi

        screen -dmS "$BACKUP_SCREEN_NAME" python3 "$AUTOBACKUP_SCRIPT"
        sleep 2

        if screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup iniciado em screen session '$BACKUP_SCREEN_NAME'"
            echo "Use 'screen -r $BACKUP_SCREEN_NAME' para acessar o console do backup"
        else
            echo "Falha ao iniciar sistema de backup"
        fi
        ;;

    backup-stop)
        echo "Parando sistema de backup..."
        if screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
            screen -S "$BACKUP_SCREEN_NAME" -X quit
            sleep 2

            if ! screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
                echo "Sistema de backup parado"
            else
                echo "Falha ao parar sistema de backup"
            fi
        else
            echo "Sistema de backup não está rodando"
        fi
        ;;

    backup-status)
        echo "=== Status do Sistema de Backup ==="
        if screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup RODANDO (session: $BACKUP_SCREEN_NAME)"
        else
            echo "Sistema de backup PARADO"
        fi

        if [ -f "$BACKUP_LOG" ]; then
            echo ""
            echo "Ultimas entradas do log de backup:"
            tail -5 "$BACKUP_LOG"
        fi
        ;;

    backup-logs)
        if [ -f "$BACKUP_LOG" ]; then
            echo "=== Log do Sistema de Backup ==="
            tail -20 "$BACKUP_LOG"
        else
            echo "Log de backup não encontrado: $BACKUP_LOG"
        fi
        ;;

    backup-console)
        if screen -list | grep -q "$BACKUP_SCREEN_NAME"; then
            echo "Conectando ao console do sistema de backup..."
            echo "Use Ctrl+A, D para desconectar sem parar o backup"
            screen -r "$BACKUP_SCREEN_NAME"
        else
            echo "Sistema de backup não está rodando!"
        fi
        ;;

    start-all)
        echo "Iniciando servidor e sistema de backup..."
        $0 start
        sleep 3
        $0 backup-start
        ;;

    stop-all)
        echo "Parando servidor e sistema de backup..."
        $0 backup-stop
        sleep 2
        $0 stop
        ;;

    restart-all)
        echo "Reiniciando servidor e sistema de backup..."
        $0 stop-all
        sleep 5
        $0 start-all
        ;;

    status-all)
        echo "=== Status Completo ==="
        echo ""
        echo "--- Servidor ---"
        $0 status
        echo ""
        echo "--- Backup ---"
        $0 backup-status
        ;;

    *)
        echo "Uso: $0 {start|stop|restart|status|logs|console|clear-crashes|backup-start|backup-stop|backup-status|backup-logs|backup-console|start-all|stop-all|restart-all|status-all}"
        echo ""
        echo "Comandos do Servidor:"
        echo "  start         - Inicia o servidor"
        echo "  stop          - Para o servidor"
        echo "  restart       - Reinicia o servidor"
        echo "  status        - Mostra status do servidor"
        echo "  logs          - Mostra logs recentes do servidor"
        echo "  console       - Conecta ao console do servidor"
        echo "  clear-crashes - Limpa contador de crashes"
        echo ""
        echo "Comandos do Backup:"
        echo "  backup-start  - Inicia sistema de backup automatico"
        echo "  backup-stop   - Para sistema de backup"
        echo "  backup-status - Mostra status do backup"
        echo "  backup-logs   - Mostra logs do backup"
        echo "  backup-console- Conecta ao console do backup"
        echo ""
        echo "Comandos Combinados:"
        echo "  start-all     - Inicia servidor e backup"
        echo "  stop-all      - Para servidor e backup"
        echo "  restart-all   - Reinicia servidor e backup"
        echo "  status-all    - Status completo (servidor + backup)"
        exit 1
        ;;
esac
