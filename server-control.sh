#!/bin/bash

# Script de controle do servidor GTNH V4 para Oracle Linux
# Uso: ./server-control.sh [start|stop|restart|kill|status|logs|console|...]

SERVER_DIR="/home/ubuntu/GTNH_V4"
SCREEN_NAME="gtnh"
BACKUP_SCREEN_NAME="gtnh_backup"
RESTART_LOG="$SERVER_DIR/restart.log"
BACKUP_LOG="$SERVER_DIR/backup.log"
AUTOBACKUP_SCRIPT="$SERVER_DIR/autobackup.py"
SERVER_JAR="lwjgl3ify-forgePatches.jar"

# Verifica se o comando screen está instalado
check_screen() {
    if ! command -v screen &> /dev/null; then
        echo "Comando 'screen' não encontrado!"
        echo "Instale com: sudo apt install screen"
        exit 1
    fi
}

# Verifica se uma screen session específica existe (match exato)
screen_exists() {
    screen -list 2>/dev/null | grep -qE "[0-9]+\.$1[[:space:]]"
}

# Encontra PIDs do processo Java do servidor
find_server_pids() {
    pgrep -f "$SERVER_JAR" 2>/dev/null
}

# Encontra PIDs do run.sh
find_runner_pids() {
    pgrep -f "run.sh" 2>/dev/null | grep -v $$ 2>/dev/null
}

case "$1" in
    start)
        check_screen
        # Verifica se já há um servidor rodando
        if screen_exists "$SCREEN_NAME"; then
            echo "Servidor já está rodando na screen '$SCREEN_NAME'!"
            exit 1
        fi
        server_pids=$(find_server_pids)
        if [ -n "$server_pids" ]; then
            echo "AVISO: Processo Java do servidor já está rodando (PID: $server_pids)"
            echo "Use '$0 stop' para parar primeiro, ou '$0 kill' para forçar."
            exit 1
        fi
        echo "Iniciando servidor GTNH V4..."
        cd "$SERVER_DIR"
        screen -dmS "$SCREEN_NAME" ./run.sh
        sleep 3
        if screen_exists "$SCREEN_NAME"; then
            echo "Servidor iniciado em screen session '$SCREEN_NAME'"
            echo "Use 'screen -r $SCREEN_NAME' para acessar o console"
            echo "Use Ctrl+A, D para desconectar sem parar o servidor"
        else
            echo "ERRO: Falha ao iniciar servidor. Verifique os logs."
        fi
        ;;

    stop)
        echo "Parando servidor..."

        # Tenta enviar comando stop via screen
        if screen_exists "$SCREEN_NAME"; then
            screen -S "$SCREEN_NAME" -X stuff "stop$(printf '\r')"
            echo "Comando 'stop' enviado ao servidor. Aguardando encerramento..."

            # Aguarda até 30 segundos pelo encerramento gracioso
            for i in $(seq 1 30); do
                if [ -z "$(find_server_pids)" ]; then
                    echo "Servidor encerrado graciosamente."
                    break
                fi
                sleep 1
            done
        else
            echo "Screen session '$SCREEN_NAME' não encontrada."
        fi

        # Se o Java ainda está rodando, mata o processo
        server_pids=$(find_server_pids)
        if [ -n "$server_pids" ]; then
            echo "Processo Java ainda rodando (PID: $server_pids). Enviando SIGTERM..."
            kill $server_pids 2>/dev/null
            sleep 5
            # Se ainda não morreu, SIGKILL
            server_pids=$(find_server_pids)
            if [ -n "$server_pids" ]; then
                echo "Processo não respondeu. Enviando SIGKILL..."
                kill -9 $server_pids 2>/dev/null
                sleep 2
            fi
        fi

        # Mata o run.sh para evitar auto-restart
        runner_pids=$(find_runner_pids)
        if [ -n "$runner_pids" ]; then
            echo "Parando script de auto-restart (PID: $runner_pids)..."
            kill $runner_pids 2>/dev/null
            sleep 2
        fi

        # Limpa screen session se ainda existir
        if screen_exists "$SCREEN_NAME"; then
            screen -S "$SCREEN_NAME" -X quit 2>/dev/null
        fi

        # Verificação final
        if [ -z "$(find_server_pids)" ]; then
            echo "Servidor parado com sucesso."
        else
            echo "ERRO: Não foi possível parar o servidor. Use '$0 kill' para forçar."
        fi
        ;;

    kill)
        echo "Forcando encerramento do servidor..."
        server_pids=$(find_server_pids)
        runner_pids=$(find_runner_pids)
        if [ -n "$server_pids" ] || [ -n "$runner_pids" ]; then
            [ -n "$runner_pids" ] && kill -9 $runner_pids 2>/dev/null
            [ -n "$server_pids" ] && kill -9 $server_pids 2>/dev/null
            sleep 2
            if screen_exists "$SCREEN_NAME"; then
                screen -S "$SCREEN_NAME" -X quit 2>/dev/null
            fi
            echo "Processos eliminados."
        else
            echo "Nenhum processo do servidor encontrado."
        fi
        ;;

    restart)
        echo "Reiniciando servidor..."
        $0 stop
        sleep 5
        $0 start
        ;;

    status)
        echo "=== Status do Servidor ==="
        server_pids=$(find_server_pids)
        has_screen=false
        screen_exists "$SCREEN_NAME" && has_screen=true

        if [ -n "$server_pids" ]; then
            echo "Servidor RODANDO (PID: $server_pids)"
            if $has_screen; then
                echo "Screen session: $SCREEN_NAME"
            else
                echo "AVISO: Rodando SEM screen session (iniciado manualmente?)"
            fi
            if ss -tuln | grep -q ":25565"; then
                echo "Porta 25565 ABERTA"
            else
                echo "Porta 25565 FECHADA (servidor ainda iniciando?)"
            fi
        elif $has_screen; then
            echo "Screen session '$SCREEN_NAME' existe mas Java não está rodando"
            echo "O servidor pode estar iniciando ou ter crashado"
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
        if [ -f "$SERVER_DIR/logs/latest.log" ]; then
            tail -20 "$SERVER_DIR/logs/latest.log"
        else
            echo "Log do servidor não encontrado"
        fi
        ;;

    console)
        if screen_exists "$SCREEN_NAME"; then
            echo "Conectando ao console do servidor..."
            echo "Use Ctrl+A, D para desconectar sem parar o servidor"
            screen -r "$SCREEN_NAME"
        else
            echo "Servidor não está rodando em screen!"
            server_pids=$(find_server_pids)
            if [ -n "$server_pids" ]; then
                echo "AVISO: Servidor rodando fora do screen (PID: $server_pids)"
                echo "Use '$0 stop' para parar e '$0 start' para iniciar via screen."
            fi
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
        cd "$SERVER_DIR"
        if screen_exists "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup já está rodando!"
            exit 1
        fi

        if [ ! -f "$AUTOBACKUP_SCRIPT" ]; then
            echo "Script de backup não encontrado: $AUTOBACKUP_SCRIPT"
            exit 1
        fi

        screen -dmS "$BACKUP_SCREEN_NAME" python3 "$AUTOBACKUP_SCRIPT"
        sleep 2

        if screen_exists "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup iniciado em screen session '$BACKUP_SCREEN_NAME'"
            echo "Use 'screen -r $BACKUP_SCREEN_NAME' para acessar o console do backup"
        else
            echo "Falha ao iniciar sistema de backup"
        fi
        ;;

    backup-stop)
        echo "Parando sistema de backup..."
        if screen_exists "$BACKUP_SCREEN_NAME"; then
            screen -S "$BACKUP_SCREEN_NAME" -X quit
            sleep 2

            if ! screen_exists "$BACKUP_SCREEN_NAME"; then
                echo "Sistema de backup parado"
            else
                echo "Falha ao parar sistema de backup"
            fi
        else
            echo "Sistema de backup não está rodando"
        fi
        # Mata processos de backup órfãos
        backup_pids=$(pgrep -f "autobackup.py" 2>/dev/null)
        if [ -n "$backup_pids" ]; then
            echo "Matando processos de backup órfãos (PID: $backup_pids)..."
            kill $backup_pids 2>/dev/null
        fi
        ;;

    backup-status)
        echo "=== Status do Sistema de Backup ==="
        if screen_exists "$BACKUP_SCREEN_NAME"; then
            echo "Sistema de backup RODANDO (session: $BACKUP_SCREEN_NAME)"
        else
            backup_pids=$(pgrep -f "autobackup.py" 2>/dev/null)
            if [ -n "$backup_pids" ]; then
                echo "Sistema de backup RODANDO sem screen (PID: $backup_pids)"
            else
                echo "Sistema de backup PARADO"
            fi
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
        if screen_exists "$BACKUP_SCREEN_NAME"; then
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
        echo "Uso: $0 {start|stop|restart|kill|status|logs|console|clear-crashes|backup-start|backup-stop|backup-status|backup-logs|backup-console|start-all|stop-all|restart-all|status-all}"
        echo ""
        echo "Comandos do Servidor:"
        echo "  start         - Inicia o servidor"
        echo "  stop          - Para o servidor (gracioso + force)"
        echo "  kill          - Forca encerramento imediato"
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
